#import "RoadMap.h"
#import "RoadPack.h"
#include "nav_map.h"
#include "nav_runtime.h"
#include <math.h>
#include <float.h>
#include <stdlib.h>
static BOOL N(id v,double lo,double hi){return [v isKindOfClass:NSNumber.class]&&isfinite([v doubleValue])&&[v doubleValue]>=lo&&[v doubleValue]<=hi;}
static BOOL LL(id p){return [p isKindOfClass:NSArray.class]&&[p count]==2&&N(p[0],-85,85)&&N(p[1],-180,180);}
static void W16(uint8_t *p,unsigned x){p[0]=x;p[1]=x>>8;}static void W32(uint8_t *p,uint32_t x){W16(p,x);W16(p+2,x>>16);}
static NSArray *XY(NSArray *ll,NSArray *origin){double y=([ll[0] doubleValue]-[origin[0] doubleValue])*111319.49,x=([ll[1] doubleValue]-[origin[1] doubleValue])*111319.49*cos([origin[0] doubleValue]*M_PI/180);return @[@(x),@(y)];}
static double Distance(NSArray *a,NSArray *b){NSArray *p=XY(a,b);return hypot([p[0] doubleValue],[p[1] doubleValue]);}
static BOOL Clip(double *x,double *y,double *xx,double *yy){double dx=*xx-*x,dy=*yy-*y,t0=0,t1=1,p[]={-dx,dx,-dy,dy},q[]={*x+500,500-*x,*y+500,500-*y};for(int i=0;i<4;i++){if(fabs(p[i])<1e-9){if(q[i]<0)return NO;}else{double t=q[i]/p[i];if(p[i]<0)t0=fmax(t0,t);else t1=fmin(t1,t);if(t0>t1)return NO;}}double ox=*x,oy=*y;*x=ox+dx*t0;*y=oy+dy*t0;*xx=ox+dx*t1;*yy=oy+dy*t1;return YES;}
static NSArray *Pieces(NSArray *coords,NSArray *origin,NSArray *(^convert)(double,double),BOOL osm){
 NSMutableArray *pieces=[NSMutableArray new],*part=nil;NSArray *last=nil;NSUInteger budget=0;
 for(id pair in coords){NSArray *ll=osm&&[pair isKindOfClass:NSArray.class]&&[pair count]==2?@[pair[1],pair[0]]:pair;if(!LL(ll)){last=nil;part=nil;continue;}if(osm&&convert)ll=convert([ll[0] doubleValue],[ll[1] doubleValue]);if(!LL(ll)){last=nil;part=nil;continue;}NSArray *xy=XY(ll,origin);
  if(last){double x=[last[0] doubleValue],y=[last[1] doubleValue],xx=[xy[0] doubleValue],yy=[xy[1] doubleValue];if(Clip(&x,&y,&xx,&yy)){
   NSArray *a=@[@((int)lround(x*4)),@((int)lround(y*4))],*b=@[@((int)lround(xx*4)),@((int)lround(yy*4))];
   if(!part||![part.lastObject isEqual:a]){part=[NSMutableArray arrayWithObject:a];[pieces addObject:part];}
   if(![part.lastObject isEqual:b])[part addObject:b];budget++;if(budget>=2048)break;
  }else part=nil;}last=xy;
 }
 return pieces;
}
static NSString *Text(id value){return [value isKindOfClass:NSString.class]?value:[value isKindOfClass:NSNumber.class]?[value stringValue]:@"";}
static NSArray *Simplify(NSArray *p){
 if(p.count<3||p.count>2049)return p;NSUInteger todo[4098],top=0;NSMutableIndexSet *keep=[NSMutableIndexSet indexSetWithIndex:0];[keep addIndex:p.count-1];todo[top++]=0;todo[top++]=p.count-1;
 while(top){NSUInteger b=todo[--top],a=todo[--top],at=0;double ax=[p[a][0] doubleValue],ay=[p[a][1] doubleValue],dx=[p[b][0] doubleValue]-ax,dy=[p[b][1] doubleValue]-ay,den=dx*dx+dy*dy,best=64;
  for(NSUInteger i=a+1;i<b;i++){double x=[p[i][0] doubleValue]-ax,y=[p[i][1] doubleValue]-ay,t=den?MAX(0,MIN(1,(x*dx+y*dy)/den)):0,ex=x-dx*t,ey=y-dy*t,d=ex*ex+ey*ey;if(d>best){best=d;at=i;}}
  if(at){[keep addIndex:at];todo[top++]=a;todo[top++]=at;todo[top++]=at;todo[top++]=b;}
 }
 NSMutableArray *out=[NSMutableArray new];[keep enumerateIndexesUsingBlock:^(NSUInteger i,BOOL *stop){[out addObject:p[i]];}];return out;
}
/* Highlighted-route budget: TNR_MAX_POINTS (768) is shared with the background
 * roads, and a dense clipped route could still exceed it after the fixed 2 m
 * Simplify above. The old selection then dropped the whole style==6 path, so
 * the lens kept the START sketch. Reduce shape-preservingly down to a reserved
 * slice instead; the C helper keeps both endpoints, so the first point stays
 * behind the vehicle and tnr_route_base_qm()'s negative projection offset does
 * not flip the marker behind the car. */
static NSArray *Budget(NSArray *pts,NSUInteger cap){
 if(pts.count<2)return pts;
 NSUInteger room=MAX(pts.count,cap);TNRPoint *route=malloc(room*sizeof *route);if(!route)return pts;
 for(NSUInteger i=0;i<pts.count;i++){route[i].x=(int16_t)[pts[i][0] intValue];route[i].y=(int16_t)[pts[i][1] intValue];}
 unsigned kept=tnr_path_budget(route,(unsigned)pts.count,(unsigned)(cap<2?2:cap));
 NSMutableArray *out=[NSMutableArray arrayWithCapacity:kept];
 for(unsigned i=0;i<kept;i++)[out addObject:@[@(route[i].x),@(route[i].y)]];
 free(route);return kept>=2?out:pts;
}
/* Same bounded Overpass query is retried on public mirrors in order; the
 * session budget (_requests<=6, 60 s apart) still counts logical requests, not
 * mirrors, so a dead primary cannot multiply user traffic (bounded 3 attempts
 * per logical request, and the working mirror is remembered). */
static NSArray<NSString *> *OverpassMirrors(void){return @[@"https://overpass-api.de/api/interpreter",@"https://overpass.kumi.systems/api/interpreter",@"https://overpass.private.coffee/api/interpreter"];}
static NSString *Brief(NSString *text){return !text.length?@"网络或服务失败":text.length>72?[[text substringToIndex:72] stringByAppendingString:@"…"]:text;}
static NSData *NameData(id value){
 NSString *name=Text(value);NSMutableString *s=[NSMutableString new];__block unsigned width=0;
 [name enumerateSubstringsInRange:NSMakeRange(0,name.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *c,NSRange r,NSRange all,BOOL *stop){
  unichar u=[c characterAtIndex:0];if(c.length!=1||u<32||(u>=127&&u<=159)||(u>=0x200b&&u<=0x202e)||(u>=0x2060&&u<=0x206f)||u>=0xfff0)return;unsigned w=u<128?9:16;if(width+w>104||[s lengthOfBytesUsingEncoding:NSUTF8StringEncoding]+[c lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>=TNR_LABEL_BYTES){*stop=YES;return;}width+=w;[s appendString:c];
 }];return [s dataUsingEncoding:NSUTF8StringEncoding];
}
static unsigned RoadStyle(NSString *h){if([@[@"motorway",@"trunk",@"motorway_link",@"trunk_link"] containsObject:h])return 0;if([h hasPrefix:@"primary"])return 1;if([h hasPrefix:@"secondary"])return 2;if([h hasPrefix:@"tertiary"])return 3;if([@[@"residential",@"unclassified",@"living_street"] containsObject:h])return 4;return 5;}
static double ROrient(double ax,double ay,double bx,double by,double cx,double cy){return (bx-ax)*(cy-ay)-(by-ay)*(cx-ax);}
static BOOL RCross(double ax,double ay,double bx,double by,double cx,double cy,double dx,double dy){
 double p=ROrient(ax,ay,bx,by,cx,cy),q=ROrient(ax,ay,bx,by,dx,dy),r=ROrient(cx,cy,dx,dy,ax,ay),s=ROrient(cx,cy,dx,dy,bx,by);return ((p>0&&q<0)||(p<0&&q>0))&&((r>0&&s<0)||(r<0&&s>0));
}
static BOOL RSegmentRect(double ax,double ay,double bx,double by,double left,double top,double right,double bottom){
 if((ax<left&&bx<left)||(ax>right&&bx>right)||(ay<top&&by<top)||(ay>bottom&&by>bottom))return NO;
 if((ax>=left&&ax<=right&&ay>=top&&ay<=bottom)||(bx>=left&&bx<=right&&by>=top&&by<=bottom))return YES;
 return RCross(ax,ay,bx,by,left,top,right,top)||RCross(ax,ay,bx,by,right,top,right,bottom)||RCross(ax,ay,bx,by,right,bottom,left,bottom)||RCross(ax,ay,bx,by,left,bottom,left,top);
}
static BOOL RLabelRoute(NSArray *parts,double left,double top,double right,double bottom,double ss,double cc,unsigned range){
 for(NSArray *part in parts)for(NSUInteger i=1;i<part.count;i++){
  double ax=[part[i-1][0] doubleValue],ay=[part[i-1][1] doubleValue],bx=[part[i][0] doubleValue],by=[part[i][1] doubleValue];
  double x0=148+(ax*cc-ay*ss)*296/((double)range*4),y0=103-(ax*ss+ay*cc)*296/((double)range*4),x1=148+(bx*cc-by*ss)*296/((double)range*4),y1=103-(bx*ss+by*cc)*296/((double)range*4);
  if(RSegmentRect(x0,y0,x1,y1,left,top,right,bottom))return YES;
 }return NO;
}
@implementation TIORoadMap{
 NSArray *(^_convert)(double,double);NSArray *_features,*_bbox,*_origin,*_regions;double _labelHeading,_sceneAt;NSData *_scene,*_scene2,*_sceneMin,*_markerScene,*_markerPose;uint32_t _generation;id _segment;NSString *_note;
 unsigned _sceneRange,_labelRange;
 NSURLSession *_session;NSURLSessionDataTask *_task;NSMutableData *_received;NSTimeInterval _lastRequest;NSUInteger _requests,_epoch;BOOL _httpOK;
 NSString *_query,*_bboxB64;NSUInteger _endpoint,_attempt;BOOL _sourceFailed;NSString *_sourceReason;
 NSString *_autoPackProvince;BOOL _autoPackBusy; /* 当前省包自动下载（导航即用，不占页面开关） */
}
- (instancetype)initWithWGS84ToMap:(NSArray *(^)(double,double))convert{if((self=[super init])){_convert=[convert copy];_note=@"路网自动开启 · 正在准备";[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(packChanged:) name:@"TIORoadPackChanged" object:nil];}return self;}
- (NSString *)note{return _note?:@"";}
- (void)reset{_epoch++;[_task cancel];[_session invalidateAndCancel];_task=nil;_session=nil;_received=nil;_regions=nil;_features=nil;_bbox=nil;_scene=nil;_scene2=nil;_sceneMin=nil;_markerScene=nil;_markerPose=nil;_origin=nil;_segment=nil;_requests=0;_lastRequest=0;_query=nil;_bboxB64=nil;_endpoint=0;_attempt=0;_sourceFailed=NO;_sourceReason=nil;_autoPackProvince=nil;_autoPackBusy=NO;self.allowNetwork=YES;_note=@"路网缓存已清理，联网授权保持开启";}
- (void)dealloc{[NSNotificationCenter.defaultCenter removeObserver:self];[_session invalidateAndCancel];}
- (void)packChanged:(NSNotification *)note{[self reloadPackData];}
- (void)reloadPackData{/* 省包新就绪：丢弃已构建场景，下一帧按 pack 重新载入路网 */_features=nil;_regions=nil;_scene=nil;_scene2=nil;_sceneMin=nil;_markerScene=nil;_markerPose=nil;_origin=nil;_segment=nil;_sceneAt=0;}
- (NSData *)minimalSceneForCoords:(NSArray *)coords origin:(NSArray *)origin range:(unsigned)range generation:(uint32_t)generation{
 /* 只含路线、无背景道路/无标签的最小 SCENE：完整场景被镜片拒收时先打通矢量通道 */
 if(!LL(origin)||![coords isKindOfClass:NSArray.class]||coords.count<2||!generation)return nil;
 NSArray *best=nil;
 for(NSArray *part in Pieces(coords,origin,nil,NO))if(part.count>=2&&(!best||part.count>best.count))best=part;
 if(!best)return nil;best=Simplify(best);if(best.count<2)return nil;best=Budget(best,128);
 if(best.count<2||best.count>128)return nil;
 NSMutableData *out=[NSMutableData dataWithLength:16+8+4*best.count];uint8_t *b=out.mutableBytes;
 W32(b,generation);W16(b+4,range);W16(b+6,1);W16(b+8,best.count);W16(b+16,best.count);b[18]=6;b[19]=0;b[20]=8;
 NSUInteger at=24;for(NSArray *p in best){W16(b+at,[p[0] intValue]);W16(b+at+2,[p[1] intValue]);at+=4;}
 return tnr_body_valid(TNR_SCENE,out.bytes,out.length)?out:nil;
}
- (NSDictionary *)markerTestFrame:(NSDictionary *)frame{
 if(!self.enabled||![frame[@"phase"] isEqual:@"navigating"])return nil;
 if(!_markerScene){
  if(_generation==UINT32_MAX)return nil;
  NSArray *origin=@[@22.5,@114.0];
  /* 路线自车位起一路向北（先 400m 再 800m）：自测标记表示"前方 20/50/90 m"，
   * 必须落在行进方向上；早期的先南后北 U 形让标记投影到车后，失去自测意义。 */
  NSArray *route=@[origin,@[@(22.5+400.0/111319.49),@114.0],@[@(22.5+800.0/111319.49),@114.0]];
  uint32_t generation=_generation+1;
  NSData *scene=[self minimalSceneForCoords:route origin:origin range:320 generation:generation];
  if(!scene)return nil;
  uint8_t pose[12]={0};W32(pose,generation);
  _generation=generation;_markerScene=scene;_markerPose=[NSData dataWithBytes:pose length:sizeof pose];
 }
 NSMutableDictionary *out=[frame mutableCopy];out[@"tnrScene"]=_markerScene;out[@"tnrSceneMin"]=_markerScene;out[@"tnrPose"]=_markerPose;out[@"tnrPoseAt"]=@(NSProcessInfo.processInfo.systemUptime);out[@"tnrSource"]=@"hud-marker-selftest";
 out[@"navHeading"]=@0;out[@"navPoints"]=@[@[@512,@900],@[@512,@700],@[@512,@100]];out[@"speedKmh"]=@42;
 out[@"lights"]=@3;out[@"lightsMeters"]=@20;out[@"lightsList"]=@[@20];out[@"roadLimit"]=@60;
 NSMutableArray *bars=[NSMutableArray new];for(unsigned i=0;i<24;i++)[bars addObject:@(i<8?1:(i<16?2:3))];out[@"barLevels"]=bars;
 out[@"camera"]=@{@"kind":@(TN_CAMERA_SPEED),@"limit":@60,@"m":@50};out[@"event"]=@{@"kind":@(TN_EVENT_ACCIDENT),@"m":@90};
 out[@"camList"]=@[@{@"kind":@1,@"limit":@60,@"m":@50},@{@"kind":@3,@"limit":@0,@"m":@140},@{@"kind":@4,@"limit":@80,@"m":@260}]; /* 沿路电子眼全量自测：测速/监控/区间 */
 return out;
}
- (void)clearMarkerTest{_markerScene=nil;_markerPose=nil;_scene=nil;_scene2=nil;_sceneMin=nil;_origin=nil;_segment=nil;_sceneAt=0;}
- (void)autoProvidePackFor:(NSArray *)wgs{
 if(!self.enabled||!LL(wgs)||_autoPackBusy)return;
 TIORoadPackManager *m=[TIORoadPackManager shared];
 double lat=[wgs[0] doubleValue],lon=[wgs[1] doubleValue];
 if([m coversLat:lat lon:lon])return;
 NSString *province=[m provinceForLat:lat lon:lon];
 if(!province.length||[province isEqual:_autoPackProvince])return;
 _autoPackProvince=[province copy];
 if([m packDownloaded:province]){[self reloadPackData];return;}
 _autoPackBusy=YES;
 _note=[NSString stringWithFormat:@"正在自动下载 %@ 省路网包（导航时自动获取，先显示路线）…",province];
 NSString *slug=[province copy];
 __weak typeof(self) weakSelf=self;
 [m downloadPack:slug progress:nil done:^(BOOL ok,NSString *note){
  dispatch_async(dispatch_get_main_queue(),^{
   TIORoadMap *s=weakSelf;if(!s)return;s->_autoPackBusy=NO;
   if(ok){[s reloadPackData];s->_note=[NSString stringWithFormat:@"%@ 省路网包已下载，正在加载周边路网…",slug];}
   else{s->_note=[NSString stringWithFormat:@"省包自动下载失败：%@（可到“省际路网包”手动重试）",note.length?note:@"原因未知"];}
  });
 }];
}
- (NSArray *)wgs:(NSArray *)map{
 if(!LL(map))return nil;if(!_convert)return map;
 // Only the Overpass search/fixture coverage uses WGS84. Render origin,
 // AMap route and pose stay in GCJ02; OSM lon/lat converts exactly once.
 double lat=[map[0] doubleValue],lon=[map[1] doubleValue];
 for(int i=0;i<6;i++){NSArray *candidate=@[@(lat),@(lon)];if(!LL(candidate))return nil;
  NSArray *q=_convert(lat,lon);if(!LL(q))return nil;
  if(Distance(q,map)<=.5)return candidate;
  lat-=[q[0] doubleValue]-[map[0] doubleValue];lon-=[q[1] doubleValue]-[map[1] doubleValue];
 }return nil; // Do not request/show a mismatched region when inverse fails.
}
// Two bounded geographic regions. Refresh coverage and render coverage are distinct.
- (BOOL)bbox:(NSArray *)b contains:(NSArray *)ll margin:(double)metres {
 if(b.count!=4||!LL(ll))return NO;
 double lat=[ll[0] doubleValue],lon=[ll[1] doubleValue],dy=metres/111319.49,dx=dy/MAX(.2,cos(lat*M_PI/180));
 return lat>=[b[0] doubleValue]+dy&&lat<=[b[2] doubleValue]-dy&&lon>=[b[1] doubleValue]+dx&&lon<=[b[3] doubleValue]-dx;
}
- (BOOL)hasCoverage:(NSArray *)ll margin:(double)metres {
 for(NSDictionary *r in _regions)if([self bbox:r[@"bbox"] contains:ll margin:metres])return YES;
 return NO;
}
- (void)installFeatures:(NSArray *)features bbox:(NSArray *)bbox {
 /* 省级路网包 3×3 窗口可达数千路段（旧上限 5000 会让密集城区整包被判无效）。 */
 if(!features.count||features.count>8000||bbox.count!=4)return;
 NSMutableArray *regions=[NSMutableArray arrayWithArray:_regions?:@[]];
 NSIndexSet *same=[regions indexesOfObjectsPassingTest:^BOOL(NSDictionary *r,NSUInteger i,BOOL *stop){return [r[@"bbox"] isEqual:bbox];}];[regions removeObjectsAtIndexes:same];
 [regions addObject:@{@"bbox":bbox,@"features":features}];while(regions.count>2)[regions removeObjectAtIndex:0];_regions=regions;
 _bbox=bbox;NSMutableArray *all=[NSMutableArray new];NSMutableSet *seen=[NSMutableSet new];
 // Current region first. Deduplicate overlapping road fragments without persisting location.
 for(NSDictionary *r in [regions reverseObjectEnumerator])for(NSDictionary *f in r[@"features"]){
  if(all.count>=10000)break;if([seen containsObject:f])continue;[seen addObject:f];[all addObject:f];
 }
 _features=all;_scene=nil;_scene2=nil;_sceneMin=nil;
}
- (BOOL)covers:(NSArray *)ll {return [self hasCoverage:ll margin:0];}
/* 省际路网包优先：已下载的省直接离线取 3×3 格窗口，不联网。 */
- (BOOL)loadPack:(NSArray *)ll {
 if(![ll isKindOfClass:NSArray.class]||[ll count]!=2)return NO;
 NSArray *bbox=nil;NSString *province=nil;
 NSArray *features=[[TIORoadPackManager shared] featuresAtLat:[ll[0] doubleValue] lon:[ll[1] doubleValue] bbox:&bbox province:&province];
 if(!features||features.count>8000||![bbox isKindOfClass:NSArray.class]||bbox.count!=4)return NO; /* 单窗 >8000 路段视为异常包，不装 */
 [self installFeatures:features bbox:bbox];
 _note=[NSString stringWithFormat:@"省际离线路网 · %@ · © OpenStreetMap",province.length?province:@"已下载省份"];
 return YES;
}
/* Overpass 结果落盘（有界缓存）：通勤路线走过一次，之后离线也能渲染。 */
- (NSString *)cacheDir {
 static NSString *dir;static dispatch_once_t once;
 dispatch_once(&once,^{
  dir=[[[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject
   stringByAppendingPathComponent:@"TurboIOResearch"] stringByAppendingPathComponent:@"RoadCache"] copy];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
 });
 return dir;
}
- (void)persistRegion:(NSArray *)bbox features:(NSArray *)features {
 if(![bbox isKindOfClass:NSArray.class]||bbox.count!=4||![features isKindOfClass:NSArray.class]||!features.count)return;
 NSError *err=nil;
 NSData *body=[NSJSONSerialization dataWithJSONObject:@{@"bbox":bbox,@"features":features} options:0 error:&err];
 if(!body.length||body.length>2*1024*1024)return;
 NSString *name=[NSString stringWithFormat:@"r%08lx.json",(unsigned long)[[bbox description] hash]&0xffffffffUL];
 [[NSFileManager defaultManager] removeItemAtPath:[[self cacheDir] stringByAppendingPathComponent:name] error:nil];
 if(![body writeToFile:[[self cacheDir] stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:nil])return;
 [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:[[self cacheDir] stringByAppendingPathComponent:name] error:nil];
 /* LRU：最多 12 个区域 / 合计 24 MB */
 NSArray *files=[[[NSFileManager defaultManager] contentsOfDirectoryAtPath:[self cacheDir] error:nil]
  sortedArrayUsingComparator:^NSComparisonResult(NSString *a,NSString *b){
   NSDate *da=[[[NSFileManager defaultManager] attributesOfItemAtPath:[[self cacheDir] stringByAppendingPathComponent:a] error:nil] fileModificationDate];
   NSDate *db=[[[NSFileManager defaultManager] attributesOfItemAtPath:[[self cacheDir] stringByAppendingPathComponent:b] error:nil] fileModificationDate];
   return [da compare:db];}];
 unsigned long long total=0;NSMutableArray *sizes=[NSMutableArray new];
 for(NSString *f in files){unsigned long long s=[[[NSFileManager defaultManager] attributesOfItemAtPath:[[self cacheDir] stringByAppendingPathComponent:f] error:nil] fileSize];[sizes addObject:@(s)];total+=s;}
 for(NSUInteger i=0;i<files.count;i++){
  if(files.count-i<=12&&total<=24*1024*1024)break;
  [[NSFileManager defaultManager] removeItemAtPath:[[self cacheDir] stringByAppendingPathComponent:files[i]] error:nil];
  total-=[sizes[i] unsignedLongLongValue];
 }
}
- (BOOL)loadCache:(NSArray *)ll {
 if(![ll isKindOfClass:NSArray.class]||[ll count]!=2)return NO;
 NSArray *files=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:[self cacheDir] error:nil];
 for(NSString *f in [files sortedArrayUsingSelector:@selector(compare:)]) {
  if([f hasSuffix:@".part"]||[f hasPrefix:@"."])continue;
  NSString *p=[[self cacheDir] stringByAppendingPathComponent:f];
  NSData *d=[NSData dataWithContentsOfFile:p];
  if(!d.length||d.length>2*1024*1024)continue;
  id j=[NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
  if(![j isKindOfClass:[NSDictionary class]])continue;
  NSArray *bbox=j[@"bbox"],*features=j[@"features"];
  if(![bbox isKindOfClass:NSArray.class]||bbox.count!=4||![features isKindOfClass:NSArray.class]||!features.count||features.count>8000)continue;
  if([self bbox:bbox contains:ll margin:0]){[self installFeatures:features bbox:bbox];_note=@"离线路网缓存 · © OpenStreetMap";return YES;}
 }
 return NO;
}
- (NSDictionary *)coverageStatus {
 /* state 把“为什么没有路网”分成四类，配合 note 给用户看的文案：
  * unauthorized-no-pack / unauthorized-pack-uncovered（未授权联网）、
  * no-pack（无省级包且图源没返回）、source-unavailable（图源不可用）、
  * pack-uncovered（已下载包与离线缓存均未覆盖当前点）。 */
 NSUInteger packs=[[TIORoadPackManager shared] downloadedCount];
 NSString *state=!self.enabled?@"disabled":_task?@"loading":_features.count?@"ready":
  self.allowNetwork?(_sourceFailed?@"source-unavailable":(packs?@"pack-uncovered":@"no-pack")):
  (packs?@"unauthorized-pack-uncovered":@"unauthorized-no-pack");
 return @{@"regions":@(_regions.count),@"features":@(_features.count),@"requests":@(_requests),@"networkAllowed":@(self.allowNetwork),@"requestInFlight":@(_task!=nil),@"requestLimit":@6,@"state":state,@"reason":self.note?:@"",@"packs":@(packs),@"sourceFailed":@(_sourceFailed)};
}
- (BOOL)hasVisibleLabelsAt:(NSArray *)position heading:(unsigned)heading {
 if(!_scene2||!_origin)return NO;
 // Evaluate the unchanged firmware's exact clipping/overlap rules locally.
 TNRState state={0};if(!tnr_receive(&state,TNR_SCENE2,_scene2.bytes,_scene2.length,0))return NO;
 NSArray *xy=XY(position,_origin);double x=[xy[0] doubleValue]*4,y=[xy[1] doubleValue]*4;
 if(fabs(x)>2000||fabs(y)>2000)return NO;
 uint8_t pose[12]={0};W32(pose,_generation);W16(pose+4,(int)lround(x));W16(pose+6,(int)lround(y));W16(pose+8,heading%360);
 if(!tnr_receive(&state,TNR_POSE,pose,12,0))return NO;
 TNRLabelView out[TNR_MAX_LABELS];return tnr_labels(&state,200,out)>0;
}
- (NSString *)fixturePath:(NSString *)name{return [NSBundle.mainBundle pathForResource:name ofType:@"json" inDirectory:@"TurboHUDMaps"];}
- (BOOL)loadFixture:(NSArray *)ll{for(NSString *name in @[@"shenzhen",@"hongkong"]){NSString *p=[self fixturePath:name];NSData *d=p?[NSData dataWithContentsOfFile:p]:nil;if(!d||d.length>2*1024*1024)continue;NSDictionary *j=[NSJSONSerialization JSONObjectWithData:d options:0 error:nil];if(![j isKindOfClass:NSDictionary.class]||![j[@"meta"] isKindOfClass:NSDictionary.class]||![j[@"geojson"] isKindOfClass:NSDictionary.class])continue;NSArray *b=j[@"meta"][@"bbox"],*features=j[@"geojson"][@"features"];if(![b isKindOfClass:NSArray.class]||b.count!=4||![features isKindOfClass:NSArray.class]||features.count>5000)continue;BOOL valid=YES;for(id n in b)valid&=N(n,-180,180);if(!valid)continue;double lat=[ll[0] doubleValue],lon=[ll[1] doubleValue];if(lat<[b[0] doubleValue]||lat>[b[2] doubleValue]||lon<[b[1] doubleValue]||lon>[b[3] doubleValue])continue;[self installFeatures:features bbox:b];_note=@"公开区域离线路网 · © OpenStreetMap";return YES;}return NO;}
- (void)request:(NSArray *)ll{
 NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;if(!self.allowNetwork||_task||_requests>=6||(_lastRequest&&now-_lastRequest<60)||![ll isKindOfClass:NSArray.class]||ll.count!=2)return;
 double lat=[ll[0] doubleValue],lon=[ll[1] doubleValue],dlat=.006,dlon=.006/MAX(.2,cos(lat*M_PI/180));
 NSArray *bbox=@[@(lat-dlat),@(lon-dlon),@(lat+dlat),@(lon+dlon)];
 _query=[NSString stringWithFormat:@"[out:json][timeout:15][maxsize:16777216];way[highway](%.6f,%.6f,%.6f,%.6f);out tags geom;",lat-dlat,lon-dlon,lat+dlat,lon+dlon];
 _bboxB64=[[NSJSONSerialization dataWithJSONObject:bbox options:0 error:nil] base64EncodedStringWithOptions:0];
 _lastRequest=now;_requests++;_attempt=0;_sourceFailed=NO;_sourceReason=nil;[self attemptRequest];
}
/* One logical request: try the remembered mirror first, then the rest in order.
 * A failed attempt does not consume the 6-request/60 s budget; the query text
 * and rate limits are unchanged (<=3 bounded attempts, same UA/timeout/size). */
- (void)attemptRequest{
 NSArray<NSString *> *mirrors=OverpassMirrors();if(!_query.length||!_bboxB64.length||_attempt>=mirrors.count)return;
 NSUInteger index=(_endpoint+_attempt)%mirrors.count;
 NSString *encoded=[_query stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
 NSURL *url=[NSURL URLWithString:[mirrors[index] stringByAppendingFormat:@"?data=%@",encoded]];
 if(!url||[url.scheme caseInsensitiveCompare:@"https"]!=NSOrderedSame){_attempt++;[self attemptRequest];return;}
 NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:22];[r setValue:@"TurboIO-TNR1-private-pilot/1.0" forHTTPHeaderField:@"User-Agent"];
 NSURLSessionConfiguration *c=NSURLSessionConfiguration.ephemeralSessionConfiguration;c.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;c.URLCache=nil;c.HTTPCookieStorage=nil;c.timeoutIntervalForResource=25;c.HTTPMaximumConnectionsPerHost=1;
 _session=[NSURLSession sessionWithConfiguration:c delegate:self delegateQueue:NSOperationQueue.mainQueue];_received=[NSMutableData new];_httpOK=NO;
 _task=[_session dataTaskWithRequest:r];_task.taskDescription=_bboxB64;
 _note=[NSString stringWithFormat:@"试验图源请求中（镜像 %lu/%lu，最多6次/会话，间隔60秒）",(unsigned long)(_attempt+1),(unsigned long)mirrors.count];[_task resume];
}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t willPerformHTTPRedirection:(NSHTTPURLResponse *)r newRequest:(NSURLRequest *)q completionHandler:(void(^)(NSURLRequest *))done{done(nil);}
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveResponse:(NSURLResponse *)r completionHandler:(void(^)(NSURLSessionResponseDisposition))done{_httpOK=s==_session&&t==_task&&[(NSHTTPURLResponse *)r statusCode]==200&&r.expectedContentLength<=2*1024*1024;done(_httpOK?NSURLSessionResponseAllow:NSURLSessionResponseCancel);}
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)d{if(s!=_session||t!=_task)return;if(d.length>2*1024*1024-_received.length){_httpOK=NO;[t cancel];return;}[_received appendData:d];}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)error{
 if(s!=_session||t!=_task)return;NSData *data=_received;NSString *b64=t.taskDescription;BOOL ok=_httpOK&&!error;NSUInteger epoch=_epoch;_task=nil;_received=nil;_session=nil;[s finishTasksAndInvalidate];
 if(!ok){
  if(_attempt+1<OverpassMirrors().count){_attempt++;[self attemptRequest];return;} /* next mirror, same logical query */
  _sourceFailed=YES;_sourceReason=Brief(error?error.localizedDescription:(_httpOK?@"响应超限":@"未获得有效响应"));
  _lastRequest=NSProcessInfo.processInfo.systemUptime; /* 冷却从失败结束算起，避免镜像轮询放大请求量 */
  _endpoint=(_endpoint+1)%OverpassMirrors().count; /* next request starts at another mirror */
  _note=[NSString stringWithFormat:@"图源不可用（%@）· 已试 %lu 个公开镜像 · 不伪造道路，保留路线示意图",_sourceReason,(unsigned long)OverpassMirrors().count];
  return;
 }
 _endpoint=(_endpoint+_attempt)%OverpassMirrors().count; /* remember the working mirror */
 _sourceFailed=NO;_sourceReason=nil;
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSDictionary *j=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];NSMutableArray *features=[NSMutableArray new];NSUInteger points=0;
  if([j isKindOfClass:NSDictionary.class]&&[j[@"elements"] isKindOfClass:NSArray.class]&&[j[@"elements"] count]<=5000&&!j[@"remark"])for(NSDictionary *way in j[@"elements"]){if(![way isKindOfClass:NSDictionary.class]||![way[@"type"] isEqual:@"way"]||![way[@"geometry"] isKindOfClass:NSArray.class])continue;NSMutableArray *coords=[NSMutableArray new];for(id point in way[@"geometry"]){if(![point isKindOfClass:NSDictionary.class]||!N(point[@"lat"],-85,85)||!N(point[@"lon"],-180,180)){[coords removeAllObjects];break;}[coords addObject:@[point[@"lon"],point[@"lat"]]];if(++points>40000)break;}if(points>40000){[features removeAllObjects];break;}if(coords.count>=2){NSMutableDictionary *p=[way[@"tags"] isKindOfClass:NSDictionary.class]?[way[@"tags"] mutableCopy]:[NSMutableDictionary new];p[@"kind"]=@"road";[features addObject:@{@"properties":p,@"geometry":@{@"coordinates":coords,@"type":@"LineString"}}];}}
  NSArray *bbox=[NSJSONSerialization JSONObjectWithData:[[NSData alloc]initWithBase64EncodedString:b64 options:0] options:0 error:nil];dispatch_async(dispatch_get_main_queue(),^{if(epoch!=self->_epoch)return;if(features.count&&bbox.count==4){self->_sourceFailed=NO;self->_sourceReason=nil;[self installFeatures:features bbox:bbox];[self persistRegion:bbox features:features];self->_note=@"联网路网就绪 · 已缓存到本机 · © OpenStreetMap · 非高德底图";}else{self->_sourceFailed=YES;self->_sourceReason=@"图源返回格式或容量不合格";self->_note=@"图源不可用（返回格式或容量不合格）· 不伪造道路，保留路线示意图";}});
 });
}
- (NSData *)scene:(NSArray *)coords origin:(NSArray *)origin range:(unsigned)range{
 NSMutableArray *items=[NSMutableArray new];NSUInteger visited=0;
 for(NSDictionary *f in _features){if(++visited>10000)break;NSDictionary *p=f[@"properties"],*g=f[@"geometry"];if(![p[@"kind"] isEqual:@"road"]||![g[@"type"] isEqual:@"LineString"]||![g[@"coordinates"] isKindOfClass:NSArray.class])continue;
  if([Text(p[@"area"]) isEqual:@"yes"])continue;
  unsigned style=RoadStyle(Text(p[@"highway"]));for(NSArray *part in Pieces(g[@"coordinates"],origin,_convert,YES)){if(part.count<2)continue;double rank=DBL_MAX;for(NSUInteger i=1;i<part.count;i++){double x=[part[i-1][0] doubleValue],y=[part[i-1][1] doubleValue],dx=[part[i][0] doubleValue]-x,dy=[part[i][1] doubleValue]-y,t=MAX(0,MIN(1,-(x*dx+y*dy)/MAX(1,dx*dx+dy*dy)));rank=MIN(rank,hypot(x+dx*t,y+dy*t)/4);}NSString *bridge=Text(p[@"bridge"]),*tunnel=Text(p[@"tunnel"]);unsigned flags=(bridge.length&&![bridge isEqual:@"no"]?1:0)|(tunnel.length&&![tunnel isEqual:@"no"]?2:0);[items addObject:@{@"points":part,@"style":@(style),@"flags":@(flags),@"layer":@(MAX(-8,MIN(8,[Text(p[@"layer"]) intValue]))),@"name":Text(p[@"name:zh"]).length?Text(p[@"name:zh"]):Text(p[@"name"]),@"rank":@(rank+style*18)}];if(items.count>4096)break;}if(items.count>4096)break;
 }
 [items sortUsingComparator:^NSComparisonResult(id a,id b){return [a[@"rank"] compare:b[@"rank"]];}];
 NSMutableArray *route=[NSMutableArray new];for(NSArray *part in Pieces(coords,origin,nil,NO))if(part.count>=2)[route addObject:@{@"points":part,@"style":@6,@"flags":@0,@"layer":@8,@"rank":@0}];
 NSMutableArray *selected=[NSMutableArray new];NSUInteger points=0;
 /* The highlighted route must never be dropped by the shared point budget:
  * reserve two thirds of TNR_MAX_POINTS for it and reduce a dense clipped
  * polyline into that slice (endpoints preserved). Background roads then fill
  * the remainder in rank order, so a long AMap route cannot starve the map. */
 NSUInteger routeLeft=TNR_MAX_POINTS*2/3;
 for(NSDictionary *item in route){
  if(selected.count>=TNR_MAX_PATHS)break;
  NSArray *part=Simplify(item[@"points"]);if(part.count<2||routeLeft<2)continue;
  part=Budget(part,routeLeft); /* also re-densifies long chords for the firmware int32 projection */
  if(part.count<2||part.count>routeLeft)continue;
  routeLeft-=part.count;points+=part.count;NSMutableDictionary *simple=[item mutableCopy];simple[@"points"]=part;[selected addObject:simple];
 }
 for(NSDictionary *item in items){
  NSArray *part=Simplify(item[@"points"]);if(part.count<2)continue;
  if(selected.count>=TNR_MAX_PATHS||points+part.count>TNR_MAX_POINTS||16+8*(selected.count+1)+4*(points+part.count)+40*TNR_MAX_LABELS+12>TNR_MAX_BYTES-32)continue;
  points+=part.count;NSMutableDictionary *simple=[item mutableCopy];simple[@"points"]=part;[selected addObject:simple];
 }
 [selected sortUsingComparator:^NSComparisonResult(id a,id b){if([a[@"style"] intValue]==6||[b[@"style"] intValue]==6)return [a[@"style"] intValue]==[b[@"style"] intValue]?NSOrderedSame:[a[@"style"] intValue]==6?NSOrderedDescending:NSOrderedAscending;return [a[@"layer"] compare:b[@"layer"]];}];
 if(!selected.count||!points||_generation==UINT32_MAX)return nil;NSMutableData *out=[NSMutableData dataWithLength:16+8*selected.count+4*points];uint8_t *b=out.mutableBytes;W32(b,++_generation);W16(b+4,range);W16(b+6,(unsigned)selected.count);W16(b+8,(unsigned)points);NSUInteger at=16+8*selected.count;
 for(NSUInteger i=0;i<selected.count;i++){NSDictionary *r=selected[i];NSArray *part=r[@"points"];W16(b+16+8*i,(unsigned)part.count);b[18+8*i]=[r[@"style"] intValue];b[19+8*i]=[r[@"flags"] intValue];b[20+8*i]=(uint8_t)[r[@"layer"] intValue];for(NSArray *p in part){W16(b+at,[p[0] intValue]);W16(b+at+2,[p[1] intValue]);at+=4;}}
 /* Labels derive only from actual road tags. Keep at most four unique names,
  * with geographic anchors; firmware clips/culls collisions on every pose. */
 NSMutableData *labels=[NSMutableData new];NSMutableSet *seen=[NSMutableSet new];NSMutableArray *occupied=[NSMutableArray new];
 _labelRange=range;
 double radians=_labelHeading*M_PI/180,ss=sin(radians),cc=cos(radians);NSMutableArray *routeParts=[NSMutableArray new];
 for(NSDictionary *item in selected)if([item[@"style"] intValue]==6)[routeParts addObject:item[@"points"]];
 for(NSDictionary *item in [selected sortedArrayUsingComparator:^NSComparisonResult(id a,id b){return [a[@"rank"] compare:b[@"rank"]];}]){
  NSData *name=NameData(item[@"name"]);if(!name.length||[seen containsObject:name])continue;
  unsigned width=0;NSString *text=[[NSString alloc]initWithData:name encoding:NSUTF8StringEncoding];for(NSUInteger j=0;j<text.length;j++)width+=[text characterAtIndex:j]<128?9:16;
  NSArray *part=item[@"points"],*anchor=nil,*screenRect=nil;double best=DBL_MAX;
  for(NSUInteger j=1;j<part.count;j++)for(unsigned step=0;step<=16;step++){
   double t=step/16.,x=[part[j-1][0] doubleValue]*(1-t)+[part[j][0] doubleValue]*t,y=[part[j-1][1] doubleValue]*(1-t)+[part[j][1] doubleValue]*t;
   double px=148+(x*cc-y*ss)*296/((double)range*4),py=103-(x*ss+y*cc)*296/((double)range*4);double left=px-width/2.,top=py-10; /* mirror of the firmware 296x148 canvas at this scene's range */
   if(left<7||left+width>289||top<7||top+20>141||(left<167&&left+width>129&&top<118&&top+20>79)||(left<76&&left+width>0&&top<147&&top+20>112))continue;
   if(RLabelRoute(routeParts,left-3,top-2,left+width+3,top+21,ss,cc,range))continue;
   BOOL collision=NO;for(NSArray *r in occupied){double rx=[r[0] doubleValue],ry=[r[1] doubleValue],rw=[r[2] doubleValue];if(left<rx+rw+8&&left+width+8>rx&&top<ry+28&&top+28>ry){collision=YES;break;}}if(collision)continue;
   double score=(px-96)*(px-96)+(py-48)*(py-48);if(score<best){best=score;anchor=@[@((int)lround(x)),@((int)lround(y))];screenRect=@[@(left),@(top),@(width)];}
  }
  if(!anchor)continue;uint8_t q[40]={0};W16(q,[anchor[0] intValue]);W16(q+2,[anchor[1] intValue]);q[4]=(uint8_t)name.length;memcpy(q+8,name.bytes,name.length);[labels appendBytes:q length:40];[seen addObject:name];[occupied addObject:screenRect];if(seen.count>=TNR_MAX_LABELS)break;
 }
 NSMutableData *v2=[out mutableCopy];[v2 appendData:labels];uint8_t pose[12]={0};W32(pose,_generation);[v2 appendBytes:pose length:12];W16((uint8_t *)v2.mutableBytes+10,(unsigned)seen.count);_scene2=tnr_body_valid(TNR_SCENE2,v2.bytes,v2.length)?v2:nil;
 return tnr_body_valid(TNR_SCENE,out.bytes,out.length)?out:nil;
}
- (NSDictionary *)decorate:(NSDictionary *)frame coordinates:(NSArray *)coords{
 /* NavigationUI.drawRoute() hands over the whole AMap route (strided to <=4096
  * points); scene: clips it to the +/-500 m render window with Pieces() and
  * budgets the highlighted path there. Rejecting >512 whole-route points here
  * used to skip every real route, leaving the lens on the START sketch. */
 if(!self.enabled||![frame[@"phase"] isEqual:@"navigating"]||![coords isKindOfClass:NSArray.class]||coords.count<2||coords.count>4096||!LL(frame[@"tnrLocation"])||!N(frame[@"tnrLocationAt"],0,DBL_MAX)||NSProcessInfo.processInfo.systemUptime-[frame[@"tnrLocationAt"] doubleValue]>4)return frame;
 NSArray *position=frame[@"tnrLocation"];NSArray *wgs=[self wgs:position];if(!LL(wgs)){_note=@"坐标转换未收敛 · 不显示错位路网";return frame;}
 BOOL covered=[self covers:wgs];
 if(!covered)covered=[self loadPack:wgs];   /* 已下载省份：纯离线，优先级最高 */
 if(!covered)covered=[self loadCache:wgs];  /* Overpass 结果的有界磁盘缓存 */
 if(!covered)covered=[self loadFixture:wgs];
 if(!covered)[self autoProvidePackFor:wgs]; /* 无覆盖时自动下载当前省包（用户要求路网强制开启） */
 // Prefetch before the rendered viewport reaches an edge. Do not clear the old
 // region while a new request is queued, rate-limited, fails, or is parsing.
 // 已有省份包覆盖时不再向 Overpass 发请求（省流量也省图源限额）。
 if(![self hasCoverage:wgs margin:300]&&![[TIORoadPackManager shared] coversLat:[wgs[0] doubleValue] lon:[wgs[1] doubleValue]])[self request:wgs];
 /* 用户可见的“为什么没路网”只有四种可执行原因；文案必须能区分，否则用户
  * 只会看到“暂缺”而不知道该开授权、下省包还是换网络。 */
 if(covered)_note=_task?@"周边路网已显示 · 正在预取下一段":@"周边路网已就绪 · © OpenStreetMap";
 else if(_task)_note=@"正在加载周边道路 · 保留已知路网";
 else if(_requests>=6)_note=@"本次会话联网取路网已达 6 次上限 · 仅显示已有道路（重新进入导航可重置）";
 else if(!self.allowNetwork){
  NSUInteger packs=[[TIORoadPackManager shared] downloadedCount];
  _note=packs?@"未授权联网取路网，且已下载省级包/离线缓存未覆盖当前点 · 仅显示已知道路"
   :@"未授权联网取路网，且尚未下载任何省级路网包 · 仅显示路线示意图（可先在“省际路网包”下载）";
 }else if(_sourceFailed)_note=[NSString stringWithFormat:@"图源不可用（%@）· 已试 %lu 个公开镜像 · 不伪造道路，保留路线示意图",_sourceReason?:@"网络或服务失败",(unsigned long)OverpassMirrors().count];
 else if(![[TIORoadPackManager shared] downloadedCount])_note=@"无省级路网包，联网图源暂未返回可用数据 · 可先在“省际路网包”逐个下载";
 else _note=@"已下载省级包与离线缓存均未覆盖当前点 · 仅显示已知道路";
 double now=NSProcessInfo.processInfo.systemUptime,heading=[frame[@"navHeading"] doubleValue],turn=fabs(fmod(heading-_labelHeading+540,360)-180);
 /* Adaptive zoom (2026-10-28 真机反馈): near an upcoming turn the map zooms
  * in for junction detail; on long straights it zooms out for context. Base
  * window follows the travel mode (walk small / ride medium / drive large).
  * ±60 m hysteresis stops flapping at a boundary. */
 NSString *travel=frame[@"travel"];
 unsigned range=[travel isEqual:@"walk"]?260:[travel isEqual:@"ride"]?400:520;
 double turnM=[frame[@"meters"] doubleValue];
 if(turnM>0){if(turnM<=120)range=range*6/10;else if(turnM<=250)range=range*8/10;else if(turnM>=600)range=range*13/10;}
 if(range<180)range=180;if(range>700)range=700;
 BOOL zoom=_sceneRange&&(range>_sceneRange+60||_sceneRange>range+60);
 /* 无名路段区域 label 数恒为 0：不要因此每 3 秒重建整张 scene（长路线 + 8000
  * 路段时这就是周期性卡顿）。只有确实存在 label 时才因不可见而重排。 */
 const uint8_t *s2=_scene2.length>=16?(const uint8_t *)_scene2.bytes:NULL;
 BOOL haveLabels=s2&&((unsigned)s2[10]+((unsigned)s2[11]<<8))>0;
 BOOL refreshNames=_features.count&&now-_sceneAt>=3&&(turn>=30||Distance(position,_origin?:position)>50||(haveLabels&&![self hasVisibleLabelsAt:position heading:(unsigned)heading]));
 if(!_scene||!_origin||Distance(position,_origin)>100||![_segment isEqual:frame[@"segment"]]||zoom||refreshNames){
  _origin=position;_segment=frame[@"segment"];_labelHeading=heading;_sceneAt=now;_sceneRange=range;_scene=[self scene:coords origin:_origin range:range];
  if(_scene)_sceneMin=[self minimalSceneForCoords:coords origin:_origin range:range generation:_generation];
  else{uint32_t gen=_generation+1;_sceneMin=[self minimalSceneForCoords:coords origin:_origin range:range generation:gen];
   if(_sceneMin){_generation=gen;_scene=_sceneMin;_note=@"完整矢量场景未通过校验收回，已降级为路线矢量图";}}
 }
 if(!_scene)return frame;NSArray *xy=XY(position,_origin);double x=[xy[0] doubleValue]*4,y=[xy[1] doubleValue]*4;if(fabs(x)>2000||fabs(y)>2000)return frame;
 uint8_t pose[12]={0};W32(pose,_generation);W16(pose+4,(int)lround(x));W16(pose+6,(int)lround(y));W16(pose+8,[frame[@"navHeading"] unsignedIntValue]%360);
 NSMutableDictionary *out=[frame mutableCopy];out[@"tnrScene"]=_scene;if(_scene2)out[@"tnrScene2"]=_scene2;if(_sceneMin)out[@"tnrSceneMin"]=_sceneMin;out[@"tnrPose"]=[NSData dataWithBytes:pose length:12];out[@"tnrPoseAt"]=frame[@"tnrLocationAt"];return out;
}
@end
