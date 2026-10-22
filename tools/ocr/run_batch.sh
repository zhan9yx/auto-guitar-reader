#!/bin/bash
# usage: run_batch.sh <agr-tool> <venv-python> <image.pgm>...   (images are the .pgm pages; OCR runs on the .jpg/.png twin if present)
# For each page: agr-tool omr regions -> <dir>/ocr/<stem>.regions.json, then ocr.py (one process, model loaded once).
TOOL="$1"; PY="$2"; shift 2
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIST=()
for p in "$@"; do
  d="$(dirname "$p")"; stem="$(basename "${p%.*}")"
  mkdir -p "$d/ocr"
  [ -f "$d/ocr/$stem.ocr.json" ] && continue
  "$TOOL" omr regions "$p" > "$d/ocr/$stem.regions.json" || continue
  img="$d/$stem.jpg"; [ -f "$img" ] || img="$d/$stem.png"; [ -f "$img" ] || img="$p"
  LIST+=("$img")
done
[ ${#LIST[@]} -gt 0 ] && "$PY" -I "$SCRIPT_DIR/ocr.py" "${LIST[@]}"
