#!/usr/bin/env bash
# Generated-copy drift guard — run: bash tests/embed-drift-check.sh
# ==================================================================
# THE CANONICAL SOURCE OF THE STATUSLINE IS THIS REPO: statusline/*.sh
# The CLI package (@aivm/brain) ships EMBEDDED copies in
# packages/aivm-brain/src/statusline-scripts.ts, produced by
# packages/aivm-brain/scripts/embed-statusline.cjs, which READS the files here and
# OVERWRITES that TypeScript file wholesale.
#
# Why this guard exists (2026-08-13, M1). Someone hand-edited the GENERATED file to add the
# rate-limit `resets_at` rendering. That edit existed ONLY there: canonical had 0 occurrences,
# the generated copy had 5. Two consequences, both landmines:
#   * editing only the canonical .sh changed nothing at runtime for anyone on the CLI install; and
#   * obeying the generated file's own "regenerate me" header would have SILENTLY DELETED the
#     resets_at feature, and the build would have looked clean.
# Drift between the two is therefore not cosmetic — it is a mechanism for losing work and for
# shipping a security fix that never reaches users. This guard fails the moment they diverge.
#
# It never writes into the CLI package: regeneration happens in a temp dir and is diffed.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Locate the CLI package (it lives in a DIFFERENT repository).
PKG="${AIVM_BRAIN_PKG:-}"
if [ -z "$PKG" ]; then
  for c in "$DIR/../aivm-brain-poc-classic-eco/packages/aivm-brain" \
           "$DIR/../aivm-brain-poc/packages/aivm-brain" \
           "$HOME/code/aivm-brain-poc-classic-eco/packages/aivm-brain" \
           "$HOME/code/aivm-brain-poc/packages/aivm-brain"; do
    [ -f "$c/src/statusline-scripts.ts" ] && PKG="$(cd "$c" && pwd)" && break
  done
fi

if [ -z "$PKG" ]; then
  echo "embed-drift-check: the @aivm/brain package was not found."
  echo "  Point at it with:  AIVM_BRAIN_PKG=/path/to/packages/aivm-brain bash tests/embed-drift-check.sh"
  if [ "${AIVM_DRIFT_SKIP_IF_MISSING:-0}" = "1" ]; then
    # Set EXPLICITLY by the workflow, never silently: this repo's CI checks out only this repo,
    # so the cross-repo half of the guard cannot run there. The RELEASING.md pair-gate is where
    # it is mandatory — that is the step at which the two repos actually ship together.
    echo "  SKIPPED (AIVM_DRIFT_SKIP_IF_MISSING=1). This guard is MANDATORY in RELEASING.md step 4b."
    exit 0
  fi
  exit 1
fi

command -v node >/dev/null 2>&1 || { echo "embed-drift-check: node is required"; exit 1; }
GEN="$PKG/scripts/embed-statusline.cjs"
CUR="$PKG/src/statusline-scripts.ts"
[ -f "$GEN" ] || { echo "embed-drift-check: missing generator $GEN"; exit 1; }
[ -f "$CUR" ] || { echo "embed-drift-check: missing generated file $CUR"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts" "$TMP/src"
cp "$GEN" "$TMP/scripts/"
node "$TMP/scripts/embed-statusline.cjs" "$DIR/statusline" >/dev/null || {
  echo "embed-drift-check: regeneration FAILED"; exit 1; }

if diff -q "$CUR" "$TMP/src/statusline-scripts.ts" >/dev/null 2>&1; then
  echo "ok: $CUR is an exact regeneration of $DIR/statusline/*.sh"
  exit 0
fi

# Decode both sides so the diff is readable SHELL, not one 16 KB JSON string literal.
decode() {
  node -e '
const fs=require("fs");
const m=fs.readFileSync(process.argv[1],"utf8");
const grab=(n)=>{const i=m.indexOf("export const "+n+" = ");if(i<0)return "";const j=m.indexOf(";\n",i);
  return JSON.parse(m.slice(i+("export const "+n+" = ").length,j));};
fs.writeFileSync(process.argv[2]+"/renderer.sh",grab("RENDERER_SH"));
fs.writeFileSync(process.argv[2]+"/wrapper.sh",grab("WRAPPER_SH"));
' "$1" "$2"
}
mkdir -p "$TMP/have" "$TMP/want"
decode "$CUR" "$TMP/have"
decode "$TMP/src/statusline-scripts.ts" "$TMP/want"

echo "FAIL: the generated copy has DRIFTED from the canonical scripts."
echo "  canonical (source of truth) : $DIR/statusline/{aivm-statusline.sh,aivm-statusline-wrap.sh}"
echo "  generated (must match)      : $CUR"
echo
echo "  READ THIS DIFF BEFORE REGENERATING. '-' is what the generated copy has today; '+' is what"
echo "  regenerating would replace it with. Anything on a '-' line that is NOT in the canonical .sh"
echo "  is real, unbackported behaviour — port it into the canonical file FIRST, or regeneration"
echo "  will delete it and the build will look clean. (That is exactly how the rate-limit"
echo "  resets_at rendering came within one command of being lost, 2026-08-13.)"
for f in renderer wrapper; do
  if ! diff -q "$TMP/have/$f.sh" "$TMP/want/$f.sh" >/dev/null 2>&1; then
    echo
    echo "  --- ${f}: generated (have) vs regenerated-from-canonical (want) ---"
    diff -u "$TMP/have/$f.sh" "$TMP/want/$f.sh" | sed -n '1,200p'
  fi
done
echo
echo "  Once the canonical .sh is the superset:  node $GEN $DIR/statusline"
exit 1
