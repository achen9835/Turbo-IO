#import "RoadMap.h"
#import "NativeNavigation.h"
#include "nav_map.h"
#include <assert.h>
#include <stdio.h>
static NSString *Fixtures;
static BOOL V2;
@interface TestMap:TIORoadMap @end
@implementation TestMap
- (NSString *)fixturePath:(NSString *)name{return [Fixtures stringByAppendingPathComponent:[name stringByAppendingString:@".json"]];}
@end
static uint32_t U32(const uint8_t *p){uint32_t n;memcpy(&n,p,4);return n;}
static NSDictionary *Ack(NSData *packet){const uint8_t *p=packet.bytes;uint8_t raw[32];tn_reply_encode(raw,32,(TNReply){.result=TN_OK,.sid=U32(p+8),.sequence=U32(p+12),.active=p[5]!=TN_STOP,.awake=true});if(V2&&p[5]==TN_QUERY){raw[24]=1;uint32_t crc=tn_crc(raw,28);memcpy(raw+28,&crc,4);}NSMutableString *hex=[NSMutableString new];for(int i=0;i<32;i++)[hex appendFormat:@"%02x",raw[i]];NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"cmd":@"turbo_nav_v1",@"payload":@{@"data":hex}} options:0 error:nil];assert(json.length<128);uint8_t head[]={8,1,16,6,26,(uint8_t)json.length};NSMutableData *pb=[NSMutableData dataWithBytes:head length:6];[pb appendData:json];return @{@"eventType":@"messageReceived",@"message":@{@"businessId":@15,@"deviceId":@"peer",@"payload":pb}};}
static NSDictionary *File(void){return @{@"eventType":@"fileShareSuccess",@"device":@{@"id":@"peer"},@"role":@"sender",@"fileName":@"turbo-navigation.tnv",@"taskId":@"native"};}
static uint32_t TFixWireCRC(uint8_t *p,size_t n){uint32_t c=~0u;for(size_t i=0;i<n;i++){uint8_t b=(i>=20&&i<24)?0:p[i];c^=b;for(unsigned k=0;k<8;k++)c=(c>>1)^((0u-(c&1u))&0xedb88320u);}return ~c;}
int main(int argc,char **argv){@autoreleasepool{
 assert(argc==4);V2=!strcmp(argv[3],"v2");Fixtures=@(argv[1]);NSString *out=@(argv[2]);NSArray *samples=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[Fixtures stringByAppendingPathComponent:@"replay.json"]] options:0 error:nil];assert(samples.count==180);
 TestMap *map=[[TestMap alloc]initWithWGS84ToMap:nil];map.enabled=YES;assert(!map.allowNetwork);
 __block NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;__block NSData *wire;__block unsigned sends=0,cleanups=0;__block TNVSubmitted submitted;static TNRState state;
 TNVSession *session=[[TNVSession alloc]initWithDevice:@"peer" session:123 clock:^{return now;} sender:^(NSData *p,NSString *task,TNVSubmitted done){assert(tn_packet_valid(p.bytes,p.length));assert(p.length<=4096);wire=p;submitted=done;sends++;} cleanup:^(NSString *t){cleanups++;}];
 unsigned maps=0,poses=0,bytes=0,max=0,namesShown=0;NSMutableArray *trace=[NSMutableArray new];
 for(unsigned i=0;i<180;i++){@autoreleasepool{
  NSDictionary *s=samples[i];NSMutableDictionary *frame=[@{@"phase":@"navigating",@"icon":s[@"icon"],@"meters":s[@"meters"],@"remainingMeters":s[@"remaining"],@"remainingSeconds":s[@"seconds"],@"road":s[@"road"],@"turn":@"前方路口",@"segment":s[@"segment"],@"navHeading":@((unsigned)[s[@"heading"] doubleValue]%360),@"tnrLocation":s[@"position"],@"tnrLocationAt":@(NSProcessInfo.processInfo.systemUptime)} mutableCopy];
  [frame addEntriesFromDictionary:TNVNormalizeCoordinates(s[@"route"])];frame=[[map decorate:frame coordinates:s[@"route"]] mutableCopy];assert(frame[@"tnrScene"]&&frame[@"tnrPose"]);frame[@"tnrPoseAt"]=@(now);
  if(!i)assert([session start:frame always:NO]);else [session offer:frame];
  for(unsigned step=0;step<10;step++){
   [session pump];if(wire){NSData *p=wire;wire=nil;const uint8_t *b=p.bytes;[trace addObject:[p base64EncodedStringWithOptions:0]];bytes+=p.length;max=MAX(max,(unsigned)p.length);
    if(b[5]>=7){assert(tnr_receive(&state,b[5],b+32,p.length-32,(uint32_t)(now*1000)));if(b[5]==7||b[5]==10)maps++;if(b[5]==8||b[5]==10)poses++;assert(V2||b[5]!=10);}
    // Exercise ACK-before-submission and file-before-submission ordering.
    [session consume:Ack(p)];[session consume:File()];assert(session.busy);submitted(YES,@"native");assert(!session.busy&&session.active);
   }now+=.1;
  }
  assert(state.valid&&state.located);uint8_t image[TNR_W*TNR_H];tnr_draw(&state,(uint32_t)(now*1000),image);
  TNRLabelView names[4];unsigned count=tnr_labels(&state,(uint32_t)(now*1000),names);namesShown+=count;for(unsigned k=0;k<count;k++){assert(names[k].x>=3&&names[k].x+names[k].width<=293&&names[k].y>=3&&names[k].y+20<=145);}
  if(i==0||i==45||i==90||i==135){NSMutableData *pgm=[[NSString stringWithFormat:@"P5\n%u %u\n255\n",TNR_W,TNR_H] dataUsingEncoding:NSASCIIStringEncoding].mutableCopy;[pgm appendBytes:image length:sizeof image];assert(([pgm writeToFile:[out stringByAppendingPathComponent:[NSString stringWithFormat:@"map-%u.pgm",i]] atomically:YES]));}
 }}
 assert(maps>=5&&poses>=60&&max<=4096&&bytes<300000);assert(sends==cleanups);
 assert([session.status[@"roadLabels"] boolValue]==V2);if(V2)assert(namesShown>20);
 // Losing map data clears it once. Stop then wins; no stale pose replay.
 [session offer:@{@"phase":@"navigating",@"icon":@9,@"meters":@100,@"remainingMeters":@200,@"remainingSeconds":@100}];now+=1;[session pump];assert(((const uint8_t *)wire.bytes)[5]==TNR_CLEAR);[session consume:Ack(wire)];[session consume:File()];submitted(YES,@"native");wire=nil;[session stop];now+=1;[session pump];assert(((const uint8_t *)wire.bytes)[5]==TN_STOP);[session consume:Ack(wire)];[session consume:File()];submitted(YES,@"native");assert(!session.active&&!session.busy);
 NSDictionary *test=[map markerTestFrame:@{@"phase":@"navigating",@"icon":@9,@"meters":@80,@"remainingMeters":@1000,@"remainingSeconds":@100}];TNScene markerScene;assert(TNVScene(test,YES,&markerScene));assert(markerScene.camera_m==50&&markerScene.camera_limit==60&&markerScene.event_m==90&&markerScene.light_count==1&&markerScene.light_m[0]==20&&markerScene.speed_kmh==42&&markerScene.road_limit==60&&markerScene.cam_count==3&&markerScene.cam_kind[0]==1&&markerScene.cam_limit[0]==60&&markerScene.cam_m[0]==50&&markerScene.cam_kind[1]==3&&markerScene.cam_kind[2]==4&&markerScene.cam_limit[2]==80&&markerScene.cam_m[2]==260&&markerScene.fac_count==3&&markerScene.fac_kind[0]==2&&markerScene.fac_m[0]==40&&markerScene.fac_kind[1]==1&&markerScene.fac_m[1]==160&&markerScene.fac_kind[2]==4&&markerScene.fac_m[2]==260);
 {uint8_t wire[512];size_t n=tn_encode(wire,sizeof wire,TN_UPDATE,7,9,&markerScene);assert(n&&tn_packet_valid(wire,n)); /* EXT6（camList+facList+road_limit）满尾巴回环：编码→校验(含解码) */
  assert(wire[32+36+53]==42&&!wire[32+36+54]&&wire[32+36+55]==60&&wire[32+36+56]==3); /* 线格式钉死：EXT5 区段 e[53]=speed42 e[55]=roadLimit60 e[56]=camCount3（2026-11-06 真机 EXT5 车速丢失根因=解码漏 EXT5 分支，字节断言防再漂移；36=空路名/空转向/3点的 base） */
  assert(wire[32+36+122]==3&&wire[32+36+123]==2&&wire[32+36+124]==40&&wire[32+36+126]==1&&wire[32+36+127]==160&&wire[32+36+129]==4); /* EXT6 区段：e[122]=facCount3，e[123+3i]=kind、e[124+3i]=m（收费站40/服务区160/隧道260） */
  /* 解码神谕：把某字段篡改为非法值并重算线 CRC，packet_valid 必须拒帧——直接证明该偏移
   * 被对应 EXT 分支解码并参与 valid()（2026-11-06 EXT5 车速丢失、11-07 EXT6 同类的回归网）。 */
  {uint32_t c;
   n=tn_encode(wire,sizeof wire,TN_UPDATE,7,15,&markerScene);assert(n);
   wire[32+36+55]=201;c=TFixWireCRC(wire,n);wire[20]=(uint8_t)c;wire[21]=(uint8_t)(c>>8);wire[22]=(uint8_t)(c>>16);wire[23]=(uint8_t)(c>>24);assert(!tn_packet_valid(wire,n)); /* road_limit 201 非法 */
   n=tn_encode(wire,sizeof wire,TN_UPDATE,7,16,&markerScene);
   wire[32+36+53]=0x58;wire[32+36+54]=2;c=TFixWireCRC(wire,n);wire[20]=(uint8_t)c;wire[21]=(uint8_t)(c>>8);wire[22]=(uint8_t)(c>>16);wire[23]=(uint8_t)(c>>24);assert(!tn_packet_valid(wire,n)); /* speed 600 非法 */
   n=tn_encode(wire,sizeof wire,TN_UPDATE,7,17,&markerScene);
   wire[32+36+123]=13;c=TFixWireCRC(wire,n);wire[20]=(uint8_t)c;wire[21]=(uint8_t)(c>>8);wire[22]=(uint8_t)(c>>16);wire[23]=(uint8_t)(c>>24);assert(!tn_packet_valid(wire,n)); /* fac_kind 13 非法 */
   n=tn_encode(wire,sizeof wire,TN_UPDATE,7,18,&markerScene);
   wire[32+36+36]=9;c=TFixWireCRC(wire,n);wire[20]=(uint8_t)c;wire[21]=(uint8_t)(c>>8);wire[22]=(uint8_t)(c>>16);wire[23]=(uint8_t)(c>>24);assert(!tn_packet_valid(wire,n)); /* light_count 9>8 非法（EXT6 下 lightsList 须被解码） */}
  TNScene noCam=markerScene;noCam.cam_count=0;n=tn_encode(wire,sizeof wire,TN_UPDATE,7,10,&noCam);assert(n&&tn_packet_valid(wire,n)); /* 无 camList 降级 EXT4 */
  TNScene noLimit=noCam;noLimit.road_limit=255;n=tn_encode(wire,sizeof wire,TN_UPDATE,7,11,&noLimit);assert(n&&tn_packet_valid(wire,n)); /* 路段限速缺省再降级 EXT3 */
  TNScene bad=markerScene;bad.cam_kind[0]=9;assert(!tn_encode(wire,sizeof wire,TN_UPDATE,7,12,&bad)); /* 非法相机类型拒帧 */
  bad=markerScene;bad.cam_limit[0]=201;assert(!tn_encode(wire,sizeof wire,TN_UPDATE,7,13,&bad));
  bad=markerScene;bad.road_limit=201;assert(!tn_encode(wire,sizeof wire,TN_UPDATE,7,14,&bad)); /* 非法限速值必须拒帧 */}
 TNRState testState={0};assert(tnr_receive(&testState,TNR_SCENE,((NSData *)test[@"tnrScene"]).bytes,((NSData *)test[@"tnrScene"]).length,0));assert(tnr_receive(&testState,TNR_POSE,((NSData *)test[@"tnrPose"]).bytes,12,0));TNRPose pose;assert(tnr_position(&testState,0,&pose));
 TNRPoint light=tnr_route_ahead(&testState,&pose,20),camera=tnr_route_ahead(&testState,&pose,50),event=tnr_route_ahead(&testState,&pose,90);assert(light.x>=0&&light.x<296&&camera.x>=0&&camera.x<296&&event.x>=0&&event.x<296);
 /* 自测场景 heading=0（车头朝 scene +y，投影为画布纵轴），路线沿行进方向时
  * 标记按距离在纵轴上单调远离：越近的标记越靠下（py 更大）。横轴单调性只在
  * 路线垂直于车头时成立，北-南走向的自测路线不适用（71789ec 引入本用例时
  * 该断言从未在任何环境运行过）。 */
 assert(light.y>camera.y&&camera.y>event.y);
 uint32_t firstGeneration=U32(((NSData *)test[@"tnrScene"]).bytes);[map clearMarkerTest];test=[map markerTestFrame:@{@"phase":@"navigating"}];assert(U32(((NSData *)test[@"tnrScene"]).bytes)>firstGeneration);[map clearMarkerTest];
 assert([map decorate:@{@"phase":@"navigating"} coordinates:@[]][@"tnrScene"]==nil);[map reset];assert(map.allowNetwork);
 NSDictionary *r=@{@"passed":@YES,@"frames":@180,@"maps":@(maps),@"poses":@(poses),@"wireBytes":@(bytes),@"maxPacket":@(max),@"roadLabels":@(V2),@"labelsShown":@(namesShown),@"packets":trace,@"source":@"public OSM fixture, no location or network",@"hardwareValidated":@NO};assert([[NSJSONSerialization dataWithJSONObject:r options:0 error:nil] writeToFile:[out stringByAppendingPathComponent:V2?@"replay-trace.json":@"replay-legacy.json"] atomically:YES]);printf("PASS 180 real-road replay samples: maps=%u poses=%u bytes=%u max=%u labels=%u\n",maps,poses,bytes,max,namesShown);
}return 0;}
