#!/usr/bin/env bash
# AIVM Brain — PreCompact: emit a memory anchor the compactor preserves, so governed
# context survives compaction. One bounded recall call; fail-soft (exit 0 on any failure).
set -uo pipefail

BRAIN_URL="${AIVM_BRAIN_URL:-}"
[ -z "$BRAIN_URL" ] && BRAIN_URL="$(jq -r '.brainUrl // empty' "$HOME/.aivm/agent/config.json" 2>/dev/null || true)"
BRAIN_URL="${BRAIN_URL:-https://brain.aivm.io}"
BRAIN_URL="${BRAIN_URL%/}"
AGENT_KEY="${AIVM_AGENT_KEY:-}"
[ -z "$AGENT_KEY" ] && AGENT_KEY="$(cat "$HOME/.aivm/agent/agent.key" 2>/dev/null || true)"
[ -z "$AGENT_KEY" ] && exit 0

INPUT="$(cat 2>/dev/null || true)"
TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
[ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] && exit 0

# Seed a recall query from the last few user turns (keywords, bounded).
SEED="$(jq -rc 'select(.type=="user") | (.message.content // "") | if type=="array" then (map(.text // "")|join(" ")) else tostring end' "$TRANSCRIPT" 2>/dev/null | tail -3 | tr '\n' ' ' | cut -c1-400)"
[ -z "$SEED" ] && exit 0

BODY="$(jq -nc --arg q "$SEED" '{tool:"brain.search",args:{query:$q}}' 2>/dev/null)" || exit 0
RESP="$(curl -fsS --max-time 4 -X POST -H "content-type: application/json" -H "Authorization: Bearer $AGENT_KEY" \
  --data "$BODY" "$BRAIN_URL/api/mcp/tools" 2>/dev/null)" || exit 0
ANSWER="$(printf '%s' "$RESP" | jq -r '.result.answer // .answer // empty' 2>/dev/null | head -c 1500)"
[ -z "$ANSWER" ] && exit 0

echo "## AIVM Brain memory anchor (preserve through compaction)"
echo "Governed recall relevant to the current work — cite what you use:"
echo "$ANSWER"
exit 0
