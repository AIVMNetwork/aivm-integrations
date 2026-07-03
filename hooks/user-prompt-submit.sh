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
[ -z "$AGENT_KEY" ] && exit 0

PROMPT="$(cat 2>/dev/null | jq -r '.prompt // empty' 2>/dev/null || true)"
[ -z "$PROMPT" ] && exit 0
# Skip trivial prompts — a recall round-trip on "yes"/"continue" is wasted latency and tokens.
[ "${#PROMPT}" -lt 12 ] && exit 0

# Fast RECALL mode: retrieval-only, bounded snippets, no LLM synthesis — synthesized search is
# 5-30s (too slow for a per-prompt hook), so this uses the recall path (local retrieval, top-K).
# format=context returns ONE compact, char-budgeted, injection-ready block (cited + dated), assembled AFTER
# the ACL/DLP filter — drop it straight in, no JSON parsing.
BODY="$(jq -nc --arg q "$PROMPT" '{tool:"brain.search",args:{query:$q,recall:true,topK:5,format:"context",maxChars:2000}}' 2>/dev/null)" || exit 0
RESP="$(curl -fsS --max-time 6 -X POST -H "content-type: application/json" -H "Authorization: Bearer $AGENT_KEY" \
  --data "$BODY" "$BRAIN_URL/api/mcp/tools" 2>/dev/null)" || exit 0
COUNT="$(printf '%s' "$RESP" | jq -r '(.data.recall // []) | length' 2>/dev/null || echo 0)"
BLOCK="$(printf '%s' "$RESP" | jq -r '.data.contextBlock // empty' 2>/dev/null || true)"
T1=$(now_ms)
if [ "${COUNT:-0}" -gt 0 ] && [ -n "$BLOCK" ]; then
  echo "[aivm-brain] governed recall (${COUNT} in $((T1 - T0))ms):"
  printf '%s\n' "$BLOCK"
fi
exit 0
