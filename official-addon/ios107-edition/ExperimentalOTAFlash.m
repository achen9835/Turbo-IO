#import "ExperimentalOTAFlash.h"
#import "MusicTransport.h"
#import "ReaderTransport.h"
#import "FocusTransport.h"
#import "TDTransport.h"
#if TIO_APP_SDK
#import "AppTransport.h"
#endif
#import "ExperimentalOTA.h"
#import "ExperimentalOTAGuard.h"
#include <TargetConditionals.h>
#include <math.h>
#if TIO_IMAGE_RX_LAB
#import "ImageUploadTransport.h"
#if TIO_DISPLAY_PHONE
#import "DisplayPhoneTransport.h"
#if TIO_NATIVE_NAV
#import "TNVTransport.h"
#endif
#if TARGET_OS_IPHONE && TIO_DISPLAY_FLASH
#import "DisplayPhoneUI.h"
#endif
#endif
#endif
/* 传输窗口（stage==2）文件类调用的可观测性：v4 起不再按方法名拦截（见下），
 * 但逐次记名——若安装再次中断，状态行直接给出中断前流过/被关注的调用名。 */
static NSUInteger StageTwoFileCalls;
static NSString *LastStageTwoFileCall=@"-";
BOOL TIOOTAFileCallBlocked(NSString *method,BOOL scopedImage,NSUInteger stage){
 if(![method isKindOfClass:NSString.class])return YES;
 /* 2026-10-31 v4：传输窗口全透明。v3 在 stage==2 拦非本方文件流（方法名含
  * sendfile/ota/upgrade）且拦截不进任何计数器（blockedCalls 只统计 prepare
  * 构建）——真机 TAP3 两次安装停在一字不差的同一字节（240 片/12,096,730，
  * 1.0.10 宿主），而官方直连（门禁整体关闭）同包同眼镜 17MB 全量成功；该拦截
  * 无法自证清白。固件本体走 business 9 帧逐片 memcmp 核对，并发流不会静默
  * 损坏；1.0.10 宿主安装流程若中途换用 sendFile 类通道，v3 会无声吞掉它。
  * 改为全放行并记名，换取可判定的真机证据。 */
 (void)scopedImage;(void)stage;
 NSString *lower=method.lowercaseString;
 if([lower containsString:@"sendfile"]||[lower containsString:@"ota"]||[lower containsString:@"upgrade"])@synchronized(NSProcessInfo.processInfo){StageTwoFileCalls++;LastStageTwoFileCall=[method copy];}
 return NO;
}
static id Error(NSError **error,NSString *s){if(error)*error=[NSError errorWithDomain:@"TurboIO.OTAFlash" code:1 userInfo:@{NSLocalizedDescriptionKey:s}];return nil;}
static BOOL Number(id n,NSUInteger *out){
    if(![n isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)n)==CFBooleanGetTypeID()||CFNumberIsFloatType((__bridge CFNumberRef)n)||[n longLongValue]<0)return NO;
    uint64_t v=[n unsignedLongLongValue];if(v>UINT32_MAX)return NO;*out=(NSUInteger)v;return YES;
}
/* 僵死会话判定（2026-10-31 真机三连败教训）：安装中断后 stage 停在 2/3 且无
 * 回落，同一 App 会话内重新授权被拒、新安装首帧被拒——只能重启 App。判据：
 * stage==3（毒化）永远可复位；授权窗（900 秒）已过可复位；stage==2 且 120 秒
 * 无任何帧（健康传输的分片间隔远小于此）可复位。复位入口只有显式重新授权
 * （用户动作），安装帧自身永不自动复活会话。 */
static BOOL DeadSession(NSUInteger stage,NSTimeInterval last,NSTimeInterval deadline,NSTimeInterval now){
    if(stage==3)return YES;
    if(isfinite(deadline)&&isfinite(now)&&now>=deadline)return YES;
    return stage==2&&isfinite(last)&&isfinite(now)&&now-last>120;
}
static BOOL Var(const uint8_t *b,NSUInteger n,NSUInteger *at,uint64_t *v){*v=0;for(unsigned i=0;i<5;i++){if(*at>=n)return NO;uint8_t x=b[(*at)++];if(i==4&&(x&0xf0))return NO;*v|=(uint64_t)(x&127)<<(i*7);if(!(x&128))return i==0||x!=0;}return NO;}
NSDictionary *TIOOTAFrame(NSData *data){
    if(![data isKindOfClass:NSData.class]||data.length<4||data.length>65536)return nil;
    const uint8_t *b=data.bytes;NSUInteger at=0;unsigned seen=0;uint64_t version=0,type=0;NSData *json=[NSData data],*binary=[NSData data];
    while(at<data.length){uint64_t key,v;if(!Var(b,data.length,&at,&key))return nil;unsigned tag=(unsigned)(key>>3),wire=key&7;
        if(tag<1||tag>6||(seen&(1u<<tag)))return nil;seen|=1u<<tag;
        if(tag==3||tag==4){if(wire!=2||!Var(b,data.length,&at,&v)||v>data.length-at)return nil;if(tag==3)json=[data subdataWithRange:NSMakeRange(at,(NSUInteger)v)];else binary=[data subdataWithRange:NSMakeRange(at,(NSUInteger)v)];at+=(NSUInteger)v;}
        else{if(wire!=0||!Var(b,data.length,&at,&v))return nil;if(tag==1)version=v;if(tag==2)type=v;if(tag==6&&v!=0)return nil;}
    }
    if(version!=1||!type)return nil;
    id obj=json.length?[NSJSONSerialization JSONObjectWithData:json options:0 error:nil]:@{};
    if(![obj isKindOfClass:NSDictionary.class]&&![obj isKindOfClass:NSArray.class])return nil;
    return @{@"type":@(type),@"json":obj,@"binary":binary};
}
BOOL TIOPhoneOTAReadAllowed(NSData *data){
    NSDictionary *frame=TIOOTAFrame(data);NSUInteger type=[frame[@"type"] unsignedIntegerValue];
    return [@[@1,@2,@11] containsObject:@(type)]&&[frame[@"json"] isEqual:@{}]&&[frame[@"binary"] length]==0;
}
@implementation TIOOTAFlashGate{
    NSDictionary<NSString *,NSData *> *_files;NSArray *_manifest;NSString *_device,*_failure;
    NSTimeInterval _deadline,_lastActivity;NSUInteger _stage,_slices,_bytes,_captureCount,_captureBytes;BOOL _versionSent,_manifestSent;
    NSMutableDictionary<NSString *,NSMutableData *> *_captureFiles;NSArray *_captureSizes;
}
- (BOOL)prepareDirectory:(NSURL *)directory device:(NSString *)device uptime:(NSTimeInterval)now error:(NSError **)error{
    @synchronized(self){
        if((_stage&&!DeadSession(_stage,_lastActivity,_deadline,now))||![device isKindOfClass:NSString.class]||!device.length||device.length>200||!isfinite(now)||now<0){Error(error,@"当前不是可授权状态或没有有效设备；未开放。");return NO;}
        /* 僵死会话（stage 粘 2/3、授权窗已过、或 120 秒无帧）随重新授权复位并
         * 重冻结——不重启 App 也能再战；活跃会话仍不可覆盖。 */
        if(_stage){_stage=0;_files=nil;_manifest=nil;_device=nil;_deadline=0;_versionSent=NO;_manifestSent=NO;_failure=nil;_slices=0;_bytes=0;}
        NSDictionary *files=TIOCopyExperimentalOTAPayloads(directory,error);if(!files)return NO;
        /* 清单负载数随候选底座走（TAP1/1.0.4.12=14，TAP2/1.0.5.5=15 含新增
         * bt_controller.bin），从 payloadPins 派生而非写死。2026-10-27 真机：
         * 写死 14 使 TAP2 授权在此被拒且 error 未置——状态行 nil 显示为空白。 */
        NSArray *pins=TIOOTACandidate()[@"payloadPins"];
        NSUInteger expected=[pins isKindOfClass:NSArray.class]&&pins.count>1?pins.count-1:0;
        id manifest=[NSJSONSerialization JSONObjectWithData:files[@"OtaFileInfo.json"] options:0 error:error];
        if(![manifest isKindOfClass:NSArray.class]||!expected||[manifest count]!=expected){
            NSString *actual=@"非清单结构";
            if([manifest isKindOfClass:NSArray.class])actual=[NSString stringWithFormat:@"%lu 项",(unsigned long)[manifest count]];
            Error(error,[NSString stringWithFormat:@"官方解压目录清单负载数不符：候选要求 %lu 项，实际 %@。未授权。",(unsigned long)expected,actual]);return NO;}
        _files=files;_manifest=manifest;_device=[device copy];_deadline=now+900;_stage=1;_failure=nil;return YES;
    }
}
// 官方直连路线的逐片截获：收齐一个负载（按清单 Size 判定）即写入
// Documents/official-capture/（house_arrest/爱思可导出），供 TAP3 基座重建。
- (void)captureFlush{
    if(!_captureFiles)return;
    NSString *dir=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/official-capture"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary *sizes=[NSMutableDictionary new];for(NSDictionary *row in _captureSizes)if([row isKindOfClass:NSDictionary.class])sizes[row[@"Name"]]=row[@"Size"];
    for(NSString *name in _captureFiles){
        NSMutableData *buf=_captureFiles[name];id want=sizes[name];
        if(want&&[want unsignedLongLongValue]!=(unsigned long long)buf.length)continue;
        [buf writeToFile:[dir stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:nil];
    }
    if(_captureSizes){NSData *manifest=[NSJSONSerialization dataWithJSONObject:_captureSizes options:NSJSONWritingPrettyPrinted error:nil];if(manifest.length)[manifest writeToFile:[dir stringByAppendingPathComponent:@"OtaFileInfo.json"] options:NSDataWritingAtomic error:nil];}
}
- (BOOL)allows:(NSData *)payload device:(NSString *)device uptime:(NSTimeInterval)now{
    @synchronized(self){
        NSDictionary *f=TIOOTAFrame(payload);NSUInteger t=[f[@"type"] unsignedIntegerValue];id j=f[@"json"];NSData *binary=f[@"binary"];
        BOOL dict=[j isKindOfClass:NSDictionary.class],empty=dict&&[j count]==0&&!binary.length;
        // 1 = OS version, 2 = battery. Idle is 11, NOT 2: official 1.0.5
        // failure recovery sent msgType=11 on 2026-09-21 at 17:38:03.477.
        // Allow its empty read even after a blocked start so the official
        // recovery loop can establish that no glasses transfer is active.
        if((t==1||t==2||t==11)&&empty)return YES;
        NSUInteger n=0;
        if(t==3&&dict&&[j count]==1&&Number(j[@"OtaSize"],&n)&&TIOOTACandidate()&&n==(NSUInteger)[TIOOTACandidate()[@"otaSize"] unsignedLongLongValue]&&!binary.length)return YES;
        if(!_stage){
            /* 2026-10-30 官方直连路线：未武装时放行官方固件流量并逐片截获到
             * Documents/official-capture/（TAP3 新基座原料）。自动更新强制关闭
             * 仍是红线；手动「开始安装」是用户显式决定。武装后（我方试刷）行为
             * 不变，仍按候选清单严格校验。 */
            if(t==4){_captureFiles=[NSMutableDictionary new];_captureSizes=nil;_captureCount=0;_captureBytes=0;return YES;}
            if(t==5)return YES;
            if(t==6){
                if([j isKindOfClass:NSArray.class]){NSMutableArray *sizes=[NSMutableArray new];for(id row in j){NSUInteger rowSize=0;if([row isKindOfClass:NSDictionary.class]&&[row[@"Name"] isKindOfClass:NSString.class]&&Number(row[@"Size"],&rowSize))[sizes addObject:@{@"Name":row[@"Name"],@"Size":row[@"Size"]}];}_captureSizes=[sizes copy];[self captureFlush];}
                return YES;}
            if(t==7){
                NSString *name=dict?j[@"Name"]:nil;NSUInteger start=0,size=0;
                if(![name isKindOfClass:NSString.class]||!name.length||name.length>128||[name rangeOfString:@"/"].location!=NSNotFound||[name rangeOfString:@".."].location!=NSNotFound||!Number(j[@"Start"],&start)||!Number(j[@"Size"],&size)||!size||size>51200||binary.length!=size)return NO;
                if(!_captureFiles)_captureFiles=[NSMutableDictionary new];
                NSMutableData *buf=_captureFiles[name];if(!buf){buf=[NSMutableData data];_captureFiles[name]=buf;}
                if(buf.length<start)[buf increaseLengthBy:start-buf.length];
                if(buf.length==start)[buf appendData:binary];
                else if(start+size<=buf.length)[buf replaceBytesInRange:NSMakeRange(start,size) withBytes:binary.bytes];
                else return NO;
                _captureCount++;_captureBytes+=size;[self captureFlush];return YES;}
            return YES;
        }
        if(_stage==3||!isfinite(now)||now<0)return NO;
        if(_stage==1&&now>=_deadline){[self cancel];return NO;}
        BOOL ok=[device isEqual:_device];
        if(t==4)ok=ok&&_stage==1&&dict&&[j count]==1&&Number(j[@"Mode"],&n)&&n==2&&!binary.length;
        else if(t==5)ok=ok&&_stage==2&&dict&&TIOOTACandidate()&&[j isEqual:@{@"OtaVersion":TIOOTACandidate()[@"baseVersion"]}]&&!binary.length;
        else if(t==6)ok=ok&&_stage==2&&_versionSent&&[j isKindOfClass:NSArray.class]&&[j isEqual:_manifest]&&!binary.length;
        else if(t==7){
            NSUInteger start=0,size=0;NSString *name=dict?j[@"Name"]:nil;NSData *file=[name isKindOfClass:NSString.class]?_files[name]:nil;
            ok=ok&&_stage==2&&_manifestSent&&dict&&[j count]==3&&file&&![name isEqual:@"OtaFileInfo.json"]&&Number(j[@"Start"],&start)&&Number(j[@"Size"],&size)&&size>0&&size<=51200&&start<file.length&&size<=file.length-start&&binary.length==size;
            if(ok)ok=memcmp(binary.bytes,(const uint8_t *)file.bytes+start,size)==0;
            if(ok){_slices++;_bytes+=size;}
        }else ok=NO;
        if(!ok){_failure=@"非预期设备、会话、清单或分片，发送被拒绝";if(_stage==2)_stage=3;return NO;}
        if(t==4)_stage=2;if(t==5)_versionSent=YES;if(t==6)_manifestSent=YES;_lastActivity=now;return YES;
    }
}
- (BOOL)cancel{@synchronized(self){if(_stage>=2)return NO;_stage=0;_files=nil;_manifest=nil;_device=nil;_deadline=0;return YES;}}
- (NSDictionary *)status{@synchronized(self){NSTimeInterval realNow=NSProcessInfo.processInfo.systemUptime;
        if(_stage==1&&isfinite(_deadline)&&realNow>=_deadline)[self cancel];
        /* stage 2 到期收尾必须同时要求 120 秒无帧：17MB 全量在低速链路上可超
         * 900 秒，仅凭到期就毒化会杀死仍在健康传输中的安装（2026-10-31）。 */
        else if(_stage==2&&isfinite(_deadline)&&realNow>=_deadline&&isfinite(_lastActivity)&&realNow-_lastActivity>120){_stage=3;_failure=[_failure length]?_failure:@"会话超时自动收尾";}
        BOOL dead=_stage>=2&&DeadSession(_stage,_lastActivity,_deadline,realNow);
        return @{@"stage":@(_stage),@"authorized":@(_stage==1||_stage==2),@"started":@(_stage>=2),@"versionMatched":@(_versionSent),@"manifestMatched":@(_manifestSent),@"validatedSlices":@(_slices),@"validatedSliceBytes":@(_bytes),@"lastActivity":@(_lastActivity),@"captureFiles":@(_captureFiles.count),@"captureBytes":@(_captureBytes),@"failure":_failure?:@"",@"dead":@(dead),@"runtimeValidated":@NO};}}
@end
BOOL TIOOTAFlashBuild(void){
#if TARGET_OS_IPHONE && TIO_OTA_FLASH_ENABLED
#if TIO_DISPLAY_FLASH
    // Compiled experimental builds must stay gated even if Info.plist is stale.
    // Authorization/feed still require the exact marker below.
    return YES;
#else
    // 打包脚本按宿主底座写 ios105-/ios107-/ios1010- 前缀（补丁脚本 report.edition），
    // 门禁接受三代标记，后缀不变；其他值仍一律拒绝。
    return [@[@"ios105-tfp1-loopback-flash-gated",@"ios107-tfp1-loopback-flash-gated",@"ios1010-tfp1-loopback-flash-gated"] containsObject:[NSBundle.mainBundle objectForInfoDictionaryKey:@"TIOExperimentalOTAQueryRouting"]];
#endif
#else
    return NO;
#endif
}
static TIOOTAFlashGate *Gate;static NSString *ObservedDevice;static NSTimeInterval ObservedAt;
BOOL TIOOTAAutoUpdateDisabled(NSDictionary *preferences){
    if(![preferences isKindOfClass:NSDictionary.class])return NO;
    NSUInteger found=0;
    for(id key in preferences){if(![key isKindOfClass:NSString.class]||![key hasSuffix:@"_ota_firmware_auto_update"])continue;found++;
        id v=preferences[key];if([v isKindOfClass:NSString.class]){if(![v isEqual:@"false"])return NO;}
        else if(![v isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)v)!=CFBooleanGetTypeID()||[v boolValue])return NO;
    }
    return found>0;
}
static TIOOTAFlashGate *Current(void){@synchronized(NSProcessInfo.processInfo){if(!Gate)Gate=[TIOOTAFlashGate new];return Gate;}}
BOOL TIOOTAFlashProtected(void){
#if TARGET_OS_IPHONE && TIO_DISPLAY_FLASH
    if(![@[@"ios105-tfp1-loopback-flash-gated",@"ios107-tfp1-loopback-flash-gated",@"ios1010-tfp1-loopback-flash-gated"] containsObject:[NSBundle.mainBundle objectForInfoDictionaryKey:@"TIOExperimentalOTAQueryRouting"]])return NO;
#endif
    return TIOOTAFlashBuild()&&[TIOOTAGuardStatus()[@"transportHookReady"] boolValue];
}
void TIOOTAFlashDisableAutoUpdateIfRequested(void){
    if(!TIOOTAFlashProtected()||![NSProcessInfo.processInfo.environment[@"TIO_OTA_DISABLE_AUTO_ONCE"] isEqual:@"DISABLE_FOR_PRIVATE_TFP1"])return;
    NSUserDefaults *p=NSUserDefaults.standardUserDefaults;NSMutableArray *keys=[NSMutableArray new];
    for(NSString *key in p.dictionaryRepresentation)if([key hasSuffix:@"_ota_firmware_auto_update"])[keys addObject:key];
    // Do not guess between accounts. The private pre-install preference backup
    // preserves the old value; no account identifiers are written to reports.
    if(keys.count!=1)return;id v=[p objectForKey:keys[0]];
    if([v isKindOfClass:NSString.class]&&([v isEqual:@"true"]||[v isEqual:@"false"]))[p setObject:@"false" forKey:keys[0]];
    else if([v isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)v)==CFBooleanGetTypeID())[p setBool:NO forKey:keys[0]];
    [p synchronize];
}
// Second layer of the update-check silence (see TIOOTAUpdateCheckBlockCall):
// force the official "firmware auto-update" switch off, so a version cached
// before the block existed cannot trigger a background download or prompt.
// 2026-10-29 解耦：自动更新强制关闭是刷机红线保护，与版本改写开关无关，
// 启动时无条件执行（版本改写默认改关后仍保护 TAP2 不被官方固件覆盖）。
void TIOOTAAutoUpdateDisableForSilence(void){
    NSUserDefaults *p=NSUserDefaults.standardUserDefaults;NSMutableArray *keys=[NSMutableArray new];
    for(NSString *key in p.dictionaryRepresentation)if([key hasSuffix:@"_ota_firmware_auto_update"])[keys addObject:key];
    if(keys.count>1)return;id v=keys.count?[p objectForKey:keys[0]]:nil;
    if([v isKindOfClass:NSString.class]&&[v isEqual:@"true"])[p setObject:@"false" forKey:keys[0]];
    else if([v isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)v)==CFBooleanGetTypeID()&&[v boolValue])[p setBool:NO forKey:keys[0]];
    else if(!v)[p setBool:NO forKey:@"ota_firmware_auto_update"]; /* 键从未落盘（官方页显示的"关"只是缺省值，重装即丢）：补一条显式关闭记录，试刷前置检查才读得到 */
    else return;
    [p synchronize];
}
static id Get(id obj,NSString *key){@try{return [obj valueForKey:key];}@catch(NSException *e){return nil;}}
BOOL TIOOTAFlashBlockCall(id call){
    if(!TIOOTAFlashBuild())return NO;
    NSString *method=Get(call,@"method");NSDictionary *args=Get(call,@"arguments");
    if(![method isKindOfClass:NSString.class])return YES;
    if([method.lowercaseString containsString:@"disconnect"]||[method.lowercaseString containsString:@"unbind"]||[method.lowercaseString containsString:@"unpair"]){@synchronized(NSProcessInfo.processInfo){ObservedDevice=nil;ObservedAt=0;}[Current() cancel];}
    if([method isEqual:@"rayneonet_sendMessage"]){
        NSUInteger business=0;if(![args isKindOfClass:NSDictionary.class]||!Number(args[@"businessId"],&business))return YES;
        if(business!=9)return NO;
        id data=args[@"payload"];if(![data isKindOfClass:NSData.class])data=Get(data,@"data");
#if TIO_DISPLAY_PHONE && !TIO_DISPLAY_FLASH
        // Phone-only test package: no OTA mutation, even if an old gate was armed.
        return !TIOPhoneOTAReadAllowed(data);
#endif
        return ![Current() allows:data device:args[@"deviceId"] uptime:NSProcessInfo.processInfo.systemUptime];
    }
    // The pinned files path uses business 9 frames, never sendFile / ZIP mode.
    BOOL scopedImage=NO;
#if TIO_APP_SDK
    scopedImage=TAPIsScopedCall(method,args);
#endif
#if TIO_IMAGE_RX_LAB
    scopedImage=scopedImage||TIOImageUploadIsScopedCall(method,args);
#if TIO_DISPLAY_PHONE
    scopedImage=scopedImage||TDPPhoneIsScopedCall(method,args);
#if TIO_NATIVE_NAV
    scopedImage=scopedImage||TNVIsScopedCall(method,args)||TMIsScopedCall(method,args)||TWIsScopedCall(method,args)||TFIsScopedCall(method,args)||TDIsScopedCall(method,args);
#endif
#endif
#endif
    return TIOOTAFileCallBlocked(method,scopedImage,[[Current() status][@"stage"] unsignedIntegerValue]);
}
void TIOOTAFlashObserveEvent(NSDictionary *event){
    if(!TIOOTAFlashBuild()||![event[@"eventType"] isEqual:@"messageReceived"])return;
    NSDictionary *m=event[@"message"];NSUInteger business=0;if(![m isKindOfClass:NSDictionary.class]||!Number(m[@"businessId"],&business)||business!=9)return;
    NSDictionary *f=TIOOTAFrame(m[@"payload"]);id j=f[@"json"];
    if([f[@"type"] isEqual:@1]){@synchronized(NSProcessInfo.processInfo){ObservedDevice=nil;ObservedAt=0;}}
    if([f[@"type"] isEqual:@1]&&[j isKindOfClass:NSDictionary.class]&&TIOOTAAcceptsReadback(j[@"OsVersion"])&&[j[@"OtaValidationConfirmed"] isEqual:@YES]&&[m[@"deviceId"] isKindOfClass:NSString.class]){
        @synchronized(NSProcessInfo.processInfo){ObservedDevice=[m[@"deviceId"] copy];ObservedAt=NSProcessInfo.processInfo.systemUptime;}
    }
}
BOOL TIOOTAFlashAuthorize(NSError **error){
    if(!TIOOTAFlashProtected()){Error(error,@"没有试刷构建与发送保护；未开放。");return NO;}
#if TARGET_OS_IPHONE && TIO_DISPLAY_FLASH
    if(!TDPPhonePauseForOTA()){Error(error,@"显示文件仍在传输或结果未知，请等待终态；未开放升级。若任务无法收尾，先退出显示页并重启 App 重新检查。");return NO;}
#endif
    if(!TIOOTAAutoUpdateDisabled(NSUserDefaults.standardUserDefaults.dictionaryRepresentation)){Error(error,@"请先在官方眼镜软件版本页关闭自动更新；未读到明确关闭状态，不授予试刷权限。");return NO;}
    NSString *device;NSTimeInterval at;@synchronized(NSProcessInfo.processInfo){device=ObservedDevice;at=ObservedAt;}
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    if(!device.length||now-at>120){Error(error,[NSString stringWithFormat:@"请先从官方固件页重新检查版本；需要两分钟内对 %@ 的有效回读。",TIOOTACandidate()[@"baseVersion"]?:@"候选底座版本"]);return NO;}
    NSURL *dir=[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Application Support/ota/%@",TIOOTAOfficialDirectoryName()]] isDirectory:YES];
    return [Current() prepareDirectory:dir device:device uptime:now error:error];
}
BOOL TIOOTAFlashCancel(void){return [Current() cancel];}
NSDictionary *TIOOTAFlashStatus(void){NSMutableDictionary *s=[[Current() status] mutableCopy];s[@"flashBuild"]=@(TIOOTAFlashBuild());s[@"automaticUpdateDisabled"]=@(TIOOTAAutoUpdateDisabled(NSUserDefaults.standardUserDefaults.dictionaryRepresentation));@synchronized(NSProcessInfo.processInfo){s[@"recentTargetVersionRead"]=@(ObservedDevice.length&&NSProcessInfo.processInfo.systemUptime-ObservedAt<=120);s[@"stageTwoFileCalls"]=@(StageTwoFileCalls);s[@"lastStageTwoFileCall"]=LastStageTwoFileCall;}return s;}
