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
 NSDictionary *test=[map markerTestFrame:@{@"phase":@"navigating",@"icon":@9,@"meters":@80,@"remainingMeters":@1000,@"remainingSeconds":@100}];TNScene markerScene;assert(TNVScene(test,YES,&markerScene));assert(markerScene.camera_m==50&&markerScene.camera_limit==60&&markerScene.event_m==90&&markerScene.light_count==1&&markerScene.light_m[0]==20&&markerScene.speed_kmh==42);
 TNRState testState={0};assert(tnr_receive(&testState,TNR_SCENE,((NSData *)test[@"tnrScene"]).bytes,((NSData *)test[@"tnrScene"]).length,0));assert(tnr_receive(&testState,TNR_POSE,((NSData *)test[@"tnrPose"]).bytes,12,0));TNRPose pose;assert(tnr_position(&testState,0,&pose));
 TNRPoint light=tnr_route_ahead(&testState,&pose,20),camera=tnr_route_ahead(&testState,&pose,50),event=tnr_route_ahead(&testState,&pose,90);assert(light.x>=0&&light.x<296&&camera.x>=0&&camera.x<296&&event.x>=0&&event.x<296);assert(light.x<camera.x&&camera.x<event.x);
 uint32_t firstGeneration=U32(((NSData *)test[@"tnrScene"]).bytes);[map clearMarkerTest];test=[map markerTestFrame:@{@"phase":@"navigating"}];assert(U32(((NSData *)test[@"tnrScene"]).bytes)>firstGeneration);[map clearMarkerTest];
 assert([map decorate:@{@"phase":@"navigating"} coordinates:@[]][@"tnrScene"]==nil);[map reset];assert(map.allowNetwork);
 NSDictionary *r=@{@"passed":@YES,@"frames":@180,@"maps":@(maps),@"poses":@(poses),@"wireBytes":@(bytes),@"maxPacket":@(max),@"roadLabels":@(V2),@"labelsShown":@(namesShown),@"packets":trace,@"source":@"public OSM fixture, no location or network",@"hardwareValidated":@NO};assert([[NSJSONSerialization dataWithJSONObject:r options:0 error:nil] writeToFile:[out stringByAppendingPathComponent:V2?@"replay-trace.json":@"replay-legacy.json"] atomically:YES]);printf("PASS 180 real-road replay samples: maps=%u poses=%u bytes=%u max=%u labels=%u\n",maps,poses,bytes,max,namesShown);
}return 0;}
