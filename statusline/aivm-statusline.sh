#!/usr/bin/env bash
# AIVM Brain statusline — ● model · 🧠 brain (role) · topic · limits
# ====================================================================
# Reads Claude Code's statusLine JSON on stdin (session_id, cwd,
# model.display_name, rate_limits.{five_hour,seven_day}.used_percentage).
#
# Modes:
#   aivm-statusline.sh            full line (model · brain · topic · limits)
#   aivm-statusline.sh --segment  ONLY the brain segment — used by the compose
#                                 wrapper to append onto a user's existing
#                                 statusline without replacing it.
#
# Brain data is CACHED-ONLY at render time: ~/.aivm/agent/status-cache.json,
# refreshed in a detached background curl (TTL 300s, single-flight lock).
# A render NEVER waits on the network. No key / no cache / unreachable →
# the brain segment is simply omitted; the rest still renders.
set -u

MODE="full"
[ "${1:-}" = "--segment" ] && MODE="segment"

AGENT_DIR="$HOME/.aivm/agent"
CACHE="$AGENT_DIR/status-cache.json"
LOCK="$AGENT_DIR/status-cache.refreshing"
TTL=300

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
print((r.get('five_hour') or {}).get('used_percentage', ''))
print((r.get('seven_day') or {}).get('used_percentage', ''))
" 2>/dev/null)

session_id=$(printf '%s' "$parsed" | sed -n '1p')
cwd=$(printf '%s' "$parsed" | sed -n '2p')
model=$(printf '%s' "$parsed" | sed -n '3p')
pct5=$(printf '%s' "$parsed" | sed -n '4p')
pct7=$(printf '%s' "$parsed" | sed -n '5p')

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

# ---- cached brain segment + detached single-flight refresh ----
brain_host="${BRAIN_URL#*://}"; brain_host="${brain_host%%/*}"
brain_role=""; brain_name=""
if [ -f "$CACHE" ]; then
  cache_read=$(python3 -c "
import json, re
# Same control-char strip as the write side — belt-and-braces for stale/foreign caches.
clean = lambda s: re.sub(r'[\x00-\x1f\x7f\x9b]', '', str(s))[:64]
try:
    c = json.load(open('$CACHE'))
    print(clean(c.get('role','')))
    print(clean(c.get('orgName','')))
except Exception:
    pass" 2>/dev/null)
  brain_role=$(printf '%s' "$cache_read" | sed -n '1p')
  brain_name=$(printf '%s' "$cache_read" | sed -n '2p')
fi

# GNU `stat -c` first — BSD stat fails it cleanly with no stdout; the reverse is NOT true
# (GNU `stat -f %m` "succeeds" printing filesystem info, poisoning the arithmetic below).
mtime_of() {
  m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0)
  case "$m" in (*[!0-9]*|"") m=0;; esac
  printf '%s' "$m"
}

cache_stale=1
if [ -f "$CACHE" ]; then
  now=$(date +%s)
  mtime=$(mtime_of "$CACHE")
  [ $((now - mtime)) -lt "$TTL" ] && cache_stale=0
fi
# Single-flight guard: mkdir is ATOMIC (test-and-set in one syscall) — a plain touch-then-check
# races when two parallel sessions render in the same instant. A crashed refresh leaves the
# lock dir behind; it self-heals after TTL.
if [ -d "$LOCK" ]; then
  now=$(date +%s)
  [ $(($now - $(mtime_of "$LOCK"))) -ge "$TTL" ] && rmdir "$LOCK" 2>/dev/null
fi
mkdir -p "$AGENT_DIR" 2>/dev/null
if [ -n "$AGENT_KEY" ] && [ "$cache_stale" = 1 ] && mkdir "$LOCK" 2>/dev/null; then
  (
    umask 077   # cache holds member/role/domains — keep it private on shared machines
    resp=$(curl -sS --max-time 4 -H "Authorization: Bearer $AGENT_KEY" \
      "$BRAIN_URL/api/agent/context" 2>/dev/null) || resp=""
    printf '%s' "$resp" | python3 -c "
import json, re, sys
# Server strings are untrusted for TERMINAL output: strip control chars (incl. ESC/CSI —
# a hostile value could otherwise inject OSC sequences into a perpetually-rendered bar).
clean = lambda s: re.sub(r'[\x00-\x1f\x7f\x9b]', '', str(s))[:64]
try:
    d = json.loads(sys.stdin.read())
    m = d.get('member') or {}
    out = {'memberName': clean(m.get('name','')), 'role': clean(m.get('role','')),
           'orgName': clean(d.get('org',{}).get('name','') if isinstance(d.get('org'), dict) else ''),
           'domains': [clean(x) for x in (d.get('domains') or []) if isinstance(x, str)][:16]}
    if d.get('ok') and (out['memberName'] or out['role']):
        print(json.dumps(out))
except Exception:
    pass" > "$CACHE.tmp.$$" 2>/dev/null
    if [ -s "$CACHE.tmp.$$" ]; then mv "$CACHE.tmp.$$" "$CACHE"; else rm -f "$CACHE.tmp.$$"; touch "$CACHE" 2>/dev/null; fi
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
brain_seg=""
if [ -n "$brain_role" ]; then
  label="${brain_name:-$brain_host}"
  brain_seg="${CYAN}🧠 ${label} ${MUTED}(${brain_role})${RESET}"
elif [ -n "$AGENT_KEY" ]; then
  brain_seg="${CYAN}🧠 ${brain_host}${RESET}"
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
usage=""
case "$pct5" in (''|*[!0-9]*) ;; (*) usage="$(usage_color "$pct5")5h ${pct5}%${RESET}";; esac
case "$pct7" in (''|*[!0-9]*) ;; (*)
  [ -n "$usage" ] && usage="${usage} ${MUTED}·${RESET} "
  usage="${usage}$(usage_color "$pct7")wk ${pct7}%${RESET}";; esac

out=""
append() { [ -z "$1" ] && return; if [ -z "$out" ]; then out="$1"; else out="${out}${SEP}${1}"; fi; }
[ -n "$model_short" ] && append "${DOT} ${BOLD}${RED}${model_short}${RESET}"
append "$brain_seg"
[ -n "$topic" ] && append "${MUTED}${topic}${RESET}"
append "$usage"

printf '%s\n' "$out"
exit 0
