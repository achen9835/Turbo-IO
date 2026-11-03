#import "NativeNavigation.h"
#import "TNVTransport.h"
#include "nav_map.h"
#include <assert.h>
static uint32_t U32(const uint8_t *p){uint32_t v;memcpy(&v,p,4);return v;}
static NSDictionary *Frame(unsigned n){return @{@"phase":@"navigating",@"icon":@3,@"meters":@(n),@"remainingMeters":@1200,@"remainingSeconds":@600,@"road":@"测试路",@"turn":@"前方右转",@"navPoints":@[@[@100,@900],@[@100,@500],@[@900,@500]],@"navHeading":@90};}
static NSDictionary *Ack(NSData *packet,unsigned result){const uint8_t *p=packet.bytes;uint8_t raw[32];tn_reply_encode(raw,32,(TNReply){.result=result,.sid=U32(p+8),.sequence=U32(p+12),.active=p[5]!=TN_STOP,.awake=true});if(p[5]==TN_QUERY){raw[24]=1;uint32_t crc=tn_crc(raw,28);memcpy(raw+28,&crc,4);}NSMutableString *hex=[NSMutableString new];for(int i=0;i<32;i++)[hex appendFormat:@"%02x",raw[i]];NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"cmd":@"turbo_nav_v1",@"payload":@{@"value":@0,@"mode":@0,@"data":hex}} options:0 error:nil];assert(json.length<128);uint8_t header[]={8,1,16,6,26,(uint8_t)json.length};NSMutableData *pb=[NSMutableData dataWithBytes:header length:6];[pb appendData:json];return @{@"eventType":@"messageReceived",@"message":@{@"deviceId":@"test-peer",@"businessId":@15,@"payload":pb}};}
static NSDictionary *File(NSString *task){return @{@"eventType":@"fileShareSuccess",@"device":@{@"id":@"test-peer"},@"taskId":task,@"fileName":@"turbo-navigation.tnv",@"role":@"sender"};}
static NSDictionary *VectorFrame(NSDictionary *base,uint32_t generation,NSTimeInterval at){
 uint8_t body[548]={0},pose[12]={0};body[0]=(uint8_t)generation;body[4]=0x40;body[5]=1;body[6]=1;body[8]=128;body[16]=128;body[18]=6;body[20]=8;pose[0]=(uint8_t)generation;
 for(unsigned i=0;i<128;i++){int y=(int)i*24-200;body[26+4*i]=(uint8_t)y;body[27+4*i]=(uint8_t)(y>>8);}
 /* SCENE2 帧尾 12 字节必须是与场景同代际的合法 TNR_POSE（固件与手机端
  * 校验器一致要求），否则 scene2 整体被拒并退化为纯 scene。 */
 memcpy(body+sizeof body-sizeof pose,pose,sizeof pose);
 NSData *scene=[NSData dataWithBytes:body length:sizeof body],*plain=[scene subdataWithRange:NSMakeRange(0,536)];NSMutableDictionary *out=[base mutableCopy];out[@"tnrScene"]=plain;out[@"tnrScene2"]=scene;out[@"tnrSceneMin"]=plain;out[@"tnrPose"]=[NSData dataWithBytes:pose length:sizeof pose];out[@"tnrPoseAt"]=@(at);return out;
}
static void Complete(TNVSession *s,NSData *packet,TNVSubmitted submit){assert([s consume:Ack(packet,TN_OK)]);(void)[s consume:File(@"vector-native")];submit(YES,@"vector-native");assert(!s.busy);}
int main(int argc,char **argv){@autoreleasepool{
 TNScene scene;assert(TNVScene(Frame(80),NO,&scene));assert(scene.icon==TN_RIGHT&&scene.point_count==3);uint8_t bytes[512];size_t n=tn_encode(bytes,512,TN_START,10,1,&scene);assert(n&&n<=328&&tn_packet_valid(bytes,n));bytes[n-1]^=1;assert(!tn_packet_valid(bytes,n));
 NSMutableDictionary *bad=[Frame(80) mutableCopy];bad[@"navPoints"]=@[@[@1024,@0]];assert(!TNVScene(bad,NO,&scene));bad[@"navPoints"]=@[];bad[@"meters"]=@(-1);assert(!TNVScene(bad,NO,&scene));
 NSDictionary *geo=TNVNormalizeCoordinates(@[@[@39.9,@116.4],@[@39.901,@116.4],@[@39.901,@116.401]]);assert([geo[@"navPoints"] count]==3&&[geo[@"navHeading"] intValue]==0);assert(!TNVNormalizeCoordinates(@[@[@0,@0],@[@0,@0]]).count);
 NSMutableArray *longgeo=[NSMutableArray new];for(int i=0;i<512;i++)[longgeo addObject:@[@(40+i*.00001),@(116+i*.00001)]];assert([TNVNormalizeCoordinates(longgeo)[@"navPoints"] count]==32);
 __block NSTimeInterval now=1;__block NSData *wire;__block NSString *task;__block TNVSubmitted submit;__block unsigned sends=0,cleanups=0;
 TNVSession *s=[[TNVSession alloc]initWithDevice:@"test-peer" session:10 clock:^{return now;} sender:^(NSData *b,NSString *t,TNVSubmitted done){assert(tn_packet_valid(b.bytes,b.length));wire=b;task=t;submit=done;sends++;} cleanup:^(NSString *t){assert([t isEqual:task]);cleanups++;}];
 NSMutableArray *trace=[NSMutableArray new];
 assert([s start:Frame(80) always:NO]);[trace addObject:[wire base64EncodedStringWithOptions:0]];assert(s.busy&&s.active&&sends==1);for(int i=0;i<100;i++)[s offer:Frame(i)];[s pump];assert(sends==1);
 assert(![s consume:File(@"sdk-native-1")]);assert([s consume:Ack(wire,0)]);assert(s.busy);submit(YES,@"sdk-native-1");assert(!s.busy&&cleanups==1);
 now+=1.1;[s pump];assert(sends==2);[trace addObject:[wire base64EncodedStringWithOptions:0]];submit(YES,@"sdk-native-2");assert([s consume:File(@"sdk-native-2")]);assert(s.busy);assert([s consume:Ack(wire,0)]);assert(!s.busy);
 now+=1.1;[s pump];assert(sends==2); // identical scene does not flood
 [s setAlways:YES];now+=1;[s pump];assert(sends==3);[trace addObject:[wire base64EncodedStringWithOptions:0]];submit(YES,@"sdk-native-3");[s consume:Ack(wire,0)];[s consume:File(@"sdk-native-3")];
 now+=20;[s pump];assert(sends==4&&((const uint8_t *)wire.bytes)[5]==TN_HEARTBEAT);[trace addObject:[wire base64EncodedStringWithOptions:0]];submit(YES,@"sdk-native-4");[s consume:Ack(wire,0)];[s consume:File(@"sdk-native-4")];now+=1.1;[s pump];assert(sends==4);
 [s stop];assert(sends==5&&((const uint8_t *)wire.bytes)[5]==TN_STOP);[trace addObject:[wire base64EncodedStringWithOptions:0]];submit(YES,@"sdk-native-5");[s consume:Ack(wire,0)];[s consume:File(@"sdk-native-5")];assert(!s.active&&!s.busy&&cleanups==5);
 assert(![s start:Frame(40) always:NO]); // Each START requires a new persisted monotonic SID.
 s=[[TNVSession alloc]initWithDevice:@"test-peer" session:11 clock:^{return now;} sender:^(NSData *b,NSString *t,TNVSubmitted done){wire=b;task=t;submit=done;} cleanup:nil];
 assert([s start:Frame(40) always:NO]);now+=9;[s pump];assert(s.active&&!s.busy); /* a lost reply drops this frame but must NOT kill the session */now+=1;[s offer:Frame(40)];[s pump];assert(((const uint8_t *)wire.bytes)[5]==TN_UPDATE);submit(YES,@"late-task");[s consume:File(@"late-task")];[s consume:Ack(wire,0)];assert(s.active&&!s.busy);
 [s stop];submit(YES,@"stop-task");[s consume:Ack(wire,0)];assert(!s.active&&!s.busy&&[s.status[@"stopped"] boolValue]);
 // Transient TN_BUSY must retry the identical packet/sequence instead of killing the session.
 now+=1;s=[[TNVSession alloc]initWithDevice:@"test-peer" session:12 clock:^{return now;} sender:^(NSData *b,NSString *t,TNVSubmitted done){wire=b;task=t;submit=done;} cleanup:nil];
 assert([s start:Frame(40) always:NO]);uint32_t retired=((const uint8_t *)wire.bytes)[5];assert(retired==TN_START);assert([s consume:Ack(wire,TN_BUSY)]);assert(s.active&&!s.busy);now+=0.5;[s pump];assert(((const uint8_t *)wire.bytes)[5]==TN_START);submit(YES,@"retry-task");[s consume:File(@"retry-task")];[s consume:Ack(wire,0)];assert(s.active&&!s.busy);
 [s stop];submit(YES,@"stop2-task");[s consume:Ack(wire,0)];assert(!s.active&&!s.busy&&[s.status[@"stopped"] boolValue]);
 // Vector frames must survive local validation, ACK and file completion. Once a
 // scene is committed, unchanged geometry must use POSE instead of resending it.
 now+=1;sends=0;s=[[TNVSession alloc]initWithDevice:@"test-peer" session:13 clock:^{return now;} sender:^(NSData *b,NSString *t,TNVSubmitted done){assert(tn_packet_valid(b.bytes,b.length));wire=b;task=t;submit=done;sends++;} cleanup:nil];NSData *vectorWire=nil;
 assert([s start:VectorFrame(Frame(80),1,now) always:NO]);Complete(s,wire,submit);
 now+=.1;[s pump];assert(((const uint8_t *)wire.bytes)[5]==TN_QUERY);Complete(s,wire,submit);assert([s.status[@"roadLabels"] boolValue]);
 now+=.1;[s pump];assert(((const uint8_t *)wire.bytes)[5]==TNR_SCENE2&&wire.length==580);vectorWire=wire;Complete(s,wire,submit);
 assert([s.status[@"maps"] unsignedIntegerValue]==1&&[s.status[@"poses"] unsignedIntegerValue]==1&&[s.status[@"mapSends"] unsignedIntegerValue]==1&&[s.status[@"mapDrops"] unsignedIntegerValue]==0);
 wire=nil;now+=.2;[s pump];assert(!wire); // unchanged scene must not be resent
 now+=1;[s pump];assert(((const uint8_t *)wire.bytes)[5]==TNR_POSE);Complete(s,wire,submit);assert([s.status[@"poses"] unsignedIntegerValue]==2&&[s.status[@"maps"] unsignedIntegerValue]==1);
 [s offer:VectorFrame(Frame(80),2,now)];[s pump];assert(((const uint8_t *)wire.bytes)[5]==TNR_SCENE2);Complete(s,wire,submit);
 [s offer:VectorFrame(Frame(80),3,now)];[s pump];assert(((const uint8_t *)wire.bytes)[5]==TNR_SCENE2);assert([s consume:Ack(wire,TN_BAD_PACKET)]);assert(!s.busy&&s.active&&[s.status[@"mapDrops"] unsignedIntegerValue]==1);
 now+=.6;[s pump];assert(((const uint8_t *)wire.bytes)[5]==TNR_SCENE2);Complete(s,wire,submit);assert([s.status[@"maps"] unsignedIntegerValue]==3);
 wire=nil;now+=.1;[s pump];assert(!wire);[s stop];Complete(s,wire,submit);assert(!s.active&&[s.status[@"stopped"] boolValue]);
 // Sender rejects wrong-peer / malformed data before touching SDK; cleanup is scoped.
 NSURL *root=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
 __block BOOL called=NO,finished=NO;
 TNVTransport *transport=[[TNVTransport alloc]initWithRoot:root device:@"test-peer" currentDevice:^{return @"test-peer";} call:^BOOL(NSString *m,NSDictionary *a,void(^done)(id)){
  called=YES;assert(TNVIsScopedCall(m,a));assert(!TNVIsScopedCall(m,[a mutableCopy]));assert([a[@"filePath"] hasSuffix:@"turbo-navigation.tnv"]);done(@{@"success":@YES,@"taskId":@"native-task"});return YES;}];
 NSString *tid=NSUUID.UUID.UUIDString;assert(vectorWire);[transport send:vectorWire task:tid submitted:^(BOOL ok,NSString *native){assert(ok&&[native isEqual:@"native-task"]);finished=YES;}];
 NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:2];while(!finished&&[limit timeIntervalSinceNow]>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];assert(called&&finished);[transport cleanup:tid];assert([[NSFileManager.defaultManager contentsOfDirectoryAtPath:root.path error:nil] count]==0);
 [NSFileManager.defaultManager removeItemAtURL:root error:nil];
 if(argc==2){NSDictionary *record=@{@"syntheticOnly":@YES,@"packets":trace};assert([[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:nil] writeToFile:@(argv[1]) atomically:YES]);}
 puts("PASS TNV1 codec, vector gate/ACK/file commit, unchanged-scene POSE pacing, map rejection recovery, real SDK task binding, STOP, transient retry and scoped cleanup");
}return 0;}
