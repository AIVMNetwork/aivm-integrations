#!/usr/bin/env bash
# Hooks key-transport gate — run: bash tests/hooks-key-transport-test.sh
# Drives every hook against a local stub brain through a curl shim that records argv, and asserts:
#   * the agent key, prompt and transcript text never appear in curl's argv (process table);
#   * every request still carries the bearer header and the body;
#   * a non-HTTPS, non-loopback brain URL is refused before the key is sent.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'kill "${SP:-}" 2>/dev/null; wait "${SP:-}" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home/.aivm/agent"
PORT=$((20000 + RANDOM % 20000))
python3 - "$T/req.log" "$PORT" <<'PY' &
import http.server, json, sys
log = open(sys.argv[1], "a")
class H(http.server.BaseHTTPRequestHandler):
    def _r(self):
        n = int(self.headers.get("content-length") or 0)
        log.write(json.dumps({"auth": self.headers.get("authorization"), "body": self.rfile.read(n).decode()}) + "\n"); log.flush()
        out = b'{"data":{"recall":[1],"contextBlock":"MEM"},"answer":"ANS"}' if self.command == "POST" else b"CTX"
        self.send_response(200); self.send_header("content-length", str(len(out))); self.end_headers(); self.wfile.write(out)
    do_GET = do_POST = _r
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[2])), H).serve_forever()
PY
SP=$!
REAL="$(command -v curl)"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/argv.log"\nexec "%s" "$@"\n' "$T" "$REAL" > "$T/bin/curl"; chmod +x "$T/bin/curl"
for _ in 1 2 3 4 5 6 7 8 9 10; do "$REAL" -s "http://127.0.0.1:$PORT/" >/dev/null && break; sleep 0.3; done
: > "$T/req.log"

export HOME="$T/home" PATH="$T/bin:$PATH" AIVM_AGENT_KEY=ak_test_KEYMARK AIVM_BRAIN_URL="http://127.0.0.1:$PORT"
printf '%s\n' '{"type":"user","message":{"content":"turn TURNMARK"}}' > "$T/t.jsonl"
bash "$DIR/hooks/session-start.sh" </dev/null >/dev/null
echo '{"prompt":"what did we decide PROMPTMARK","session_id":"s"}' | bash "$DIR/hooks/user-prompt-submit.sh" >/dev/null
echo "{\"transcript_path\":\"$T/t.jsonl\"}" | bash "$DIR/hooks/pre-compact.sh" >/dev/null
echo "{\"session_id\":\"s\",\"transcript_path\":\"$T/t.jsonl\"}" | bash "$DIR/hooks/session-end.sh" >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(wc -l < "$T/req.log")" -ge 5 ] && break; sleep 0.5; done

fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
check "five requests reached the stub" '[ "$(wc -l < "$T/req.log")" -ge 5 ]'
check "every request carried the bearer key" '! grep -v "\"auth\": \"Bearer ak_test_KEYMARK\"" "$T/req.log" | grep -q .'
check "prompt and transcript reached the body" 'grep -q PROMPTMARK "$T/req.log" && grep -q TURNMARK "$T/req.log"'
check "no key, prompt or turn text in curl argv" '! grep -qE "KEYMARK|PROMPTMARK|TURNMARK" "$T/argv.log"'

: > "$T/argv.log"
for u in http://brain.example.com http://localhost:80@evil.example http://127.0.0.1.evil.example HTTPS://x ftp://x; do
  AIVM_BRAIN_URL="$u" bash "$DIR/hooks/session-start.sh" </dev/null >/dev/null
  echo '{"prompt":"what did we decide PROMPTMARK","session_id":"s"}' | AIVM_BRAIN_URL="$u" bash "$DIR/hooks/user-prompt-submit.sh" >/dev/null
done
check "unsafe brain URLs never reach curl" '[ ! -s "$T/argv.log" ]'
exit $fail
