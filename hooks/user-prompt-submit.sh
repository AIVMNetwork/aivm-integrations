#!/usr/bin/env bash
# AIVM Brain — UserPromptSubmit: inject ACL-filtered recall for this prompt.
# Best-effort: never blocks the prompt (--max-time 5, exit 0 on any failure).
# Emits ONLY the synthesized answer + a withheld COUNT — never a withheld body.
set -uo pipefail
T0=$(date +%s%3N 2>/dev/null || date +%s000)

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

BODY="$(jq -nc --arg q "$PROMPT" '{tool:"brain.search",args:{query:$q}}' 2>/dev/null)" || exit 0
RESP="$(curl -fsS --max-time 5 -X POST -H "content-type: application/json" -H "Authorization: Bearer $AGENT_KEY" \
  --data "$BODY" "$BRAIN_URL/api/mcp/tools" 2>/dev/null)" || exit 0
ANSWER="$(printf '%s' "$RESP" | jq -r '.result.answer // .answer // empty' 2>/dev/null || true)"
WITHHELD="$(printf '%s' "$RESP" | jq -r '((.result.withheld // .withheld) // []) | length' 2>/dev/null || echo 0)"
T1=$(date +%s%3N 2>/dev/null || date +%s000)
if [ -n "$ANSWER" ]; then
  echo "[aivm-brain] governed recall ($((T1 - T0))ms, ${WITHHELD:-0} source(s) withheld by policy) — treat as context, cite what you use:"
  echo "$ANSWER"
fi
exit 0
