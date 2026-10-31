#import "NativeNavigationUI.h"
#import "MusicPlayer.h"
#import "ReaderUI.h"
#import "ReaderBridge.h"
#import "NativeNavigation.h"
#import "NavigationUI.h"
#import "NavigationCore.h"
#import "TNVTransport.h"
#import "ProtocolContext.h"
#import "ExperimentalOTAFlash.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
static TNVSession *Session;static TNVTransport *Transport;static NSTimer *Timer;static NSString *Peer;static NSTimeInterval LastSave;
BOOL TNVAlways(void){NSUserDefaults *d=NSUserDefaults.standardUserDefaults;id v=[d objectForKey:@"TurboNavigationAlwaysOnV1"];return [v isKindOfClass:NSNumber.class]?[v boolValue]:YES;} // Default ON per product decision; the settings toggle still overrides.
void TNVSetAlways(BOOL value){[NSUserDefaults.standardUserDefaults setBool:value forKey:@"TurboNavigationAlwaysOnV1"];[Session setAlways:value];}
NSDictionary *TNVStatus(void){return Session.status?:@{@"active":@NO,@"busy":@NO,@"snapshots":@0,@"note":@"TNV1专用固件：手机开始导航后可自动打开眼镜页面"};}
BOOL TNVConsume(NSDictionary *e){if(Peer&&![Peer isEqual:TIOProtocolDevice()])[Session disconnect];return [Session consume:e];}
BOOL TNVPauseForOTA(void){return !Session.active&&!Session.busy;}
void TNVPump(void){
 if(Peer&&![Peer isEqual:TIOProtocolDevice()])[Session disconnect];
 [Session pump];
 NSDictionary *st=TNVStatus();
 // Fail/active transition breadcrumbs: a mid-run session death used to be invisible
 // (the lens just froze) until the user read the status note much later.
 static BOOL LastFailed=NO,LastActive=NO;BOOL failed=[st[@"failed"] boolValue],active=[st[@"active"] boolValue];
 if(failed&&!LastFailed){TIOVoiceNavTrace([NSString stringWithFormat:@"眼镜HUD会话中断：%@（自动重试上镜中）",st[@"note"]?:@"原因未知"]);TIONavDiagHUDEvent(@"会话中断",st[@"note"]);}
 if(active!=LastActive)TIONavDiagHUDEvent(active?@"会话激活":@"会话结束",st[@"note"]);
 LastFailed=failed;LastActive=active;
 NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;if(now-LastSave<1)return;LastSave=now;
 // 诊断：会话状态（active/note/lastEvent/acks/transients/mapDrops/tries/stopTries）+ 最近 HUD
 // 事件环形缓冲 + 当前语音阶段 + 退出补发计数。只放固定短语与眼镜会话自身 note，
 // 不含坐标、设备号、Key 或账号。
 NSDictionary *diag=TIONavDiagSnapshot();
 NSMutableDictionary *d=[st mutableCopy];
 d[@"build"]=@"NAVIGATION-PHONE-03-BG";d[@"physicalVerified"]=@NO;d[@"timestamp"]=@(NSDate.date.timeIntervalSince1970);d[@"appState"]=@(UIApplication.sharedApplication.applicationState);
 d[@"voiceStage"]=diag[@"voiceStage"]?:@"";d[@"hudEvents"]=diag[@"hudEvents"]?:@[];d[@"stopRetryAttempts"]=diag[@"stopRetryAttempts"]?:@0;d[@"stopRetryMax"]=diag[@"stopRetryMax"]?:@0;d[@"stopRetryPending"]=diag[@"stopRetryPending"]?:@NO;
 NSData *json=[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingSortedKeys error:nil];if(!json)return;
 // 双写：Library/Application Support 给扩展自身诊断页读；Documents/TurboIOResearch 走宿主
 // 已开的 UIFileSharingEnabled，用户可用爱思/文件App直接导出（Library 里的导不出来）。
 // 两处都 0700 目录 + 0600 文件。
 NSArray *targets=@[@[[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TurboIOPrivateAddon"],@0700],
                    @[[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/TurboIOResearch"],@0700]];
 for(NSArray *target in targets){
  NSString *dir=target[0];
  [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:target[1],NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];
  NSString *file=[dir stringByAppendingPathComponent:@"native-navigation-status.json"];
  [json writeToFile:file options:NSDataWritingAtomic error:nil];
  [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:file error:nil];
 }
}
// Last refusal reason from TNVStart's gates, surfaced in HUD breadcrumbs so a
// background rejection says WHICH door was closed instead of a generic NO.
static NSString *TNVRefusal=@"";
NSString *TNVRefusalReason(void){return TNVRefusal;}
void TNVSetRefusal(NSString *reason){TNVRefusal=[reason copy];}
BOOL TNVStart(NSDictionary *frame){
 NSCAssert(NSThread.isMainThread,@"main only");
 if(!TMMusicPauseForOTA()){TNVRefusal=@"音乐桥未就绪（playing/active/busy）";return NO;}
 if(!TWReaderPauseForOTA()){TNVRefusal=@"提词桥占线（已请求关闭，2秒后重试可自愈）";return NO;}
 if(Session.active||Session.busy){TNVRefusal=@"上一导航会话仍占用（active/busy）";return NO;}
 NSDictionary *flash=TIOOTAFlashStatus();NSUInteger flashStage=[flash[@"stage"] unsignedIntegerValue];
 // 只拦武装（1）与活跃传输（2 且 120 秒内有分片往来）窗口；3=已收尾/超时终态、
 // 0=无会话。刷完固件后 stage 粘 2 直到 15 分钟超时才落 3（01505d2 已知），
 // 一刀切拦 2 会把刷机后的导航堵死 15 分钟——按 99b1812 意图收窄到活跃窗口。
 BOOL flashActive=flashStage==1||(flashStage==2&&NSProcessInfo.processInfo.systemUptime-[flash[@"lastActivity"] doubleValue]<120);
 if(flashActive){TNVRefusal=@"实验OTA进行中";return NO;}
 NSString *device=TIOProtocolDevice();if(!device.length){TNVRefusal=@"设备号未知（协议缓存为空）";return NO;}
 TNScene scene;if(!TNVScene(frame,TNVAlways(),&scene)){TNVRefusal=@"转向帧无效（等待指引数据）";return NO;}
 TNVRefusal=@"";
 NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;uint64_t last=[[defaults objectForKey:@"TurboNavigationSessionCounterV1"] unsignedLongLongValue];
 uint64_t epoch=(uint64_t)MAX(1,NSDate.date.timeIntervalSince1970);uint64_t sid=MAX(last+1,epoch);if(sid>UINT32_MAX)return NO;
 [defaults setObject:@(sid) forKey:@"TurboNavigationSessionCounterV1"];if(![defaults synchronize])return NO;
 Peer=[device copy];NSString *pinned=Peer;
 NSURL *root=[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TurboIOPrivateAddon/NativeNavigationV1"] isDirectory:YES];
 Transport=[[TNVTransport alloc]initWithRoot:root device:device currentDevice:^{return TIOProtocolDevice();} call:^BOOL(NSString *method,NSDictionary *args,void(^result)(id)){
  if(!NSThread.isMainThread||![pinned isEqual:TIOProtocolDevice()])return NO;id plugin=TIOProtocolPlugin();Class cls=NSClassFromString(@"FlutterMethodCall");SEL make=NSSelectorFromString(@"methodCallWithMethodName:arguments:"),handle=NSSelectorFromString(@"handleMethodCall:result:");
  if(!plugin||![cls respondsToSelector:make]||![plugin respondsToSelector:handle])return NO;
  @try{id call=((id(*)(id,SEL,id,id))objc_msgSend)(cls,make,method,args);((void(*)(id,SEL,id,id))objc_msgSend)(plugin,handle,call,[result copy]);return YES;}@catch(NSException *e){return NO;}
 }];TNVTransport *transport=Transport;
 Session=[[TNVSession alloc]initWithDevice:device session:(uint32_t)sid clock:^{return NSProcessInfo.processInfo.systemUptime;} sender:^(NSData *packet,NSString *task,TNVSubmitted done){[transport send:packet task:task submitted:done];} cleanup:^(NSString *task){[transport cleanup:task];}];
 if(!Timer)Timer=[NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t){TNVPump();}];
 BOOL started=[Session start:frame always:TNVAlways()];
 TIONavDiagHUDEvent(@"会话",started?@"START 已提交":@"START 未被接受");
 return started;
}
void TNVOffer(NSDictionary *frame){[Session offer:frame];}
void TNVStop(void){TIONavDiagHUDEvent(@"会话",@"退出指令已发出");[Session stop];}
