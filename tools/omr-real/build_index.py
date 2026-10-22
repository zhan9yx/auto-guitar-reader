#!/usr/bin/env python3
"""build_index.py : writes datasets/real/index.json from images/map.json, a static source table and gt/*.meta.json (if present)."""
import json, os, glob
from PIL import Image
R = os.environ['OMR_REAL_ROOT']
SRC = {  # raw dir/name-prefix -> (page url, site, terms note)
 '_ref/': ('(user-provided sample; origin unknown)', 'user-sample', 'provided by the project owner'),
 'ccguitar/youpu': ('https://www.ccguitar.cn/cchtml/68187779.htm', '虫虫吉他 ccguitar.cn', 'viewing page; copyright of score authors'),
 'github-elephantnose/': ('https://github.com/elephantnose/Guitar-chords', 'GitHub elephantnose/Guitar-chords (唯音悦 scores)', 'repo has no license; scores (c) original arrangers'),
 'guitarworld-cn/xiaochou': ('https://www.guitarworld.com.cn/pu/q6535', '吉他世界 guitarworld.com.cn', 'public page; copyright of arrangers'),
 'guitarworld/buran': ('https://www.guitarworld.cc/thread-2664-1-1.html', '吉他世界 guitarworld.cc', 'site says free to save; (c) arranger 高音教'),
 'guitarworld/wuwen': ('https://www.guitarworld.cc/thread-9599-1-1.html', '吉他世界 guitarworld.cc', 'site says free to save; (c) arranger 高音教'),
 'guitarworld/xiaoxingyun': ('https://www.guitarworld.cc/thread-11900-1-1.html', '吉他世界 guitarworld.cc', 'site says free to save'),
 'jianpujia/': ('https://www.jianpujia.com/jitapu/270091.html', '简谱之家 jianpujia.com', 'free download page; (c) arranger 虫虫吉他'),
 'jitabang/guiji': ('https://www.jitabang.com/jitapu/7782.html', '吉他帮 jitabang.com', 'public page'),
 'jitabang/kaibuliaokou': ('https://www.jitabang.com/jitapu/72745.html', '吉他帮 jitabang.com', 'public page'),
 'jitabang/qilixiang': ('https://www.jitabang.com/jitapu/6023.html', '吉他帮 jitabang.com', 'public page'),
 'jitabang/shouxie': ('https://www.jitabang.com/jiaoxue/7801.html', '吉他帮 jitabang.com', 'public page'),
 'jitabang/xinyu': ('https://www.jitabang.com/jitapu/6698.html', '吉他帮 jitabang.com', 'public page'),
 'jitapai/caier23': ('https://www.jitapai.com/202459457.html', '吉他派 jitapai.com', 'public page'),
 'jitapai/laonanhai': ('https://www.jitapai.com/202357133.html', '吉他派 jitapai.com', 'public page'),
 'jitapai/qingge': ('https://www.jitapai.com/202459477.html', '吉他派 jitapai.com', 'public page'),
 'jitapai/songbie': ('https://www.jitapai.com/202357702.html', '吉他派 jitapai.com', 'public page'),
 'jitapai/xiaoxingyun': ('https://www.jitapai.com/202457705.html', '吉他派 jitapai.com', 'public page'),
 'jitashe/chengdu': ('https://www.jitashe.org/thread/1314274/', '吉他社 jitashe.org', 'public thread; uploader-owned'),
 'jitashe/shaonianjinshi': ('https://www.jitashe.org/thread/1339571/', '吉他社 jitashe.org', 'public thread; uploader-owned'),
 'jitashe/wojide-gm': ('https://www.jitashe.org/thread/1391440/', '吉他社 jitashe.org', 'public thread; uploader-owned'),
 'jitashe/wojide': ('https://www.jitashe.org/thread/1391555/', '吉他社 jitashe.org', 'public thread; uploader-owned'),
 'jitashe/xiaoxingji': ('https://www.jitashe.org/thread/1392966/', '吉他社 jitashe.org', 'public thread; uploader-owned'),
 'jitashe/xiaoxingyun': ('https://www.jitashe.org/thread/168518/', '吉他社 jitashe.org', 'public thread; uploader-owned'),
}
m = json.load(open(f'{R}/images/map.json')); out = []
for i in sorted(m):
    rel = m[i]; key = max((k for k in SRC if rel.startswith(k)), key=len)
    url, site, terms = SRC[key]
    f = (glob.glob(f'{R}/images/{i}.png') + glob.glob(f'{R}/images/{i}.jpg'))[0]
    w, h = Image.open(f).size
    e = {'id': i, 'file': os.path.basename(f), 'pgm': i + '.pgm', 'rawPath': 'raw/' + rel, 'site': site, 'sourceUrl': url, 'terms': terms, 'width': w, 'height': h, 'hasGT': False}
    mp = f'{R}/gt/{i}.meta.json'
    if os.path.exists(mp):
        mt = json.load(open(mp)); e.update(hasGT=True, style=mt.get('style'), features=mt.get('features', []), watermarks=mt.get('watermarks', []), pageNumber=mt.get('pageNumber'))
    out.append(e)
sites = {}
for e in out: sites.setdefault(e['sourceUrl'], 0); sites[e['sourceUrl']] += 1
for e in out: e['pagesFromSameSourceCollected'] = sites[e['sourceUrl']]
json.dump({'count': len(out), 'withGT': sum(e['hasGT'] for e in out), 'images': out}, open(f'{R}/index.json', 'w'), ensure_ascii=False, indent=1)
print(len(out), 'indexed')
