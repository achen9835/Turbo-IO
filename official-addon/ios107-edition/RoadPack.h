#import <Foundation/Foundation.h>
/* 省际离线路网包（TNR 矢量小地图数据源）：
 * Release tag=roadmap-packs 提供 manifest.json + 每省一个 .pack；
 * 本管理器负责清单刷新、按需下载（SHA-256 钉值校验）、删除，
 * 以及按当前位置取 3×3 网格的路段特征（与 RoadMap 的 GeoJSON
 * 特征结构一致，installFeatures 直接可用）。
 * 磁盘格式见 tools/roadmap-pack-builder.py 头注释。 */
@interface TIORoadPackManager : NSObject
@property(nonatomic,readonly) NSArray<NSDictionary *> *manifest;
@property(nonatomic,readonly) NSString *note;
@property(nonatomic,readonly) NSUInteger downloadedCount;
+ (instancetype)shared;
- (void)refreshManifest:(void(^)(BOOL ok, NSString *note))done; /* 主线程回调；离线回落本地缓存 */
- (BOOL)packDownloaded:(NSString *)province;
- (NSString *)localPathFor:(NSString *)province;
- (void)downloadPack:(NSString *)province
            progress:(void(^)(double fraction))progress
                 done:(void(^)(BOOL ok, NSString *note))done;   /* 主线程回调 */
- (void)deletePack:(NSString *)province;
- (BOOL)coversLat:(double)lat lon:(double)lon; /* 仅查已下载包的省级 bbox，不加载格数据 */
/* 3×3 格合并查询；bbox/province 出参给 RoadMap 做区域登记与状态行。 */
- (NSArray *)featuresAtLat:(double)lat lon:(double)lon bbox:(NSArray **)bbox province:(NSString **)province;
@end
