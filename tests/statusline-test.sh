#!/usr/bin/env bash
# Statusline checks — run: bash tests/statusline-test.sh
# Sandboxed: HOME is a temp dir, so the real ~/.aivm and ~/.claude are never touched.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
RENDER="$DIR/statusline/aivm-statusline.sh"
WRAP="$DIR/statusline/aivm-statusline-wrap.sh"
FIX='{"session_id":"s1","cwd":"/tmp/proj","model":{"display_name":"Fable 5"},"rate_limits":{"five_hour":{"used_percentage":42},"seven_day":{"used_percentage":91}}}'

export HOME="$(mktemp -d)"
unset AIVM_AGENT_KEY AIVM_BRAIN_URL 2>/dev/null || true
mkdir -p "$HOME/.aivm/agent"
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok: $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL: $1"; }
has()  { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

echo "1. degrade: no key, no cache → renders model+topic+limits, NO brain segment, exit 0"
out=$(printf '%s' "$FIX" | bash "$RENDER"); rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc"
has "$out" "Fable 5" && ok "model" || bad "model missing: $out"
has "$out" "proj" && ok "topic falls back to cwd basename" || bad "topic missing: $out"
has "$out" "5h 42%" && ok "5h limit" || bad "5h limit missing: $out"
has "$out" "wk 91%" && ok "wk limit" || bad "wk limit missing: $out"
has "$out" "🧠" && bad "brain segment leaked with no key" || ok "no brain segment"

echo "ak_test" > "$HOME/.aivm/agent/agent.key"
export AIVM_BRAIN_URL="http://127.0.0.1:1"   # closed port: proves render never needs the network

# The cache is an AUTH-STATE record (M1, 2026-08-13), not an identity blob: it is BOUND to the
# (key, host) that proved it and carries a proof clock the renderer leases the identity against.
# A flat v1 blob is deliberately treated as "never validated" — see tests/statusline-auth-state-test.sh.
# seed_cache <role> <orgName> [seconds-since-last-attempt]
seed_cache() {
  SC_ROLE="$1" SC_ORG="$2" SC_TRY="${3:-0}" python3 <<'PY' > "$HOME/.aivm/agent/status-cache.json"
import hashlib, json, os, sys, time
now = int(time.time())
fp = hashlib.sha256(b"ak_test").hexdigest()[:16]
json.dump({"v": 2, "host": "127.0.0.1:1", "keyFp": fp, "state": "ok",
           "httpCode": 200, "curlExit": 0,
           "lastAttemptAt": now - int(os.environ["SC_TRY"]), "lastSuccessAt": now,
           "identity": {"memberName": "ceo@x.org", "role": os.environ["SC_ROLE"],
                        "orgName": os.environ["SC_ORG"], "domains": []}}, sys.stdout)
PY
}

echo "2. cached brain data → 🧠 segment with name+role (no network: bogus URL)"
seed_cache "admin" "Acme"
out=$(printf '%s' "$FIX" | bash "$RENDER")
has "$out" "🧠 Acme" && ok "org name" || bad "org name missing: $out"
has "$out" "(admin)" && ok "role" || bad "role missing: $out"

echo "2b. hostile cache values -> ESC/control chars stripped before hitting the terminal"
seed_cache "$(printf 'admin\033]52;c;ZXZpbA==')" "$(printf 'Acme\033[2JX')"
out=$(printf '%s' "$FIX" | bash "$RENDER")
if printf '%s' "$out" | grep -q $'\x1b\]52'; then bad "OSC-52 escape leaked to terminal"; else ok "OSC-52 stripped"; fi
if printf '%s' "$out" | grep -q $'\x1b\[2J'; then bad "CSI clear-screen leaked"; else ok "CSI stripped"; fi
has "$out" "(admin" && ok "role still displayed (cleaned)" || bad "role lost: $out"
seed_cache "admin" "Acme"

echo "3. segment mode → segment only"
out=$(bash "$RENDER" --segment </dev/null)
has "$out" "🧠 Acme" && ok "segment renders" || bad "segment: $out"
has "$out" "Fable" && bad "segment mode leaked full line" || ok "segment only"

echo "4. topic file wins over cwd basename"
mkdir -p "$HOME/.claude/session-topics"; printf 'Ship the thing' > "$HOME/.claude/session-topics/s1.txt"
out=$(printf '%s' "$FIX" | bash "$RENDER")
has "$out" "Ship the thing" && ok "topic file" || bad "topic file ignored: $out"

echo "5. compose wrapper: original output preserved, segment appended"
printf '%s' '{"version":1,"hadStatusLine":true,"original":{"type":"command","command":"printf my-original-line"}}' > "$HOME/.aivm/agent/statusline-backup.json"
mkdir -p "$HOME/.aivm/agent/statusline"; cp "$RENDER" "$HOME/.aivm/agent/statusline/aivm-statusline.sh"; chmod +x "$HOME/.aivm/agent/statusline/aivm-statusline.sh"
out=$(printf '%s' "$FIX" | bash "$WRAP")
has "$out" "my-original-line" && ok "original preserved" || bad "original lost: $out"
has "$out" "🧠 Acme" && ok "segment appended" || bad "segment not appended: $out"

echo "5b. compose wrapper: multi-line original → segment on first line, rest passthrough"
printf '%s' '{"version":1,"hadStatusLine":true,"original":{"command":"printf \"line-one\\nline-two\\n\""}}' > "$HOME/.aivm/agent/statusline-backup.json"
out=$(printf '%s' "$FIX" | bash "$WRAP")
first=$(printf '%s\n' "$out" | sed -n 1p); second=$(printf '%s\n' "$out" | sed -n 2p)
has "$first" "line-one" && has "$first" "🧠 Acme" && ok "segment on first line" || bad "first line wrong: $first"
[ "$second" = "line-two" ] && ok "rest passthrough untouched" || bad "rest mangled: $second"

echo "6. compose wrapper: broken original → falls back to full brain line (never blank)"
printf '%s' '{"version":1,"hadStatusLine":true,"original":{"command":"exit 1"}}' > "$HOME/.aivm/agent/statusline-backup.json"
out=$(printf '%s' "$FIX" | bash "$WRAP")
has "$out" "Fable 5" && ok "fallback full line" || bad "blank statusline: $out"

echo "6b. wrapper prefers the marketplace renderer copy (plugin updates propagate)"
mkdir -p "$HOME/.claude/plugins/marketplaces/aivm/statusline"
printf '#!/usr/bin/env bash\necho MARKETPLACE-COPY\n' > "$HOME/.claude/plugins/marketplaces/aivm/statusline/aivm-statusline.sh"
printf '%s' '{"version":1,"hadStatusLine":true,"original":{"command":"exit 1"}}' > "$HOME/.aivm/agent/statusline-backup.json"
out=$(printf '%s' "$FIX" | bash "$WRAP")
has "$out" "MARKETPLACE-COPY" && ok "marketplace copy wins" || bad "marketplace copy ignored: $out"
rm -rf "$HOME/.claude/plugins"

echo "7. render is fast even with stale cache + dead brain (background refresh, <2s)"
# Staleness now comes from the record's ATTEMPT clock, not the file mtime (a failed refresh must
# never be able to advance freshness). An old lastAttemptAt is what actually fires the background curl.
seed_cache "admin" "Acme" 4000
t0=$(date +%s)
printf '%s' "$FIX" | bash "$RENDER" >/dev/null
t1=$(date +%s)
[ $((t1 - t0)) -le 2 ] && ok "non-blocking ($((t1-t0))s)" || bad "render blocked $((t1-t0))s"

echo "8. display fields cannot carry terminal control sequences or shift lines"
EVIL='{"session_id":"s2","cwd":"/tmp/pr\u001b[31moj\nFAKE","model":{"display_name":"Fa\u001b]0;pwn\u0007ble"}}'
out=$(printf '%s' "$EVIL" | bash "$RENDER")
has "$out" $'\e]0;' && bad "OSC from model reached the terminal" || ok "model OSC stripped"
has "$out" "Fa]0;pwnble" && ok "model text kept, controls removed" || bad "model mangled: $out"
has "$out" $'\e[31moj' && bad "CSI from cwd reached the terminal" || ok "cwd CSI stripped"
printf 'Top\033[2Jic\n' > "$HOME/.claude/session-topics/s2.txt"
out=$(printf '%s' "$EVIL" | bash "$RENDER")
has "$out" $'\e[2J' && bad "CSI from topic file reached the terminal" || ok "topic CSI stripped"
has "$out" "Top[2Jic" && ok "topic text kept" || bad "topic missing: $out"

echo "9. agent state dir is repaired to owner-only"
chmod 777 "$HOME/.aivm" "$HOME/.aivm/agent"
printf '%s' "$FIX" | bash "$RENDER" >/dev/null
[ "$(ls -ld "$HOME/.aivm/agent" | cut -c5-10)" = "------" ] && [ "$(ls -ld "$HOME/.aivm" | cut -c5-10)" = "------" ] \
  && ok "~/.aivm and ~/.aivm/agent are 0700" || bad "perms: $(ls -ld "$HOME/.aivm" "$HOME/.aivm/agent")"

echo "10. wrapper runs the backup command only when it is owner-only"
printf '%s' '{"version":1,"hadStatusLine":true,"original":{"command":"echo BACKUP-RAN"}}' > "$HOME/.aivm/agent/statusline-backup.json"
chmod 600 "$HOME/.aivm/agent/statusline-backup.json"
out=$(printf '%s' "$FIX" | bash "$WRAP"); has "$out" "BACKUP-RAN" && ok "owner-only backup runs" || bad "backup ignored: $out"
chmod 666 "$HOME/.aivm/agent/statusline-backup.json"
out=$(printf '%s' "$FIX" | bash "$WRAP"); has "$out" "BACKUP-RAN" && bad "world-writable backup was run" || ok "world-writable backup refused"
rm -f "$HOME/.aivm/agent/statusline-backup.json"

echo "11. cleartext non-loopback brain URL: no request, no brain segment"
seed_cache "admin" "Acme" 4000
rm -rf "$HOME/.aivm/agent/status-cache.refreshing"
out=$(printf '%s' "$FIX" | AIVM_BRAIN_URL="http://brain.example.com" bash "$RENDER")
has "$out" "🧠" && bad "brain segment for cleartext URL: $out" || ok "no brain segment"
[ -d "$HOME/.aivm/agent/status-cache.refreshing" ] && bad "refresh started for cleartext URL" || ok "no refresh started"

echo "12. background refresh keeps the key out of curl argv"
SHIM="$(mktemp -d)"; REALCURL="$(command -v curl)"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/argv.log"\nexec "%s" "$@"\n' "$SHIM" "$REALCURL" > "$SHIM/curl"; chmod +x "$SHIM/curl"
echo "ak_test_ARGVMARK" > "$HOME/.aivm/agent/agent.key"
seed_cache "admin" "Acme" 4000; rm -rf "$HOME/.aivm/agent/status-cache.refreshing"
printf '%s' "$FIX" | PATH="$SHIM:$PATH" bash "$RENDER" >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$SHIM/argv.log" ] && break; sleep 0.3; done
[ -s "$SHIM/argv.log" ] && ok "refresh called curl" || bad "no refresh curl observed"
grep -q ARGVMARK "$SHIM/argv.log" 2>/dev/null && bad "key in curl argv" || ok "key not in curl argv"
rm -rf "$SHIM"; echo "ak_test" > "$HOME/.aivm/agent/agent.key"

echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
