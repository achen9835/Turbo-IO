#import "ExperimentalOTAFeed.h"
#import "ExperimentalOTAFlash.h"
#import "ExperimentalOTA.h"
#import "ExperimentalOTAGuard.h"
#import <TargetConditionals.h>
#import <CommonCrypto/CommonDigest.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

#ifndef TIO_OTA_FEED_ARMING_ENABLED
#define TIO_OTA_FEED_ARMING_ENABLED 0
#endif
static NSError *FeedError(NSString *message){return [NSError errorWithDomain:@"TurboIO.OTAFeed" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];}
static NSArray<NSString *> *QueryPaths(void){return @[@"/g/xxxxxxxA78p2M",@"/g/xxxxxxxxxxCCXhB"];}
static NSString *QueryKind(NSString *target){
    NSURLComponents *u=[NSURLComponents componentsWithString:[@"http://127.0.0.1" stringByAppendingString:[target stringByReplacingOccurrencesOfString:@"+" withString:@"%20"]]];
    NSMutableDictionary *params=[NSMutableDictionary new];
    for(NSURLQueryItem *item in u.queryItems){if(params[item.name])return @"invalid";params[item.name]=item.value?:@"";}
    // 版本码不钉死：查询携带的是眼镜当前版本（TAP1=01.00.04.0012 / TAP2=01.00.05.x），
    // 钉死旧码会让 1.0.5.5 系眼镜的更新查询落 unknown → 官方页回「已是最新」。
    if([params[@"packageType"] isEqual:@"firmware"]&&[params[@"packageName"] isEqual:@"strix OS"]&&[params[@"glassesType"] isEqual:@"S3"]&&[params[@"deviceType"] isEqual:@"iOS"])return @"firmware";
    if([params[@"packageType"] isEqual:@"app"])return @"app";
    return @"unknown";
}
static BOOL SendAll(int fd,NSData *data){const uint8_t *p=data.bytes;NSUInteger n=data.length;while(n){ssize_t k=send(fd,p,MIN(n,65536),0);if(k<0&&errno==EINTR)continue;if(k<=0)return NO;p+=k;n-=(NSUInteger)k;}return YES;}
static void Reply(int fd,NSInteger status,NSData *body,NSString *mime,NSDictionary *extra,BOOL head){
    NSMutableString *h=[NSMutableString stringWithFormat:@"HTTP/1.1 %ld %@\r\nContent-Length: %lu\r\nContent-Type: %@\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n",(long)status,status==200?@"OK":status==206?@"Partial Content":@"Rejected",(unsigned long)body.length,mime];
    for(NSString *key in extra)[h appendFormat:@"%@: %@\r\n",key,extra[key]];
    [h appendString:@"\r\n"];if(SendAll(fd,[h dataUsingEncoding:NSUTF8StringEncoding])&&!head)SendAll(fd,body);
}
// 候选元数据从内嵌候选描述派生（TAP1: Strix OS 1.0.4.12 / TAP2: Strix OS 1.0.5.5），
// 不再硬编码——官方 App 按这些字段判定「可升级」并命名下载/解压目录。
static NSString *OTAZipName(void){
    NSString *base=[TIOOTACandidate()[@"baseVersion"] stringByReplacingOccurrencesOfString:@"Strix OS " withString:@""];
    return [NSString stringWithFormat:@"Strix_OS_%@.zip",base.length?base:@"1.0.4.12"];
}
static NSString *OTAVersionName(void){ /* "1.0.4.12" -> "0100040012" */
    NSString *base=[TIOOTACandidate()[@"baseVersion"] stringByReplacingOccurrencesOfString:@"Strix OS " withString:@""];
    NSArray *parts=[base componentsSeparatedByString:@"."];NSMutableString *out=[NSMutableString string];
    for(NSUInteger i=0;i<4;i++){NSString *p=i<parts.count?parts[i]:@"0";int v=p.integerValue;[out appendFormat:i==3?@"%04d":@"%02d",v];}
    return out;
}
static long OTAVersionCode(void){return OTAVersionName().longLongValue;} /* "0100040012" -> 100040012 */
static long QueryVersionCode(NSString *target){ /* 查询携带的眼镜当前版本码（01.00.04.0012 -> 100040012） */
    NSURLComponents *u=[NSURLComponents componentsWithString:[@"http://127.0.0.1" stringByAppendingString:[target stringByReplacingOccurrencesOfString:@"+" withString:@"%20"]]];
    for(NSURLQueryItem *item in u.queryItems)if([item.name isEqual:@"versionCode"]&&item.value.length<24)return item.value.longLongValue;
    return 0;
}
/* 服务版本严格高于眼镜当前版本：同基座（TAP2 重刷 TAP2）也要出更新卡。 */
static long OTAServedVersionCode(NSString *target){
    long natural=OTAVersionCode(),current=QueryVersionCode(target);
    return natural>current?natural:current+1;
}
static NSString *OTAServedVersionName(NSString *target){return [NSString stringWithFormat:@"%010ld",OTAServedVersionCode(target)];}
@implementation TIOExperimentalOTAFeed {
    dispatch_queue_t _queue;
    dispatch_source_t _listener;
    uint16_t _port;
    NSData *_archive;
    NSString *_token, *_md5;
    NSTimeInterval _deadline;
    NSUInteger _queries, _downloads, _rejected;
    NSUInteger _firmwareQueries, _appQueries, _unknownQueries;
}
- (instancetype)init{if((self=[super init]))_queue=dispatch_queue_create("io.turboio.ota.loopback",DISPATCH_QUEUE_SERIAL);return self;}
- (uint16_t)port{@synchronized(self){return _port;}}
- (BOOL)startOnPort:(uint16_t)port error:(NSError **)error{
    @synchronized(self){
        if(_listener){if(error)*error=FeedError(@"本机服务已启动，未替换监听器。");return NO;}
        int fd=socket(AF_INET,SOCK_STREAM,0);if(fd<0){if(error)*error=FeedError(@"创建本机监听器失败。");return NO;}
        struct sockaddr_in addr={0};addr.sin_len=sizeof(addr);addr.sin_family=AF_INET;addr.sin_port=htons(port);addr.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
        // No SO_REUSEPORT: never share the endpoint with another process.
        if(bind(fd,(struct sockaddr *)&addr,sizeof(addr))||listen(fd,4)||fcntl(fd,F_SETFL,O_NONBLOCK)<0){close(fd);if(error)*error=FeedError(@"绑定本机端口失败；未改用其他地址或远程服务。");return NO;}
        socklen_t size=sizeof(addr);if(getsockname(fd,(struct sockaddr *)&addr,&size)){close(fd);return NO;}
        _port=ntohs(addr.sin_port);_listener=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,fd,0,_queue);
        __weak typeof(self) weakSelf=self;
        dispatch_source_set_event_handler(_listener,^{
            struct sockaddr_in peer={0};socklen_t count=sizeof(peer);int client=accept(fd,(struct sockaddr *)&peer,&count);if(client<0)return;
            @autoreleasepool{int one=1;setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
                struct timeval timeout={2,0};setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));setsockopt(client,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
                fcntl(client,F_SETFL,fcntl(client,F_GETFL)&~O_NONBLOCK);
                if(peer.sin_addr.s_addr==htonl(INADDR_LOOPBACK))[weakSelf handleClient:client];
                close(client);
            }
        });
        dispatch_source_set_cancel_handler(_listener,^{close(fd);});dispatch_resume(_listener);return YES;
    }
}
- (BOOL)armArchive:(NSURL *)url lifetime:(NSTimeInterval)seconds error:(NSError **)error{
#if !TIO_OTA_FEED_ARMING_ENABLED
    (void)url;(void)seconds;if(error)*error=FeedError(@"刷机门禁尚未开放：需先验收官方入口与同版本缓存。");return NO;
#else
    // 私用放宽（2026-10-14 用户决策）：上游「武装仅限官方包名宿主」的分发红线
    // 已移除——固件完整性由候选 SHA pin、原厂 AP 指纹、分片逐项核对独立保证，
    // 与宿主包名无关；自定义包名本机构建同样允许武装，仅限自刷自验。
#if TARGET_OS_IPHONE
    if(!TIOOTAPreparationProtected()&&!TIOOTAFlashProtected()){if(error)*error=FeedError(@"未确认发送保护，拒绝提供实验包。");return NO;}
#endif
    if(!isfinite(seconds)||seconds<=0||seconds>900){if(error)*error=FeedError(@"授权有效期必须在 0 至 900 秒之间。");return NO;}
    if(!TIOReadExperimentalOTA(url,error))return NO;
    // Keep the verified exact bytes, so a later disk change cannot alter a reply.
    NSData *data=[NSData dataWithContentsOfURL:url options:0 error:error];
    if(!data||!TIOCheckExperimentalOTA(data,error))return NO;
    unsigned char bytes[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5(data.bytes,(CC_LONG)data.length,bytes);
#pragma clang diagnostic pop
    NSMutableString *digest=[NSMutableString new];for(NSUInteger i=0;i<sizeof(bytes);i++)[digest appendFormat:@"%02x",bytes[i]];
    @synchronized(self){if(!_listener){if(error)*error=FeedError(@"本机服务未启动。");return NO;}
        _archive=data;_md5=digest;_token=[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
        _deadline=NSProcessInfo.processInfo.systemUptime+seconds;return YES;}
#endif
}
- (void)expireLocked{if(_archive&&NSProcessInfo.processInfo.systemUptime>=_deadline){_archive=nil;_token=nil;_md5=nil;_deadline=0;}}
- (void)disarm{@synchronized(self){_archive=nil;_token=nil;_md5=nil;_deadline=0;}}
- (void)stop{@synchronized(self){[self disarm];if(_listener){dispatch_source_cancel(_listener);_listener=nil;}_port=0;}}
- (void)dealloc{if(_listener)dispatch_source_cancel(_listener);}
- (NSDictionary *)status{@synchronized(self){[self expireLocked];return @{@"running":@(_listener!=nil),@"port":@(_port),@"armed":@(_archive!=nil),@"queryCount":@(_queries),@"firmwareQueries":@(_firmwareQueries),@"appQueries":@(_appQueries),@"unknownQueries":@(_unknownQueries),@"downloadRequests":@(_downloads),@"rejectedCount":@(_rejected),@"armingCompiledIn":@(TIO_OTA_FEED_ARMING_ENABLED),@"runtimeValidated":@NO};}}
- (void)handleClient:(int)fd{
    // Headers and query may contain account/device identifiers. Never log or persist them.
    NSMutableData *request=[NSMutableData new];NSData *end=[@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];NSTimeInterval until=NSProcessInfo.processInfo.systemUptime+2;
    while(request.length<16384&&NSProcessInfo.processInfo.systemUptime<until){uint8_t bytes[2048];ssize_t n=recv(fd,bytes,MIN(sizeof(bytes),16384-request.length),0);if(n<=0)break;[request appendBytes:bytes length:(NSUInteger)n];if([request rangeOfData:end options:0 range:NSMakeRange(0,request.length)].location!=NSNotFound)break;}
    NSString *text=[[NSString alloc]initWithData:request encoding:NSUTF8StringEncoding];NSRange terminator=[text rangeOfString:@"\r\n\r\n"];
    NSArray *lines=text&&terminator.location!=NSNotFound?[[text substringToIndex:terminator.location] componentsSeparatedByString:@"\r\n"]:@[];
    NSArray *first=lines.count?[lines[0] componentsSeparatedByString:@" "]:@[];
    NSMutableDictionary *headers=[NSMutableDictionary new];BOOL valid=first.count==3&&[first[2] isEqual:@"HTTP/1.1"];
    for(NSUInteger i=1;i<lines.count;i++){NSString *line=lines[i];NSRange colon=[line rangeOfString:@":"];if(colon.location==NSNotFound||colon.location==0){valid=NO;break;}NSString *name=[[line substringToIndex:colon.location] lowercaseString];if(headers[name])valid=NO;headers[name]=[[line substringFromIndex:colon.location+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];}
    NSString *method=first.count?first[0]:@"",*target=first.count>1?first[1]:@"";
    BOOL head=[method isEqual:@"HEAD"];
    NSDictionary *response=nil;NSData *body=nil;NSString *mime=@"application/json";NSInteger code=200;NSDictionary *extra=@{};
    @synchronized(self){[self expireLocked];
        if(!valid||![headers[@"host"] isEqual:[NSString stringWithFormat:@"127.0.0.1:%u",_port]]||headers[@"transfer-encoding"]||(headers[@"content-length"]&&![headers[@"content-length"] isEqual:@"0"]))code=400;
        else if(![method isEqual:@"GET"]&&!head)code=405;
        else if([QueryPaths() containsObject:[[target componentsSeparatedByString:@"?"] firstObject]]){
            _queries++;id data=NSNull.null;
            NSString *kind=QueryKind(target);if([kind isEqual:@"firmware"])_firmwareQueries++;else if([kind isEqual:@"app"])_appQueries++;else _unknownQueries++;
            if(_archive&&[kind isEqual:@"firmware"]){
                NSDictionary *c=TIOOTACandidate();unsigned pins=[c[@"payloadPins"] isKindOfClass:NSArray.class]?[c[@"payloadPins"] count]:0;
                data=@{@"taskName":[NSString stringWithFormat:@"%@ PRIVATE EXPERIMENT",c[@"codeName"]?:@"TURBO"],@"appName":@"Strix OS",@"packageName":@"Strix OS",@"versionName":OTAServedVersionName(target),@"versionCode":@(OTAServedVersionCode(target)),@"upgradeType":@1,@"userScope":@0,@"updateDesc":[NSString stringWithFormat:@"PRIVATE EXPERIMENT %@: AP modified, other %u payloads byte-identical to %@. Runtime unverified.",c[@"codeName"]?:@"",pins>0?pins-2:0,c[@"baseVersion"]?:@""],@"appIcon":@"",@"apkSize":@(_archive.length),@"apkMd5":_md5,@"downloadUrl":[NSString stringWithFormat:@"http://127.0.0.1:%u/p/%@/%@",_port,_token,OTAZipName()]};
            }
            response=@{@"error_code":@1000,@"error_msg":@"success",@"data":data};
        }else if(_archive&&[target isEqual:[NSString stringWithFormat:@"/p/%@/%@",_token,OTAZipName()]]){
            body=_archive;mime=@"application/zip";extra=@{@"Accept-Ranges":@"bytes"};
            NSString *range=headers[@"range"];
            if(range){
                NSRegularExpression *regex=[NSRegularExpression regularExpressionWithPattern:@"^bytes=([0-9]{1,10})-([0-9]{0,10})$" options:0 error:nil];NSTextCheckingResult *match=[regex firstMatchInString:range options:0 range:NSMakeRange(0,range.length)];
                if(!match)code=416;
                else{NSUInteger from=[[range substringWithRange:[match rangeAtIndex:1]] longLongValue];NSString *last=[range substringWithRange:[match rangeAtIndex:2]];NSUInteger to=last.length?(NSUInteger)last.longLongValue:body.length-1;
                    if(from>=body.length||to<from)code=416;
                    else{to=MIN(to,body.length-1);extra=@{@"Accept-Ranges":@"bytes",@"Content-Range":[NSString stringWithFormat:@"bytes %lu-%lu/%lu",(unsigned long)from,(unsigned long)to,(unsigned long)body.length]};body=[body subdataWithRange:NSMakeRange(from,to-from+1)];code=206;}
                }
                if(code==416)extra=@{@"Content-Range":[NSString stringWithFormat:@"bytes */%lu",(unsigned long)_archive.length]};
            }
            if(code<300)_downloads++;
        }else code=404;
        if(code>=400){_rejected++;body=[NSData data];}
    }
    if(response)body=[NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
    Reply(fd,code,body?:[NSData data],mime,extra,head);
    TIORefreshExperimentalOTAReport();
}
@end

static TIOExperimentalOTAFeed *SharedFeed;
static NSString *BootstrapFailure;
NSDictionary *TIOExperimentalOTAFeedStatus(void){
    return SharedFeed.status?:@{@"running":@NO,@"armed":@NO,@"armingCompiledIn":@NO,@"reason":BootstrapFailure?:@"当前不是实验升级来源包"};
}
BOOL TIOBeginExperimentalOTAPreparation(NSError **error){
    if(!TIOOTAPreparationProtected()&&!TIOOTAFlashProtected()){if(error)*error=FeedError(@"此包没有启用发送保护；未开放下载。");return NO;}
    NSURL *directory=[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TurboIOPrivateAddon/ExperimentalOTA"] isDirectory:YES];
    NSURL *archive=[directory URLByAppendingPathComponent:[TIOExperimentalOTASHA() stringByAppendingString:@".zip"]];
    if(!TIOImportExperimentalOTA(archive,directory,error))return NO;
    BOOL ok=SharedFeed&&[SharedFeed armArchive:archive lifetime:900 error:error];TIORefreshExperimentalOTAReport();return ok;
}
void TIOCancelExperimentalOTAPreparation(void){[SharedFeed disarm];TIORefreshExperimentalOTAReport();}
void TIORefreshExperimentalOTAReport(void){
#if TARGET_OS_IPHONE
    if(!SharedFeed)return;
    static BOOL pending;@synchronized(NSProcessInfo.processInfo){if(pending)return;pending=YES;}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
        NSURL *directory=[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TurboIOPrivateAddon/ExperimentalOTA"] isDirectory:YES];
        NSFileManager *fm=NSFileManager.defaultManager;NSError *error=nil;
        if([fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]&&[directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&error]){
            NSMutableDictionary *report=[@{@"build":@"OTA-PREPARE-02",@"timestamp":@(NSDate.date.timeIntervalSince1970),@"feed":TIOExperimentalOTAFeedStatus(),@"guard":TIOOTAGuardStatus(),@"flashAuthorized":@NO,@"transferSessionBound":@NO} mutableCopy];
            if(TIOOTAFlashBuild()){report[@"build"]=@"DIAGNOSTICS-OTA-01";report[@"flashGate"]=TIOOTAFlashStatus();report[@"flashAuthorized"]=report[@"flashGate"][@"authorized"];}
            NSURL *zip=[directory URLByAppendingPathComponent:[TIOExperimentalOTASHA() stringByAppendingString:@".zip"]];error=nil;
            report[@"archive"]=TIOReadExperimentalOTA(zip,&error)?:@{@"integrityPassed":@NO};
            NSURL *official=[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Application Support/ota/%@",TIOOTAOfficialDirectoryName()]] isDirectory:YES];error=nil;
            report[@"officialDirectory"]=TIOCheckExperimentalOTADirectory(official,&error)?:@{@"integrityPassed":@NO,@"note":error.localizedDescription?:@"尚未读取"};
            NSURL *file=[directory URLByAppendingPathComponent:@"preparation-status.json"];
            NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
            [data writeToURL:file options:NSDataWritingAtomic|NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:nil];
            [fm setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:file.path error:nil];
        }
        @synchronized(NSProcessInfo.processInfo){pending=NO;}
    }});
#endif
}
void TIOStartExperimentalOTAFeedIfMarked(void){
    static dispatch_once_t once;
    dispatch_once(&once,^{
        NSBundle *bundle=NSBundle.mainBundle;
        // IKLAZ2 v2：URL 补丁随 focus 构建进入 merged 日常包（自定义 Bundle ID，
        // 且该构建 TIO_OTA_FEED_ARMING_ENABLED=1），更新检查会被打到本机回环端口
        // ——应答器必须常驻，否则官方把连接拒绝渲染成「软件更新检查失败」全屏页。
        // 610a993 曾按「刷机构建必须官方包名」设门，但日常包本身就是刷机宏构建，
        // 被该门挡死（真机无效）。改为：启动只要求宿主在已核对清单内且 App 内回环
        // 补丁字节在场（下方校验），未武装时对一切检查只回「无更新」；「官方包名」
        // 红线移入 armArchive——武装（提供固件）仅限官方宿主，红线保留未删。
        // 2026-10-26：新增 1.0.7/230 宿主（同口径：版本门禁+App 快照回环字节校验）。
        // 2026-10-29：新增 1.0.10/258 宿主（净化第三方砸壳，偏移 39880448/30866352）。
        NSString *version=[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        NSString *build=[bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
        BOOL is105=[version isEqual:@"1.0.5"]&&[build isEqual:@"201"];
        BOOL is107=[version isEqual:@"1.0.7"]&&[build isEqual:@"230"];
        BOOL is1010=[version isEqual:@"1.0.10"]&&[build isEqual:@"258"];
        if(!is105&&!is107&&!is1010){BootstrapFailure=@"实验升级来源的宿主版本不匹配";return;}
        // Read two fixed Dart string records (cached-hash + length + bytes, the
        // same record layout the packer wrote). Code signing is handled by
        // packaging; this check prevents starting a feed with an unpatched or
        // mismatched host. 1.0.7 的两条 gray/upgrade 路径字符串与 1.0.5 同文、
        // 同回环替换串（makeRoute 确定性同后缀），仅偏移不同；偏移/缓存哈希
        // 已在本机解出的 1.0.7 快照上逐字节核对，并与上游 ios107 审计互证。
        NSString *file=[bundle.bundlePath stringByAppendingPathComponent:@"Frameworks/App.framework/App"];
        NSFileHandle *handle=[NSFileHandle fileHandleForReadingAtPath:file];BOOL ok=handle!=nil;
        // 每项：偏移 / 回环替换串 / Dart 缓存哈希（u32，记录头 offset-12）
        NSArray *records=is105?@[@[@39310656,@352684455u,@"http://127.0.0.1:18794/g/xxxxxxxA78p2M"],@[@30324336,@555237387u,@"http://127.0.0.1:18794/g/xxxxxxxxxxCCXhB"]]
                               :is107?@[@[@41206352,@352684455u,@"http://127.0.0.1:18794/g/xxxxxxxA78p2M"],@[@32115728,@555237387u,@"http://127.0.0.1:18794/g/xxxxxxxxxxCCXhB"]]
                               :@[@[@39880448,@352684455u,@"http://127.0.0.1:18794/g/xxxxxxxA78p2M"],@[@30866352,@555237387u,@"http://127.0.0.1:18794/g/xxxxxxxxxxCCXhB"]];
        @try{for(NSArray *r in records){
                if(!ok)break;
                NSData *expected=[r[2] dataUsingEncoding:NSASCIIStringEncoding];
                [handle seekToFileOffset:[r[0] unsignedLongLongValue]-12];
                NSData *head=[handle readDataOfLength:12];
                if(head.length!=12){ok=NO;break;}
                uint32_t cachedHash;uint64_t wireLen;memcpy(&cachedHash,head.bytes,4);memcpy(&wireLen,(const uint8_t *)head.bytes+4,8);
                ok=cachedHash==[r[1] unsignedIntValue]&&wireLen==(uint64_t)expected.length*2;
                if(!ok)break;
                [handle seekToFileOffset:[r[0] unsignedLongLongValue]];
                ok=[[handle readDataOfLength:expected.length] isEqual:expected];
            }
        }@catch(NSException *exception){(void)exception;ok=NO;}@finally{[handle closeFile];}
        if(!ok){BootstrapFailure=@"实验升级查询路径不匹配，未启动服务";return;}
        NSError *error=nil;SharedFeed=[TIOExperimentalOTAFeed new];if(![SharedFeed startOnPort:18794 error:&error]){BootstrapFailure=error.localizedDescription;SharedFeed=nil;}
        TIORefreshExperimentalOTAReport();
        // Never arm on startup. Production armArchive is itself disabled.
    });
}
