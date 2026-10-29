#!/usr/bin/env python3
"""Build a TIORoadPack binary province pack from an OSM GeoJSONSeq export.

Runs in CI (roadmap-packs workflow) after `osmium tags-filter` + `osmium
export`. Pure stdlib; no device interaction. Output format v1 (see
official-addon/focus-edition/RoadPack.m for the reader side):

  header : b"TRPM" | u32 version | u8 provLen + province
           f64 x4 bbox | f64 cellLat, cellLon | u32 gridLat, gridLon
           u32 cellEntries | entries { u32 cellIndex, u64 offset, u32 csize, u32 rsize }
           u32 namesSize | names { u16 len + utf8 }   (index 0 = empty)
  data   : per-cell zlib blobs; segments inside are
           { u8 style, i8 layer, u8 flags, u32 nameIdx, u16 pointCount,
             i32 lat0, i32 lon0 (1e-6 deg), (n-1) x (i16 dlat, i16 dlon) (1e-5 deg) }

A segment is copied into EVERY grid cell its (simplified) bbox intersects so
cell borders never gap; RoadMap's installFeatures dedupes the overlap.
"""
import argparse
import json
import math
import struct
import sys
import zlib
from pathlib import Path

STYLES = {
    'motorway': 0, 'motorway_link': 0, 'trunk': 0, 'trunk_link': 0,
    'primary': 1, 'primary_link': 1,
    'secondary': 2, 'secondary_link': 2,
    'tertiary': 3, 'tertiary_link': 3,
    'residential': 4, 'unclassified': 4, 'living_street': 4,
    'service': 5, 'road': 5,
}
CELL = 0.05          # degrees per grid cell (~5.5 km)
DP_TOL = 2e-5        # Douglas-Peucker tolerance in degrees (~2 m)
MAX_POINTS = 512     # per simplified segment


def simplify(points):
    """Iterative Douglas-Peucker on (lat, lon); keeps endpoints."""
    n = len(points)
    if n < 3:
        return points
    keep = [False] * n
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        a, b = stack.pop()
        ax, ay = points[a]
        bx, by = points[b]
        dx, dy = bx - ax, by - ay
        den = dx * dx + dy * dy
        best, at = DP_TOL * DP_TOL, -1
        for i in range(a + 1, b):
            x, y = points[i]
            t = 0.0 if den == 0 else max(0.0, min(1.0, ((x - ax) * dx + (y - ay) * dy) / den))
            ex, ey = x - (ax + dx * t), y - (ay + dy * t)
            d = ex * ex + ey * ey
            if d > best:
                best, at = d, i
        if at > 0:
            keep[at] = True
            stack.append((a, at))
            stack.append((at, b))
    out = [p for p, k in zip(points, keep) if k]
    return out[:MAX_POINTS] if len(out) > MAX_POINTS else out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--input', required=True, help='osmium export geojsonseq file')
    ap.add_argument('--province', required=True, help='province slug, e.g. guangdong')
    ap.add_argument('--display', default='', help='display name, e.g. 广东 · Guangdong')
    ap.add_argument('--out', required=True, help='output .pack path')
    args = ap.parse_args()

    names = {}
    name_list = [b'']
    def name_idx(text):
        if not text:
            return 0
        if text not in names:
            b = text.encode('utf-8')
            if len(b) > 250:      # reader caps label text anyway
                return 0
            names[text] = len(name_list)
            name_list.append(b)
        return names[text]

    cells = {}                    # cellIndex -> list of segment tuples
    bbox = [90.0, 180.0, -90.0, -180.0]
    segments = ways = 0
    with open(args.input, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                feat = json.loads(line)
            except ValueError:
                continue
            if not isinstance(feat, dict) or feat.get('type') != 'Feature':
                continue
            props = feat.get('properties') or {}
            highway = props.get('highway')
            if not isinstance(highway, str) or highway not in STYLES:
                continue
            geom = feat.get('geometry') or {}
            coords = geom.get('coordinates')
            if geom.get('type') != 'LineString' or not isinstance(coords, list) or len(coords) < 2:
                continue
            pts = []
            for pair in coords:
                if not isinstance(pair, list) or len(pair) != 2:
                    pts = []
                    break
                lon, lat = pair[0], pair[1]
                if not (-180 <= lon <= 180 and -85 <= lat <= 85):
                    pts = []
                    break
                pts.append((lat, lon))
            if len(pts) < 2:
                continue
            ways += 1
            pts = simplify(pts)
            if len(pts) < 2:
                continue
            for lat, lon in pts:                       # bbox 覆盖全部顶点，不只端点
                bbox[0] = min(bbox[0], lat)
                bbox[1] = min(bbox[1], lon)
                bbox[2] = max(bbox[2], lat)
                bbox[3] = max(bbox[3], lon)
            style = STYLES[highway]
            # layer 标签可以是小数（"0.5"）或乱值，float 解析后取整、越界钳位
            try:
                layer = int(float(props.get('layer') or 0))
            except ValueError:
                layer = 0
            layer = max(-8, min(8, layer))
            flags = 0
            if str(props.get('bridge') or 'no') != 'no':
                flags |= 1
            if str(props.get('tunnel') or 'no') != 'no':
                flags |= 2
            name = props.get('name:zh') or props.get('name') or ''
            ni = name_idx(str(name)) if name else 0
            lat0, lon0 = pts[0]
            lat1, lon1 = pts[-1]
            deltas = []
            plat, plon = pts[0]
            for lat, lon in pts[1:]:
                dlat = round((lat - plat) * 1e5)
                dlon = round((lon - plon) * 1e5)
                if not (-32768 <= dlat <= 32767 and -32768 <= dlon <= 32767):
                    dlat = max(-32768, min(32767, dlat))
                    dlon = max(-32768, min(32767, dlon))
                deltas.append((dlat, dlon))
                plat, plon = lat, lon
            seg = (style, layer, flags, ni, pts[0], deltas)
            segments += 1
            # every cell the segment bbox touches gets a copy (border safety)
            r0 = int(math.floor(min(lat0, lat1) / CELL))
            r1 = int(math.floor(max(lat0, lat1) / CELL))
            c0 = int(math.floor(min(lon0, lon1) / CELL))
            c1 = int(math.floor(max(lon0, lon1) / CELL))
            if (r1 - r0 + 1) * (c1 - c0 + 1) > 64:
                continue                      # pathological long segment, skip
            for r in range(r0, r1 + 1):
                for c in range(c0, c1 + 1):
                    if 0 <= r < 65536 and 0 <= c < 65536:
                        cells.setdefault((r, c), []).append(seg)

    if not cells:
        sys.exit('no road segments kept; refusing to emit an empty pack')
    grid_lat = max(cells, key=lambda k: k[0])[0] + 1
    grid_lon = max(cells, key=lambda k: k[1])[1] + 1
    names_blob = b''.join(struct.pack('<H', len(n)) + n for n in name_list)

    header = bytearray()
    header += b'TRPM'
    header += struct.pack('<I', 1)
    prov = args.province.encode('utf-8')
    header += struct.pack('<B', len(prov)) + prov
    header += struct.pack('<4d', *bbox)
    header += struct.pack('<2d', CELL, CELL)
    header += struct.pack('<2I', grid_lat, grid_lon)
    entries = sorted(((r * grid_lon + c, segs) for (r, c), segs in cells.items()), key=lambda kv: kv[0])
    header += struct.pack('<I', len(entries))

    data = bytearray()
    index = []
    for cell_index, segs in entries:
        blob = bytearray()
        for style, layer, flags, ni, (lat0, lon0), deltas in segs:
            blob += struct.pack('<3b', style, layer, flags)
            blob += struct.pack('<I', ni)
            blob += struct.pack('<H', len(deltas) + 1)
            blob += struct.pack('<2i', round(lat0 * 1e6), round(lon0 * 1e6))
            for dlat, dlon in deltas:
                blob += struct.pack('<2h', dlat, dlon)
        packed = zlib.compress(bytes(blob), 9)
        index.append((cell_index, len(data), len(packed), len(blob)))
        data += packed

    out = Path(args.out)
    out.write_bytes(bytes(header) + b'')
    with open(out, 'ab') as fo:
        for cell_index, offset, csize, rsize in index:
            fo.write(struct.pack('<IQII', cell_index, offset, csize, rsize))
        fo.write(struct.pack('<I', len(names_blob)))
        fo.write(names_blob)
        fo.write(bytes(data))

    import hashlib
    body = out.read_bytes()
    meta = {
        'province': args.province,
        'display': args.display or args.province,
        'file': out.name,
        'size': len(body),
        'sha256': hashlib.sha256(body).hexdigest(),
        'gridLat': grid_lat, 'gridLon': grid_lon, 'cells': len(entries),
        'waysKept': ways, 'segments': segments, 'bbox': bbox, 'format': 1,
    }
    Path(str(out) + '.meta.json').write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding='utf-8')
    print(json.dumps(meta, ensure_ascii=False))


if __name__ == '__main__':
    main()
