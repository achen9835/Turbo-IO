import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import zipfile

HERE = Path(__file__).resolve().parent
FLASH = 0x10190000
OLD_ROOT = HERE.parent / 'strix-1.0.5.5-tvp2'
OLD_STOCK = HERE.parent / 'strix-1.0.5.5/stock/Strix-OS-1.0.5.5-original.zip'
NEW_STOCK = HERE / 'stock/Strix-OS-1.0.5.12-original.zip'
MAP_PATH = HERE / 'address-map.json'
ALIAS_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(0x[0-9a-fA-F]+);', re.M)

RESUME_ROLES = {
    'resume_show': 'Entry trampoline show',
    'resume_hide': 'Entry trampoline hide',
    'resume_destroy': 'Entry trampoline destroy',
    'resume_wheel': 'Entry trampoline wheel',
    'resume_event': 'Entry trampoline event',
    'resume_message': 'Entry trampoline message',
    'resume_dc_text': 'Entry trampoline dc_text',
    'resume_names': 'Entry trampoline names',
    'resume_dots': 'Entry trampoline dots',
    'resume_delete_dots': 'Entry trampoline delete_dots',
    'resume_lottie': 'Entry trampoline lottie',
    'resume_app_id': 'Entry trampoline app_id',
    'resume_refresh_label': 'Entry trampoline refresh_label',
    'resume_vm_event': 'Entry trampoline vm_event',
    'ce_stock_head_start_resume': 'ce_serial_start_entry',
    'ce_stock_head_stop_resume': 'ce_serial_stop_entry',
    'ce_stock_sys_destroy_resume': 'ce_serial_destroy_entry',
    'ce_stock_head_notify_resume': 'ce_head_notify_entry',
    'tdc_resume_source': 'tdc_hook_source',
    'tdc_resume_serialize': 'tdc_hook_serialize',
    'tdc_resume_message': 'tdc_hook_message',
}
FIXED_ROM = {'memcpy', 'memset', 'strlen', 'strcmp'}
MANUAL = {
    'tio_lv_image_create_ex': (0x10561b1c, 'image-create wrapper; calls the mapped LVGL create/set-target pair'),
    'ce_ext_106e7b5c': (0x105921c0, 'focus/monitor cluster beside ce_focus_manager'),
    'ce_ext_106b61f0': (0x10558732, 'unique 96-byte branch-relocated fingerprint'),
    'ce_ext_106b60c4': (0x10559998, 'JSON cluster beside ce_ext_106b61f0'),
    'ce_utc_time': (0x10586a48, 'unique 64-byte branch-relocated fingerprint'),
    'tgr_indev_next': (0x10550db4, 'input-device cluster; distinct from display/timer twins'),
    'dc_text_mode': (0x104c4614, 'unique 64-byte branch-relocated fingerprint'),
    'native_report_activity': (0x106392f8, 'unique 96-byte branch-relocated fingerprint'),
    'native_label_create': (0x104c3998, 'label cluster; same wrapper as canvas with distinct literal pool'),
    'stream_tick': (0x106d1ecc, 'unique 96-byte branch-relocated fingerprint'),
    'focus_screen_on': (0x1063924c, 'screen-power cluster beside nav_always_on'),
    'stream_canvas_create': (0x106ffa7c, 'canvas cluster immediately before mapped set_buffer'),
    'stream_stride': (0x104aec1c, 'wrapper preserves its local -0x14 call target'),
    'stream_display_next': (0x1054b5d8, 'display cluster; distinct from input/timer twins'),
    'nav_force_off': (0x10639210, 'screen-power cluster; line-number immediate differs'),
    'nav_monitors': (0x105921c0, 'same stock function as ce_ext_106e7b5c'),
    'port_stock_new': (0x106d1f04, 'unique 96-byte branch-relocated fingerprint'),
    'dcj_object': (0x10557430, 'unique masked wrapper; object constructor immediate 0x40'),
    'dcj_array': (0x105573ec, 'unique masked wrapper; array constructor immediate 0x20'),
    'dcj_get': (0x1055714a, 'unique 96-byte branch-relocated fingerprint'),
    'dcj_add': (0x10557160, 'unique 96-byte branch-relocated fingerprint'),
    'dcj_append': (0x10557156, 'unique 96-byte branch-relocated fingerprint'),
    'tdc_uninstall': (0x10714968, 'unique 96-byte branch-relocated fingerprint'),
}


def read_ap(path):
    with zipfile.ZipFile(path) as archive:
        return archive.read('nuttx_ap.bin')


def aliases(path):
    return {name: int(value, 16) for name, value in ALIAS_RE.findall(Path(path).read_text())}


def specs():
    old = json.loads((OLD_ROOT / 'build-inputs.json').read_text())
    new = json.loads((HERE / 'build-inputs.json').read_text())
    return ({row['role']: row for row in old['edits']}, {row['role']: row for row in new['edits']})


def even(value):
    return value & ~1


def hits(data, pattern):
    out = []
    at = 0
    while True:
        at = data.find(pattern, at)
        if at < 0 or len(out) == 2:
            return out
        out.append(at)
        at += 2


def normalized(data):
    out = bytearray(data)
    for at in range(0, len(out) - 3, 2):
        h1, h2 = struct.unpack_from('<HH', out, at)
        if h1 & 0xF800 == 0xF000 and h2 & 0x8000 == 0x8000:
            out[at:at + 4] = b'\0' * 4
    for at in range(0, len(out) - 1, 2):
        h = struct.unpack_from('<H', out, at)[0]
        if h & 0xF800 in (0xD800, 0xE000) or h & 0xBD00 == 0xB100:
            out[at:at + 2] = b'\0' * 2
    return bytes(out)


def masked_prefix(old, new, old_addr, new_addr):
    a = old[even(old_addr) - FLASH:even(old_addr) - FLASH + 96]
    b = new[even(new_addr) - FLASH:even(new_addr) - FLASH + 96]
    limit = min(len(a), len(b))
    same = 0
    for x, y in zip(normalized(a), normalized(b)):
        if x != y:
            break
        same += 1
        if same == limit:
            break
    return same


def decode_bl(data, address):
    at = even(address) - FLASH
    h1, h2 = struct.unpack_from('<HH', data, at)
    assert h1 & 0xF800 == 0xF000 and h2 & 0xD000 == 0xD000, 'Not a Thumb BL'
    s, i1, i2 = (h1 >> 10) & 1, (h2 >> 13) & 1, (h2 >> 11) & 1
    value = (s << 24) | ((0 if s ^ i1 else 1) << 23) | ((0 if s ^ i2 else 1) << 22)
    value |= ((h1 & 0x3FF) << 12) | ((h2 & 0x7FF) << 1)
    if value & (1 << 24):
        value -= 1 << 25
    return even(address) + 4 + value


EXTRA = [
    ('launcher_manager', 0x19971594, 0x19989694, 'direct'),
    ('launcher_callback_struct', 0x196aea48, 0x196c6988, 'direct'),
    ('launcher_callback_manager', 0x196aeabc, 0x196c69fc, 'direct'),
    ('launcher_published_tail', 0x196aead4, 0x196c6a14, 'derived:launcher_callback_struct:0x8c'),
    ('stream_link_callback', 0x10569ba5, 0x10583605, 'direct'),
    ('head_start_literal', 0x181b5ce4, 0x181ca732, 'direct'),
    ('head_stop_literal', 0x181b5cbf, 0x181ca70d, 'direct'),
    ('sys_destroy_literal', 0x181cf300, 0x181e6e8c, 'direct'),
    ('sys_destroy_legacy_literal', 0x182ca670, 0x181e6e8c, 'direct'),
    ('head_monitor_destroy', 0x1056d191, 0x10586bf1, 'exact:32'),
    ('imu_start_object', 0x196988bc, 0x1959a7b4, 'direct'),
    ('imu_stop_object', 0x19698884, 0x1959a77c, 'direct'),
    ('coexist_string_a', 0x18052201, 0x1805244d, 'direct'),
    ('coexist_string_b', 0x1805240d, 0x18052659, 'direct'),
    ('coexist_format', 0x18177273, 0x18177536, 'direct'),
    ('coexist_log_format', 0x1804300a, 0x1804338b, 'direct'),
    ('render_units', 0x184d4440, 0x184ec384, 'direct'),
    ('render_dispatch', 0x10428d89, 0x10440cf1, 'exact:64'),
    ('render_dispatch_alt', 0x105335ff, 0x1054c447, 'exact:16'),
    ('lv_mem_current', 0x184d45fc, 0x184ec540, 'derived:render_units:0x1bc'),
    ('lv_mem_peak', 0x184d4600, 0x184ec544, 'derived:render_units:0x1c0'),
    ('imu_rpmsg_resume', 0x104e7e81, 0x104e9241, 'exact:64'),
    ('imu_start_resume', 0x104e8ee1, 0x104ea2a1, 'masked:64'),
    ('imu_stop_resume', 0x104e8f4d, 0x104ea30d, 'masked:64'),
    ('thread_create', 0x1047a931, 0x10492899, 'masked:24'),
    ('thread_join', 0x1046eb39, 0x10486aa1, 'exact:24'),
    ('thread_sleep', 0x104814cd, 0x10499435, 'exact:64'),
]


def generate(old, new, old_aliases):
    old_spec, new_spec = specs()
    rows = []
    for name, old_value in old_aliases.items():
        if name in RESUME_ROLES:
            role = RESUME_ROLES[name]
            a, b = old_spec[role], new_spec[role]
            size = len(bytes.fromhex(a['before']))
            old_expected = int(a['address'], 16) + size + 1
            new_value = int(b['address'], 16) + size + 1
            assert old_value == old_expected, (name, hex(old_value), hex(old_expected))
            evidence = 'patch-resume:' + role
        elif name == 'stock_ctor':
            role = 'Initialize tail after new stock constructor'
            old_target = decode_bl(old, int(old_spec[role]['address'], 16))
            new_target = decode_bl(new, int(new_spec[role]['address'], 16))
            assert old_value == old_target | 1
            new_value = new_target | 1
            evidence = 'bl-target:' + role
        elif name in FIXED_ROM:
            new_value = old_value
            count = new.count(struct.pack('<I', new_value))
            assert count > 0, name
            evidence = 'fixed-rom-literal:' + str(count)
        elif name in MANUAL:
            target, reason = MANUAL[name]
            new_value = target | 1
            size = masked_prefix(old, new, old_value, target)
            assert size >= 8, (name, size)
            evidence = f'manual-masked-{size}:{reason}'
        else:
            at = even(old_value) - FLASH
            found = None
            for size in (64, 48, 32, 24, 16, 12, 8):
                matches = hits(new, old[at:at + size])
                if len(matches) == 1:
                    found = (matches[0] + FLASH, size)
                    break
            assert found, ('Unresolved symbol', name, hex(old_value))
            new_value = found[0] | 1
            evidence = 'unique-exact-' + str(found[1])
        rows.append({'name': name, 'old': hex(old_value), 'new': hex(new_value), 'evidence': evidence})
    return rows


def audit(new, new_link_path=HERE / 'link.ld', map_path=MAP_PATH):
    document = json.loads(Path(map_path).read_text())
    old = read_ap(OLD_STOCK)
    old_aliases = aliases(OLD_ROOT / 'link.ld')
    new_aliases = aliases(new_link_path)
    assert hashlib.sha256(new).hexdigest() == document['stockAPSHA256'], 'Address map stock AP mismatch'
    assert hashlib.sha256(old).hexdigest() == document['previousStockAPSHA256'], 'Address map previous AP mismatch'
    rows = document['symbols']
    assert len(rows) == len(old_aliases) == len(new_aliases) == 173, 'Symbol map coverage mismatch'
    assert {row['name'] for row in rows} == set(old_aliases) == set(new_aliases), 'Symbol names mismatch'
    old_spec, new_spec = specs()
    counts = {}
    for row in rows:
        name, old_value, new_value = row['name'], int(row['old'], 16), int(row['new'], 16)
        evidence = row['evidence']
        kind = evidence.split(':', 1)[0].split('-', 1)[0]
        counts[kind] = counts.get(kind, 0) + 1
        assert old_aliases[name] == old_value and new_aliases[name] == new_value, ('Unverified address binding', name)
        old_at, new_at = even(old_value) - FLASH, even(new_value) - FLASH
        if evidence.startswith('unique-exact-'):
            size = int(evidence.rsplit('-', 1)[1])
            pattern = old[old_at:old_at + size]
            assert new[new_at:new_at + size] == pattern and hits(new, pattern) == [new_at], name
        elif evidence.startswith('manual-masked-'):
            size = int(evidence.split(':', 1)[0].rsplit('-', 1)[1])
            assert normalized(old[old_at:old_at + size]) == normalized(new[new_at:new_at + size]), name
        elif evidence.startswith('patch-resume:'):
            role = evidence.split(':', 1)[1]
            size = len(bytes.fromhex(new_spec[role]['before']))
            assert new_value == int(new_spec[role]['address'], 16) + size + 1, name
        elif evidence.startswith('bl-target:'):
            role = evidence.split(':', 1)[1]
            assert new_value == decode_bl(new, int(new_spec[role]['address'], 16)) | 1, name
        elif evidence.startswith('fixed-rom-literal:'):
            assert old_value == new_value and struct.pack('<I', new_value) in new, name
        else:
            raise AssertionError(('Unknown evidence', name, evidence))
    extras = document['literals']
    expected_extras = [{'name': name, 'old': hex(old_value), 'new': hex(new_value), 'evidence': evidence}
                       for name, old_value, new_value, evidence in EXTRA]
    assert extras == expected_extras, 'Literal evidence table mismatch'
    values = {name: (old_value, new_value) for name, old_value, new_value, evidence in EXTRA}
    for name, old_value, new_value, evidence in EXTRA:
        kind, _, argument = evidence.partition(':')
        if kind == 'direct':
            assert struct.pack('<I', new_value) in new, ('Missing new stock literal', name)
        elif kind == 'derived':
            base_name, offset_text = argument.rsplit(':', 1)
            offset = int(offset_text, 16)
            assert old_value == values[base_name][0] + offset and new_value == values[base_name][1] + offset, name
        else:
            size = int(argument)
            old_at, new_at = even(old_value) - FLASH, even(new_value) - FLASH
            if kind == 'exact':
                pattern = old[old_at:old_at + size]
                assert new[new_at:new_at + size] == pattern and hits(new, pattern) == [new_at], name
            elif kind == 'masked':
                assert normalized(old[old_at:old_at + size]) == normalized(new[new_at:new_at + size]), name
            else:
                raise AssertionError(('Unknown literal evidence', name, evidence))
    source_files = list(HERE.glob('**/*.S'))
    source_files += [path for path in HERE.glob('src/**/*.c')
                     if not path.name.endswith('_test.c') and path.name != 'render_idle_test.c']
    for path in source_files:
        text = path.read_text(encoding='utf-8').lower()
        for name, old_value, new_value, evidence in EXTRA:
            if old_value != new_value:
                assert hex(old_value) not in text, ('Stale source binding', name, str(path))
    return {'symbolBindings': len(rows), 'externalBindings': len(extras),
            'bindingEvidence': counts, 'addressAuditPassed': True}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--generate', action='store_true')
    parser.add_argument('--stock', type=Path, default=NEW_STOCK)
    args = parser.parse_args()
    new = read_ap(args.stock)
    if args.generate:
        old = read_ap(OLD_STOCK)
        rows = generate(old, new, aliases(OLD_ROOT / 'link.ld'))
        document = {
            'schema': 1,
            'baseline': 'Strix OS 1.0.5.12',
            'stockAPSHA256': hashlib.sha256(new).hexdigest(),
            'previousStockAPSHA256': hashlib.sha256(old).hexdigest(),
            'symbols': rows,
            'literals': [{'name': name, 'old': hex(old_value), 'new': hex(new_value), 'evidence': evidence}
                         for name, old_value, new_value, evidence in EXTRA],
        }
        MAP_PATH.write_text(json.dumps(document, indent=2, ensure_ascii=False) + '\n', encoding='utf-8', newline='\n')
        print(json.dumps({'generated': len(rows), 'literals': len(EXTRA), 'path': str(MAP_PATH)}, indent=2))
    else:
        print(json.dumps(audit(new), indent=2))


if __name__ == '__main__':
    main()
