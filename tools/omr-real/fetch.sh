#!/usr/bin/env bash
# Polite fetch helper: fetch.sh <url> <outfile> [referer]
# Browser UA, >= 2s between requests to the same host, honours a per-host stamp file in $OMR_REAL_STAMPS.
set -u
URL="$1"; OUT="$2"; REF="${3:-}"
STAMPS="${OMR_REAL_STAMPS:?set OMR_REAL_STAMPS to a directory inside the session root}"
mkdir -p "$STAMPS" "$(dirname "$OUT")"
HOST=$(printf '%s' "$URL" | sed -E 's#^[a-z]+://([^/]+).*#\1#')
STAMP="$STAMPS/$HOST"
if [ -f "$STAMP" ]; then
  NOW=$(date +%s.%N); LAST=$(cat "$STAMP")
  WAIT=$(awk -v n="$NOW" -v l="$LAST" 'BEGIN{w=2.2-(n-l); if(w<0)w=0; print w}')
  sleep "$WAIT"
fi
date +%s.%N > "$STAMP"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
ARGS=(-sL --max-time 40 --max-filesize 15000000 -A "$UA" -o "$OUT" -w '%{http_code} %{size_download} %{content_type}\n')
[ -n "$REF" ] && ARGS+=(-e "$REF")
curl "${ARGS[@]}" "$URL"
