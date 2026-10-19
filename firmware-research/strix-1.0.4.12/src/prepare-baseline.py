"""Offline extraction of the exact published, repacked original baseline.
No devices, network, overwrites, recursive cleanup or flash authorization.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('gate', Path(__file__).with_name('preflight-menu8-ota.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def prepare(archive, output):
    if output.exists():
        raise ValueError('Output exists; choose a new directory. Nothing removed.')
    with archive.open('rb') as stream:
        blob = stream.read(gate.MAX_ZIP + 1)
    # 钉值 = stock-strix-1.0.4.12-archive Release 正式资产（SHA256SUMS.txt 认证
    # 54eb155b…）；2026-10-19 更新，旧值 22c1d844… 为云 Mac 时代的早期副本。
    # 更新前已做成员级核对：ZIP 内 14/14 负载与 metadata/baseline.json 指纹一致。
    if hashlib.sha256(blob).hexdigest() != '54eb155b1b9980c0334005c2051720879204b6b5448180ee594eb735b92e905a':
        raise ValueError('Not the pinned original baseline ZIP')
    baseline = json.loads((ROOT / 'metadata/baseline.json').read_text())
    pins = {r['name']: r for r in baseline['files']}
    members = gate.read_members(blob, set(pins) | {'OtaFileInfo.json'})
    for name, data in members.items():
        if name in pins and hashlib.sha256(data).hexdigest() != pins[name]['sha256']:
            raise ValueError('Baseline member differs: ' + name)
    for row in gate.parse_manifest(members['OtaFileInfo.json']):
        data = members[row['Name']]
        if len(data) != row['Size'] or hashlib.md5(data).hexdigest() != row['Md5']:
            raise ValueError('Manifest mismatch')
    output.mkdir(parents=True, mode=0o700)
    for name, data in members.items():
        with (output / name).open('xb') as f:
            f.write(data)
    for name in ('baseline.json', 'symbols.json'):
        with (output / name).open('xb') as f:
            f.write((ROOT / 'metadata' / name).read_bytes())
    print(json.dumps({'membersVerified': len(members), 'deviceIO': False, 'flashAuthorized': False}))


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('archive', type=Path)
    p.add_argument('--output', type=Path, default=ROOT / 'work/baseline')
    a = p.parse_args()
    prepare(a.archive, a.output)
