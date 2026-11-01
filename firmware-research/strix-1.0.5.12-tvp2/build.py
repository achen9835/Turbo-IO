"""Reproduce exact tested TVP2 from official ZIP. Never connects to a device.

Patch-table invariant (2026-11-01 incident):
  The 40 in-place patches in the stock AP contain fixed Thumb branch encodings
  (B.W / BL) that jump into the injected module. Those encodings depend on the
  linked module symbol addresses. Any source edit that changes module layout
  shifts later symbols and silently turns those branches into garbage -- the
  first 11B candidate hung on the RayNeo boot logo because 17 branches were
  stale. Every edit whose target is a module symbol now carries targetSymbol
  and targetOffset; build() recomputes the encoding from the freshly linked
  ELF and STOPS if the checked-in bytes no longer match. After editing module
  sources run:

      python3 build.py --stock <official.zip> --llvm-bin <llvm/bin> \
          --out build/repin --repin [--code-name ...] [--display-name ...]

  which re-links, refreshes the patch table/pins in build-inputs.json,
  candidate-ota.json and verification.json, and installs the new candidate zip.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import zipfile
from port_audit import audit as audit_addresses

HERE = Path(__file__).resolve().parent
FLASH = 0x10190000


def sha(data, algorithm='sha256'):
    return hashlib.new(algorithm, data).hexdigest()


def run(arguments):
    r = subprocess.run([str(a) for a in arguments], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stderr)
    return r.stdout


def safe_zip(path, expected=None):
    if expected:assert sha(path.read_bytes()) == expected, 'Wrong input archive'
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        assert len(names) == len(set(names)) == 16
        assert all(n == Path(n).name and not n.startswith('.') for n in names)
        assert sum(i.file_size for i in z.infolist()) < 24_000_000
        assert all((i.external_attr >> 16) & 0o170000 != 0o120000 for i in z.infolist())
        assert z.testzip() is None
        files = {n: z.read(n) for n in names}
    rows = json.loads(files['OtaFileInfo.json'])
    assert isinstance(rows, list) and len(rows) == 15
    assert len({r['Name'] for r in rows}) == 15
    assert set(files) == {r['Name'] for r in rows} | {'OtaFileInfo.json'}
    for r in rows:
        b = files[r['Name']]
        assert len(b) == r['Size'] and sha(b, 'md5') == r['Md5']
    return files, rows


# ---- Thumb-2 branch codec (B.W T4 and BL T1 share the immediate layout used by
# ---- the stock patch table; the second halfword differs in its fixed prefix). --

def decode_branch(code, site):
    if len(code) < 4:
        return None
    h1, h2 = struct.unpack_from('<HH', code)
    if h1 & 0xF800 != 0xF000 or (h2 & 0xD000) not in (0x9000, 0xD000):
        return None
    s, i1, i2 = (h1 >> 10) & 1, (h2 >> 13) & 1, (h2 >> 11) & 1
    value = (s << 24) | ((0 if s ^ i1 else 1) << 23) | ((0 if s ^ i2 else 1) << 22)
    value |= ((h1 & 0x3FF) << 12) | ((h2 & 0x7FF) << 1)
    if value & (1 << 24):
        value -= 1 << 25
    return site + 4 + value


def branch_kind(code):
    h1, h2 = struct.unpack_from('<HH', code)
    if h1 & 0xF800 != 0xF000:
        raise ValueError('not a Thumb-2 wide branch: ' + code.hex())
    if h2 & 0xC000 == 0x8000:
        return 'bw'
    if h2 & 0xC000 == 0xC000:
        return 'bl'
    raise ValueError('unknown Thumb-2 branch kind: ' + code.hex())


def encode_branch(site, target, kind):
    off = target - (site + 4)
    if off & 1 or not (-(1 << 24) <= off < (1 << 24)):
        raise ValueError('branch offset out of range')
    u = off & 0x1FFFFFF
    s, i1, i2 = (u >> 24) & 1, (u >> 23) & 1, (u >> 22) & 1
    imm10, imm11 = (u >> 12) & 0x3FF, (u >> 1) & 0x7FF
    j1, j2 = i1 ^ s ^ 1, i2 ^ s ^ 1
    h1 = 0xF000 | (s << 10) | imm10
    if kind == 'bw':
        h2 = 0x9000 | (j1 << 13) | (j2 << 11) | imm11
    else:
        h2 = 0xD000 | (j1 << 13) | (j2 << 11) | imm11
    code = struct.pack('<HH', h1, h2)
    assert decode_branch(code, site) == target, ('branch round-trip failed', kind, hex(site), hex(target))
    return code


def module_symbols(llvm, elf):
    symbols = {}
    for line in run([llvm / 'llvm-nm', '-n', '--defined-only', elf]).splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        try:
            address = int(parts[0], 16)
        except ValueError:
            continue
        symbols.setdefault(parts[2], address)
    return symbols


def resolve_edits(spec, llvm, elf, repin=False):
    symbols = module_symbols(llvm, elf)
    module_va = int(spec['moduleVA'], 16)
    resolved = []
    for row in spec['edits']:
        row = dict(row)
        name = row.get('targetSymbol')
        if not name:
            resolved.append(row)
            continue
        assert name in symbols, ('patch target symbol missing', name)
        target = symbols[name]
        offset = target - module_va
        code = bytes.fromhex(row['after'])
        kind = branch_kind(code[:4])
        encoded = encode_branch(int(row['address'], 16), target, kind)
        if repin:
            row['after'] = (encoded + code[4:]).hex()
            row['targetOffset'] = hex(offset)
        else:
            assert 'targetOffset' in row, ('patch target has no pinned offset; run --repin', name)
            assert int(row['targetOffset'], 16) == offset, (
                'module layout shifted for ' + name + ': pinned ' + row['targetOffset'] +
                ' vs actual ' + hex(offset) + '; run build.py --repin before flashing')
            assert code[:4] == encoded, (
                'stale patch encoding for ' + name + '; run build.py --repin before flashing')
        resolved.append(row)
    return resolved


def audit_patch_branches(spec, ap, module_bytes):
    module_start = int(spec['moduleVA'], 16)
    for row in spec['edits']:
        code = bytes.fromhex(row['after'])
        if len(code) < 4:
            continue
        target = decode_branch(code, int(row['address'], 16))
        if target is None:
            continue
        assert module_start <= target < module_start + module_bytes, ('Patch branch outside module', row['role'], hex(target))


def audit(stock_path, candidate_path, spec=None):
    if spec is None:
        spec = json.loads((HERE / 'build-inputs.json').read_text(encoding='utf-8'))
    stock, before = safe_zip(stock_path, spec['stockZIP'])
    files, after = safe_zip(candidate_path, spec['archive'].get('sha256'))
    ap = files['nuttx_ap.bin']
    base = stock['nuttx_ap.bin']
    address_result = audit_addresses(base)
    if spec.get('APSHA256'):assert len(ap) == spec['APBytes'] and sha(ap) == spec['APSHA256']
    assert len(ap) < 9_600_000
    assert [r['Name'] for r in before] == [r['Name'] for r in after]
    for old, new in zip(before, after):
        if old['Name'] == 'nuttx_ap.bin':
            assert {k:v for k,v in old.items() if k not in ('Size','Md5')} == {k:v for k,v in new.items() if k not in ('Size','Md5')}
        else:
            assert old == new and stock[old['Name']] == files[new['Name']]
    assert ap[:16] == base[:16] and ap[-8:] == base[-8:]
    for at in (0x408, 0x414, 0x574, 0x580, 0x58c, 0x598, 0x674):
        assert ap[at:at+12] == base[at:at+12]
    module_va = int(spec['moduleVA'], 16)
    allowed = set()
    for e in spec['edits']:
        at = int(e['offset'], 16)
        a, b = bytes.fromhex(e['before']), bytes.fromhex(e['after'])
        assert len(a) == len(b) and base[at:at+len(a)] == a and ap[at:at+len(b)] == b
        if e.get('targetSymbol'):
            assert e.get('targetOffset'), ('patch target offset missing', e.get('role'))
            decoded = decode_branch(b, int(e['address'], 16))
            assert decoded == module_va + int(e['targetOffset'], 16), (
                'patch table does not point at the pinned symbol offset', e.get('role'))
        assert not allowed.intersection(range(at, at+len(b)))
        allowed.update(range(at, at+len(b)))
    assert len(spec['edits']) == 40
    assert all(x == y or i in allowed for i, (x,y) in enumerate(zip(base[:-8],ap)))
    at = int(spec['moduleVA'], 16) - FLASH
    assert not any(ap[len(base)-8:at])
    module_bytes = len(ap) - 8 - at
    audit_patch_branches(spec, ap, module_bytes)
    if spec.get('moduleSHA256'):
        assert sha(ap[at:at+spec['moduleBytes']]) == spec['moduleSHA256']
        assert not any(ap[at+spec['moduleBytes']:-8])
    return {'passed':True, 'baseline':'1.0.5.12','customChangedPayloads':['nuttx_ap.bin'],
        'unchangedNewStockPayloads':14,'manifestPayloads':15,'archiveEntries':16,
        'APBytes':len(ap),'APSHA256':sha(ap),'APMD5':sha(ap,'md5'),
        'archiveSHA256':sha(candidate_path.read_bytes()),'archiveMD5':sha(candidate_path.read_bytes(),'md5'),
        'whitelistedPatches':40,'startupDescriptorsPreserved':7,'deviceIO':False,**address_result}


def build(stock_path, llvm, out, spec=None, repin=False):
    if spec is None:
        spec = json.loads((HERE / 'build-inputs.json').read_text())
    stock, rows = safe_zip(stock_path, spec['stockZIP'])
    assert sha(stock['nuttx_ap.bin']) == spec['stockAP']
    audit_addresses(stock['nuttx_ap.bin'])
    assert not out.exists(), 'Choose a fresh output directory'
    out.mkdir(parents=True)
    src = HERE / 'src'
    flags = ['--target=arm-none-eabi','-mcpu=cortex-m33','-mthumb','-mfloat-abi=hard',
        '-mfpu=fpv5-sp-d16','-ffreestanding','-fno-builtin',
        '-Os','-Wall','-Wextra','-Werror',
        '-I',str(src),'-I',str(src/'app-runtime-v1/arm-include'),'-I',str(HERE/'include'),
        '-include',str(src/'firmware_profile.h'),'-DTIO_IMAGE_RX_WIDE=1',
        '-DTIO_DISPLAY_RUNTIME=1','-DTDP_FREESTANDING','-DTIO_ANIMATION_EXPERIMENT=1',
        '-DTIO_MUSIC_RUNTIME=1','-DTD_DIAGNOSTICS_RUNTIME=1','-DTD_FREESTANDING=1',
        '-DTD_STOCK_10412=0','-DTD_STOCK_10512=1']
    objects = []
    animation = HERE/'assets/animation-frames.l8'
    assert sha(animation.read_bytes()) == 'f758dd6e3cdf5fc6550238df26e46111e9d45d098b9d95f649626ea58210ee1d'
    asm = out/'animation-asset.S'
    asm.write_text('.section .rodata.ta_asset,"a",%progbits\n.balign 64\n.global ta_asset\n.type ta_asset,%object\nta_asset:\n.incbin "'+animation.as_posix()+'", 0, 33792\n.size ta_asset, .-ta_asset\n')
    for i,row in enumerate(spec['sources']):
        p = asm if row['path']=='@generated-animation' else HERE/row['path']
        if row.get('sha256'):assert sha(p.read_bytes())==row['sha256'], 'Edited source: '+row['path']
        obj = out/(str(i)+'-'+p.stem+'.o')
        run([llvm/'clang',*flags,'-c',p,'-o',obj]);objects.append(obj)
    elf = out/'module.elf'
    run([llvm/'ld.lld','-T',HERE/'link.ld','--entry=m8_hook_ctor',*objects,'-o',elf])
    assert not run([llvm/'llvm-nm','-u',elf]).strip()
    run([llvm/'llvm-objcopy','-O','binary',elf,out/'module.bin'])
    module = (out/'module.bin').read_bytes()
    if spec.get('moduleSHA256') and not repin:
        assert sha(module) == spec['moduleSHA256'], 'Toolchain/source differs from tested module; STOP'
    edits = resolve_edits(spec, llvm, elf, repin=repin)
    base = stock['nuttx_ap.bin']; at = int(spec['moduleVA'],16)-FLASH
    ap = bytearray(base[:-8]) + bytearray(at-(len(base)-8)) + module
    ap += bytearray((-len(ap))%4) + base[-8:]
    for e in edits:
        offset = int(e['offset'],16); old, new = bytes.fromhex(e['before']),bytes.fromhex(e['after'])
        assert ap[offset:offset+len(old)] == old
        ap[offset:offset+len(new)] = new
    if spec.get('APSHA256') and not repin:
        assert len(ap) == spec['APBytes'] and sha(ap) == spec['APSHA256']
    assert len(ap) < 9_600_000, 'AP size budget'
    stock['nuttx_ap.bin'] = bytes(ap)
    for row in rows:
        if row['Name'] == 'nuttx_ap.bin': row.update(Size=len(ap),Md5=sha(ap,'md5'))
    stock['OtaFileInfo.json'] = (json.dumps(rows,indent=2)+'\n').encode()
    archive = out/spec['archive']['name']
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
        for name,data in sorted(stock.items()):
            info = zipfile.ZipInfo(name,(2026,10,16,0,0,0));info.compress_type=zipfile.ZIP_DEFLATED
            info.external_attr=0o100600<<16;z.writestr(info,data,compresslevel=9)
    final_spec = dict(spec); final_spec['edits'] = edits
    result = audit(stock_path, archive, spec=final_spec)
    result.update({'moduleBytes':len(module), 'moduleSHA256':sha(module), 'edits':edits,
                   'archivePath':str(archive), 'moduleVA':spec['moduleVA']})
    (out/'audit.json').write_text(json.dumps(result,indent=2)+'\n')
    return result


def _write_json(path, value, newline='\r\n', indent=1):
    text = json.dumps(value, indent=indent, ensure_ascii=False) + '\n'
    path.write_bytes(text.replace('\n', newline).encode('utf-8'))


def repin(stock_path, llvm, out, code_name=None, display_name=None):
    spec_path = HERE/'build-inputs.json'
    spec = json.loads(spec_path.read_text(encoding='utf-8'))
    working = json.loads(json.dumps(spec))
    for key in ('moduleSHA256','APBytes','APSHA256'):
        working.pop(key, None)
    working['archive'].pop('sha256', None)
    result = build(stock_path, llvm, out, spec=working, repin=True)
    edits = result['edits']
    spec['edits'] = edits
    spec['moduleBytes'] = result['moduleBytes']
    spec['moduleSHA256'] = result['moduleSHA256']
    spec['APBytes'] = result['APBytes']
    spec['APSHA256'] = result['APSHA256']
    spec['archive']['sha256'] = result['archiveSHA256']
    _write_json(spec_path, spec)
    archive = Path(result['archivePath'])
    files, rows = safe_zip(archive)
    manifest = files['OtaFileInfo.json']
    pins = [{'name':'OtaFileInfo.json','size':len(manifest),'sha256':sha(manifest)}]
    pins += [{'name':n,'size':len(files[n]),'sha256':sha(files[n])} for n in sorted(files) if n != 'OtaFileInfo.json']
    ap = files['nuttx_ap.bin']
    cand_path = HERE/'candidate-release'/'candidate-ota.json'
    cand = json.loads(cand_path.read_text(encoding='utf-8'))
    if code_name: cand['codeName'] = code_name
    if display_name: cand['displayName'] = display_name
    cand['zip'] = {'size':archive.stat().st_size, 'sha256':result['archiveSHA256']}
    cand['otaSize'] = archive.stat().st_size
    cand['ap'] = {'name':'nuttx_ap.bin','size':len(ap),'sha256':sha(ap),'md5':sha(ap,'md5')}
    cand['manifest'] = {'name':'OtaFileInfo.json','size':len(manifest),'sha256':sha(manifest)}
    cand['payloadPins'] = pins
    _write_json(cand_path, cand, indent=2)
    ver_path = HERE/'verification.json'
    ver = json.loads(ver_path.read_text(encoding='utf-8'))
    ver['candidate'] = cand['codeName']
    ver['APBytes'] = len(ap); ver['APSHA256'] = sha(ap); ver['APMD5'] = sha(ap,'md5')
    ver['moduleBytes'] = result['moduleBytes']; ver['moduleSHA256'] = result['moduleSHA256']
    ver['archiveBytes'] = archive.stat().st_size; ver['archiveSHA256'] = result['archiveSHA256']
    _write_json(ver_path, ver, newline='\n', indent=2)
    (HERE/'candidate-release'/'firmware.zip').write_bytes(archive.read_bytes())
    final = audit(stock_path, archive, spec=spec)
    (out/'audit.json').write_text(json.dumps(final,indent=2)+'\n')
    print(json.dumps({'repinned':True, 'candidate':cand['codeName'], 'zipBytes':archive.stat().st_size,
        'zipSHA256':result['archiveSHA256'], 'APBytes':len(ap), 'APSHA256':sha(ap), 'APMD5':sha(ap,'md5'),
        'manifestBytes':len(manifest), 'manifestSHA256':sha(manifest), 'moduleBytes':result['moduleBytes'],
        'moduleSHA256':result['moduleSHA256']}, indent=2))
    return final


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--stock',type=Path,required=True)
    parser.add_argument('--audit',type=Path);parser.add_argument('--llvm-bin',type=Path);parser.add_argument('--out',type=Path)
    parser.add_argument('--repin',action='store_true')
    parser.add_argument('--code-name');parser.add_argument('--display-name')
    args = parser.parse_args()
    if args.audit: result = audit(args.stock,args.audit)
    else:
        assert args.llvm_bin and args.out
        if args.repin:
            result = repin(args.stock.resolve(),args.llvm_bin.resolve(),args.out.resolve(),args.code_name,args.display_name)
        else:
            result = build(args.stock.resolve(),args.llvm_bin.resolve(),args.out.resolve())
    print(json.dumps(result,indent=2))


if __name__ == '__main__':
    main()