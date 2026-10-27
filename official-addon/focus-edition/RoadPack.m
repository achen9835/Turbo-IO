#import "RoadPack.h"
#import <CommonCrypto/CommonDigest.h>
#include <zlib.h>
#include <math.h>
#include <stdint.h>

static NSString *const kReleaseBase = @"https://github.com/achen9835/Turbo-IO/releases/download/roadmap-packs";
static const NSUInteger kMaxPackBytes = 200u * 1024u * 1024u; /* 单包上限 200 MB */

static NSString *SHA256Hex(NSData *data) {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *s = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (unsigned i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", digest[i]];
    return s;
}

/* 一份已打开的包文件：头部 + 格索引（cellIndex 升序，二分查找）。 */
@interface TIORoadPackFile : NSObject {
 @public
  NSString *province;
  NSData *blob;                                    /* mmap 的整包内容 */
  NSArray<NSNumber *> *indexes;                    /* 升序 cellIndex */
  NSDictionary<NSNumber *, NSValue *> *entries;    /* cellIndex -> NSRange(offset, csize)（文件绝对坐标） */
  NSDictionary<NSNumber *, NSNumber *> *rsizes;    /* cellIndex -> 解压后字节数 */
  NSArray<NSString *> *names;
  double minLat, minLon, maxLat, maxLon, cellLat, cellLon;
  uint32_t gridLat, gridLon;
  NSCache *cellCache;
}
- (NSArray *)featuresForCell:(uint32_t)cell;
@end
@implementation TIORoadPackFile
static uint32_t rd32(const uint8_t *p) { return p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
- (instancetype)initWithPath:(NSString *)path province:(NSString *)prov {
    if (!(self = [super init])) return nil;
    blob = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!blob.length || blob.length < 64) return nil;
    const uint8_t *b = blob.bytes;
    NSUInteger n = blob.length, at = 0;
    if (memcmp(b, "TRPM", 4)) return nil;
    at = 4;
    if (rd32(b + at) != 1) return nil; /* version */
    at += 4;
    unsigned provLen = b[at]; at += 1;
    if (at + provLen + 60 > n) return nil;
    province = prov.length ? [prov copy] : [[NSString alloc]initWithData:[blob subdataWithRange:NSMakeRange(at, provLen)] encoding:NSUTF8StringEncoding];
    at += provLen;
    const double *d = (const double *)(b + at);
    minLat = d[0]; minLon = d[1]; maxLat = d[2]; maxLat = fmax(maxLat, minLat); maxLon = d[3]; maxLon = fmax(maxLon, minLon);
    at += 32;
    cellLat = d[4]; cellLon = d[5];
    at += 16;
    if (!(cellLat > 0 && cellLon > 0)) return nil;
    gridLat = rd32(b + at); at += 4;
    gridLon = rd32(b + at); at += 4;
    if (!gridLat || !gridLon || gridLat > 65536 || gridLon > 65536) return nil;
    uint32_t count = rd32(b + at); at += 4;
    if (!count || count > 2000000u || at + (NSUInteger)count * 20u + 4u > n) return nil;
    NSMutableArray *idx = [NSMutableArray arrayWithCapacity:count];
    NSMutableDictionary *ent = [NSMutableDictionary dictionaryWithCapacity:count];
    NSMutableDictionary *rs = [NSMutableDictionary dictionaryWithCapacity:count];
    for (uint32_t i = 0; i < count; i++) {
        uint32_t cellIndex = rd32(b + at);
        uint64_t off = 0;
        for (unsigned k = 0; k < 8; k++) off |= (uint64_t)b[at + 4 + k] << (8 * k);
        uint32_t csize = rd32(b + at + 12), rsize = rd32(b + at + 16);
        at += 20;
        if (!csize || !rsize || rsize > 64u * 1024u * 1024u || off > n || csize > n - off) return nil;
        NSNumber *k = @(cellIndex);
        [idx addObject:k];
        ent[k] = [NSValue valueWithRange:NSMakeRange((NSUInteger)off, (NSUInteger)csize)];
        rs[k] = @(rsize);
    }
    uint32_t namesSize = rd32(b + at); at += 4;
    if (at + namesSize > n) return nil;
    NSMutableArray *nm = [NSMutableArray array];
    NSUInteger nat = at, stop = at + namesSize;
    while (nat + 2 <= stop) {
        unsigned len = b[nat] | (unsigned)b[nat + 1] << 8; nat += 2;
        if (nat + len > stop) return nil;
        NSString *s = len ? [[NSString alloc]initWithData:[blob subdataWithRange:NSMakeRange(nat, len)] encoding:NSUTF8StringEncoding] : @"";
        [nm addObject:s ?: @""];
        nat += len;
    }
    at = stop; /* 数据区起点；entries 的 offset 已是文件绝对坐标 */
    indexes = idx; entries = ent; rsizes = rs; names = nm;
    cellCache = [NSCache new];
    cellCache.countLimit = 48;
    return self;
}
- (NSValue *)entryForCell:(uint32_t)cell {
    NSUInteger lo = 0, hi = indexes.count;
    while (lo < hi) {
        NSUInteger mid = (lo + hi) / 2;
        uint32_t v = (uint32_t)[indexes[mid] unsignedIntValue];
        if (v == cell) return entries[indexes[mid]];
        if (v < cell) lo = mid + 1; else hi = mid;
    }
    return nil;
}
- (NSArray *)featuresForCell:(uint32_t)cell {
    NSValue *e = [self entryForCell:cell];
    if (!e) return nil;
    NSString *key = [NSString stringWithFormat:@"%u", cell];
    NSArray *cached = [cellCache objectForKey:key];
    if (cached) return cached;
    NSRange r = [e rangeValue];
    uint32_t rsize = (uint32_t)[rsizes[@(cell)] unsignedIntValue];
    if (!rsize || rsize > 64u * 1024u * 1024u) return nil;
    NSData *packed = [blob subdataWithRange:r];
    uint8_t *dst = malloc(rsize);
    if (!dst) return nil;
    uLongf cap = rsize;
    if (uncompress(dst, &cap, packed.bytes, (uLong)packed.length) != Z_OK || cap != rsize) { free(dst); return nil; }
    NSMutableArray *out = [NSMutableArray array];
    NSUInteger at = 0;
    static NSString *const styleNames[6] = {@"motorway", @"primary", @"secondary", @"tertiary", @"residential", @"service"};
    while (at + 17 <= (NSUInteger)rsize) {
        uint8_t style = dst[at], layer = dst[at + 1], flags = dst[at + 2]; at += 3;
        uint32_t nameIdx = rd32(dst + at); at += 4;
        uint16_t cnt = dst[at] | (uint16_t)dst[at + 1] << 8; at += 2;
        if (!cnt || at + 8 + (NSUInteger)(cnt - 1) * 4u > (NSUInteger)rsize) break;
        int32_t lat0 = (int32_t)rd32(dst + at), lon0 = (int32_t)rd32(dst + at + 4); at += 8;
        double lat = lat0 / 1e6, lon = lon0 / 1e6;
        NSMutableArray *coords = [NSMutableArray arrayWithCapacity:cnt];
        [coords addObject:@[@(lon), @(lat)]];
        BOOL broken = NO;
        for (unsigned i = 1; i < cnt; i++) {
            int16_t dlat = (int16_t)(dst[at] | (uint16_t)dst[at + 1] << 8);
            int16_t dlon = (int16_t)(dst[at + 2] | (uint16_t)dst[at + 3] << 8);
            at += 4;
            lat += dlat / 1e5; lon += dlon / 1e5;
            if (lat < -85 || lat > 85 || lon < -180 || lon > 180) { broken = YES; break; }
            [coords addObject:@[@(lon), @(lat)]];
        }
        if (broken || coords.count < 2) continue;
        NSMutableDictionary *p = [@{@"kind": @"road", @"highway": styleNames[style < 6 ? style : 5]} mutableCopy];
        if (nameIdx < names.count && names[nameIdx].length) p[@"name"] = names[nameIdx];
        if (flags & 1) p[@"bridge"] = @"yes";
        if (flags & 2) p[@"tunnel"] = @"yes";
        if (layer) p[@"layer"] = @(layer);
        [out addObject:@{@"properties": p, @"geometry": @{@"type": @"LineString", @"coordinates": coords}}];
        if (out.count >= 20000) break; /* 单格防御上限 */
    }
    free(dst);
    [cellCache setObject:out forKey:key];
    return out;
}
@end

@interface TIORoadPackManager () <NSURLSessionDataDelegate>
@end
@implementation TIORoadPackManager {
    NSArray<NSDictionary *> *_manifest;
    NSString *_note;
    NSMutableDictionary<NSString *, TIORoadPackFile *> *_files;
    NSURLSession *_manifestSession;
    NSURLSession *_downloadSession;
    NSLock *_lock;
    NSMapTable<NSURLSessionTask *, NSMutableDictionary *> *_downloads;
}
+ (instancetype)shared {
    static TIORoadPackManager *m; static dispatch_once_t once;
    dispatch_once(&once, ^{m = [TIORoadPackManager new];});
    return m;
}
- (instancetype)init {
    if ((self = [super init])) {
        _manifest = @[];
        _note = @"省际路网包：未加载清单";
        _files = [NSMutableDictionary dictionary];
        _lock = [NSLock new];
        _downloads = [NSMapTable weakToStrongObjectsMapTable];
        NSURLSessionConfiguration *c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        c.timeoutIntervalForResource = 120;
        _manifestSession = [NSURLSession sessionWithConfiguration:c];
        c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        c.timeoutIntervalForResource = 900;
        c.HTTPMaximumConnectionsPerHost = 1;
        _downloadSession = [NSURLSession sessionWithConfiguration:c delegate:self delegateQueue:nil];
        [self loadCachedManifest];
    }
    return self;
}
- (NSString *)packsDir {
    NSString *dir = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"TurboIOResearch"] stringByAppendingPathComponent:@"TurboRoadPacks"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil];
    return dir;
}
- (NSString *)manifestCachePath { return [[self packsDir] stringByAppendingPathComponent:@"manifest.json"]; }
- (void)loadCachedManifest {
    NSData *d = [NSData dataWithContentsOfFile:self.manifestCachePath];
    id obj = d.length && d.length < 1024u * 1024u ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if ([obj isKindOfClass:[NSDictionary class]] && [obj[@"packs"] isKindOfClass:NSArray.class]) {
        _manifest = obj[@"packs"];
        _note = [NSString stringWithFormat:@"省际路网包：清单缓存 · %lu 省", (unsigned long)_manifest.count];
    }
}
- (NSArray<NSDictionary *> *)manifest { return _manifest; }
- (NSString *)note { return _note; }
- (NSString *)localPathFor:(NSString *)province {
    if (![province isKindOfClass:NSString.class] || !province.length || province.length > 64) return nil;
    static NSCharacterSet *bad;
    if (!bad) bad = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789-_"] invertedSet];
    if ([province rangeOfCharacterFromSet:bad].location != NSNotFound) return nil; /* 只收 slug，防路径注入 */
    return [[self packsDir] stringByAppendingPathComponent:[province stringByAppendingString:@".pack"]];
}
- (BOOL)packDownloaded:(NSString *)province {
    NSString *p = [self localPathFor:province];
    if (!p) return NO;
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
    return [attr[NSFileSize] unsignedLongLongValue] > 64;
}
- (NSUInteger)downloadedCount {
    NSUInteger n = 0;
    for (NSDictionary *p in _manifest) if ([self packDownloaded:p[@"province"]]) n++;
    return n;
}
- (void)refreshManifest:(void (^)(BOOL, NSString *))done {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kReleaseBase stringByAppendingString:@"/manifest.json"]]
                                                     cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    NSURLSessionDataTask *t = [_manifestSession dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
        id obj = (code == 200 && data.length && data.length < 1024u * 1024u) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        BOOL valid = [obj isKindOfClass:[NSDictionary class]] && [obj[@"packs"] isKindOfClass:NSArray.class] && [obj[@"packs"] count] <= 64;
        if (valid) for (NSDictionary *p in obj[@"packs"])
            if (![p[@"province"] isKindOfClass:NSString.class] || ![p[@"file"] isKindOfClass:NSString.class] || ![p[@"sha256"] isKindOfClass:NSString.class] || p[@"file"].length > 96 || p[@"province"].length > 64) valid = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (valid) {
                self->_manifest = obj[@"packs"];
                self->_note = [NSString stringWithFormat:@"省际路网包：清单 %lu 省", (unsigned long)self->_manifest.count];
                [data writeToFile:self.manifestCachePath options:NSDataWritingAtomic error:nil];
                if (done) done(YES, self->_note);
            } else {
                self->_note = @"省际路网包：清单获取失败（用本地缓存）";
                if (done) done(NO, error ? error.localizedDescription : self->_note);
            }
        });
    }];
    [t resume];
}
- (NSDictionary *)manifestEntry:(NSString *)province {
    for (NSDictionary *p in _manifest) if ([p[@"province"] isEqual:province]) return p;
    return nil;
}
- (void)downloadPack:(NSString *)province progress:(void (^)(double))progress done:(void (^)(BOOL, NSString *))done {
    NSDictionary *entry = [self manifestEntry:province];
    NSString *path = [self localPathFor:province];
    void(^finish)(BOOL, NSString *) = ^(BOOL ok, NSString *note) {
        void(^cb)(BOOL, NSString *) = [done copy];
        dispatch_async(dispatch_get_main_queue(), ^{if (cb) cb(ok, note);});
    };
    if (!entry || !path) { finish(NO, @"清单里没有这个省"); return; }
    if ([self packDownloaded:province]) { finish(YES, @"已下载"); return; }
    long long expected = [entry[@"size"] longLongValue];
    if (expected <= 0 || expected > (long long)kMaxPackBytes) { finish(NO, @"包大小异常，拒下"); return; }
    NSURL *url = [NSURL URLWithString:[kReleaseBase stringByAppendingFormat:@"/%@", entry[@"file"]]];
    if (!url || [url.scheme caseInsensitiveCompare:@"https"] != NSOrderedSame) { finish(NO, @"下载地址无效"); return; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:120];
    NSMutableDictionary *ctx = [NSMutableDictionary dictionaryWithDictionary:@{
        @"body": [NSMutableData data], @"expected": @(expected), @"path": path,
        @"sha256": entry[@"sha256"] ?: @"", @"province": province,
        @"progress": progress ? [progress copy] : [NSNull null],
        @"done": done ? [done copy] : [NSNull null],
    }];
    NSURLSessionDataTask *task = [_downloadSession dataTaskWithRequest:req];
    [_downloads setObject:ctx forKey:task];
    if (progress) dispatch_async(dispatch_get_main_queue(), ^{progress(0);});
    [task resume];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    NSMutableDictionary *ctx = [_downloads objectForKey:dataTask];
    if (!ctx) return;
    [(NSMutableData *)ctx[@"body"] appendData:data];
    void(^prog)(double) = [ctx[@"progress"] isEqual:[NSNull null]] ? nil : ctx[@"progress"];
    if (prog) {
        double f = (double)((NSMutableData *)ctx[@"body"]).length / (double)[ctx[@"expected"] longLongValue];
        dispatch_async(dispatch_get_main_queue(), ^{prog(f > 1 ? 1 : f);});
    }
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSMutableDictionary *ctx = [_downloads objectForKey:task];
    if (!ctx) return;
    [_downloads removeObjectForKey:task];
    void(^prog)(double) = [ctx[@"progress"] isEqual:[NSNull null]] ? nil : ctx[@"progress"];
    void(^cb)(BOOL, NSString *) = [ctx[@"done"] isEqual:[NSNull null]] ? nil : ctx[@"done"];
    void(^finish)(BOOL, NSString *) = ^(BOOL ok, NSString *note) {
        if (prog) dispatch_async(dispatch_get_main_queue(), ^{prog(ok ? 1 : 0);});
        if (cb) dispatch_async(dispatch_get_main_queue(), ^{cb(ok, note);});
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TIORoadPackChanged" object:ctx[@"province"] userInfo:@{@"ok": @(ok), @"note": note ?: @""}];
    };
    NSData *body = ctx[@"body"];
    NSString *path = ctx[@"path"];
    long long expected = [ctx[@"expected"] longLongValue];
    if (error || !body.length || body.length != expected) { finish(NO, error ? error.localizedDescription : @"下载不完整"); return; }
    if (![SHA256Hex(body) isEqual:ctx[@"sha256"]]) { finish(NO, @"SHA-256 不符，已丢弃"); return; }
    NSString *tmp = [path stringByAppendingString:@".part"];
    if (![body writeToFile:tmp options:NSDataWritingAtomic error:nil]) { finish(NO, @"写入失败"); return; }
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:tmp error:nil];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    if (![[NSFileManager defaultManager] moveItemAtPath:tmp toPath:path error:nil]) { finish(NO, @"落盘失败"); return; }
    [_lock lock]; [_files removeObjectForKey:ctx[@"province"]]; [_lock unlock];
    finish(YES, @"下载完成");
}
- (void)deletePack:(NSString *)province {
    NSString *p = [self localPathFor:province];
    if (p) {
        [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
        [_lock lock]; [_files removeObjectForKey:province]; [_lock unlock];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TIORoadPackChanged" object:province userInfo:@{@"ok": @YES, @"note": @"已删除"}];
    }
}
- (TIORoadPackFile *)fileFor:(NSString *)province {
    [_lock lock];
    TIORoadPackFile *f = _files[province];
    [_lock unlock];
    if (f) return f;
    if (![self packDownloaded:province]) return nil;
    f = [[TIORoadPackFile alloc]initWithPath:[self localPathFor:province] province:province];
    if (f) {
        [_lock lock];
        _files[province] = f;
        [_lock unlock];
    }
    return f;
}
- (BOOL)coversLat:(double)lat lon:(double)lon {
    for (NSDictionary *p in _manifest) {
        if (![p isKindOfClass:[NSDictionary class]] || ![self packDownloaded:p[@"province"]]) continue;
        TIORoadPackFile *f = [self fileFor:p[@"province"]];
        if (f && lat >= f->minLat && lat <= f->maxLat && lon >= f->minLon && lon <= f->maxLon) return YES;
    }
    return NO;
}
- (NSArray *)featuresAtLat:(double)lat lon:(double)lon bbox:(NSArray **)bbox province:(NSString **)province {
    if (bbox) *bbox = nil;
    if (province) *province = nil;
    for (NSDictionary *p in _manifest) {
        if (![p isKindOfClass:[NSDictionary class]] || ![self packDownloaded:p[@"province"]]) continue;
        TIORoadPackFile *f = [self fileFor:p[@"province"]];
        if (!f || lat < f->minLat || lat > f->maxLat || lon < f->minLon || lon > f->maxLon) continue;
        /* 打包器按绝对经纬度分格（floor(lat/CELL)），这里用同一坐标系取格 */
        int row = (int)floor(lat / f->cellLat), col = (int)floor(lon / f->cellLon);
        if (row < 0 || col < 0 || row >= (int)f->gridLat || col >= (int)f->gridLon) continue;
        NSMutableArray *all = [NSMutableArray array];
        double loLat = 90, loLon = 180, hiLat = -90, hiLon = -180;
        for (int dr = -1; dr <= 1; dr++) for (int dc = -1; dc <= 1; dc++) {
            int r = row + dr, c = col + dc;
            if (r < 0 || c < 0 || r >= (int)f->gridLat || c >= (int)f->gridLon) continue;
            for (NSDictionary *feat in [f featuresForCell:(uint32_t)(r * (int)f->gridLon + c)]) [all addObject:feat];
            double a = r * f->cellLat, b = c * f->cellLon; /* 绝对格边界 */
            loLat = MIN(loLat, a); loLon = MIN(loLon, b);
            hiLat = MAX(hiLat, a + f->cellLat); hiLon = MAX(hiLon, b + f->cellLon);
        }
        if (!all.count || all.count > 40000) continue;
        if (bbox) *bbox = @[@(loLat), @(loLon), @(hiLat), @(hiLon)];
        if (province) *province = f->province;
        return all;
    }
    return nil;
}
@end
