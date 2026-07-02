#!/usr/bin/env bash
# AIVM Brain — SessionStart: load your governed company context into the session.
# Fail-soft by design: offline / unconfigured → exit 0 silently (never a crashed session).
set -uo pipefail
# Portable epoch-milliseconds (macOS BSD date has no %N; GNU/Linux does).
now_ms() {
  local t
  t=$(date +%s%3N 2>/dev/null)
  case "$t" in (*[!0-9]*|"") ;; (*) echo "$t"; return;; esac
  if command -v python3 >/dev/null 2>&1; then python3 -c 'import time;print(int(time.time()*1000))'; else echo "$(($(date +%s)*1000))"; fi
}
T0=$(now_ms)

# Credentials: env first (the Connect wizard's exports), then the aivm-brain installer's files.
BRAIN_URL="${AIVM_BRAIN_URL:-}"
[ -z "$BRAIN_URL" ] && BRAIN_URL="$(jq -r '.brainUrl // empty' "$HOME/.aivm/agent/config.json" 2>/dev/null || true)"
BRAIN_URL="${BRAIN_URL:-https://brain.aivm.io}"
BRAIN_URL="${BRAIN_URL%/}"
AGENT_KEY="${AIVM_AGENT_KEY:-}"
[ -z "$AGENT_KEY" ] && AGENT_KEY="$(cat "$HOME/.aivm/agent/agent.key" 2>/dev/null || true)"
[ -z "$AGENT_KEY" ] && exit 0

# The primer: org/member derived server-side from the agent key (one secret = full setup).
CTX="$(curl -fsS --max-time 5 -H "Authorization: Bearer $AGENT_KEY" \
  "$BRAIN_URL/api/agent/context?format=text" 2>/dev/null)" || exit 0
[ -z "$CTX" ] && exit 0
T1=$(now_ms)
echo "$CTX"
echo ""
echo "[aivm-brain] Context loaded in $((T1 - T0))ms. Use the aivm-brain tools to search and capture governed memory; document decisions as they happen (brain-document skill) and wrap the session before exit (brain-wrap skill)."
exit 0
