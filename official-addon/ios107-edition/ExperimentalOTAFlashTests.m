#import "ExperimentalOTAFlash.h"
#import "ExperimentalOTA.h"
#include <assert.h>
static void V(NSMutableData *d,NSUInteger n){do{uint8_t b=n&127;n>>=7;if(n)b|=128;[d appendBytes:&b length:1];}while(n);}
static NSData *F(NSUInteger type,id json,NSData *binary){NSMutableData *d=[NSMutableData new];V(d,8);V(d,1);V(d,16);V(d,type);if(json){NSData *j=[NSJSONSerialization dataWithJSONObject:json options:0 error:nil];V(d,26);V(d,j.length);[d appendData:j];}if(binary){V(d,34);V(d,binary.length);[d appendData:binary];}return d;}
static TIOOTAFlashGate *Ready(NSURL *dir){TIOOTAFlashGate *g=[TIOOTAFlashGate new];NSError *e=nil;assert([g prepareDirectory:dir device:@"TEST_DEVICE" uptime:10 error:&e]);return g;}
int main(int argc,const char **argv){@autoreleasepool{
    assert(argc==3);NSURL *dir=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
    NSURL *previous=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
    assert(!TIOCopyExperimentalOTAPayloads(previous,nil));
    assert(TIOOTAAutoUpdateDisabled(@{@"test_ota_firmware_auto_update":@"false"}));assert(TIOOTAAutoUpdateDisabled(@{@"test_ota_firmware_auto_update":@NO}));
    for(id v in @[@"true",@YES,@0,@1,@"unknown",NSNull.null])assert(!TIOOTAAutoUpdateDisabled(@{@"test_ota_firmware_auto_update":v}));assert(!TIOOTAAutoUpdateDisabled(@{}));assert(!TIOOTAAutoUpdateDisabled(@{@"one_ota_firmware_auto_update":@"false",@"two_ota_firmware_auto_update":@"true"}));
    NSDictionary *files=TIOCopyExperimentalOTAPayloads(dir,nil),*candidate=TIOOTACandidate();assert(files.count==[candidate[@"payloadPins"] count]);NSArray *manifest=[NSJSONSerialization JSONObjectWithData:files[@"OtaFileInfo.json"] options:0 error:nil];
    NSString *apName=candidate[@"ap"][@"name"];
    for(NSDictionary *row in manifest)if([row[@"Name"] isEqual:apName]){assert([row[@"Md5"] isEqual:candidate[@"ap"][@"md5"]]);assert([row[@"Size"] unsignedIntegerValue]==[candidate[@"ap"][@"size"] unsignedIntegerValue]);}
    NSData *start=F(4,@{@"Mode":@2},nil),*version=F(5,@{@"OtaVersion":candidate[@"baseVersion"]},nil),*info=F(6,manifest,nil);
    /* 2026-10-30 官方直连路线：未武装会话放行并逐片截获官方安装流量
     * （captureFiles 计数可见）；只有畸形分片（路径穿越/长度不符）仍拒。
     * 旧「未授权全拒」断言随之改写。 */
    TIOOTAFlashGate *g=[TIOOTAFlashGate new];assert([g allows:start device:@"TEST_DEVICE" uptime:10]);assert([g allows:F(6,nil,nil) device:@"TEST_DEVICE" uptime:10]);
    assert([g allows:F(1,nil,nil) device:@"TEST_DEVICE" uptime:10]);assert([g allows:F(2,nil,nil) device:@"TEST_DEVICE" uptime:10]);assert([g allows:F(3,@{@"OtaSize":candidate[@"otaSize"]},nil) device:@"TEST_DEVICE" uptime:10]);
    assert([g allows:F(11,@{@"Mode":@2},nil) device:@"TEST_DEVICE" uptime:10]);
    assert([g allows:F(11,nil,[NSData dataWithBytes:"x" length:1]) device:@"TEST_DEVICE" uptime:10]);
    for(NSUInteger t=4;t<256;t++)if(t!=7)assert([g allows:F(t,nil,nil) device:@"TEST_DEVICE" uptime:10]);
    assert(![g allows:F(7,@{@"Name":@"../nuttx_ap.bin",@"Start":@0,@"Size":@1},[NSData dataWithBytes:"x" length:1]) device:@"TEST_DEVICE" uptime:10]);
    assert(![g allows:F(7,@{@"Name":@"nuttx_ap.bin",@"Start":@0,@"Size":@2},[NSData dataWithBytes:"x" length:1]) device:@"TEST_DEVICE" uptime:10]);
    assert([g allows:F(7,@{@"Name":@"nuttx_ap.bin",@"Start":@0,@"Size":@1},[NSData dataWithBytes:"x" length:1]) device:@"TEST_DEVICE" uptime:10]);
    assert([g.status[@"captureFiles"] unsignedIntegerValue]==1);assert([g.status[@"failure"] length]==0);
    g=Ready(dir);assert(![g allows:start device:@"OTHER_DEVICE" uptime:11]);assert(![g allows:F(4,@{@"Mode":@1},nil) device:@"TEST_DEVICE" uptime:11]);assert([g cancel]);/* 撤销后未武装：官方重试 Mode 帧按 2026-10-30 截获路线放行 */assert([g allows:start device:@"TEST_DEVICE" uptime:11]);
    g=Ready(dir);assert(![g allows:start device:@"TEST_DEVICE" uptime:910]);assert(![g.status[@"authorized"] boolValue]);
    g=Ready(dir);assert([g allows:start device:@"TEST_DEVICE" uptime:11]);assert(![g cancel]);assert(![g allows:info device:@"TEST_DEVICE" uptime:12]);assert([g.status[@"stage"] intValue]==3);
    /* 2026-10-31 僵死会话复位：安装中断后 stage 粘 2/3 且无回落，同一 App 会话
     * 内重新授权必须能复位（活跃会话——120 秒内有帧——仍不可覆盖）。 */
    g=Ready(dir);assert([g allows:start device:@"TEST_DEVICE" uptime:11]);assert([g allows:version device:@"TEST_DEVICE" uptime:12]);
    assert(![g prepareDirectory:dir device:@"TEST_DEVICE" uptime:13 error:nil]);
    assert([g prepareDirectory:dir device:@"TEST_DEVICE" uptime:200 error:nil]);
    assert([g allows:start device:@"TEST_DEVICE" uptime:201]);assert([g allows:version device:@"TEST_DEVICE" uptime:202]);
    g=Ready(dir);assert([g allows:start device:@"TEST_DEVICE" uptime:11]);assert(![g allows:info device:@"TEST_DEVICE" uptime:12]);assert([g.status[@"stage"] intValue]==3);
    assert([g.status[@"dead"] boolValue]);assert([g prepareDirectory:dir device:@"TEST_DEVICE" uptime:13 error:nil]);
    assert([g allows:start device:@"TEST_DEVICE" uptime:14]);
    g=Ready(dir);assert([g prepareDirectory:dir device:@"TEST_DEVICE" uptime:1000 error:nil]);assert([g allows:start device:@"TEST_DEVICE" uptime:1001]);
    g=Ready(dir);assert([g allows:start device:@"TEST_DEVICE" uptime:11]);assert([g allows:version device:@"TEST_DEVICE" uptime:12]);assert([g allows:info device:@"TEST_DEVICE" uptime:13]);
    NSUInteger slices=0,total=0,expectedTotal=0;
    for(NSString *name in files)if(![name isEqual:candidate[@"manifest"][@"name"]])expectedTotal+=[files[name] length];
    for(NSDictionary *row in manifest){NSString *name=row[@"Name"];NSData *file=files[name];for(NSUInteger at=0;at<file.length;at+=51200){NSUInteger size=MIN((NSUInteger)51200,file.length-at);NSData *part=[file subdataWithRange:NSMakeRange(at,size)];assert([g allows:F(7,@{@"Name":name,@"Start":@(at),@"Size":@(size)},part) device:@"TEST_DEVICE" uptime:20]);slices++;total+=size;}}
    assert([g.status[@"validatedSlices"] unsignedIntegerValue]==slices);assert([g.status[@"validatedSliceBytes"] unsignedIntegerValue]==total);assert(total==expectedTotal);
    assert([g.status[@"transferComplete"] boolValue]);assert(![g.status[@"installationValidated"] boolValue]);
    NSTimeInterval evidenceAt=NSProcessInfo.processInfo.systemUptime;
    [g observe:F(1,@{@"OsVersion":candidate[@"baseVersion"],@"OtaValidationConfirmed":@YES,@"OtaValidationState":@"idle",@"PackageTypes":@[@"files"]},nil) device:@"TEST_DEVICE" uptime:evidenceAt];
    [g observe:F(11,@{@"Result":@YES},nil) device:@"TEST_DEVICE" uptime:evidenceAt];
    assert([g.status[@"readbackFresh"] boolValue]);assert(![g.status[@"installationValidated"] boolValue]);
    assert([g confirmRuntimeAt:evidenceAt error:nil]);assert([g.status[@"runtimeValidated"] boolValue]);assert([g.status[@"installationValidated"] boolValue]);
    for(NSString *name in files){if([name isEqual:@"OtaFileInfo.json"])continue;
        TIOOTAFlashGate *probe=Ready(dir);assert([probe allows:start device:@"TEST_DEVICE" uptime:11]);assert([probe allows:version device:@"TEST_DEVICE" uptime:12]);assert([probe allows:info device:@"TEST_DEVICE" uptime:13]);
        uint8_t byte=((const uint8_t *)[files[name] bytes])[0]^1;
        assert(![probe allows:F(7,@{@"Name":name,@"Start":@0,@"Size":@1},[NSData dataWithBytes:&byte length:1]) device:@"TEST_DEVICE" uptime:14]);
    }
    NSArray *previousManifest=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:[previous URLByAppendingPathComponent:@"OtaFileInfo.json"]] options:0 error:nil];assert(previousManifest.count==manifest.count);
    TIOOTAFlashGate *oldGate=Ready(dir);assert([oldGate allows:start device:@"TEST_DEVICE" uptime:11]);assert([oldGate allows:version device:@"TEST_DEVICE" uptime:12]);assert(![oldGate allows:F(6,previousManifest,nil) device:@"TEST_DEVICE" uptime:13]);
    NSData *ap=files[apName];NSMutableData *bad=[[ap subdataWithRange:NSMakeRange(0,51200)] mutableCopy];((uint8_t *)bad.mutableBytes)[50]^=1;
    assert(![g allows:F(7,@{@"Name":apName,@"Start":@0,@"Size":@51200},bad) device:@"TEST_DEVICE" uptime:21]);assert([g.status[@"stage"] intValue]==3);
    assert([g allows:F(11,nil,nil) device:@"TEST_DEVICE" uptime:22]);assert([g.status[@"stage"] intValue]==3);
    g=Ready(dir);assert([g allows:start device:@"TEST_DEVICE" uptime:11]);assert([g allows:version device:@"TEST_DEVICE" uptime:12]);NSMutableArray *old=[manifest mutableCopy];for(NSUInteger i=0;i<old.count;i++){if([old[i][@"Name"] isEqual:apName]){NSMutableDictionary *row=[old[i] mutableCopy];row[@"Md5"]=@"9156b9419c3557e9bd72dc61692d0b4b";old[i]=row;}}assert(![g allows:F(6,old,nil) device:@"TEST_DEVICE" uptime:13]);
    for(NSDictionary *badRange in @[@{@"Name":@"../nuttx_ap.bin",@"Start":@0,@"Size":@1},@{@"Name":@"nuttx_ap.bin",@"Start":@(-1),@"Size":@1},@{@"Name":@"nuttx_ap.bin",@"Start":@0,@"Size":@YES},@{@"Name":@"nuttx_ap.bin",@"Start":@9906631,@"Size":@2}]){
        g=Ready(dir);assert([g allows:start device:@"TEST_DEVICE" uptime:11]);assert([g allows:version device:@"TEST_DEVICE" uptime:12]);assert([g allows:info device:@"TEST_DEVICE" uptime:13]);assert(![g allows:F(7,badRange,[NSData dataWithBytes:"xx" length:2]) device:@"TEST_DEVICE" uptime:14]);
    }
    TIOOTAFlashGate *partial=Ready(dir);assert([partial allows:start device:@"TEST_DEVICE" uptime:11]);assert([partial allows:version device:@"TEST_DEVICE" uptime:12]);assert([partial allows:info device:@"TEST_DEVICE" uptime:13]);
    NSUInteger accepted=0;
    for(NSDictionary *row in manifest){NSString *name=row[@"Name"];NSData *file=files[name];for(NSUInteger at=0;at<file.length&&accepted<240;at+=51200){NSUInteger size=MIN((NSUInteger)51200,file.length-at);NSData *part=[file subdataWithRange:NSMakeRange(at,size)];assert([partial allows:F(7,@{@"Name":name,@"Start":@(at),@"Size":@(size)},part) device:@"TEST_DEVICE" uptime:20]);accepted++;}if(accepted==240)break;}
    assert(accepted==240);assert(![partial.status[@"transferComplete"] boolValue]);
    evidenceAt=NSProcessInfo.processInfo.systemUptime;assert(![partial confirmRuntimeAt:evidenceAt error:nil]);
    [partial observe:F(1,@{@"OsVersion":candidate[@"baseVersion"],@"OtaValidationConfirmed":@YES,@"OtaValidationState":@"idle",@"PackageTypes":@[@"files"]},nil) device:@"TEST_DEVICE" uptime:evidenceAt];
    [partial observe:F(11,@{@"Result":@YES},nil) device:@"TEST_DEVICE" uptime:evidenceAt];
    assert([partial confirmRuntimeAt:evidenceAt error:nil]);assert([partial.status[@"runtimeValidated"] boolValue]);assert(![partial.status[@"installationValidated"] boolValue]);
    NSMutableData *dup=[start mutableCopy];V(dup,16);V(dup,4);assert(!TIOOTAFrame(dup));assert(!TIOOTAFrame([NSData dataWithBytes:"\x08\x81\x00\x10\x04" length:5]));
    assert(!TIOOTAFlashBuild());assert(!TIOOTAFlashProtected());assert(!TIOOTAFlashAuthorize(nil));assert(!TIOOTAFlashConfirmRuntime(nil));
    NSLog(@"PASS: candidate-driven archive/gate checks, %lu slices (%lu bytes), per-payload coverage, 240-slice false-success rejection, fresh readback and manual lens validation; no device IO",(unsigned long)slices,(unsigned long)total);
}return 0;}
