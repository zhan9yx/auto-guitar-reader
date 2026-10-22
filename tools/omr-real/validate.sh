#!/usr/bin/env bash
# validate.sh <session-root> <worktree> : lint every GT with check_gt.py and decode it with the Swift model (agr-tool import).
set -u
S="$1"; W="$2"; R="$S/datasets/real"
source "$S/tools/env.sh"
PY="$R/.venv/bin/python -I"
$PY "$W/tools/omr-real/check_gt.py" "$R"/gt/*.agr.json || true
cd "$W/Core" && swift build -j 8 >/dev/null 2>&1
for f in "$R"/gt/*.agr.json; do
  if ./.build/debug/agr-tool import "$f" >/dev/null 2>"$R/tmp/imp.err"; then echo "swift-ok  $(basename "$f")"; else echo "SWIFT-FAIL $(basename "$f"): $(head -c 300 "$R/tmp/imp.err")"; fi
done
