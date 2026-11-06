#import "NativeNavigation.h"
#include "nav_map.h"
#include <math.h>
static uint32_t U32(const uint8_t *p){return p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static unsigned U16(const uint8_t *p){return (unsigned)p[0]|((unsigned)p[1]<<8);}
static BOOL Var(const uint8_t *p,NSUInteger n,NSUInteger *at,uint32_t *v){*v=0;for(unsigned i=0;i<5;i++){if(*at>=n)return NO;uint8_t b=p[(*at)++];if(i==4&&(b&240))return NO;*v|=(uint32_t)(b&127)<<(i*7);if(!(b&128))return YES;}return NO;}
// capabilities bit0 = the firmware speaks TNR vector-map packets (TN_QUERY
// reply carries it at b+24; older firmware zeroes the field).
static BOOL DecodeReply(NSDictionary *event,TNReply *out,uint32_t *capabilities){
 if(![event isKindOfClass:NSDictionary.class]||![event[@"eventType"] isEqual:@"messageReceived"])return NO;
 NSDictionary *m=event[@"message"];if(![m isKindOfClass:NSDictionary.class]||![m[@"businessId"] isEqual:@15]||![m[@"payload"] isKindOfClass:NSData.class])return NO;
 NSData *d=m[@"payload"];if(d.length>512)return NO;const uint8_t *p=d.bytes;NSUInteger at=0;uint32_t version=0,type=0;NSData *json=nil;unsigned seen=0;
 while(at<d.length){uint32_t k,v;if(!Var(p,d.length,&at,&k)||k>>3>6||k>>3==0||(seen&(1u<<(k>>3))))return NO;seen|=1u<<(k>>3);
  if((k&7)==0){if(!Var(p,d.length,&at,&v))return NO;if(k>>3==1)version=v;else if(k>>3==2)type=v;}
  else if((k&7)==2){if(!Var(p,d.length,&at,&v)||v>d.length-at)return NO;if(k>>3==3)json=[d subdataWithRange:NSMakeRange(at,v)];at+=v;}else return NO;
 }
 if(version!=1||type!=6||!json)return NO;id j=[NSJSONSerialization JSONObjectWithData:json options:0 error:nil];if(![j isKindOfClass:NSDictionary.class]||![j[@"cmd"] isEqual:@"turbo_nav_v1"]||![j[@"payload"] isKindOfClass:NSDictionary.class])return NO;
 NSString *hex=j[@"payload"][@"data"];if(![hex isKindOfClass:NSString.class]||hex.length!=64)return NO;uint8_t b[32];
 for(unsigned i=0;i<32;i++){unsigned v=0;for(unsigned k=0;k<2;k++){unichar c=[hex characterAtIndex:2*i+k];unsigned x=c>='0'&&c<='9'?c-'0':c>='a'&&c<='f'?c-'a'+10:16;if(x>15)return NO;v=v*16+x;}b[i]=v;}
 if(memcmp(b,"TNA1",4)||b[4]!=1||b[5]>TN_NO_SESSION||(b[6]&~7)||b[7]>1||U32(b+16)!=60000||U32(b+20)!=32||(U32(b+24)&~1u)||tn_crc(b,28)!=U32(b+28))return NO;
 if(capabilities)*capabilities=U32(b+24);
 if(out)*out=(TNReply){.result=b[5],.sid=U32(b+8),.sequence=U32(b+12),.active=!!(b[6]&1),.awake=!!(b[6]&2),.stale=!!(b[6]&4),.mode=b[7]};return YES;
}
BOOL TNVDecodeReply(NSDictionary *event,TNReply *out){return DecodeReply(event,out,NULL);}
static void Clip(char *out,NSUInteger cap,id value){
 if(![value isKindOfClass:NSString.class])return;NSMutableString *s=[NSMutableString new];
 [value enumerateSubstringsInRange:NSMakeRange(0,[value length]) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *c,NSRange r,NSRange all,BOOL *stop){
  if([c rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)return;
  if([s lengthOfBytesUsingEncoding:NSUTF8StringEncoding]+[c lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>=cap){*stop=YES;return;}[s appendString:c];}];
 NSData *d=[s dataUsingEncoding:NSUTF8StringEncoding];memcpy(out,d.bytes,d.length);
}
static BOOL Number(id v,double max){return [v isKindOfClass:NSNumber.class]&&isfinite([v doubleValue])&&[v doubleValue]>=0&&[v doubleValue]<=max;}
NSDictionary *TNVNormalizeCoordinates(NSArray *coords){
 if(![coords isKindOfClass:NSArray.class]||coords.count<2||coords.count>512)return @{};
 double xs[512],ys[512],loX=DBL_MAX,loY=DBL_MAX,hiX=-DBL_MAX,hiY=-DBL_MAX;
 for(NSUInteger i=0;i<coords.count;i++){id p=coords[i];if(![p isKindOfClass:NSArray.class]||[p count]!=2||![p[0] isKindOfClass:NSNumber.class]||![p[1] isKindOfClass:NSNumber.class])return @{};
  double lat=[p[0] doubleValue],lon=[p[1] doubleValue];if(!isfinite(lat)||!isfinite(lon)||fabs(lat)>85||fabs(lon)>180)return @{};
  double ref=[coords[0][0] doubleValue];xs[i]=(lon-[coords[0][1] doubleValue])*cos(ref*M_PI/180);ys[i]=-(lat-ref);loX=MIN(loX,xs[i]);hiX=MAX(hiX,xs[i]);loY=MIN(loY,ys[i]);hiY=MAX(hiY,ys[i]);
 }
 // Heading-up mini-map: rotate every point around the current position by the
 // travel bearing so the user's direction always points UP on the lens, no
 // matter how the firmware interprets the heading field (north-up renderer
 // gets an already-rotated frame).
 double h=0;
 if(coords.count>=2){h=atan2(xs[1]-xs[0],-(ys[1]-ys[0]));if(h<0)h+=2*M_PI;}
 double ch=cos(-h),sh=sin(-h);
 loX=loY=DBL_MAX;hiX=hiY=-DBL_MAX; // recompute bounds on the rotated frame
 for(NSUInteger i=0;i<coords.count;i++){double rx=xs[i]*ch-ys[i]*sh,ry=xs[i]*sh+ys[i]*ch;xs[i]=rx;ys[i]=ry;loX=MIN(loX,xs[i]);hiX=MAX(hiX,xs[i]);loY=MIN(loY,ys[i]);hiY=MAX(hiY,ys[i]);}
 double span=MAX(hiX-loX,hiY-loY);if(span<1e-10)return @{};NSMutableArray *out=[NSMutableArray new];NSUInteger count=MIN(coords.count,32);
 // Perspective sampling: the 32-point protocol budget goes where detail pays
 // off -- dense near the user (exact shape of the next turns), sparse far away
 // (still visible). t^2.2 concentrates half the points in the first ~20% of
 // the covered distance; uniform sampling wasted the budget far away.
 double arc[512];arc[0]=0;for(NSUInteger i=1;i<coords.count;i++)arc[i]=arc[i-1]+hypot(xs[i]-xs[i-1],ys[i]-ys[i-1]);
 double total=arc[coords.count-1];NSUInteger cursor=0;
 for(NSUInteger i=0;i<count;i++){double t=count>1?(double)i/(count-1):0;double target=total*pow(t,2.2);
  while(cursor+1<coords.count&&arc[cursor+1]<target)cursor++;
  double x=511.5+(xs[cursor]-(loX+hiX)*.5)*900/span,y=511.5+(ys[cursor]-(loY+hiY)*.5)*900/span;[out addObject:@[@((unsigned)lround(x)),@((unsigned)lround(y))]];}
 return @{@"navPoints":out,@"navHeading":@((unsigned)lround(h*180/M_PI)%360)};
}
BOOL TNVScene(NSDictionary *d,BOOL always,TNScene *s){
 if(!s||![d isKindOfClass:NSDictionary.class]||![d[@"phase"] isEqual:@"navigating"]||!Number(d[@"meters"],1000000)||!Number(d[@"remainingMeters"],10000000)||!Number(d[@"remainingSeconds"],604800)||!Number(d[@"icon"],255))return NO;
 memset(s,0,sizeof *s);s->lights=255;s->camera_limit=-1;s->camera_m=65535;s->event_m=65535;s->lights_m=65535;s->speed_kmh=65535;s->road_limit=255; /* absent extension data must not encode as real zeros */NSInteger i=[d[@"icon"] integerValue];switch(i){case 2:s->icon=TN_LEFT;break;case 3:s->icon=TN_RIGHT;break;case 4:s->icon=TN_SLIGHT_LEFT;break;case 5:s->icon=TN_SLIGHT_RIGHT;break;case 6:s->icon=TN_SHARP_LEFT;break;case 7:s->icon=TN_SHARP_RIGHT;break;case 8:case 19:s->icon=TN_UTURN;break;case 9:case 20:s->icon=TN_STRAIGHT;break;case 11:case 12:case 17:case 18:s->icon=TN_ROUNDABOUT;break;case 13:s->icon=TN_SERVICE;break;case 14:s->icon=TN_TOLL;break;case 16:s->icon=TN_TUNNEL;break;case 15:s->icon=TN_ARRIVE;break;default:s->icon=TN_UNKNOWN;}
 s->mode=always?TN_ALWAYS:TN_SMART;s->distance_m=[d[@"meters"] unsignedIntValue];s->remaining_m=[d[@"remainingMeters"] unsignedIntValue];s->remaining_s=[d[@"remainingSeconds"] unsignedIntValue];Clip(s->road,sizeof s->road,d[@"road"]);Clip(s->turn,sizeof s->turn,d[@"turn"]);
 NSArray *points=d[@"navPoints"];if(points){if(![points isKindOfClass:NSArray.class]||points.count>32)return NO;for(id pair in points){if(![pair isKindOfClass:NSArray.class]||[pair count]!=2||!Number(pair[0],1023)||!Number(pair[1],1023))return NO;s->points[s->point_count++]=(TNPoint){[pair[0] unsignedIntValue],[pair[1] unsignedIntValue]};}}
 if(s->point_count)s->position=s->points[0];if(Number(d[@"navHeading"],359))s->heading=[d[@"navHeading"] unsignedIntValue];
 /* Extension fields default to documented unknowns; malformed values reject
  * the frame, which the session treats as transient and keeps rendering. */
 s->lights=255;s->camera_limit=-1;s->camera_m=65535;s->event_m=65535;s->lights_m=65535;s->road_limit=255;
 id lights=d[@"lights"];if(lights){if(![lights isKindOfClass:NSNumber.class])return NO;long v=[lights longValue];if(v<0||v>255)v=255;s->lights=(uint8_t)v;} /* clamp: an SDK unknown must never reject the whole turn frame */
 id lm=d[@"lightsMeters"];if(lm){if(![lm isKindOfClass:NSNumber.class])return NO;long v=[lm longValue];if(v<0||v>65534)return NO;s->lights_m=(uint16_t)v;}
 id sp=d[@"speedKmh"];if(sp){if(![sp isKindOfClass:NSNumber.class])return NO;long v=[sp longValue];if(v<0||v>511)return NO;s->speed_kmh=(uint16_t)v;}
 id ll=d[@"lightsList"];if(ll){if(![ll isKindOfClass:NSArray.class]||[ll count]>8)return NO;unsigned n=0;for(id m in ll){if(![m isKindOfClass:NSNumber.class])return NO;long v=[m longValue];if(v<0||v>65534)return NO;s->light_m[n++]=(uint16_t)v;}s->light_count=(uint8_t)n;}
 id rl=d[@"roadLimit"];if(rl){if(![rl isKindOfClass:NSNumber.class])return NO;long v=[rl longValue];if(v<0||v>200)return NO;s->road_limit=(uint8_t)v;} /* 0 = 高德回报本段无限速；255 = 未上报 */
 id cl=d[@"camList"];if(cl){if(![cl isKindOfClass:NSArray.class]||[cl count]>TN_CAM_MAX)return NO;unsigned n=0; /* 沿路电子眼全量（近→远），替代单槽标记 */
  for(id e in cl){if(![e isKindOfClass:NSDictionary.class])return NO;id k=e[@"kind"],lim=e[@"limit"],m=e[@"m"];
   if(![k isKindOfClass:NSNumber.class]||[k longValue]<1||[k longValue]>TN_CAMERA_OTHER)return NO;
   if(lim){if(![lim isKindOfClass:NSNumber.class])return NO;long v=[lim longValue];if(v<0||v>200)return NO;}
   if(m){if(![m isKindOfClass:NSNumber.class])return NO;long v=[m longValue];if(v<0||v>65534)return NO;}
   s->cam_kind[n]=(uint8_t)[k longValue];s->cam_limit[n]=(uint8_t)(lim?[lim longValue]:0);s->cam_m[n]=(uint16_t)(m?[m longValue]:65535);n++;}
  s->cam_count=(uint8_t)n;}
 id fl=d[@"facList"];if(fl){if(![fl isKindOfClass:NSArray.class]||[fl count]>TN_FAC_MAX)return NO;unsigned n=0; /* 特殊设施全量（近→远）：服务区/收费站/检查站/隧道/渡口/警示… */
  for(id e in fl){if(![e isKindOfClass:NSDictionary.class])return NO;id k=e[@"kind"],m=e[@"m"];
   if(![k isKindOfClass:NSNumber.class]||[k longValue]<1||[k longValue]>12)return NO;
   if(m){if(![m isKindOfClass:NSNumber.class])return NO;long v=[m longValue];if(v<0||v>65534)return NO;}
   s->fac_kind[n]=(uint8_t)[k longValue];s->fac_m[n]=(uint16_t)(m?[m longValue]:65535);n++;}
  s->fac_count=(uint8_t)n;}
 id bar=d[@"barLevels"];if(bar){if(![bar isKindOfClass:NSArray.class]||[bar count]>TN_BAR_MAX)return NO;
  unsigned n=0;for(id level in bar){if(![level isKindOfClass:NSNumber.class])return NO;long x=[level longValue];if(x<0||x>4)return NO;s->bar[n++]=(uint8_t)x;}s->bar_count=(uint8_t)n;}
 id cam=d[@"camera"];if(cam){if(![cam isKindOfClass:NSDictionary.class])return NO;id k=cam[@"kind"];id lim=cam[@"limit"];id mtr=cam[@"m"];
  if(![k isKindOfClass:NSNumber.class]||[k longValue]<1||[k longValue]>TN_CAMERA_OTHER)return NO;s->camera_kind=(uint8_t)[k longValue];
  if(lim){if(![lim isKindOfClass:NSNumber.class])return NO;long v=[lim longValue];if(v!=-1&&(v<0||v>500))return NO;s->camera_limit=(int16_t)v;}
  if(mtr){if(![mtr isKindOfClass:NSNumber.class])return NO;long v=[mtr longValue];if(v<0||v>65534)return NO;s->camera_m=(uint16_t)v;}}
 id ev=d[@"event"];if(ev){if(![ev isKindOfClass:NSDictionary.class])return NO;id k=ev[@"kind"];id mtr=ev[@"m"];
  if(![k isKindOfClass:NSNumber.class]||[k longValue]<1||[k longValue]>TN_EVENT_CONTROL)return NO;s->event_kind=(uint8_t)[k longValue];
  if(mtr){if(![mtr isKindOfClass:NSNumber.class])return NO;long v=[mtr longValue];if(v<0||v>65534)return NO;s->event_m=(uint16_t)v;}}
 return YES;
}
@implementation TNVSession{
 NSString *_device,*_task,*_nativeTask,*_note;uint32_t _sid,_seq;NSTimeInterval(^_clock)(void);void(^_sender)(NSData *,NSString *,TNVSubmitted);void(^_cleanup)(NSString *);
 NSData *_packet,*_latest,*_committed,*_sending;NSMutableArray *_early;BOOL _active,_fileBusy,_ack,_submitted,_failed,_stopping,_stopped,_always;
 NSData *_mapLatest,*_map2Latest,*_mapCommitted,*_mapSending,*_mapMin,*_poseLatest,*_poseCommitted;NSTimeInterval _poseAt,_lastPose;NSUInteger _maps,_poses;BOOL _extended,_probed,_mapV2,_minSent;NSString *_mapReason;
 NSString *_source;NSUInteger _wireBytes;
 NSTimeInterval _deadline,_lastOffer,_lastCommit,_lastWire,_next;NSUInteger _count;unsigned _op;
 unsigned _dbgSpeed,_dbgLimit,_dbgCam;BOOL _dbgSim; /* 诊断：最后一帧上镜值（65535=缺省） */
 /* 2026-11-01: transient recovery. A single TN_BUSY/TN_UI_FAILED used to kill the
  * whole session while the lens kept its last frame and the firmware kept the
  * session active -- later STARTs were answered TN_BUSY forever (frozen lens).
  * Now the same packet (same sequence) is retried; vector-map frames are
  * best-effort and can never take the navigation session down; the terminal
  * TN_STOP is retried until the lens confirms or the bounded budget runs out. */
 NSData *_retryPacket,*_retryScene;unsigned _retryOp;NSTimeInterval _retryAt;
 NSUInteger _tries,_stopTries,_acks,_transients,_mapSends,_mapDrops;
 NSTimeInterval _stopNext;NSString *_lastEvent;
}
- (instancetype)initWithDevice:(NSString *)device session:(uint32_t)sid clock:(NSTimeInterval(^)(void))clock sender:(void(^)(NSData *,NSString *,TNVSubmitted))sender cleanup:(void(^)(NSString *))cleanup{if(!device.length||!sid||!clock||!sender)return nil;if((self=[super init])){_device=[device copy];_sid=sid;_clock=[clock copy];_sender=[sender copy];_cleanup=[cleanup copy];_note=@"尚未开始";}return self;}
- (BOOL)active{return _active;}- (BOOL)busy{return _packet||_fileBusy;}
- (NSDictionary *)status{return @{@"active":@(_active),@"busy":@(self.busy),@"note":_note?:@"",@"snapshots":@(_count),@"session":@(_sid),@"sequence":@(_seq),@"always":@(_always),@"failed":@(_failed),@"maps":@(_maps),@"poses":@(_poses),@"mapBytes":@(_mapV2?_map2Latest.length:_mapLatest.length),@"mapPaths":@(_mapLatest.length>=16?U16((const uint8_t *)_mapLatest.bytes+6):0),@"mapLabels":@(_map2Latest.length>=16?U16((const uint8_t *)_map2Latest.bytes+10):0),@"mapMode":@(_extended),@"roadLabels":@(_mapV2),@"source":_source?:@"unknown",@"wireBytes":@(_wireBytes),@"acks":@(_acks),@"transients":@(_transients),@"mapSends":@(_mapSends),@"mapDrops":@(_mapDrops),@"mapMin":@(_mapMin!=nil),@"minSent":@(_minSent),@"mapReason":_mapReason?:@"",@"tries":@(_tries),@"stopTries":@(_stopTries),@"stopped":@(_stopped),@"lastEvent":_lastEvent?:@"",@"dbgSpeed":@(_dbgSpeed),@"dbgLimit":@(_dbgLimit),@"dbgCam":@(_dbgCam),@"dbgSim":@(_dbgSim)};}
// Breadcrumb kept in the status JSON so a frozen lens has a readable cause.
- (void)note:(NSString *)text{_note=text;_lastEvent=[NSString stringWithFormat:@"%.0f %@",_clock(),text?:@""];}
// Drop the current in-flight file bookkeeping. Ownership of an uncertain native
// transfer stays with the transport; unlatching busy lets a fresh retry go out.
- (void)clearWire{NSString *task=_task;_packet=nil;_task=nil;_nativeTask=nil;_early=nil;_sending=nil;_fileBusy=NO;_ack=_submitted=NO;if(task&&_cleanup)_cleanup(task);}
- (void)fail:(NSString *)note{_active=NO;_failed=YES;_stopping=NO;_retryPacket=nil;_retryScene=nil;_tries=0;[self clearWire];[self note:note];}
- (void)finish{if(!_packet||!_ack||_fileBusy||!_submitted)return;unsigned op=_op;NSData *sent=_sending;NSString *task=_task;_packet=nil;_nativeTask=nil;_early=nil;_sending=nil;_retryPacket=nil;_retryScene=nil;if(_cleanup)_cleanup(task);_task=nil;_tries=0;_next=_clock()+(_extended?0:1);
 if(op==TN_START||op==TN_UPDATE){_committed=sent;_lastCommit=_clock();_count++;}
 if(op==TNR_SCENE){_mapCommitted=sent;_poseCommitted=nil;_maps++;}
 if(op==TNR_SCENE2){_mapCommitted=_mapSending?:sent;_mapSending=nil;_poseCommitted=[sent subdataWithRange:NSMakeRange(sent.length-12,12)];_lastPose=_clock();_maps++;_poses++;}
 if(op==TN_QUERY)_probed=YES;
 if(op==TNR_POSE){_poseCommitted=sent;_lastPose=_clock();_poses++;}
 if(op==TNR_CLEAR){_mapCommitted=nil;_poseCommitted=nil;}
 if(op==TN_STOP){_active=NO;_stopping=NO;_stopped=YES;[self note:@"眼镜已确认退出导航"];return;}
 [self note:@"原生导航已提交 · 镜片效果待确认"];
}
// Reply/submit failures that must not kill navigation: BUSY (another task owns
// the lens), UI_FAILED (renderer was busy for one frame) and any vector-map
// rejection. Retry the identical packet/sequence after a short pause; vector
// map frames are simply dropped because the text HUD keeps working without them.
- (void)transient:(NSString *)reason code:(unsigned)code{
 unsigned op=_op;NSData *packet=_packet;NSData *scene=_sending;
 if(op==TN_STOP){[self clearWire];_stopTries++;_stopNext=_clock()+2.0;if(_stopTries>=10){_stopped=YES;_stopping=NO;[self note:@"多次补发退出指令未获确认；请用眼镜返回键退出"];}else [self note:[NSString stringWithFormat:@"退出指令未确认（%@），稍后重试 %lu/10",reason,(unsigned long)_stopTries]];return;}
 [self clearWire];
 if(op>=TNR_SCENE){_mapDrops++;[self note:[NSString stringWithFormat:@"镜片未接受矢量图（%@，码 %u），导航继续",reason,code]];_next=_clock()+0.5;return;}
 _transients++;
 if(_tries>=4){[self fail:[NSString stringWithFormat:@"眼镜连续拒绝导航包（码 %u）；本轮停止，等待自动恢复",code]];return;}
 _tries++;_retryPacket=packet;_retryScene=scene;_retryOp=op;_retryAt=_clock()+0.4;
 [self note:[NSString stringWithFormat:@"眼镜暂忙（码 %u），第 %lu 次重试同一包",code,(unsigned long)_tries]];
}

- (BOOL)send:(enum TNOp)op scene:(NSData *)scene{
 if(self.busy||_failed||_seq==UINT32_MAX)return NO;_retryPacket=nil;_retryScene=nil;_tries=0;uint8_t b[TNR_MAX_BYTES];size_t n=op>=TNR_SCENE?tnr_wrap(b,sizeof b,op,_sid,++_seq,scene.bytes,scene.length):tn_encode(b,sizeof b,op,_sid,++_seq,scene?(const TNScene *)scene.bytes:NULL);if(!n){if(op>=TNR_SCENE)_mapDrops++;return NO;}
 if(op>=TNR_SCENE)_mapSends++;
 _packet=[NSData dataWithBytes:b length:n];_wireBytes+=n;_task=NSUUID.UUID.UUIDString;_nativeTask=nil;_early=[NSMutableArray new];_ack=_submitted=NO;_fileBusy=YES;_op=op;_sending=scene;_lastWire=_clock();_deadline=_lastWire+(op==TNR_POSE?3:8);NSString *task=_task;
 __weak typeof(self) weak=self;_sender(_packet,task,^(BOOL ok,NSString *native){TNVSession *s=weak;if(!s||![task isEqual:s->_task])return;
  if(!ok||![native isKindOfClass:NSString.class]||!native.length||native.length>256){s->_fileBusy=NO;[s transient:@"文件提交失败" code:0];return;}
  s->_submitted=YES;s->_nativeTask=[native copy];NSArray *early=[s->_early copy];s->_early=nil;for(NSDictionary *e in early)[s consume:e];[s finish];});return YES;
}
- (void)mapOffer:(NSDictionary *)frame{
 // Transient frames (planning/reroute) carry no tnr keys by design; keep the
 // last committed map instead of tearing it down on every reroute blip.
 if(![frame isKindOfClass:NSDictionary.class]||![frame[@"phase"] isEqual:@"navigating"])return;
 NSData *map=frame[@"tnrScene"],*pose=frame[@"tnrPose"];id at=frame[@"tnrPoseAt"];
 BOOL valid=[map isKindOfClass:NSData.class]&&[pose isKindOfClass:NSData.class]&&[at isKindOfClass:NSNumber.class]&&isfinite([at doubleValue])&&[at doubleValue]<=_clock()&&_clock()-[at doubleValue]<=4&&tnr_body_valid(TNR_SCENE,map.bytes,map.length)&&tnr_body_valid(TNR_POSE,pose.bytes,pose.length)&&U32(map.bytes)==U32(pose.bytes);
 if(!valid){/* tnrHold=矢量图暂缺（定位暂缺/图源未就绪）：保留最后一张图，避免每个
  * 静止间隙都发 TNR_CLEAR 把镜片上的路网清掉；只有路网开关关闭（无 hold 标记）
  * 才走清屏。 */if([frame[@"tnrHold"] isEqual:@YES])return;_mapReason=!map?@"无场景数据":!pose?@"无姿态数据":!at?@"无姿态时间":([at doubleValue]>_clock()?@"姿态时间超前":(_clock()-[at doubleValue]>4?@"姿态过期":@"本机场景校验失败"));_mapLatest=nil;_map2Latest=nil;_poseLatest=nil;return;}
 NSData *v2=frame[@"tnrScene2"];_map2Latest=[v2 isKindOfClass:NSData.class]&&tnr_body_valid(TNR_SCENE2,v2.bytes,v2.length)&&U32(v2.bytes)==U32(map.bytes)?[v2 copy]:nil;
 NSData *min=frame[@"tnrSceneMin"];NSData *minOK=[min isKindOfClass:NSData.class]&&tnr_body_valid(TNR_SCENE,min.bytes,min.length)&&U32(min.bytes)==U32(map.bytes)?[min copy]:nil;
 if(![map isEqual:_mapLatest]||![minOK isEqual:_mapMin])_minSent=NO;
 _mapReason=nil;_mapMin=minOK;_extended=YES;_mapLatest=[map copy];_poseLatest=[pose copy];_poseAt=[at doubleValue];
}
- (BOOL)start:(NSDictionary *)frame always:(BOOL)always{if(_seq||_active||self.busy||_failed)return NO;TNScene s;if(!TNVScene(frame,always,&s))return NO;[self mapOffer:frame];_source=[frame[@"tnrSource"] isKindOfClass:NSString.class]?frame[@"tnrSource"]:@"unknown";_always=always;_latest=[NSData dataWithBytes:&s length:sizeof s];_lastOffer=_clock();_active=YES;_note=@"正在请求自动打开原生导航";if(![self send:TN_START scene:_latest]){_active=NO;return NO;}return YES;}
- (void)offer:(NSDictionary *)frame{if(!_active||_stopping)return;[self mapOffer:frame];TNScene s;if(!TNVScene(frame,_always,&s)){/* Only terminal phases stop the session; transient non-navigating frames (planning/reroute transitions) must not kill a live render. */if([frame[@"phase"] isEqual:@"arrived"]||[frame[@"phase"] isEqual:@"stopped"])[self stop];return;}_dbgSpeed=s.speed_kmh;_dbgLimit=s.road_limit;_dbgCam=s.cam_count;_dbgSim=[frame[@"simulated"] boolValue];_latest=[NSData dataWithBytes:&s length:sizeof s];_lastOffer=_clock();}
- (void)setAlways:(BOOL)always{_always=always;if(_latest){NSMutableData *d=[_latest mutableCopy];((TNScene *)d.mutableBytes)->mode=always?TN_ALWAYS:TN_SMART;_latest=d;}}
// Bounded, confirmed terminal stop. A dead or wedged session still has to remove
// the lens page: the firmware only leaves navigation on TN_STOP, so a lost STOP
// used to leave "导航数据已过期" on the lens forever (真机 2026-10-30/11-01 反馈).
- (void)sendStopOnce{
 if(_stopped||!_sid)return;
 if(self.busy){_stopNext=_clock()+0.3;return;}
 if(_stopTries>=10){_stopped=YES;_stopping=NO;[self note:@"多次补发退出指令未获确认；请用眼镜返回键退出"];return;}
 if(_clock()<_stopNext)return;
 _stopTries++;_retryPacket=nil;_retryScene=nil;
 uint8_t b[TNR_MAX_BYTES];size_t n=tn_encode(b,sizeof b,TN_STOP,_sid,++_seq,NULL);
 if(!n){_stopped=YES;_stopping=NO;[self note:@"退出指令构造失败；请用眼镜返回键退出"];return;}
 NSString *task=NSUUID.UUID.UUIDString;
 _packet=[NSData dataWithBytes:b length:n];_task=task;_nativeTask=nil;_early=[NSMutableArray new];_ack=_submitted=NO;_fileBusy=YES;_op=TN_STOP;_sending=nil;_lastWire=_clock();_deadline=_lastWire+8;
 [self note:[NSString stringWithFormat:@"已补发退出指令（%lu/10），等待眼镜退出",(unsigned long)_stopTries]];
 __weak typeof(self) weak=self;_sender(_packet,task,^(BOOL ok,NSString *native){TNVSession *s=weak;if(!s||![task isEqual:s->_task])return;
  if(!ok){s->_fileBusy=NO;s->_packet=nil;s->_task=nil;s->_stopNext=s->_clock()+2.0;if(s->_stopTries>=10){s->_stopped=YES;s->_stopping=NO;[s note:@"退出指令提交失败；请用眼镜返回键退出"];}else [s note:@"退出指令提交失败，稍后重试"];return;}
  s->_submitted=YES;s->_nativeTask=[native copy];NSArray *early=[s->_early copy];s->_early=nil;for(NSDictionary *e in early)[s consume:e];[s finish];});
}
- (void)stop{
 if(_stopping||_stopped)return;
 if(!_sid){_stopped=YES;[self note:@"尚未建立导航会话，无需退出"];return;}
 _stopping=YES;_stopTries=0;_stopNext=_clock();
 [self note:_active?@"等待在途包结束后退出导航":@"已请求退出眼镜导航"];
 [self pump];
}
- (void)disconnect{[self fail:@"连接中断；已停止。眼镜会在约60秒失联后自动退出导航，请查看手机。"];}
// Re-send the byte-identical packet (same session and sequence) after a transient
// rejection, so the firmware's dedupe/staleness checks stay monotonic.
- (void)resubmit{
 NSData *packet=_retryPacket,*scene=_retryScene;unsigned op=_retryOp;if(!packet)return;
 _retryPacket=nil;_retryScene=nil;
 NSString *task=NSUUID.UUID.UUIDString;_packet=packet;_task=task;_nativeTask=nil;_early=[NSMutableArray new];_ack=_submitted=NO;_fileBusy=YES;_op=op;_sending=scene;_lastWire=_clock();_deadline=_lastWire+(op==TNR_POSE?3:8);
 __weak typeof(self) weak=self;_sender(packet,task,^(BOOL ok,NSString *native){TNVSession *s=weak;if(!s||![task isEqual:s->_task])return;
  if(!ok||![native isKindOfClass:NSString.class]||!native.length||native.length>256){s->_fileBusy=NO;[s transient:@"文件提交失败" code:0];return;}
  s->_submitted=YES;s->_nativeTask=[native copy];NSArray *early=[s->_early copy];s->_early=nil;for(NSDictionary *e in early)[s consume:e];[s finish];});
}
- (void)pump{
 NSTimeInterval now=_clock();
 if(_packet&&now>=_deadline){
  if(_op==TN_STOP)[self transient:@"回执超时" code:0];
  else{if(_op>=TNR_SCENE)_mapDrops++;[self clearWire];_tries=0;_next=now+0.5;[self note:@"导航包回执超时，本轮跳过"];}
  return;
 }
 if(self.busy)return;
 if(_stopping){[self sendStopOnce];return;}
 if(_retryPacket){if(now>=_retryAt)[self resubmit];return;}
 if(!_active||now<_next)return;
 if(_extended&&!_probed){[self send:TN_QUERY scene:nil];return;}
 // One in-flight file, one latest geometry and one latest pose. Never replay old locations.
 if(_extended&&_mapV2&&_mapCommitted&&!_mapLatest){[self send:(enum TNOp)TNR_CLEAR scene:nil];return;}
 BOOL fresh=now-_lastOffer<=15;
 BOOL changed=![_latest isEqual:_committed],urgent=NO;
 if(_latest&&_committed){const TNScene *a=_latest.bytes,*b=_committed.bytes;urgent=a->icon!=b->icon||a->mode!=b->mode||strcmp(a->road,b->road)||strcmp(a->turn,b->turn);}
 if(fresh&&(urgent||now-_lastCommit>=10||(changed&&now-_lastCommit>=1))){[self send:TN_UPDATE scene:_latest];return;}
 if(_extended&&fresh&&_poseLatest&&now-_poseAt<=4&&now>=_poseAt){
  /* 完整场景连续被拒两次后，先发一条只含路线的 SCENE v1（不依赖 SCENE2 caps
     和背景路网），把矢量通道与比例尺/车辆/标记先打通。 */
  if(_mapMin&&_mapDrops>=2&&!_minSent){_minSent=YES;[self send:(enum TNOp)TNR_SCENE scene:_mapMin];return;}
  NSData *map=_mapV2&&_map2Latest?_map2Latest:_mapLatest;
  if(map&&![map isEqual:_mapCommitted]){
   if(_mapV2&&_map2Latest){NSMutableData *combined=[map mutableCopy];uint8_t *p=(uint8_t *)combined.mutableBytes+combined.length-12;memcpy(p,_poseLatest.bytes,12);unsigned age=(unsigned)((now-_poseAt)*1000);p[10]=age;p[11]=age>>8;_mapSending=map;[self send:(enum TNOp)TNR_SCENE2 scene:combined];}
   else [self send:(enum TNOp)TNR_SCENE scene:map];return;
  }
  if(_mapCommitted&&now-_lastPose>=0.2){
   NSMutableData *pose=[_poseLatest mutableCopy];uint8_t *p=pose.mutableBytes;unsigned age=(unsigned)((now-_poseAt)*1000);p[10]=age;p[11]=age>>8;
   if(!_poseCommitted||memcmp(_poseLatest.bytes,_poseCommitted.bytes,10)||now-_lastPose>=1){[self send:(enum TNOp)TNR_POSE scene:pose];return;}
  }
 }
 if(!_extended&&fresh&&changed){[self send:TN_UPDATE scene:_latest];return;}
 if(now-_lastWire>=10)[self send:TN_HEARTBEAT scene:nil];
}
- (BOOL)consume:(NSDictionary *)e{
 if(![e isKindOfClass:NSDictionary.class])return NO;NSString *type=e[@"eventType"];
 if([@[@"fileShareSuccess",@"fileShareFailed"] containsObject:type]){
  NSDictionary *dev=e[@"device"];if(![dev isKindOfClass:NSDictionary.class]||![dev[@"id"] isEqual:_device]||![e[@"role"] isEqual:@"sender"])return NO;
  NSString *tid=e[@"taskId"];if(![tid isKindOfClass:NSString.class]||!tid.length||tid.length>256)return NO;
  if([type isEqual:@"fileShareSuccess"]&&![e[@"fileName"] isEqual:@"turbo-navigation.tnv"])return NO;
  if(!_nativeTask&&_fileBusy){if(_early.count<8)[_early addObject:[e copy]];return NO;}
  if(![tid isEqual:_nativeTask])return NO;_fileBusy=NO;
  if([type isEqual:@"fileShareFailed"]){[self transient:@"导航文件传输失败" code:0];}else [self finish];return YES;
 }
 TNReply q;uint32_t caps=0;if(!DecodeReply(e,&q,&caps))return NO;if(![e[@"message"][@"deviceId"] isEqual:_device])return NO;
 if(!_packet||q.sid!=_sid||q.sequence!=_seq)return YES;
 if(_clock()>=_deadline&&_op!=TN_STOP){[self transient:@"收到迟到回执" code:q.result];return YES;}
 if(_op==TN_STOP){
  if(q.result==TN_OK||q.result==TN_NO_SESSION){_acks++;_active=NO;_stopping=NO;_stopped=YES;_retryPacket=nil;_retryScene=nil;[self clearWire];[self note:q.result==TN_OK?@"眼镜已确认退出导航":@"眼镜已无导航会话（视为已退出）"];}
  else [self transient:[NSString stringWithFormat:@"眼镜未接受退出（码 %u）",q.result] code:q.result];
  return YES;
 }
 if(_op>=TNR_SCENE){
  if(q.result==TN_OK&&q.active){_acks++;_ack=YES;[self finish];return YES;}
  if(q.result==TN_NO_SESSION||q.result==TN_OK){[self fail:[NSString stringWithFormat:@"眼镜导航会话已不存在（码 %u）；本轮结束，等待自动恢复",q.result]];return YES;}
  [self transient:[NSString stringWithFormat:@"镜片未接受矢量图（码 %u）",q.result] code:q.result];return YES;
 }
 if(q.result==TN_STALE){[self clearWire];[self note:@"眼镜回执过期，跳过本帧"];return YES;}
 if(q.result==TN_BUSY||q.result==TN_UI_FAILED){[self transient:[NSString stringWithFormat:@"眼镜暂忙（码 %u）",q.result] code:q.result];return YES;}
 if(q.result!=TN_OK||(_op!=TN_STOP&&!q.active)){[self fail:[NSString stringWithFormat:@"眼镜拒绝导航（%u）；先退出其他任务后重新开启",q.result]];return YES;}
 if(_op==TN_QUERY)_mapV2=!!(caps&1);
 _acks++;_ack=YES;[self finish];return YES;
}

@end
