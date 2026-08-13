#!/usr/bin/env bash
# AIVM Brain statusline — ● model · 🧠 brain (role) · topic · limits
# ====================================================================
# Reads Claude Code's statusLine JSON on stdin (session_id, cwd, model.display_name,
# rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}). Claude Code exposes ONLY the
# account-wide 5h + weekly windows — there is no per-model rate-limit field — so the model NAME is
# shown and the two windows carry the % and reset time. resets_at (unix epoch s) omitted when absent.
#
# Modes:
#   aivm-statusline.sh            full line (model · brain · topic · limits)
#   aivm-statusline.sh --segment  ONLY the brain segment — used by the compose
#                                 wrapper to append onto a user's existing
#                                 statusline without replacing it.
#
# Brain data is CACHED-ONLY at render time: ~/.aivm/agent/status-cache.json,
# refreshed in a detached background curl (single-flight lock). A render NEVER
# waits on the network.
#
# THE CACHE IS AN AUTH-STATE RECORD, NOT AN IDENTITY BLOB (M1, 2026-08-13).
# It carries TWO clocks and a binding:
#   lastSuccessAt — advanced ONLY by a proven success; gates rendering the identity
#                   (IDENTITY_LEASE). No failure path may touch it.
#   lastAttemptAt — advanced by every completed attempt; gates the next refresh only.
#   host + keyFp  — the identity is valid ONLY for the (key, host) pair that proved it.
# A failed refresh therefore CANNOT make a stale identity look fresh. Degraded states are
# rendered honestly and distinctly: 401 "key rejected" / 403 "access denied" (identity ERASED,
# red) vs 404 "no brain API" / 5xx "brain unavailable" / timeout "offline" (identity retained
# under lease, amber). A wrong host and an outage MUST NEVER resemble a revoked key — reading a
# 503 as a dead key is the silent-death incident class of 2026-07-02.
# No key at all → no brain segment; the rest of the line still renders.
set -u

MODE="full"
[ "${1:-}" = "--segment" ] && MODE="segment"

AGENT_DIR="$HOME/.aivm/agent"
CACHE="$AGENT_DIR/status-cache.json"
LOCK="$AGENT_DIR/status-cache.refreshing"
TTL=300              # refresh interval — throttles ATTEMPTS (never freshness)
IDENTITY_LEASE=900   # 3x TTL: survives two missed refreshes, expires any silent failure in <=15m

input=$(cat 2>/dev/null || true)

parsed=$(printf '%s' "$input" | /usr/bin/env python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
except Exception:
    d = {}
print(d.get('session_id', ''))
print(d.get('cwd', '') or d.get('workspace', {}).get('current_dir', ''))
m = d.get('model', {}) or {}
print(m.get('display_name', '') or m.get('id', ''))
r = d.get('rate_limits', {}) or {}
f = r.get('five_hour') or {}
w = r.get('seven_day') or {}
print(f.get('used_percentage', ''))
print(w.get('used_percentage', ''))
print(f.get('resets_at', ''))
print(w.get('resets_at', ''))
" 2>/dev/null)

session_id=$(printf '%s' "$parsed" | sed -n '1p')
cwd=$(printf '%s' "$parsed" | sed -n '2p')
model=$(printf '%s' "$parsed" | sed -n '3p')
pct5=$(printf '%s' "$parsed" | sed -n '4p')
pct7=$(printf '%s' "$parsed" | sed -n '5p')
reset5=$(printf '%s' "$parsed" | sed -n '6p')
reset7=$(printf '%s' "$parsed" | sed -n '7p')

# ---- brain credentials (same resolution as the session-start hook) ----
BRAIN_URL="${AIVM_BRAIN_URL:-}"
[ -z "$BRAIN_URL" ] && BRAIN_URL="$(python3 -c "
import json,sys
try: print(json.load(open('$AGENT_DIR/config.json')).get('brainUrl',''))
except Exception: print('')" 2>/dev/null)"
BRAIN_URL="${BRAIN_URL:-https://brain.aivm.io}"
BRAIN_URL="${BRAIN_URL%/}"
AGENT_KEY="${AIVM_AGENT_KEY:-}"
[ -z "$AGENT_KEY" ] && AGENT_KEY="$(cat "$AGENT_DIR/agent.key" 2>/dev/null || true)"
brain_host="${BRAIN_URL#*://}"; brain_host="${brain_host%%/*}"

# ---- ONE decision function: read + bind + lease, in a single choke point ----
# Everything that can emit a role happens HERE. Bash below only formats. Five bash branches
# could not be audited for the invariant; one python block can. Paths and host go in by
# ENVIRONMENT and the key by STDIN — the key is never widened into argv, and no shell value is
# interpolated into python source. Spawn-neutral: replaces the old cache-read python.
# Skipped ENTIRELY when there is no key — a non-brain user pays nothing and sees nothing.
brain_state=""; brain_label=""; brain_role=""; brain_detail=""; brain_keyfp=""; brain_refresh=0
if [ -n "$AGENT_KEY" ]; then
  decision=$(printf '%s' "$AGENT_KEY" | AIVM_SL_CACHE="$CACHE" AIVM_SL_HOST="$brain_host" \
    AIVM_SL_TTL="$TTL" AIVM_SL_LEASE="$IDENTITY_LEASE" python3 -c '
import hashlib, json, os, re, sys, time

# Server strings are untrusted for TERMINAL output: strip control chars (incl. ESC/CSI — a hostile
# value could otherwise inject OSC sequences into a perpetually-rendered bar). Same strip as write.
clean = lambda s: re.sub(r"[\x00-\x1f\x7f\x9b]", "", str(s))[:64]

key  = sys.stdin.read().strip()
fp   = hashlib.sha256(key.encode("utf-8")).hexdigest()[:16] if key else ""
host = os.environ.get("AIVM_SL_HOST", "")
now  = int(time.time())
def envint(name, dflt):
    try: return int(os.environ.get(name, ""))
    except Exception: return dflt
ttl   = envint("AIVM_SL_TTL", 300)
lease = envint("AIVM_SL_LEASE", 900)

rec = {}
try:
    with open(os.environ["AIVM_SL_CACHE"]) as fh:
        rec = json.load(fh)
    if not isinstance(rec, dict):
        rec = {}
except Exception:
    rec = {}

# FAIL-CLOSED BINDING. A record speaks only for the (key, host) that produced it. v1 records
# (flat, no "v"), 0-byte files, unparseable files and mismatched bindings are ALL "never
# validated" — inferring a success we cannot prove is precisely the bug being fixed here.
bound = (rec.get("v") == 2 and rec.get("keyFp") == fp and rec.get("host") == host)
if not bound:
    rec = {}

STATES = ("ok", "unauthorized", "forbidden", "no_api", "unavailable", "unreachable")
# reason word, and whether an age (time since last PROOF) is meaningful for it.
REASON = {
    "ok":           ("stale", True),
    "unauthorized": ("key rejected", False),
    "forbidden":    ("access denied", False),
    "no_api":       ("no brain API", True),
    "unavailable":  ("brain unavailable", True),
    "unreachable":  ("offline", True),
}

state = clean(rec.get("state", ""))
if state not in STATES:
    state = ""
def as_int(v):
    return v if isinstance(v, int) and not isinstance(v, bool) else 0
last_ok  = as_int(rec.get("lastSuccessAt"))
last_try = as_int(rec.get("lastAttemptAt"))
ident    = rec.get("identity") if isinstance(rec.get("identity"), dict) else None

def age(t):
    d = max(0, now - t)
    if d < 60:    return str(d) + "s"
    if d < 3600:  return str(d // 60) + "m"
    if d < 86400: return str(d // 3600) + "h"
    return str(d // 86400) + "d"

label = ""
role = ""
detail = ""
if not state:
    # Nothing has ever COMPLETED for this (key, host). Never validated — say so, and give no age.
    state = "cold"
    detail = "unverified"
else:
    word, aged = REASON[state]
    # The lease is computed from lastSuccessAt, which no failure path can advance.
    if ident is not None and last_ok > 0 and (now - last_ok) <= lease:
        role = clean(ident.get("role", ""))
        # NOTE: /api/agent/context does not emit "org" today (verified 2026-08-13) — orgName is
        # therefore usually empty and the label falls back to the host. Render what is proven;
        # never invent an org. R2 makes the server emit it.
        label = clean(ident.get("orgName", "")) or host
        if state != "ok":
            detail = word + (" " + age(last_ok) if aged and last_ok else "")
    else:
        detail = word + (" " + age(last_ok) if aged and last_ok else "")
    if not role:
        label = ""
        role = ""

# Refresh scheduling reads the ATTEMPT clock ONLY. A failure may never extend freshness, but it
# must still throttle retries — otherwise a dead host turns into a curl on every single render.
# Unbound (cold / re-keyed / host changed) refreshes immediately so a new pair proves itself in
# one render instead of after TTL.
refresh = 1 if (not bound or (now - last_try) >= ttl) else 0

print(state)
print(label)
print(role)
print(detail)
print(fp)
print(refresh)
' 2>/dev/null)
  brain_state=$(printf '%s' "$decision" | sed -n '1p')
  brain_label=$(printf '%s' "$decision" | sed -n '2p')
  brain_role=$(printf '%s' "$decision" | sed -n '3p')
  brain_detail=$(printf '%s' "$decision" | sed -n '4p')
  brain_keyfp=$(printf '%s' "$decision" | sed -n '5p')
  brain_refresh=$(printf '%s' "$decision" | sed -n '6p')
  case "$brain_refresh" in (0|1) ;; (*) brain_refresh=0;; esac
fi

# GNU `stat -c` first — BSD stat fails it cleanly with no stdout; the reverse is NOT true
# (GNU `stat -f %m` "succeeds" printing filesystem info, poisoning the arithmetic below).
mtime_of() {
  m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0)
  case "$m" in (*[!0-9]*|"") m=0;; esac
  printf '%s' "$m"
}

# Single-flight guard: mkdir is ATOMIC (test-and-set in one syscall) — a plain touch-then-check
# races when two parallel sessions render in the same instant. A crashed refresh leaves the
# lock dir behind; it self-heals after TTL.
if [ -d "$LOCK" ]; then
  now=$(date +%s)
  [ $(($now - $(mtime_of "$LOCK"))) -ge "$TTL" ] && rmdir "$LOCK" 2>/dev/null
fi
mkdir -p "$AGENT_DIR" 2>/dev/null
if [ -n "$AGENT_KEY" ] && [ "$brain_refresh" = 1 ] && mkdir "$LOCK" 2>/dev/null; then
  (
    umask 077   # cache holds member/role/domains — keep it private on shared machines
    # Capture the HTTP STATUS. Without -w, `curl -sS` exits 0 on a 404/401/503 alike, so a
    # revoked key, a wrong host and an outage arrive indistinguishable. Same pattern as
    # hooks/session-start.sh:31-33 — deliberately the one convention, not a new invention.
    RAW=$(curl -sS --max-time 4 -w '\n%{http_code}' \
      -H "Authorization: Bearer $AGENT_KEY" "$BRAIN_URL/api/agent/context" 2>/dev/null); rc=$?
    CODE="${RAW##*$'\n'}"; BODY="${RAW%$'\n'*}"
    [ "$rc" != 0 ] && CODE="000"
    case "$CODE" in (''|*[!0-9]*) CODE="000";; esac
    # THE WRITER. Every completed attempt writes a FULL record through tmp + atomic rename.
    # The old failure-branch cache-mtime bump is GONE: it advanced the only clock in the
    # system by FAILING, which is exactly how a revoked key stayed "fresh" forever.
    printf '%s' "$BODY" | AIVM_SL_CACHE="$CACHE" AIVM_SL_TMP="$CACHE.tmp.$$" \
      AIVM_SL_HOST="$brain_host" AIVM_SL_KEYFP="$brain_keyfp" \
      AIVM_SL_CODE="$CODE" AIVM_SL_RC="$rc" python3 -c '
import json, os, re, sys, time

clean = lambda s: re.sub(r"[\x00-\x1f\x7f\x9b]", "", str(s))[:64]
now   = int(time.time())
code  = os.environ.get("AIVM_SL_CODE", "000")
rc    = os.environ.get("AIVM_SL_RC", "0")
cache = os.environ["AIVM_SL_CACHE"]
tmp   = os.environ["AIVM_SL_TMP"]
host  = os.environ.get("AIVM_SL_HOST", "")
fp    = os.environ.get("AIVM_SL_KEYFP", "")

prev = {}
try:
    with open(cache) as fh:
        p = json.load(fh)
    if isinstance(p, dict) and p.get("v") == 2 and p.get("keyFp") == fp and p.get("host") == host:
        prev = p
except Exception:
    prev = {}

identity = None
if code == "401":
    state = "unauthorized"
elif code == "403":
    state = "forbidden"
elif code == "000":
    state = "unreachable"
elif code == "429" or code.startswith("5"):
    # An outage is NOT a revoked key. 2026-07-02 silent-death class: never render this as red.
    state = "unavailable"
elif code.startswith("2"):
    state = "no_api"
    try:
        d = json.loads(sys.stdin.read())
        m = d.get("member") or {}
        o = d.get("org") if isinstance(d.get("org"), dict) else {}
        cand = {"memberName": clean(m.get("name", "")),
                "role": clean(m.get("role", "")),
                "orgName": clean((o or {}).get("name", "")),
                "domains": [clean(x) for x in (d.get("domains") or []) if isinstance(x, str)][:16]}
        if d.get("ok") and (cand["memberName"] or cand["role"]):
            identity = cand
            state = "ok"
    except Exception:
        pass
else:
    # 3xx, and every 4xx we did not name: this host is not serving our agent-context endpoint.
    # Same meaning as 404, and deliberately NOT the same as 401.
    state = "no_api"

def as_int(v):
    return v if isinstance(v, int) and not isinstance(v, bool) else 0

rec = {"v": 2, "host": host, "keyFp": fp, "state": state,
       "httpCode": int(code) if code.isdigit() else 0,
       "curlExit": int(rc) if rc.isdigit() else 0,
       "lastAttemptAt": now,
       # SINGLE WRITER for the proof clock. This is the whole invariant.
       "lastSuccessAt": now if state == "ok" else as_int(prev.get("lastSuccessAt"))}
if state == "ok":
    rec["identity"] = identity
elif state in ("unauthorized", "forbidden"):
    pass   # ERASURE ON CONTRADICTION: the rejected identity ceases to exist on disk.
else:
    pi = prev.get("identity")
    if isinstance(pi, dict):
        rec["identity"] = pi   # 404/5xx/timeout do not mean the key is bad — keep it, mark it.

with open(tmp, "w") as fh:
    json.dump(rec, fh)
os.replace(tmp, cache)
' 2>/dev/null
    rm -f "$CACHE.tmp.$$" 2>/dev/null
    rmdir "$LOCK" 2>/dev/null
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi

# ---- colors ----
BOLD=$'\033[1m'
ORANGE=$'\033[38;2;207;108;77m'
RED=$'\033[38;2;229;72;77m'
MUTED=$'\033[38;2;110;100;90m'
ACCENT=$'\033[38;2;138;168;136m'
CYAN=$'\033[38;2;96;165;250m'
RESET=$'\033[0m'
DOT="${ORANGE}●${RESET}"
SEP="  ${MUTED}·${RESET}  "

# ---- brain segment (shared by both modes) ----
# Pure formatting of what the decision function emitted. A role reaches here ONLY under a live
# lease against the current (key, host); there is no other source for one.
brain_seg=""
if [ -n "$AGENT_KEY" ]; then
  case "$brain_state" in
    unauthorized|forbidden) mark="$RED";;      # the key is the problem — re-key
    no_api|unavailable)     mark="$ORANGE";;   # the host/service is the problem — NOT the key
    *)                      mark="$MUTED";;    # offline / stale / unverified
  esac
  if [ -n "$brain_role" ]; then
    label="${brain_label:-$brain_host}"
    brain_seg="${CYAN}🧠 ${label} ${MUTED}(${brain_role})${RESET}"
    [ -n "$brain_detail" ] && brain_seg="${brain_seg} ${mark}⚠ ${brain_detail}${RESET}"
  elif [ -n "$brain_detail" ]; then
    brain_seg="${CYAN}🧠 ${brain_host}${RESET} ${MUTED}·${RESET} ${mark}${brain_detail}${RESET}"
  else
    brain_seg="${CYAN}🧠 ${brain_host}${RESET}"
  fi
fi
# no key at all → no segment (not a brain user; stay silent)

if [ "$MODE" = "segment" ]; then
  [ -n "$brain_seg" ] && printf '%s\n' "$brain_seg"
  exit 0
fi

# ---- full line ----
topic=""
topic_file="$HOME/.claude/session-topics/$session_id.txt"
if [ -n "$session_id" ] && [ -f "$topic_file" ]; then
  topic=$(head -n 1 "$topic_file" 2>/dev/null | tr -d '\r\n' | cut -c1-80)
fi
[ -z "$topic" ] && [ -n "$cwd" ] && topic=$(basename "$cwd" 2>/dev/null)

model_short=$(printf '%s' "$model" | cut -c1-22)

usage_color() {
  if [ "$1" -ge 90 ]; then printf '%s' "$RED"
  elif [ "$1" -ge 70 ]; then printf '%s' "$ORANGE"
  else printf '%s' "$ACCENT"; fi
}
# resets_at is unix epoch SECONDS (Claude Code docs). date -r (BSD) / date -d @ (GNU); omit if absent — never faked.
reset_hm() {
  case "$1" in (''|*[!0-9]*) return;; esac
  date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M 2>/dev/null || true
}
usage=""
r5=$(reset_hm "$reset5"); r7=$(reset_hm "$reset7")
case "$pct5" in (''|*[!0-9]*) ;; (*)
  seg5="5h ${pct5}%"; [ -n "$r5" ] && seg5="${seg5}${MUTED}→${r5}${RESET}$(usage_color "$pct5")"
  usage="$(usage_color "$pct5")${seg5}${RESET}";; esac
case "$pct7" in (''|*[!0-9]*) ;; (*)
  [ -n "$usage" ] && usage="${usage} ${MUTED}·${RESET} "
  seg7="wk ${pct7}%"; [ -n "$r7" ] && seg7="${seg7}${MUTED}→${r7}${RESET}$(usage_color "$pct7")"
  usage="${usage}$(usage_color "$pct7")${seg7}${RESET}";; esac

out=""
append() { [ -z "$1" ] && return; if [ -z "$out" ]; then out="$1"; else out="${out}${SEP}${1}"; fi; }
[ -n "$model_short" ] && append "${DOT} ${BOLD}${RED}${model_short}${RESET}"
append "$brain_seg"
[ -n "$topic" ] && append "${MUTED}${topic}${RESET}"
append "$usage"

printf '%s\n' "$out"
exit 0
