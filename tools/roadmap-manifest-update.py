#!/usr/bin/env python3
"""Merge a freshly built pack's .meta.json into the roadmap-packs manifest."""
import json
import sys
from pathlib import Path

# slug -> 中文显示名（Geofabrik 中国子区按拼音命名；缺失的回落到 slug 本身）
ZH = {
    'anhui': '安徽', 'beijing': '北京', 'chongqing': '重庆', 'fujian': '福建',
    'gansu': '甘肃', 'guangdong': '广东', 'guangxi': '广西', 'guizhou': '贵州',
    'hainan': '海南', 'hebei': '河北', 'heilongjiang': '黑龙江', 'henan': '河南',
    'hubei': '湖北', 'hunan': '湖南', 'neimenggu': '内蒙古', 'jiangsu': '江苏',
    'jiangxi': '江西', 'jilin': '吉林', 'liaoning': '辽宁', 'ningxia': '宁夏',
    'qinghai': '青海', 'shaanxi': '陕西', 'shandong': '山东', 'shanghai': '上海',
    'shanxi': '山西', 'sichuan': '四川', 'taiwan': '台湾', 'tianjin': '天津',
    'xinjiang': '新疆', 'xizang': '西藏', 'yunnan': '云南', 'zhejiang': '浙江',
    'hongkong': '香港', 'macau': '澳门', 'aomen': '澳门', 'xianggang': '香港',
}

manifest_path = Path(sys.argv[1])
meta = json.loads(Path(sys.argv[2]).read_text(encoding='utf-8'))

try:
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    if not isinstance(manifest, dict) or not isinstance(manifest.get('packs'), list):
        raise ValueError
except (OSError, ValueError):
    manifest = {'schema': 1, 'packs': []}

packs = [p for p in manifest['packs'] if p.get('province') != meta['province']]
slug = meta['province']
display = meta.get('display') or slug
if display == slug and slug in ZH:
    display = f'{ZH[slug]} · {slug}'
packs.append({
    'province': slug, 'display': display, 'file': meta['file'],
    'size': meta['size'], 'sha256': meta['sha256'], 'format': 1,
    'gridLat': meta['gridLat'], 'gridLon': meta['gridLon'], 'cells': meta['cells'],
    'bbox': meta['bbox'], 'builtAt': meta.get('builtAt', ''),
})
packs.sort(key=lambda p: p['province'])
manifest['packs'] = packs
manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
print(f'manifest now lists {len(packs)} packs')
