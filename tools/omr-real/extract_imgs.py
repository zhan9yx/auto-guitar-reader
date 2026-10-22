#!/usr/bin/env python3
"""extract_imgs.py <html-file> <base-url> [alt-substring]
Print candidate content image URLs (src / data-original / zoomfile / file) of an article page,
optionally only <img> tags whose alt/title contains the substring. Reads the file as untrusted text only."""
import re, sys, urllib.parse
html = open(sys.argv[1], encoding='utf-8', errors='replace').read()
base = sys.argv[2]
flt = sys.argv[3] if len(sys.argv) > 3 else ''
seen = []
for tag in re.findall(r'<img\b[^>]*>', html, flags=re.I):
    if flt and flt not in tag:
        continue
    for attr in ('zoomfile', 'file', 'data-original', 'data-src', 'src'):
        m = re.search(r'\b%s="([^"]+)"' % attr, tag)
        if m and not re.search(r'lazy|none\.gif|loading|blank', m.group(1), re.I):
            u = urllib.parse.urljoin(base, m.group(1).replace('&amp;', '&'))
            if u not in seen:
                seen.append(u)
            break
print('\n'.join(seen))
