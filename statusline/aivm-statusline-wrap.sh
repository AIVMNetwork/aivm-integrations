#!/usr/bin/env bash
# AIVM Brain statusline COMPOSE wrapper.
# =======================================
# Installed as the statusLine command ONLY when the user already had one.
# Runs the user's original statusline with the same stdin, then appends the
# brain segment — their line stays theirs, the brain is additive.
#
# The original command lives in ~/.aivm/agent/statusline-backup.json
# ({"command": "<original command>"}), written at install time; uninstall
# restores it into ~/.claude/settings.json verbatim.
#
# Fail-soft: original missing/broken → render the brain full line instead of
# a blank statusline; segment fails → original output unchanged.
set -u

AGENT_DIR="$HOME/.aivm/agent"
BACKUP="$AGENT_DIR/statusline-backup.json"
RENDER="$AGENT_DIR/statusline/aivm-statusline.sh"
[ -x "$RENDER" ] || RENDER="$(dirname "$0")/aivm-statusline.sh"

input=$(cat 2>/dev/null || true)

orig_cmd=$(python3 -c "
import json
try: print(json.load(open('$BACKUP')).get('command',''))
except Exception: print('')" 2>/dev/null)

orig_out=""
if [ -n "$orig_cmd" ]; then
  orig_out=$(printf '%s' "$input" | /bin/sh -c "$orig_cmd" 2>/dev/null | head -n 1)
fi

if [ -z "$orig_out" ]; then
  # ponytail: broken/missing original → our full line beats an empty bar
  printf '%s' "$input" | "$RENDER"
  exit 0
fi

seg=$("$RENDER" --segment </dev/null 2>/dev/null || true)
if [ -n "$seg" ]; then
  MUTED=$'\033[38;2;110;100;90m'; RESET=$'\033[0m'
  printf '%s\n' "${orig_out}  ${MUTED}·${RESET}  ${seg}"
else
  printf '%s\n' "$orig_out"
fi
exit 0
