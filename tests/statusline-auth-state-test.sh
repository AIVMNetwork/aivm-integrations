#!/usr/bin/env bash
# M1 gate — the statusline must NEVER render an identity the current credential has not proven.
# Run: bash tests/statusline-auth-state-test.sh
#
# Drives the REAL renderer through REAL bash against a REAL local HTTP server scripted to return
# 401 / 403 / 404 / 5xx / a non-API 200 / a hang (curl timeout), plus a closed port (connection
# refused) and a cold cache. Sandboxed: HOME is a temp dir, so ~/.aivm and ~/.claude are untouched.
#
# Synchronisation is on the renderer's own single-flight lock dir (created in the FOREGROUND before
# the refresh is detached, removed when it finishes) — no sleep-and-hope.
#
# Every test here is written to go RED on unmodified HEAD (e67b705) *and* on the plausible wrong
# variants: "stop touching the cache but still render the stale role" (W1) and "keep computing
# freshness from the file mtime" (W2). A gate that only passes after the fix is not a gate.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
RENDER="$DIR/statusline/aivm-statusline.sh"
FIX='{"session_id":"s1","cwd":"/tmp/proj","model":{"display_name":"Fable 5"},"rate_limits":{"five_hour":{"used_percentage":42},"seven_day":{"used_percentage":91}}}'
OKBODY='{"ok":true,"member":{"name":"ceo@x.org","role":"admin"},"org":{"name":"Acme"},"domains":["eng.example"]}'

export HOME="$(mktemp -d)"
unset AIVM_AGENT_KEY 2>/dev/null || true
AG="$HOME/.aivm/agent"; mkdir -p "$AG"
KEY="ak_live_1"
printf '%s\n' "$KEY" > "$AG/agent.key"
KEYFP=$(printf '%s' "$KEY" | python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.read().strip().encode()).hexdigest()[:16])')

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
has() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

# ---- scriptable brain ----------------------------------------------------------------------
cat > "$HOME/srv.py" <<'PY'
import http.server, os, socketserver, time
CTL, HITS, PORTFILE = os.environ["CTL"], os.environ["HITS"], os.environ["PORTFILE"]
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_GET(self):
        with open(HITS, "a") as f:
            f.write("1\n")
        code, _, body = open(CTL).read().partition("\n")
        code = code.strip()
        if code == "hang":
            time.sleep(20)          # curl --max-time 4 -> exit 28
            return
        b = body.encode()
        self.send_response(int(code))
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def log_message(self, *a):
        pass
class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
srv = S(("127.0.0.1", 0), H)
open(PORTFILE, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
: > "$HOME/hits"
printf '200\n%s' "$OKBODY" > "$HOME/ctl"
CTL="$HOME/ctl" HITS="$HOME/hits" PORTFILE="$HOME/port" python3 "$HOME/srv.py" &
SRVPID=$!
trap 'kill $SRVPID 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do [ -s "$HOME/port" ] && break; sleep 0.1; done
PORT=$(cat "$HOME/port" 2>/dev/null || echo "")
[ -n "$PORT" ] || { echo "FATAL: test brain never bound a port"; exit 1; }
export AIVM_BRAIN_URL="http://127.0.0.1:$PORT"
HOSTV="127.0.0.1:$PORT"

# ---- helpers -------------------------------------------------------------------------------
scenario() { printf '%s\n%s' "$1" "${2:-}" > "$HOME/ctl"; }

# seed <state> <secs-since-last-success|none> <identity 0|1> <secs-since-last-attempt|none>
seed() {
  HOSTV="$HOSTV" KEYFP="$KEYFP" python3 -c '
import json, os, sys, time
now = int(time.time())
state, okoff, ident, tryoff = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
r = {"v": 2, "host": os.environ["HOSTV"], "keyFp": os.environ["KEYFP"], "state": state,
     "httpCode": 200, "curlExit": 0,
     "lastAttemptAt": 0 if tryoff == "none" else now - int(tryoff),
     "lastSuccessAt": 0 if okoff  == "none" else now - int(okoff)}
if ident == "1":
    r["identity"] = {"memberName": "ceo@x.org", "role": "admin", "orgName": "Acme", "domains": []}
    # ALSO write the pre-fix (v1) FLAT keys. This is what makes the fixture discriminate: the
    # HEAD renderer reads role/orgName from the TOP LEVEL, so without these it renders a bare host
    # and every "no identity leaked" assertion would pass at HEAD for the wrong reason. With them,
    # HEAD renders "Acme (admin)" after a 401 — the actual defect — and the fixed renderer must
    # still refuse, because it reads ONLY the bound, leased identity object (E4, fail-closed).
    r["memberName"], r["role"], r["orgName"] = "ceo@x.org", "admin", "Acme"
sys.stdout.write(json.dumps(r))' "$1" "$2" "$3" "$4" > "$AG/status-cache.json"
}

render() { printf '%s' "$FIX" | bash "$RENDER" 2>/dev/null | sed $'s/\033\\[[0-9;]*m//g'; }

wait_refresh() {
  # `local` matters: this is called from inside counted loops, and a bare `i` would clobber theirs.
  local n=0
  while [ -d "$AG/status-cache.refreshing" ] && [ "$n" -lt 200 ]; do sleep 0.1; n=$((n+1)); done
}

# one full cycle: render (fires the detached refresh) -> wait for it -> render again
cycle() { render >/dev/null; wait_refresh; render; }

field() {
  python3 -c '
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: d = {}
v = d.get(sys.argv[2])
sys.stdout.write("" if v is None else str(v))' "$AG/status-cache.json" "$1" 2>/dev/null
}
hits() { wc -l < "$HOME/hits" | tr -d ' '; }

# assert-no-identity: the load-bearing invariant, asserted the same way everywhere
no_identity() {
  if has "$1" "Acme";  then bad "$2: org name leaked -> $1"; return; fi
  if has "$1" "admin"; then bad "$2: role leaked -> $1";     return; fi
  ok "$2: no org, no role"
}

echo "=== M1: the statusline never claims an identity the current key has not proven ==="

echo "0. source-level: the failure branch may not touch the cache (E5/AC-12)"
n=$(grep -v '^[[:space:]]*#' "$RENDER" | grep -c 'touch "\$CACHE"' || true)
[ "$n" = "0" ] && ok "no touch \$CACHE in the renderer" || bad "touch \$CACHE still present ($n)"
grep -q 'lastSuccessAt' "$RENDER" && ok "a proof clock exists" || bad "no lastSuccessAt in renderer"
grep -q 'lastAttemptAt'  "$RENDER" && ok "an attempt clock exists" || bad "no lastAttemptAt in renderer"

echo "1. AC-1 — a REVOKED key stops claiming the last-known-good identity (401)"
seed ok 60 1 400
before_ok=$(field lastSuccessAt)
scenario 401 '{"error":"Unauthorized."}'
out=$(cycle)
no_identity "$out" "401"
has "$out" "key rejected" && ok "401 reads 'key rejected'" || bad "401 wording: $out"
[ "$(field lastSuccessAt)" = "$before_ok" ] && ok "proof clock unchanged by 401" || bad "401 moved lastSuccessAt"
[ -z "$(field identity)" ] && ok "identity ERASED from disk on 401" || bad "identity survived 401 on disk"
[ "$(field state)" = "unauthorized" ] && ok "state=unauthorized" || bad "state=$(field state)"

echo "2. AC-4 — a DENIED tenant is not a revoked key (403)"
seed ok 60 1 400
scenario 403 '{"error":"Tenant access denied (org)."}'
out=$(cycle)
no_identity "$out" "403"
has "$out" "access denied" && ok "403 reads 'access denied'" || bad "403 wording: $out"
has "$out" "key rejected" && bad "403 rendered as revocation" || ok "403 is NOT 'key rejected'"
[ -z "$(field identity)" ] && ok "identity ERASED on 403" || bad "identity survived 403"

echo "3. AC-3 — a WRONG HOST is not a revoked key (404)"
seed ok 60 1 400
before_ok=$(field lastSuccessAt)
scenario 404 '<!doctype html><title>Not Found</title>'
out=$(cycle)
has "$out" "no brain API" && ok "404 reads 'no brain API'" || bad "404 wording: $out"
has "$out" "key rejected" && bad "404 rendered as revocation" || ok "404 is NOT 'key rejected'"
has "$out" "access denied" && bad "404 rendered as denial" || ok "404 is NOT 'access denied'"
[ "$(field lastSuccessAt)" = "$before_ok" ] && ok "proof clock unchanged by 404" || bad "404 moved lastSuccessAt"
[ "$(field state)" = "no_api" ] && ok "state=no_api" || bad "state=$(field state)"
has "$out" "admin" && ok "identity RETAINED under lease (404 != bad key)" || bad "404 wrongly erased identity: $out"

echo "3b. AC-3b — a 200 that is not our API means the same thing as a 404"
seed ok 60 1 400
before_ok=$(field lastSuccessAt)
scenario 200 '<!doctype html><html><body>captive portal</body></html>'
out=$(cycle)
[ "$(field state)" = "no_api" ] && ok "non-API 200 -> no_api" || bad "state=$(field state)"
[ "$(field lastSuccessAt)" = "$before_ok" ] && ok "non-API 200 did not advance the proof clock" || bad "non-API 200 advanced proof clock"
has "$out" "key rejected" && bad "non-API 200 rendered as revocation" || ok "not 'key rejected'"

echo "4. AC-5 — a brain OUTAGE keeps the identity and never accuses the key (503)"
seed ok 60 1 400
scenario 503 '{"error":"auth store unavailable"}'
out=$(cycle)
has "$out" "admin" && ok "identity retained through 503" || bad "503 erased the identity: $out"
has "$out" "brain unavailable" && ok "503 carries a degraded marker" || bad "503 marker missing: $out"
has "$out" "key rejected" && bad "503 rendered as revocation (2026-07-02 class)" || ok "503 is NOT 'key rejected'"
[ "$(field state)" = "unavailable" ] && ok "state=unavailable" || bad "state=$(field state)"

echo "5. TIMEOUT — curl exit 28, identity retained, rendered as offline"
seed ok 60 1 400
before_ok=$(field lastSuccessAt)
scenario hang
out=$(cycle)
has "$out" "offline" && ok "timeout reads 'offline'" || bad "timeout wording: $out"
has "$out" "key rejected" && bad "timeout rendered as revocation" || ok "timeout is NOT 'key rejected'"
[ "$(field lastSuccessAt)" = "$before_ok" ] && ok "proof clock unchanged by timeout" || bad "timeout moved lastSuccessAt"
[ "$(field state)" = "unreachable" ] && ok "state=unreachable" || bad "state=$(field state)"
[ "$(field curlExit)" = "28" ] && ok "curlExit 28 persisted for doctor" || bad "curlExit=$(field curlExit)"

echo "5b. CONNECTION REFUSED — closed port renders identically to a timeout"
seed ok 60 1 400
( export AIVM_BRAIN_URL="http://127.0.0.1:1"
  printf '%s' "$FIX" | bash "$RENDER" >/dev/null 2>&1
  i=0; while [ -d "$AG/status-cache.refreshing" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done )
out=$(AIVM_BRAIN_URL="http://127.0.0.1:1" bash -c 'printf "%s" "$0" | bash "$1"' "$FIX" "$RENDER" 2>/dev/null | sed $'s/\033\\[[0-9;]*m//g')
has "$out" "127.0.0.1:1" && ok "renders the host it actually tried" || bad "host wrong: $out"
has "$out" "key rejected" && bad "refused connection rendered as revocation" || ok "refused is NOT 'key rejected'"

echo "6. AC-2 — a FAILED refresh cannot make a stale identity look fresh"
# The discriminator: lastSuccessAt is 30 minutes old while the FILE MTIME IS NOW.
# Any implementation that derives freshness from the mtime renders the role here.
seed unreachable 1800 1 400
touch "$AG/status-cache.json"
out=$(render)
no_identity "$out" "expired lease (mtime fresh, proof 30m old)"
has "$out" "offline" && ok "reads 'offline'" || bad "reason missing: $out"
has "$out" "30m" && ok "reports the true age 30m" || bad "age wrong: $out"

echo "7. AC-6 — no failure outcome may advance the proof clock (5 outcomes)"
for spec in "401|{}" "403|{}" "404|{}" "503|{}" "hang|"; do
  code="${spec%%|*}"; body="${spec#*|}"
  seed ok 120 1 400
  t_ok=$(field lastSuccessAt); t_try=$(field lastAttemptAt)
  scenario "$code" "$body"
  cycle >/dev/null
  a_ok=$(field lastSuccessAt); a_try=$(field lastAttemptAt)
  [ "$a_ok" = "$t_ok" ] && ok "$code: lastSuccessAt byte-identical" || bad "$code: lastSuccessAt $t_ok -> $a_ok"
  [ -n "$a_try" ] && [ "$a_try" -gt "$t_try" ] && ok "$code: lastAttemptAt advanced" || bad "$code: lastAttemptAt $t_try -> $a_try"
done

echo "8. AC-7 / cold cache — never validated is worded differently from expired"
rm -f "$AG/status-cache.json"
out=$(render)
no_identity "$out" "cold cache"
has "$out" "unverified" && ok "cold reads 'unverified'" || bad "cold wording: $out"
case "$out" in *"unverified "[0-9]*) bad "cold reported an age";; *) ok "cold reports NO age";; esac
wait_refresh
printf '' > "$AG/status-cache.json"   # 0-byte file: only the OLD code could produce this
out=$(render)
no_identity "$out" "0-byte cache"
has "$out" "unverified" && ok "0-byte cache reads 'unverified'" || bad "0-byte wording: $out"
wait_refresh

echo "9. AC-8 — a PRE-FIX (v1) cache is treated as never validated, not as proof"
printf '%s' '{"memberName":"ceo@x.org","role":"admin","orgName":"Acme"}' > "$AG/status-cache.json"
out=$(render)
no_identity "$out" "v1 legacy cache"
has "$out" "unverified" && ok "v1 cache reads 'unverified'" || bad "v1 wording: $out"
wait_refresh

echo "10. AC-9 — re-keying does not inherit the previous key's identity"
seed ok 30 1 0            # attempt clock is NOW: a bound record would NOT refresh
printf '%s\n' "ak_live_2_different" > "$AG/agent.key"
h0=$(hits)
out=$(render)
no_identity "$out" "re-keyed"
wait_refresh
h1=$(hits)
[ "$h1" -gt "$h0" ] && ok "re-key forces an immediate refresh (not after TTL)" || bad "no refresh after re-key ($h0 -> $h1)"
printf '%s\n' "$KEY" > "$AG/agent.key"

echo "11. AC-10c — a dead brain does not become a retry storm"
seed ok 60 1 400
scenario 404 '{}'
cycle >/dev/null
# Back-date the FILE MTIME. Throttling must come from the record's attempt clock, not from the
# mtime — otherwise "just delete the touch" (W1) turns a dead host into a curl on every render,
# i.e. trades 74 failures over six days for 74 per minute. Inert for a record-driven implementation.
touch -t 202001010000 "$AG/status-cache.json"
h0=$(hits)
i=0; while [ "$i" -lt 10 ]; do render >/dev/null; wait_refresh; i=$((i+1)); done
wait_refresh
h1=$(hits)
[ $((h1 - h0)) -le 1 ] && ok "10 renders after a 404 -> $((h1-h0)) further refresh(es)" \
                       || bad "retry storm: $((h1-h0)) refreshes from 10 renders"

echo "12. HAPPY PATH — a proven identity renders exactly as before, with no marker"
seed cold none 0 400
rm -f "$AG/status-cache.json"
scenario 200 "$OKBODY"
out=$(cycle)
has "$out" "🧠 Acme" && ok "org name renders on a proven success" || bad "org missing: $out"
has "$out" "(admin)" && ok "role renders" || bad "role missing: $out"
has "$out" "⚠" && bad "healthy line carries a degraded marker" || ok "no marker on the happy path"
[ "$(field state)" = "ok" ] && ok "state=ok" || bad "state=$(field state)"
[ -n "$(field lastSuccessAt)" ] && [ "$(field lastSuccessAt)" != "0" ] && ok "proof clock set by success" || bad "success did not set lastSuccessAt"

echo "13. AC-10a — an operator with NO agent key still sees no brain segment"
rm -f "$AG/agent.key" "$AG/status-cache.json"
out=$(render); rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc"
has "$out" "🧠" && bad "brain segment leaked with no key: $out" || ok "no brain segment"
has "$out" "unverified" && bad "a non-brain user was shown an auth error" || ok "no auth error for a non-brain user"
has "$out" "Fable 5" && ok "model still renders" || bad "model lost: $out"
has "$out" "5h 42%" && ok "limits still render" || bad "limits lost: $out"
printf '%s\n' "$KEY" > "$AG/agent.key"

echo "14. AC-10b — the render never waits on the network (black hole)"
seed unreachable 60 1 400
t0=$(date +%s)
AIVM_BRAIN_URL="http://127.0.0.1:1" bash -c 'printf "%s" "$0" | bash "$1" >/dev/null 2>&1' "$FIX" "$RENDER"
t1=$(date +%s)
[ $((t1 - t0)) -le 2 ] && ok "non-blocking ($((t1-t0))s)" || bad "render blocked $((t1-t0))s"

echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
