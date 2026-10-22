#!/usr/bin/env bash
# dl_list.sh <list.tsv> <rawdir>   list lines: <site>\t<name>\t<url>\t<referer>
# Downloads each into <rawdir>/<site>/<name>; skips existing; verifies image magic.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
while IFS=$'\t' read -r site name url ref; do
  [ -z "$site" ] && continue
  out="$2/$site/$name"
  [ -s "$out" ] && continue
  echo -n "$site/$name  "
  "$HERE/fetch.sh" "$url" "$out" "$ref"
  # keep only genuine images
  if ! head -c 12 "$out" | od -An -tx1 | tr -d ' \n' | grep -qiE '^(ffd8ff|89504e47|52494646|47494638)'; then echo "  not an image; removed"; rm -f "$out"; fi
done < "$1"
