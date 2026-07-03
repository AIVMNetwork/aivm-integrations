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
# Renderer resolution: marketplace copy first (stable unversioned path — updates
# with the plugin), then the CLI-installed copy, then a sibling (dev checkout).
RENDER=""
for c in "$HOME/.claude/plugins/marketplaces/aivm/statusline/aivm-statusline.sh" \
         "$AGENT_DIR/statusline/aivm-statusline.sh" \
         "$(dirname "$0")/aivm-statusline.sh"; do
  [ -f "$c" ] && RENDER="$c" && break
done
[ -z "$RENDER" ] && exit 0

input=$(cat 2>/dev/null || true)

# Backup schema (written by `aivm-brain statusline install`):
#   {"version":1, "hadStatusLine":bool, "original": {"type":"command","command":"..."} | null}
orig_cmd=$(python3 -c "
import json
try: print(((json.load(open('$BACKUP')).get('original') or {}).get('command') or ''))
except Exception: print('')" 2>/dev/null)

orig_out=""
if [ -n "$orig_cmd" ]; then
  orig_out=$(printf '%s' "$input" | /bin/sh -c "$orig_cmd" 2>/dev/null)
fi

if [ -z "$orig_out" ]; then
  # ponytail: broken/missing original → our full line beats an empty bar
  printf '%s' "$input" | bash "$RENDER"
  exit 0
fi

seg=$(bash "$RENDER" --segment </dev/null 2>/dev/null || true)
first=$(printf '%s\n' "$orig_out" | sed -n '1p')
rest=$(printf '%s\n' "$orig_out" | sed -n '2,$p')
if [ -n "$seg" ]; then
  MUTED=$'\033[38;2;110;100;90m'; RESET=$'\033[0m'
  printf '%s\n' "${first}  ${MUTED}·${RESET}  ${seg}"
else
  printf '%s\n' "$first"
fi
[ -n "$rest" ] && printf '%s\n' "$rest"
exit 0
