#!/usr/bin/env bash
# AIVM Brain — SessionEnd: sync the session into governed memory WITHOUT blocking exit.
# The hook returns immediately; a detached worker captures the salient transcript turns as
# governed episodes (server-side salience -> authorize -> DLP -> dedup -> record) and posts
# the session's usage metrics (numbers only — never session text). Timings land in
# ~/.aivm/logs/sync.log so sync performance is measurable. Fail-soft everywhere.
set -uo pipefail

BRAIN_URL="${AIVM_BRAIN_URL:-}"
[ -z "$BRAIN_URL" ] && BRAIN_URL="$(jq -r '.brainUrl // empty' "$HOME/.aivm/agent/config.json" 2>/dev/null || true)"
BRAIN_URL="${BRAIN_URL:-https://brain.aivm.io}"
BRAIN_URL="${BRAIN_URL%/}"
AGENT_KEY="${AIVM_AGENT_KEY:-}"
[ -z "$AGENT_KEY" ] && AGENT_KEY="$(cat "$HOME/.aivm/agent/agent.key" 2>/dev/null || true)"
[ -z "$AGENT_KEY" ] && exit 0

INPUT="$(cat 2>/dev/null || true)"
SESSION="$(printf '%s' "$INPUT" | jq -r '.session_id // "session"' 2>/dev/null || echo session)"
TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)"

LOG_DIR="$HOME/.aivm/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true

# Detached worker (survives the host exiting): capture turns, then metrics, then log timings.
(
  T0=$(date +%s%3N 2>/dev/null || date +%s000)
  CAPTURED=0
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    IDX=0
    while IFS= read -r TURN; do
      [ -z "$TURN" ] && continue
      BODY="$(jq -nc --argjson t "$TURN" --arg sid "$SESSION" --argjson i "$IDX" \
        '{tool:"brain.capture",args:{episode:{sessionId:$sid,turnIndex:$i,role:$t.role,text:$t.text}}}' 2>/dev/null)" || { IDX=$((IDX+1)); continue; }
      curl -fsS --max-time 5 -X POST -H "content-type: application/json" -H "Authorization: Bearer $AGENT_KEY" \
        --data "$BODY" "$BRAIN_URL/api/mcp/tools" >/dev/null 2>&1 && CAPTURED=$((CAPTURED+1)) || true
      IDX=$((IDX+1))
    done < <(jq -rc 'select(.type=="user" or .type=="assistant") | {role:.type, text:((.message.content // "") | if type=="array" then (map(.text // "")|join(" ")) else tostring end)} | select(.text | length > 0)' "$TRANSCRIPT" 2>/dev/null | tail -20)
  fi

  METRICS=""
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    METRICS="$(jq -sc '[.[] | select(.type=="assistant") | {m: (.message.model // ""), i: (.message.usage.input_tokens // 0), o: (.message.usage.output_tokens // 0)}] | select(length > 0) | {model: (map(.m) | map(select(. != "")) | last // ""), inputTokens: (map(.i) | add), outputTokens: (map(.o) | add), turns: length}' "$TRANSCRIPT" 2>/dev/null || true)"
  fi
  T1=$(date +%s%3N 2>/dev/null || date +%s000)
  SYNC_MS=$((T1 - T0))
  BODY="$(jq -nc --argjson metrics "${METRICS:-null}" --argjson cap "$CAPTURED" --argjson ms "$SYNC_MS" \
    '(if ($metrics | type) == "object" then {metrics: ($metrics + {syncMs: $ms, captured: $cap})} else {metrics: {syncMs: $ms, captured: $cap}} end)' 2>/dev/null)" || BODY='{}'
  curl -fsS --max-time 5 -X POST -H "content-type: application/json" -H "Authorization: Bearer $AGENT_KEY" \
    --data "$BODY" "$BRAIN_URL/api/agent/capture" >/dev/null 2>&1 || true
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) session=$SESSION captured=$CAPTURED sync_ms=$SYNC_MS" >> "$LOG_DIR/sync.log" 2>/dev/null || true
) </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true

echo "[aivm-brain] session syncing to governed memory in the background (salient turns, agent-attributed; timing in ~/.aivm/logs/sync.log)."
exit 0
