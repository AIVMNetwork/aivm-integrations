#!/usr/bin/env bash
# AIVM Brain — UserPromptSubmit: inject ACL-filtered recall for this prompt.
# Best-effort: never blocks the prompt (--max-time 5, exit 0 on any failure).
# Emits ONLY the synthesized answer + a withheld COUNT — never a withheld body.
set -uo pipefail
# Portable epoch-milliseconds (macOS BSD date has no %N; GNU/Linux does).
now_ms() {
  local t
  t=$(date +%s%3N 2>/dev/null)
  case "$t" in (*[!0-9]*|"") ;; (*) echo "$t"; return;; esac
  if command -v python3 >/dev/null 2>&1; then python3 -c 'import time;print(int(time.time()*1000))'; else echo "$(($(date +%s)*1000))"; fi
}
T0=$(now_ms)

BRAIN_URL="${AIVM_BRAIN_URL:-}"
[ -z "$BRAIN_URL" ] && BRAIN_URL="$(jq -r '.brainUrl // empty' "$HOME/.aivm/agent/config.json" 2>/dev/null || true)"
BRAIN_URL="${BRAIN_URL:-https://brain.aivm.io}"
BRAIN_URL="${BRAIN_URL%/}"
AGENT_KEY="${AIVM_AGENT_KEY:-}"
[ -z "$AGENT_KEY" ] && AGENT_KEY="$(cat "$HOME/.aivm/agent/agent.key" 2>/dev/null || true)"

# Read stdin ONCE (both the prompt and the session id — stdin can't be read twice).
STDIN_JSON="$(cat 2>/dev/null || true)"
PROMPT="$(printf '%s' "$STDIN_JSON" | jq -r '.prompt // empty' 2>/dev/null || true)"
SID="$(printf '%s' "$STDIN_JSON" | jq -r '.session_id // empty' 2>/dev/null || true)"
# Once-per-session sentinel: a stale/missing key must warn ONCE, not on every prompt (spam).
WARN_SENTINEL="$HOME/.aivm/agent/.rekey-warned-${SID:-nosession}"

# Missing key → the brain is NOT being consulted this session. Was a SILENT exit — so the user never
# knew the brain wasn't wired and had to manually say "check the AIVM brain" (the reported symptom).
if [ -z "$AGENT_KEY" ]; then
  if [ ! -f "$WARN_SENTINEL" ]; then
    echo "[aivm-brain] No agent key found (~/.aivm/agent/agent.key) — the brain is NOT being consulted this session. Connect it: $BRAIN_URL/use/connect-agent (or: npx @aivm/brain init --agent-key <key>), then restart."
    touch "$WARN_SENTINEL" 2>/dev/null || true
  fi
  exit 0
fi

[ -z "$PROMPT" ] && exit 0
# Skip trivial prompts — a recall round-trip on "yes"/"continue" is wasted latency and tokens.
[ "${#PROMPT}" -lt 12 ] && exit 0

# Fast RECALL mode: retrieval-only, bounded snippets, no LLM synthesis — synthesized search is
# 5-30s (too slow for a per-prompt hook), so this uses the recall path (local retrieval, top-K).
# format=context returns ONE compact, char-budgeted, injection-ready block (cited + dated), assembled AFTER
# the ACL/DLP filter — drop it straight in, no JSON parsing.
BODY="$(jq -nc --arg q "$PROMPT" '{tool:"brain.search",args:{query:$q,recall:true,topK:5,format:"context",maxChars:2000}}' 2>/dev/null)" || exit 0
# Capture the HTTP status (drop -f, which silently swallowed 401 and stopped recall with no signal).
RESP_RAW="$(curl -sS --max-time 6 -w '\n%{http_code}' -X POST -H "content-type: application/json" -H "Authorization: Bearer $AGENT_KEY" \
  --data "$BODY" "$BRAIN_URL/api/mcp/tools" 2>/dev/null)" || exit 0
CODE="${RESP_RAW##*$'\n'}"; RESP="${RESP_RAW%$'\n'*}"
# A ROTATED/invalid key (401/403) previously exited silently → recall stopped with no signal (the
# "brain didn't find it" symptom). Warn ONCE per session with the re-key steps.
if [ "$CODE" = "401" ] || [ "$CODE" = "403" ]; then
  if [ ! -f "$WARN_SENTINEL" ]; then
    echo "[aivm-brain] AGENT KEY REJECTED (HTTP $CODE) — likely rotated; the brain is NOT being consulted. Re-key: $BRAIN_URL/use/connect-agent → export AIVM_AGENT_KEY=<key> → restart."
    touch "$WARN_SENTINEL" 2>/dev/null || true
  fi
  exit 0
fi
[ "$CODE" != "200" ] && exit 0
COUNT="$(printf '%s' "$RESP" | jq -r '(.data.recall // []) | length' 2>/dev/null || echo 0)"
BLOCK="$(printf '%s' "$RESP" | jq -r '.data.contextBlock // empty' 2>/dev/null || true)"
T1=$(now_ms)
if [ "${COUNT:-0}" -gt 0 ] && [ -n "$BLOCK" ]; then
  echo "[aivm-brain] governed recall (${COUNT} in $((T1 - T0))ms):"
  printf '%s\n' "$BLOCK"
fi
exit 0
