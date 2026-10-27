#!/usr/bin/env python3
"""Merge a freshly built pack's .meta.json into the roadmap-packs manifest."""
import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
meta = json.loads(Path(sys.argv[2]).read_text(encoding='utf-8'))

try:
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    if not isinstance(manifest, dict) or not isinstance(manifest.get('packs'), list):
        raise ValueError
except (OSError, ValueError):
    manifest = {'schema': 1, 'packs': []}

packs = [p for p in manifest['packs'] if p.get('province') != meta['province']]
packs.append({
    'province': meta['province'], 'display': meta['display'], 'file': meta['file'],
    'size': meta['size'], 'sha256': meta['sha256'], 'format': 1,
    'gridLat': meta['gridLat'], 'gridLon': meta['gridLon'], 'cells': meta['cells'],
    'bbox': meta['bbox'], 'builtAt': meta.get('builtAt', ''),
})
packs.sort(key=lambda p: p['province'])
manifest['packs'] = packs
manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
print(f'manifest now lists {len(packs)} packs')
