# Real-dataset sources

The page images are committed under `datasets/real/images` (the project owner confirmed they may be published). They were fetched with `tools/omr-real/fetch.sh` / `dl_list.sh` (browser User-Agent, >= 2.2 s between requests per host, no login/paywall/captcha bypass). Held-out pages: `datasets/holdout/sources.md`.

| site | page URL | terms note | ids |
|---|---|---|---|
| user-sample | (user-provided sample; origin unknown) | provided by the project owner | real-000 |
| 虫虫吉他 ccguitar.cn | https://www.ccguitar.cn/cchtml/68187779.htm | viewing page; copyright of score authors | real-001 |
| GitHub elephantnose/Guitar-chords (唯音悦 scores) | https://github.com/elephantnose/Guitar-chords | repo has no license; scores (c) original arrangers | real-002, real-003, real-004, real-005, real-006, real-007, real-008, real-009, real-010 |
| 吉他世界 guitarworld.com.cn | https://www.guitarworld.com.cn/pu/q6535 | public page; copyright of arrangers | real-011 |
| 吉他世界 guitarworld.cc | https://www.guitarworld.cc/thread-2664-1-1.html | site says free to save; (c) arranger 高音教 | real-013 |
| 吉他世界 guitarworld.cc | https://www.guitarworld.cc/thread-9599-1-1.html | site says free to save; (c) arranger 高音教 | real-014 |
| 吉他世界 guitarworld.cc | https://www.guitarworld.cc/thread-11900-1-1.html | site says free to save | real-015, real-016, real-017 |
| 简谱之家 jianpujia.com | https://www.jianpujia.com/jitapu/270091.html | free download page; (c) arranger 虫虫吉他 | real-018 |
| 吉他帮 jitabang.com | https://www.jitabang.com/jitapu/7782.html | public page | real-019, real-020, real-021 |
| 吉他帮 jitabang.com | https://www.jitabang.com/jitapu/72745.html | public page | real-022, real-023, real-024 |
| 吉他帮 jitabang.com | https://www.jitabang.com/jitapu/6023.html | public page | real-025, real-026, real-027 |
| 吉他帮 jitabang.com | https://www.jitabang.com/jiaoxue/7801.html | public page | real-028, real-029, real-030 |
| 吉他帮 jitabang.com | https://www.jitabang.com/jitapu/6698.html | public page | real-031, real-032 |
| 吉他派 jitapai.com | https://www.jitapai.com/202459457.html | public page | real-033, real-034 |
| 吉他派 jitapai.com | https://www.jitapai.com/202357133.html | public page | real-035, real-036 |
| 吉他派 jitapai.com | https://www.jitapai.com/202459477.html | public page | real-037 |
| 吉他派 jitapai.com | https://www.jitapai.com/202357702.html | public page | real-038, real-039 |
| 吉他派 jitapai.com | https://www.jitapai.com/202457705.html | public page | real-040, real-041 |
| 吉他社 jitashe.org | https://www.jitashe.org/thread/1314274/ | public thread; uploader-owned | real-042 |
| 吉他社 jitashe.org | https://www.jitashe.org/thread/1339571/ | public thread; uploader-owned | real-043, real-044 |
| 吉他社 jitashe.org | https://www.jitashe.org/thread/1391555/ | public thread; uploader-owned | real-045, real-046 |
| 吉他社 jitashe.org | https://www.jitashe.org/thread/1391440/ | public thread; uploader-owned | real-047, real-048 |
| 吉他社 jitashe.org | https://www.jitashe.org/thread/1392966/ | public thread; uploader-owned | real-049 |
| 吉他社 jitashe.org | https://www.jitashe.org/thread/168518/ | public thread; uploader-owned | real-050 |

## Access notes
- Reachable: jitashe.org, jitabang.com, jitapai.com, guitarworld.cc/.com.cn, jianpujia.com, ccguitar.cn, raw.githubusercontent.com (image URLs from public article pages). Some sites publish no robots.txt (or an HTML error page).
- Blocked / skipped: jita2012.com (image URLs redirect to the home page when hot-linked), qinyipu.com (connection failed), chord4.com (Cloudflare challenge), qianliying.net (timeout). Wikimedia Commons: no freely licensed Chinese 弹唱六线谱 pages found.
- jitabang.com robots.txt disallows only /Feed/, /trackback/, /wp-admin/; jitapai.com only /wp-admin/.
- `real-000` is the owner-provided reference sample.
- Removed: a guitarworld.cc thumbnail that was a portrait photo, not a score (real-012 id retired).
