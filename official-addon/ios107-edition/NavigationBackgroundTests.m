// NavigationBackgroundTests.m — macOS 离线测试：直接编译真实的 NavigationBackground.inc
// 与 NavigationCore.h 里的纯策略函数（不需要 iOS 运行时、手机、网络或刷机）。
// 本文件自带 TIO_DISPLAY_PHONE=1，覆盖眼镜会话分支；生产构建的宏由 build.sh 决定。
// 运行（mac 上，无 Xcode 工程依赖）：
//   xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Wno-unused-parameter -framework Foundation \
//     NavigationBackgroundTests.m -o build/navigation-background-tests && ./build/navigation-background-tests
#define TIO_DISPLAY_PHONE 1

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import "NavigationCore.h"
#import "NavigationBackground.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

typedef NSUInteger UIBackgroundTaskIdentifier;
static const UIBackgroundTaskIdentifier UIBackgroundTaskInvalid=NSUIntegerMax;
typedef NS_ENUM(NSInteger,UIApplicationState){UIApplicationStateActive=0,UIApplicationStateInactive=1,UIApplicationStateBackground=2};
typedef NS_ENUM(int,CLAuthorizationStatus){kCLAuthorizationStatusNotDetermined=0,kCLAuthorizationStatusRestricted=1,kCLAuthorizationStatusDenied=2,kCLAuthorizationStatusAuthorizedAlways=3,kCLAuthorizationStatusAuthorizedWhenInUse=4};
typedef double CLLocationAccuracy;
static const CLLocationAccuracy kCLLocationAccuracyHundredMeters=100.0;
typedef struct {double latitude,longitude;} CLLocationCoordinate2D;

@interface CLLocation:NSObject
@property CLLocationCoordinate2D coordinate;
@property CLLocationAccuracy horizontalAccuracy;
@property NSDate *timestamp;
@end
@implementation CLLocation
@end

@interface CLLocationManager:NSObject
@property CLAuthorizationStatus authorizationStatus;
@property CLLocationAccuracy desiredAccuracy;
@property double distanceFilter;
@property BOOL allowsBackgroundLocationUpdates;
@property NSUInteger locationStarts,locationStops;
- (void)startUpdatingLocation;
- (void)stopUpdatingLocation;
@end
@implementation CLLocationManager
- (void)startUpdatingLocation{self.locationStarts++;}
- (void)stopUpdatingLocation{self.locationStops++;}
@end

@interface UIApplication:NSObject
@property UIApplicationState applicationState;
@property NSUInteger begins,ends;
@property BOOL deny;
@property(copy) void(^expiry)(void);
+ (instancetype)sharedApplication;
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(NSString *)name expirationHandler:(void(^)(void))handler;
- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)t;
@end
@implementation UIApplication
+ (instancetype)sharedApplication{static UIApplication *s;static dispatch_once_t o;dispatch_once(&o,^{s=[UIApplication new];});return s;}
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(NSString *)n expirationHandler:(void(^)(void))h{self.begins++;self.expiry=h;return self.deny?UIBackgroundTaskInvalid:self.begins;}
- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)t{assert(t!=UIBackgroundTaskInvalid);self.ends++;}
@end

// 眼镜会话替身：NavigationBackground.inc 在 TIO_DISPLAY_PHONE 分支里查询它。
static NSDictionary *HUDStatus;
static NSUInteger HUDStopCalls;
NSDictionary *TDPPhoneNavigationStatus(void){return HUDStatus?:@{@"active":@NO,@"note":@"",@"stopped":@NO};}
void TDPPhoneNavigationStop(void){HUDStopCalls++;}
static NSUInteger TraceCalls;
void TIOVoiceNavTrace(NSString *step){TraceCalls++;}

@interface TIONavigationPanel:NSObject
@property BOOL navigationStarted,fixture,simulated,backgroundLocationEnabled;
@property BOOL voiceSession,voiceLocating,planning,active,hasVoiceFix;
@property NSUInteger backgroundEpoch,stops,stopArms;
@property NSTimeInterval stopArmDelay;
@property UIBackgroundTaskIdentifier navigationBackgroundTask,voiceBridgeTask;
@property NSUInteger voiceBridgeEpoch;
@property NSInteger voicePipelineStage;
@property NSTimeInterval voicePipelineStageAt,voicePipelineStarted,voiceLastSelfHealAt;
@property BOOL voicePipelineExpired,voiceLocationKept;
@property NSTimeInterval voicePipelineNextArmAt;
@property CLLocationManager *permission;
@property CLLocationCoordinate2D voiceFix;
@property NSString *note;
@property NSUInteger searchStarts,relocates,searches,plans;
- (void)stopUser;
- (void)refresh;
- (void)voiceSearchDestination;
- (void)voiceRetryLocating;
- (void)voiceRetrySearch;
- (void)voiceRetryPlanning;
- (void)armStopRetryWindow:(NSTimeInterval)firstDelay;
// 下面这些方法由 NavigationBackground.inc 在本实现内定义；此处声明只是为了让 main() 里能调用。
- (void)background;
- (void)navigationForeground;
- (void)endNavigationBackgroundTask;
- (void)expireNavigationBackgroundTask:(NSUInteger)epoch;
- (void)expireVoiceBridgeTask:(NSUInteger)epoch;
- (void)enterVoiceStage:(NSInteger)stage title:(NSString *)title;
- (void)refreshVoicePipelineState;
- (void)voicePipelineSelfHealIfNeeded;
- (void)voiceFixAcquired:(CLLocation *)loc;
@end
@implementation TIONavigationPanel
- (instancetype)init{if((self=[super init])){_navigationBackgroundTask=UIBackgroundTaskInvalid;_voiceBridgeTask=UIBackgroundTaskInvalid;_permission=[CLLocationManager new];_note=@"";}return self;}
- (void)refresh{}
- (void)stopUser{self.stops++;self.navigationStarted=NO;self.voiceSession=NO;self.backgroundLocationEnabled=NO;[self endNavigationBackgroundTask];[self endVoiceBridgeTask];}
- (void)voiceSearchDestination{self.searchStarts++;}
- (void)voiceRetryLocating{self.relocates++;}
- (void)voiceRetrySearch{self.searches++;}
- (void)voiceRetryPlanning{self.plans++;}
- (void)armStopRetryWindow:(NSTimeInterval)firstDelay{self.stopArms++;self.stopArmDelay=firstDelay;}
#include "NavigationBackground.inc"
@end

static NSTimeInterval Now(void){return NSProcessInfo.processInfo.systemUptime;}

int main(void){@autoreleasepool{
    unsigned checks=0;
    // ---- 1) 原有的 TIONavBackgroundPolicy 组合（回归：手动/模拟/后台策略不变） ----
    for(int started=0;started<2;started++)for(int fixture=0;fixture<2;fixture++)for(int sim=0;sim<2;sim++)for(int enabled=0;enabled<2;enabled++)for(int auth=0;auth<2;auth++){
        TIONavBackgroundAction expected=fixture?TIONavBackgroundStop:!started?TIONavBackgroundIdle:sim?TIONavBackgroundSimulation:(enabled&&auth)?TIONavBackgroundLocation:TIONavBackgroundStop;
        assert(TIONavBackgroundPolicy(started,fixture,sim,enabled,auth)==expected);checks++;
    }
    // ---- 2) 语音链路后台保持纯策略：只覆盖“未上镜的中间阶段”，且总时长有界 ----
    double durations[3]={0,TIONavVoiceHoldMaxSeconds-1,TIONavVoiceHoldMaxSeconds+1};
    for(int voice=0;voice<2;voice++)for(int hud=0;hud<2;hud++)for(int stage=0;stage<=TIONavVoiceStageFailed;stage++)for(int d=0;d<3;d++){
        BOOL expected=voice&&!hud&&stage>TIONavVoiceStageIdle&&stage<TIONavVoiceStageEngaged&&durations[d]<TIONavVoiceHoldMaxSeconds;
        assert(TIONavVoicePipelineShouldHold(voice,hud,stage,durations[d])==expected);checks++;
    }
    assert(!TIONavVoicePipelineShouldHold(YES,NO,TIONavVoiceStageLocating,-1)); // 未起表不持有
    // ---- 3) 回前台自愈策略：只对停滞的定位/搜索/算路重试一次，候选与启动阶段不碰，节流生效 ----
    struct {NSInteger stage;double age;double since;BOOL planning;TIONavVoiceSelfHealAction want;} table[]={
        {TIONavVoiceStageLocating,9,1e9,NO,TIONavVoiceSelfHealRelocate},
        {TIONavVoiceStageLocating,TIONavVoiceHealStaleSeconds-1,1e9,NO,TIONavVoiceSelfHealNone},
        {TIONavVoiceStageLocating,30,TIONavVoiceHealThrottleSeconds-1,NO,TIONavVoiceSelfHealNone},
        {TIONavVoiceStageLocating,30,-1,NO,TIONavVoiceSelfHealRelocate},
        {TIONavVoiceStageSearching,20,1e9,NO,TIONavVoiceSelfHealResearch},
        {TIONavVoiceStageChoosing,200,1e9,NO,TIONavVoiceSelfHealNone},
        {TIONavVoiceStagePlanning,20,1e9,YES,TIONavVoiceSelfHealReplan},
        {TIONavVoiceStagePlanning,20,1e9,NO,TIONavVoiceSelfHealNone},
        {TIONavVoiceStageRouteReady,200,1e9,NO,TIONavVoiceSelfHealNone},
        {TIONavVoiceStageStarting,200,1e9,NO,TIONavVoiceSelfHealNone},
        {TIONavVoiceStageEngaged,200,1e9,NO,TIONavVoiceSelfHealNone}
    };
    for(size_t i=0;i<sizeof table/sizeof *table;i++){assert(TIONavVoiceSelfHealActionFor(table[i].stage,table[i].age,table[i].since,table[i].planning)==table[i].want);checks++;}
    // ---- 4) 退出补发策略：会话 active 且未到上限才补发 ----
    assert(TIONavStopRetryShouldSend(YES,0,TIONavStopRetryMaxAttempts));checks++;
    assert(TIONavStopRetryShouldSend(YES,TIONavStopRetryMaxAttempts-1,TIONavStopRetryMaxAttempts));checks++;
    assert(!TIONavStopRetryShouldSend(YES,TIONavStopRetryMaxAttempts,TIONavStopRetryMaxAttempts));checks++;
    assert(!TIONavStopRetryShouldSend(NO,0,TIONavStopRetryMaxAttempts));checks++;
    assert(!TIONavStopRetryShouldSend(YES,0,0));checks++;
    assert(TIONavStopRetryFirstDelay>=0&&TIONavStopRetryInterval>0);checks++;

    UIApplication *app=UIApplication.sharedApplication;
    HUDStatus=@{@"active":@NO,@"note":@"",@"stopped":@NO};

    // ---- 5) 退后台发起语音链路：单标识后台任务，阶段推进只续期不重复申请 ----
    TIONavigationPanel *p=[TIONavigationPanel new];
    app.applicationState=UIApplicationStateActive;
    p.voiceSession=YES;
    [p enterVoiceStage:TIONavVoiceStageLocating title:@"定位"];
    assert(app.begins==0&&app.ends==0&&p.voiceBridgeTask==UIBackgroundTaskInvalid); // 前台不空占后台额度
    app.applicationState=UIApplicationStateBackground;
    [p background]; // 退后台通知：立即补申请
    assert(p.voiceBridgeTask!=UIBackgroundTaskInvalid&&app.begins==1&&app.ends==0);checks++;
    [p enterVoiceStage:TIONavVoiceStageSearching title:@"搜索"];
    assert(app.begins==2&&app.ends==1);checks++; // 续期 = 先结束旧的再重开唯一的标识
    [p enterVoiceStage:TIONavVoiceStagePlanning title:@"算路"];
    assert(app.begins==3&&app.ends==2);checks++;
    [p voiceFixAcquired:[CLLocation new]]; // 阶段推进不重复申请（定位回调直接触发搜索阶段）
    assert(app.begins==4&&app.ends==3&&p.searchStarts==1);checks++;
    assert(TraceCalls>0);checks++; // 每步都有面包屑，现场可回溯

    // ---- 6) 回前台释放额度；阶段未停滞时不自愈重试 ----
    app.applicationState=UIApplicationStateActive;
    p.voicePipelineStageAt=Now(); // 刚推进过阶段：未停滞，不应触发自愈
    [p navigationForeground];
    assert(p.voiceBridgeTask==UIBackgroundTaskInvalid&&app.ends==4);checks++;
    assert(p.relocates==0&&p.searches==0&&p.plans==0);checks++;

    // ---- 7) 挂起自愈：按记录阶段重试一次，且 15 秒节流；手动/候选阶段不碰 ----
    p.voicePipelineStage=TIONavVoiceStageLocating;p.voicePipelineStageAt=Now()-20;p.voiceLastSelfHealAt=0;
    [p voicePipelineSelfHealIfNeeded];assert(p.relocates==1);checks++;
    [p voicePipelineSelfHealIfNeeded];assert(p.relocates==1);checks++; // 节流窗口内不重发
    p.voiceLastSelfHealAt=0;p.voicePipelineStage=TIONavVoiceStageSearching;p.voicePipelineStageAt=Now()-20;
    [p voicePipelineSelfHealIfNeeded];assert(p.searches==1);checks++;
    p.voiceLastSelfHealAt=0;p.voicePipelineStage=TIONavVoiceStagePlanning;p.voicePipelineStageAt=Now()-20;p.planning=NO;
    [p voicePipelineSelfHealIfNeeded];assert(p.plans==0);checks++; // 不在算路中不重提
    p.planning=YES;[p voicePipelineSelfHealIfNeeded];assert(p.plans==1);checks++;
    p.planning=NO;
    p.voiceSession=NO;p.voiceLastSelfHealAt=0;p.voicePipelineStage=TIONavVoiceStageLocating;
    [p voicePipelineSelfHealIfNeeded];assert(p.relocates==1);checks++; // 手动导航/非语音会话一律不碰
    p.voiceSession=YES;

    // ---- 8) 后台额度到期：结束保持 + note/trace 留证据，回到前台可自愈 ----
    app.applicationState=UIApplicationStateBackground;p.voicePipelineStarted=0;p.voicePipelineStage=TIONavVoiceStageSearching;
    [p enterVoiceStage:TIONavVoiceStageSearching title:@"搜索"];
    assert(p.voiceBridgeTask!=UIBackgroundTaskInvalid);checks++;
    NSUInteger bridgeEpoch=p.voiceBridgeEpoch;
    [p expireVoiceBridgeTask:bridgeEpoch];
    assert(p.voiceBridgeTask==UIBackgroundTaskInvalid&&p.voicePipelineExpired);checks++;
    assert([p.note rangeOfString:@"后台时间到期"].location!=NSNotFound);checks++;
    [p expireVoiceBridgeTask:bridgeEpoch]; // 过期后重复回调不重复处理
    assert(p.voiceBridgeTask==UIBackgroundTaskInvalid);checks++;

    // ---- 9) 上镜成功：语音链路收尾，结束后台保持并释放额外定位 ----
    app.applicationState=UIApplicationStateActive;
    p.voiceSession=YES;p.voicePipelineStage=TIONavVoiceStageStarting;p.voicePipelineStarted=Now();
    p.voiceLocationKept=YES;p.permission.locationStops=0;
    HUDStatus=@{@"active":@YES,@"note":@"眼镜已确认导航",@"stopped":@NO};
    [p refreshVoicePipelineState];
    assert(p.voicePipelineStage==TIONavVoiceStageEngaged);checks++;
    assert(p.voiceBridgeTask==UIBackgroundTaskInvalid);checks++;
    assert(p.voiceLocationKept==NO&&p.permission.locationStops==1);checks++;

    // ---- 10) 超出总上限：不再持有后台额度，并明确提示（不静默死等） ----
    HUDStatus=@{@"active":@NO,@"note":@"",@"stopped":@NO};
    app.applicationState=UIApplicationStateBackground;
    p.voiceSession=YES;p.voicePipelineStage=TIONavVoiceStageSearching;p.voicePipelineStarted=Now()-TIONavVoiceHoldMaxSeconds-1;p.voiceLocationKept=NO;p.note=@"";
    [p refreshVoicePipelineState];
    assert(p.voiceBridgeTask==UIBackgroundTaskInvalid);checks++;
    assert([p.note rangeOfString:@"上限"].location!=NSNotFound);checks++;

    // ---- 11) 回前台发现“手机已不在导航、眼镜会话仍 active”→ 立即补发退出并武装重试窗口 ----
    app.applicationState=UIApplicationStateActive;
    p.voiceSession=NO;p.navigationStarted=NO;p.active=NO;
    HUDStopCalls=0;p.stopArms=0;
    HUDStatus=@{@"active":@YES,@"note":@"旧会话仍在",@"stopped":@NO};
    [p navigationForeground];
    assert(HUDStopCalls==1&&p.stopArms==1&&p.stopArmDelay==0);checks++;
    HUDStopCalls=0;HUDStatus=@{@"active":@NO,@"note":@"",@"stopped":@YES};[p navigationForeground];
    assert(HUDStopCalls==0);checks++; // 眼镜已退出时不打扰

    // ---- 12) 模拟导航后台 25s 到期：停止手机导航后立即武装退出补发（2s/次链路由 tick 驱动） ----
    TIONavigationPanel *sim=[TIONavigationPanel new];
    app.deny=NO;app.applicationState=UIApplicationStateBackground;
    sim.navigationStarted=YES;sim.simulated=YES;sim.backgroundLocationEnabled=YES;sim.permission.authorizationStatus=kCLAuthorizationStatusAuthorizedWhenInUse;
    [sim background];
    assert(sim.navigationBackgroundTask!=UIBackgroundTaskInvalid);checks++;
    NSUInteger bgEpoch=sim.backgroundEpoch;
    [sim expireNavigationBackgroundTask:bgEpoch];
    assert(sim.stops==1&&sim.stopArms==1&&sim.stopArmDelay==0);checks++;

    // ---- 13) 手动/模拟导航永不申请语音链路后台额度 ----
    TIONavigationPanel *manual=[TIONavigationPanel new];
    app.begins=0;app.ends=0;
    manual.backgroundLocationEnabled=YES;manual.permission.authorizationStatus=kCLAuthorizationStatusAuthorizedWhenInUse;
    [manual background];
    assert(app.begins==0&&manual.voiceBridgeTask==UIBackgroundTaskInvalid);checks++;
    manual.navigationStarted=YES;manual.simulated=YES;[manual background];
    assert(manual.voiceBridgeTask==UIBackgroundTaskInvalid);checks++; // 模拟只走 navigationBackgroundTask

    printf("PASS %u checks: voice-pipeline hold policy, self-heal policy, stop-retry policy and real NavigationBackground.inc lifecycle (single background task, renew, expiry, HUD engagement, foreground recovery)\n",checks);
    return 0;
}}