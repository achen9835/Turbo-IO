#import "RoadPack.h"
#import <CommonCrypto/CommonDigest.h>
#include <zlib.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>

static NSString *const kReleaseBase = @"https://github.com/achen9835/Turbo-IO/releases/download/roadmap-packs";
static const NSUInteger kMaxPackBytes = 200u * 1024u * 1024u; /* 单包上限 200 MB */
/* 单格/单窗上限：一次 featuresAtLat 合并 3×3 格，旧 64 MB 原始格上限 + 每格
 * 20000 路段会把内存峰值推到数百 MB（“全部下载”/首次进入市区时被 jetsam 杀）。 */
static const uint32_t kMaxCellRaw = 16u * 1024u * 1024u;    /* 解压后单格 */
static const uint32_t kMaxCellPacked = 8u * 1024u * 1024u;  /* 压缩后单格 */
static const NSUInteger kMaxCellFeatures = 6000;            /* 单格路段上限 */
static const NSUInteger kMaxWindowFeatures = 8000;          /* 3×3 窗口合并上限 */
static const NSUInteger kMaxPackFiles = 4;                  /* 常驻 mmap 的省包数 */
static const NSUInteger kMaxManifestPacks = 64;
static const NSUInteger kMaxManifestBytes = 1024u * 1024u;

static NSString *SHA256HexFromCtx(CC_SHA256_CTX *ctx) {
    CC_SHA256_CTX copy = *ctx;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &copy);
    NSMutableString *s = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (unsigned i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", digest[i]];
    return s;
}

/* 文件名白名单：清单来自网络 Release，绝不允许路径分隔符/上跳。 */
static BOOL SafeSlug(NSString *value, NSUInteger maxLength) {
    if (![value isKindOfClass:NSString.class] || !value.length || value.length > maxLength) return NO;
    static NSCharacterSet *bad;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789._-"] invertedSet];
    });
    if ([value rangeOfCharacterFromSet:bad].location != NSNotFound) return NO;
    return ![value containsString:@".."];
}

static BOOL HexDigest(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length != CC_SHA256_DIGEST_LENGTH * 2) return NO;
    static NSCharacterSet *bad;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    });
    return [value rangeOfCharacterFromSet:bad].location == NSNotFound;
}

/* 逐条校验 manifest.packs：非字典元素直接跳过（旧代码对 NSString 取下标
 * 会 unrecognized selector 崩溃），字段不全/越界的条目同样丢弃。 */
static NSArray<NSDictionary *> *ValidPacks(id object) {
    if (![object isKindOfClass:NSArray.class]) return nil;
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (id item in object) {
        if (out.count >= kMaxManifestPacks) break;
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *province = item[@"province"], *file = item[@"file"];
        NSNumber *size = item[@"size"];
        if (!SafeSlug(province, 64) || [province containsString:@"."] || !SafeSlug(file, 96) || !HexDigest(item[@"sha256"])) continue; /* province 与 localPathFor 的字符集一致（不带点） */
        if (![size isKindOfClass:NSNumber.class] || [size longLongValue] <= 64 || [size longLongValue] > (long long)kMaxPackBytes) continue;
        [out addObject:item];
    }
    return out.count ? out : nil;
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
    if (!blob.length || blob.length < 64 || blob.length > kMaxPackBytes) return nil;
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
    if (!(cellLat > 0 && cellLon > 0 && cellLat <= 1 && cellLon <= 1)) return nil;
    if (!isfinite(minLat) || !isfinite(minLon) || !isfinite(maxLat) || !isfinite(maxLon)) return nil;
    if (minLat < -85 || maxLat > 85 || minLon < -180 || maxLon > 180 || maxLat <= minLat || maxLon <= minLon) return nil;
    gridLat = rd32(b + at); at += 4;
    gridLon = rd32(b + at); at += 4;
    if (!gridLat || !gridLon || gridLat > 65536 || gridLon > 65536) return nil;
    uint32_t count = rd32(b + at); at += 4;
    /* 省域 5.5 km 格网约 400×400；2,000,000 条索引会先吃掉上百 MB 内存。 */
    if (!count || count > 200000u || at + (NSUInteger)count * 20u + 4u > n) return nil;
    NSMutableArray *idx = [NSMutableArray arrayWithCapacity:count];
    NSMutableDictionary *ent = [NSMutableDictionary dictionaryWithCapacity:count];
    NSMutableDictionary *rs = [NSMutableDictionary dictionaryWithCapacity:count];
    for (uint32_t i = 0; i < count; i++) {
        uint32_t cellIndex = rd32(b + at);
        uint64_t off = 0;
        for (unsigned k = 0; k < 8; k++) off |= (uint64_t)b[at + 4 + k] << (8 * k);
        uint32_t csize = rd32(b + at + 12), rsize = rd32(b + at + 16);
        at += 20;
        if (!csize || !rsize || rsize > kMaxCellRaw || csize > kMaxCellPacked || off > n || csize > n - off) return nil;
        NSNumber *k = @(cellIndex);
        [idx addObject:k];
        ent[k] = [NSValue valueWithRange:NSMakeRange((NSUInteger)off, (NSUInteger)csize)];
        rs[k] = @(rsize);
    }
    uint32_t namesSize = rd32(b + at); at += 4;
    if (at + namesSize > n || namesSize > n) return nil;
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
    cellCache.countLimit = 16;
    cellCache.totalCostLimit = 24u * 1024u * 1024u;
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
    if (!rsize || rsize > kMaxCellRaw || r.length > kMaxCellPacked) return nil;
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
        if (out.count >= kMaxCellFeatures) break; /* 单格防御上限（按 5.5 km 格实际路段数收紧） */
    }
    free(dst);
    [cellCache setObject:out forKey:key cost:rsize];
    return out;
}
@end

@interface TIORoadPackManager () <NSURLSessionDataDelegate>
@end
@implementation TIORoadPackManager {
    NSArray<NSDictionary *> *_manifest;
    NSString *_note;
    NSMutableDictionary<NSString *, TIORoadPackFile *> *_files;
    NSMutableArray<NSString *> *_fileOrder;
    NSURLSession *_manifestSession;
    NSURLSession *_downloadSession;
    NSLock *_lock;
    /* 下载队列只在主队列读写（delegateQueue=主队列）。一次只传一个包：单包
     * 可达 200 MB，旧的 26 任务并发 + 整包 NSMutableData 是“全部下载”闪退根因。 */
    NSMutableArray<NSMutableDictionary *> *_pending;
    NSMutableDictionary *_active;
    NSURLSessionDataTask *_activeTask;
    NSFileHandle *_activeHandle;
    CC_SHA256_CTX _activeSHA;
    unsigned long long _activeBytes;
    NSTimeInterval _lastProgressAt;
    double _lastProgress;
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
        _fileOrder = [NSMutableArray array];
        _lock = [NSLock new];
        _pending = [NSMutableArray array];
        NSURLSessionConfiguration *c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        c.timeoutIntervalForResource = 30;
        c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _manifestSession = [NSURLSession sessionWithConfiguration:c];
        c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        c.timeoutIntervalForResource = 900;
        c.HTTPMaximumConnectionsPerHost = 1;
        c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _downloadSession = [NSURLSession sessionWithConfiguration:c delegate:self delegateQueue:NSOperationQueue.mainQueue];
        [self loadCachedManifest];
        /* 清掉上次进程/旧实现中断留下的半包，避免长期占用磁盘。 */
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *f in [fm contentsOfDirectoryAtPath:[self packsDir] error:nil])
            if ([f hasSuffix:@".part"]) [fm removeItemAtPath:[[self packsDir] stringByAppendingPathComponent:f] error:nil];
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
    id obj = d.length && d.length < kMaxManifestBytes ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    NSArray<NSDictionary *> *packs = [obj isKindOfClass:NSDictionary.class] ? ValidPacks(obj[@"packs"]) : nil;
    if (packs) {
        _manifest = packs;
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
    for (NSDictionary *p in _manifest) if ([p isKindOfClass:NSDictionary.class] && [self packDownloaded:p[@"province"]]) n++;
    return n;
}
- (void)refreshManifest:(void (^)(BOOL, NSString *))done {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kReleaseBase stringByAppendingString:@"/manifest.json"]]
                                                     cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    NSURLSessionDataTask *t = [_manifestSession dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
        id obj = (code == 200 && data.length && data.length < kMaxManifestBytes) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray<NSDictionary *> *packs = [obj isKindOfClass:NSDictionary.class] ? ValidPacks(obj[@"packs"]) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (packs.count) {
                self->_manifest = packs;
                self->_note = [NSString stringWithFormat:@"省际路网包：清单 %lu 省", (unsigned long)self->_manifest.count];
                [data writeToFile:self.manifestCachePath options:NSDataWritingAtomic error:nil];
                [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:self.manifestCachePath error:nil];
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
    for (NSDictionary *p in _manifest) if ([p isKindOfClass:NSDictionary.class] && [p[@"province"] isEqual:province]) return p;
    return nil;
}
/* 完成回调 + 通知一律在主队列：UIKit 只能在主线程 reloadData。 */
- (void)finishContext:(NSMutableDictionary *)ctx ok:(BOOL)ok note:(NSString *)note {
    void (^prog)(double) = ctx[@"progress"];
    void (^cb)(BOOL, NSString *) = ctx[@"done"];
    if (prog) prog(ok ? 1.0 : 0.0);
    if (cb) cb(ok, note ?: @"");
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TIORoadPackChanged" object:ctx[@"province"] userInfo:@{@"ok": @(ok), @"note": note ?: @""}];
}
- (void)downloadPack:(NSString *)province progress:(void (^)(double))progress done:(void (^)(BOOL, NSString *))done {
    if (![NSThread isMainThread]) { /* 头文件约定主线程回调；防御性转主队列 */
        dispatch_async(dispatch_get_main_queue(), ^{ [self downloadPack:province progress:progress done:done]; });
        return;
    }
    NSMutableDictionary *ctx = [NSMutableDictionary dictionary];
    ctx[@"province"] = province ?: @"";
    if (progress) ctx[@"progress"] = [progress copy];
    if (done) ctx[@"done"] = [done copy];
    NSDictionary *entry = [self manifestEntry:province];
    NSString *path = [self localPathFor:province];
    if (!entry || !path) { [self finishContext:ctx ok:NO note:@"清单里没有这个省"]; return; }
    if ([self packDownloaded:province]) { [self finishContext:ctx ok:YES note:@"已下载"]; return; }
    long long expected = [entry[@"size"] longLongValue];
    if (expected <= 64 || expected > (long long)kMaxPackBytes) { [self finishContext:ctx ok:NO note:@"包大小异常，拒下"]; return; }
    NSString *file = entry[@"file"];
    if (!SafeSlug(file, 96)) { [self finishContext:ctx ok:NO note:@"包文件名不安全，拒下"]; return; }
    NSURL *url = [NSURL URLWithString:[kReleaseBase stringByAppendingFormat:@"/%@", file]];
    if (!url || [url.scheme caseInsensitiveCompare:@"https"] != NSOrderedSame) { [self finishContext:ctx ok:NO note:@"下载地址无效"]; return; }
    for (NSMutableDictionary *queued in _pending) if ([queued[@"province"] isEqual:province]) { [self finishContext:ctx ok:NO note:@"已在下载队列"]; return; }
    if ([_active[@"province"] isEqual:province]) { [self finishContext:ctx ok:NO note:@"已在下载队列"]; return; }
    ctx[@"path"] = path;
    ctx[@"part"] = [path stringByAppendingString:@".part"];
    ctx[@"expected"] = @(expected);
    ctx[@"sha256"] = entry[@"sha256"];
    ctx[@"url"] = url;
    [_pending addObject:ctx];
    if (progress) progress(0);
    [self startNextDownload];
}
/* 串行下载：同一时刻只有一个 NSURLSessionDataTask、一个 .part 文件。 */
- (void)startNextDownload {
    while (!_active && _pending.count) {
        NSMutableDictionary *ctx = _pending.firstObject;
        [_pending removeObjectAtIndex:0];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *part = ctx[@"part"];
        [fm removeItemAtPath:part error:nil];
        if (![fm createFileAtPath:part contents:nil attributes:@{NSFilePosixPermissions: @0600}]) {
            [self finishContext:ctx ok:NO note:@"无法创建临时文件"];
            continue;
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:part];
        if (!handle) {
            [fm removeItemAtPath:part error:nil];
            [self finishContext:ctx ok:NO note:@"无法写入临时文件"];
            continue;
        }
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:ctx[@"url"]
                                                            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:120];
        [req setValue:@"TurboIO-TNR1-private-pilot/1.0" forHTTPHeaderField:@"User-Agent"];
        _active = ctx;
        _activeHandle = handle;
        _activeBytes = 0;
        _lastProgress = 0;
        _lastProgressAt = 0;
        CC_SHA256_Init(&_activeSHA);
        _activeTask = [_downloadSession dataTaskWithRequest:req];
        _activeTask.taskDescription = ctx[@"province"];
        [_activeTask resume];
    }
}
/* Release 资源走 GitHub 重定向；只允许 https，避免被降级到明文。 */
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    if (session != _downloadSession || task != _activeTask) { completionHandler(nil); return; }
    completionHandler([request.URL.scheme caseInsensitiveCompare:@"https"] == NSOrderedSame ? request : nil);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    if (session != _downloadSession || dataTask != _activeTask) { completionHandler(NSURLSessionResponseCancel); return; }
    long long status = [(NSHTTPURLResponse *)response statusCode];
    long long expected = [_active[@"expected"] longLongValue];
    long long length = response.expectedContentLength;
    BOOL ok = status == 200 && (length < 0 || length == expected);
    if (!ok) _active[@"failure"] = @"服务器响应不合格（状态/长度与清单不符）";
    completionHandler(ok ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (session != _downloadSession || dataTask != _activeTask || !_activeHandle) return;
    unsigned long long expected = [_active[@"expected"] unsignedLongLongValue];
    if (_activeBytes + data.length > expected || _activeBytes + data.length > kMaxPackBytes) {
        _active[@"failure"] = @"下载长度与清单不符，已中止";
        [dataTask cancel];
        return;
    }
    @try {
        [_activeHandle writeData:data]; /* NSFileHandle 用异常报告磁盘错误：必须接住，不能崩 */
    } @catch (NSException *e) {
        _active[@"failure"] = @"临时文件写入失败";
        [dataTask cancel];
        return;
    }
    _activeBytes += data.length;
    CC_SHA256_Update(&_activeSHA, data.bytes, (CC_LONG)data.length);
    /* 进度节流：>=5% 或 >=200 ms 才回调一次，避免每块数据都刷 UI。 */
    double fraction = expected ? (double)_activeBytes / (double)expected : 0;
    if (fraction > 1) fraction = 1;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (fraction >= 1 || fraction - _lastProgress >= 0.05 || (_lastProgressAt && now - _lastProgressAt >= 0.2)) {
        _lastProgress = fraction;
        _lastProgressAt = now;
        void (^prog)(double) = _active[@"progress"];
        if (prog) prog(fraction);
    }
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (session != _downloadSession || task != _activeTask) return;
    NSMutableDictionary *ctx = _active;
    _active = nil;
    _activeTask = nil;
    NSFileHandle *handle = _activeHandle;
    _activeHandle = nil;
    if (handle) { @try { [handle closeFile]; } @catch (NSException *e) { } }
    NSString *failure = [ctx[@"failure"] isKindOfClass:NSString.class] ? ctx[@"failure"] : nil;
    unsigned long long expected = [ctx[@"expected"] unsignedLongLongValue];
    if (error || failure || _activeBytes <= 64 || _activeBytes != expected) {
        NSString *why = failure ?: error.localizedDescription;
        if (!why.length) why = @"下载不完整";
        [[NSFileManager defaultManager] removeItemAtPath:ctx[@"part"] error:nil]; /* 失败清理，不留半包 */
        [self finishContext:ctx ok:NO note:why];
        [self startNextDownload];
        return;
    }
    NSString *digest = SHA256HexFromCtx(&_activeSHA);
    if (![digest isEqual:ctx[@"sha256"]]) {
        [[NSFileManager defaultManager] removeItemAtPath:ctx[@"part"] error:nil];
        [self finishContext:ctx ok:NO note:@"SHA-256 不符，已丢弃"];
        [self startNextDownload];
        return;
    }
    /* 校验和改名放到后台队列；主线程只做本管理器簿记，不阻塞导航 UI。 */
    NSString *part = ctx[@"part"], *path = ctx[@"path"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:path error:nil];
        NSError *moveError = nil;
        if (![fm moveItemAtPath:part toPath:path error:&moveError]) {
            [fm removeItemAtPath:part error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishContext:ctx ok:NO note:@"落盘失败"];
                [self startNextDownload];
            });
            return;
        }
        [fm setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:path error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_lock lock];
            [self->_files removeObjectForKey:ctx[@"province"]];
            [self->_fileOrder removeObject:ctx[@"province"]];
            [self->_lock unlock];
            [self finishContext:ctx ok:YES note:@"下载完成"];
            [self startNextDownload];
        });
    });
}
- (void)deletePack:(NSString *)province {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self deletePack:province]; });
        return;
    }
    NSString *p = [self localPathFor:province];
    if (!p) return;
    [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
    [_lock lock];
    [_files removeObjectForKey:province];
    [_fileOrder removeObject:province];
    [_lock unlock];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TIORoadPackChanged" object:province userInfo:@{@"ok": @YES, @"note": @"已删除"}];
}
- (TIORoadPackFile *)fileFor:(NSString *)province {
    if (!province.length) return nil;
    [_lock lock];
    TIORoadPackFile *f = _files[province];
    if (f) { [_fileOrder removeObject:province]; [_fileOrder addObject:province]; }
    [_lock unlock];
    if (f) return f;
    if (![self packDownloaded:province]) return nil;
    f = [[TIORoadPackFile alloc]initWithPath:[self localPathFor:province] province:province];
    if (f) {
        [_lock lock];
        _files[province] = f;
        [_fileOrder removeObject:province];
        [_fileOrder addObject:province];
        while (_fileOrder.count > kMaxPackFiles) {
            NSString *old = _fileOrder.firstObject;
            [_fileOrder removeObjectAtIndex:0];
            if (![old isEqual:province]) [_files removeObjectForKey:old]; /* 有界 mmap 缓存 */
        }
        [_lock unlock];
    }
    return f;
}
- (BOOL)coversLat:(double)lat lon:(double)lon {
    if (!isfinite(lat) || !isfinite(lon)) return NO;
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
    if (!isfinite(lat) || !isfinite(lon)) return nil;
    static const int offsets[9][2] = {{0,0},{-1,0},{1,0},{0,-1},{0,1},{-1,-1},{-1,1},{1,-1},{1,1}};
    for (NSDictionary *p in _manifest) {
        if (![p isKindOfClass:[NSDictionary class]] || ![self packDownloaded:p[@"province"]]) continue;
        TIORoadPackFile *f = [self fileFor:p[@"province"]];
        if (!f || lat < f->minLat || lat > f->maxLat || lon < f->minLon || lon > f->maxLon) continue;
        /* 打包器按绝对经纬度分格（floor(lat/CELL)），这里用同一坐标系取格 */
        int row = (int)floor(lat / f->cellLat), col = (int)floor(lon / f->cellLon);
        if (row < 0 || col < 0 || row >= (int)f->gridLat || col >= (int)f->gridLon) continue;
        NSMutableArray *all = [NSMutableArray array];
        double loLat = 90, loLon = 180, hiLat = -90, hiLon = -180;
        /* 中心格优先：先在内存上限内装车附近的格，远处只补 bbox。 */
        for (unsigned k = 0; k < 9; k++) {
            int r = row + offsets[k][0], c = col + offsets[k][1];
            if (r < 0 || c < 0 || r >= (int)f->gridLat || c >= (int)f->gridLon) continue;
            double a = r * f->cellLat, b = c * f->cellLon; /* 绝对格边界 */
            loLat = MIN(loLat, a); loLon = MIN(loLon, b);
            hiLat = MAX(hiLat, a + f->cellLat); hiLon = MAX(hiLon, b + f->cellLon);
            if (all.count >= kMaxWindowFeatures) continue;
            for (NSDictionary *feat in [f featuresForCell:(uint32_t)(r * (int)f->gridLon + c)]) {
                if (all.count >= kMaxWindowFeatures) break;
                [all addObject:feat];
            }
        }
        if (!all.count) continue;
        if (bbox) *bbox = @[@(loLat), @(loLon), @(hiLat), @(hiLon)];
        if (province) *province = f->province;
        return all;
    }
    return nil;
}
@end
