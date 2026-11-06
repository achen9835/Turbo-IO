#import "NavigationUI.h"
#import "ResearchUI.h"
#import "NavigationCore.h"
#import "NavigationModes.h"
#import "NavigationTransport.h"
#import "ManualHUD.h"
#import "NavigationTeleHUD.h"
#import "NavigationSubtitleHUD.h"
#import "SubtitleHUD.h"
#import "NewsTeleprompter.h"
#import "NavigationPlaces.h"
#import "NavigationBackground.h"
#import "MusicPlayer.h"
#import "ReaderUI.h"
#import "AlwaysOnAudio.h"
#if TIO_DISPLAY_PHONE
#import "DisplayPhoneUI.h"
#import "NativeNavigationUI.h"
#import "NativeNavigation.h"
#import "RoadMap.h"
#import "RoadPack.h"
#import "RoadPackUI.h"
#import "ProtocolContext.h"
#import "DisplayHUDRenderer.h"
#endif
#import <CoreLocation/CoreLocation.h>
#import <Security/Security.h>
#if TIO_AMAP_ENABLED
#import <AMapNaviKit/AMapNaviKit.h>
#import <AMapNaviKit/MAMapKit.h>
#import <AMapFoundationKit/AMapFoundationKit.h>
#import <AMapSearchKit/AMapSearchKit.h>
#endif

static NSString *const NavConsent=@"io.turboio.navigation.privacy.v1";
static NSDictionary *KeyQuery(void){return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:@"io.turboio.navigation",(__bridge id)kSecAttrAccount:@"amap-ios"};}
static NSString *ReadNavKey(void){NSMutableDictionary *q=[KeyQuery() mutableCopy];q[(__bridge id)kSecReturnData]=@YES;CFTypeRef v=NULL;if(SecItemCopyMatching((__bridge CFDictionaryRef)q,&v)!=errSecSuccess)return nil;return [[NSString alloc]initWithData:CFBridgingRelease(v) encoding:NSUTF8StringEncoding];}
static BOOL ValidKey(NSString *s){return [s isKindOfClass:NSString.class]&&s.length==32&&[s rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"].invertedSet].location==NSNotFound;}
static BOOL WriteNavKey(NSString *s){if(!ValidKey(s))return NO;NSDictionary *a=@{(__bridge id)kSecValueData:[s dataUsingEncoding:NSUTF8StringEncoding],(__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly};OSStatus r=SecItemUpdate((__bridge CFDictionaryRef)KeyQuery(),(__bridge CFDictionaryRef)a);if(r==errSecItemNotFound){NSMutableDictionary *q=[KeyQuery() mutableCopy];[q addEntriesFromDictionary:a];r=SecItemAdd((__bridge CFDictionaryRef)q,NULL);}return r==errSecSuccess;}
static void BootstrapKey(void){if(ReadNavKey().length)return;NSString *p=[NSBundle.mainBundle pathForResource:@"TIOAMapPrivate" ofType:@"json"];NSData *d=[NSData dataWithContentsOfFile:p?:@""];if(!d||d.length>4096)return;id j=[NSJSONSerialization JSONObjectWithData:d options:0 error:nil];if([j isKindOfClass:NSDictionary.class]&&[j[@"bundleIdentifier"] isEqual:NSBundle.mainBundle.bundleIdentifier])WriteNavKey(j[@"apiKey"]);}

@interface TIONavigationPanel:UIViewController<CLLocationManagerDelegate
#if TIO_AMAP_ENABLED
,MAMapViewDelegate,AMapSearchDelegate,AMapNaviWalkManagerDelegate,AMapNaviWalkDataRepresentable,AMapNaviRideManagerDelegate,AMapNaviRideDataRepresentable,AMapNaviDriveManagerDelegate,AMapNaviDriveDataRepresentable
#endif
>
@property UILabel *statusLabel,*hudLabel,*destinationLabel;
@property UIStackView *stack;
@property UIScrollView *scroll;
@property NSTimer *timer;
@property CLLocationManager *permission;
@property NSDictionary *display;
@property TIONavTeleHUD *teleHUD;
@property TIONavSubtitleHUD *subtitleHUD;
@property NSDictionary *lastSubtitleDiagnostic;
@property NSDictionary *lastTeleDiagnostic;
@property NSString *note;
@property BOOL initialized,active,planning,simulated,fixture,hasDestination,gpsWeak,staleShown,rerouting;
@property NSUInteger generation,fixtureStep;
@property NSTimeInterval lastInfo;
@property CLLocationCoordinate2D destination;
@property UIView *mapHost;
@property NSLayoutConstraint *mapHeight;
@property UIStackView *routeCard,*lensCard;
@property BOOL showLegacyDisplay;
@property NSMutableArray<UIView *> *legacyDisplayViews;
@property UILabel *routeSummary,*briefLabel,*lensStatus,*mapHint;
@property UILabel *originHint;
@property UILabel *startLabel;
@property UIImageView *mapCrosshair;
@property UIButton *centerButton,*zoomInButton,*zoomOutButton;
@property UISegmentedControl *mapPickRole;
@property NSString *pendingMapAction,*simulationStartName;
@property BOOL hasSimulationStart;
@property UIButton *planButton,*beginButton,*lensButton,*stopButton,*searchButton;
@property UISegmentedControl *travelMode;
@property UISegmentedControl *transportMode;
@property NSInteger selectedTransport,sessionTransport;
@property BOOL routeReady,locating;
@property BOOL navigationStarted,backgroundLocationEnabled;
@property BOOL voiceSession,voiceLifelogWasOn,voiceLocating,hasVoiceFix,voiceSearchAround;
@property NSArray<NSDictionary *> *voiceCandidates; // pending multi-choice dialog: name/lat/lon/meters/city (meters=-1 without a step-1 fix)
@property NSTimeInterval voiceCandidatesExpire;
@property BOOL voiceAwaitingMode; // destination picked, waiting for a spoken 步行/骑行/驾车
@property NSTimeInterval voiceModeExpire;
@property NSInteger voiceModeFallback; // distance-aware timeout default: walk nearby, drive far/unknown
@property BOOL voiceModeExplicit; // the trigger utterance already named the mode ("骑车去X") → skip the follow-up
@property CLLocationCoordinate2D voiceFix; // Fresh CLLocationManager fix from voice step 1; used as the explicit route origin so background planning never waits on the SDK's own (paused) location engine.
#if TIO_AMAP_ENABLED
@property AMapSearchAPI *voiceSearch;
@property AMapPOIKeywordsSearchRequest *voiceRequest;
@property AMapInputTipsSearchRequest *voiceTipsRequest;
#endif
@property NSString *voiceQuery;
@property UIBackgroundTaskIdentifier navigationBackgroundTask;
@property NSUInteger backgroundEpoch;
@property UIBackgroundTaskIdentifier voiceBridgeTask; // 语音链路唯一后台保持：voiceStart 起持有，关键阶段续期，上镜/失败/停止/超时后结束
@property NSUInteger voiceBridgeEpoch;
@property NSInteger voicePipelineStage; // TIONavVoiceStage：无头语音链路阶段（挂起自愈按它重试，诊断 JSON/状态行展示）
@property NSInteger diagVoiceStage; // 已写入诊断环形缓冲的阶段（只在变化时记一条，形成语音链路时间线）
@property NSTimeInterval voicePipelineStageAt,voicePipelineStarted,voiceLastSelfHealAt;
@property BOOL voicePipelineExpired,voiceLocationKept;
@property NSTimeInterval voicePipelineNextArmAt; // 后台额度被系统拒绝后的重试节流，避免 1Hz 刷 trace
@property BOOL stopRetryArmed; // 退出补发窗口：halt/回前台发现眼镜会话仍在时武装，tick 里每2秒补发
@property NSUInteger stopRetryAttempts;
@property NSTimeInterval stopRetryNextAt;
@property unsigned long long stopRetrySessionId; // 武装时的眼镜会话号：出现新会话就停止补发，绝不打断新导航
@property NSString *destinationName;
@property CLLocationCoordinate2D simulationStart;
@property NSUInteger locationGeneration;
#if TIO_DISPLAY_PHONE
@property UIButton *tdpButton;
@property UILabel *tdpStatus;
@property BOOL autoNativeHUD;
@property NSUInteger autoNativeHUDAttempts;
@property NSTimeInterval autoNativeHUDNextAt;
@property UIImageView *tdpPreview;
@property NSData *hudIconPixels,*crossPixels;
@property NSInteger hudIconType;
@property NSTimeInterval crossReceived;
@property NSUInteger crossReceivedCount,iconReceivedCount;
#endif
#if TIO_AMAP_ENABLED
@property AMapNaviHUDView *nativeHUD;
@property MAMapView *map;
@property id<TIONavigationManager> manager;
@property Class retiringManagerClass;
@property(weak) id<TIONavigationManager> retiringManager;
@property MAPointAnnotation *pin;
@property MAPointAnnotation *startPin;
@property MAPolyline *routeLine;
@property NSArray<NSNumber *> *trafficBarLevels;
@property NSInteger cameraKind,cameraLimit,eventKind;
@property NSUInteger cameraMeters,eventMeters,lightMeters;
@property NSInteger roadSpeedLimit; /* 路段限速 km/h；-1 = 高德尚未上报 */
@property (copy) NSArray<NSNumber *> *lightDistances; /* 逐盏闯红灯相机距离，近→远 */
@property (copy) NSArray<NSDictionary *> *cameraList; /* 沿路全部相机（kind/limit/m 字典），近→远 */
@property (copy) NSArray<NSDictionary *> *serviceAreas; /* 服务区/收费站/检查站（高德 type 0/1/2） */
@property (copy) NSArray<NSDictionary *> *trafficFacilities; /* 警示类设施（已映射为本方 kind 4..12） */
@property NSTimeInterval lastSpeedSampleAt; /* 模拟车速差分采样时刻（systemUptime） */
@property NSUInteger lastRemainingMetersForSpeed; /* 模拟车速差分上一次剩余里程 */
@property double navLat,navLon;
@property NSInteger navSpeedKmh,navHeadingDeg; /* -1=尚未从 AMapNaviLocation 读到 */
#endif
/* 大地图与路网自动开启；HUD 自测使用独立场景，不改变真实导航回调。
 * 只依赖 TIO_DISPLAY_PHONE 构建线（RoadMap.m 在该线编译），不依赖高德链接。 */
#if TIO_DISPLAY_PHONE
@property TIORoadMap *roadMap;
@property NSTimeInterval hudMarkerTestUntil;
@property UIButton *roadButton;
@property UILabel *roadStatus;
@property NSArray *roadCoordinates;
@property NSArray *roadLocation;
@property double roadLocationAt,roadHeading;
#endif
/* 语音链路生命周期/退出补发/自愈方法：实现分布在 NavigationBackground.inc、
 * NavigationDisplayHUD.inc 与本文件里，但调用点（tick/halt/voiceStart 等）在 include
 * 之前，先在这里声明，保证 -Wall 下没有未知 self 消息的告警。 */
- (BOOL)voicePipelineHUDEngaged;
- (BOOL)voicePipelineShouldHold;
- (void)enterVoiceStage:(NSInteger)stage title:(NSString *)title;
- (void)refreshVoicePipelineState;
- (void)voicePipelineSelfHealIfNeeded;
- (BOOL)holdVoiceLocationForVoicePipeline;
- (void)releaseVoiceLocationForVoicePipeline;
- (void)endVoiceBridgeTask;
- (void)expireVoiceBridgeTask:(NSUInteger)epoch;
- (void)beginVoiceBridgeTask;
- (void)expireNavigationBackgroundTask:(NSUInteger)epoch;
- (void)endNavigationBackgroundTask;
- (void)voiceRetryLocating;
- (void)voiceRetrySearch;
- (void)voiceRetryPlanning;
#if TIO_DISPLAY_PHONE
- (void)armStopRetryWindow:(NSTimeInterval)firstDelay;
- (void)pumpStopRetries;
- (void)endStopRetryWindow;
#endif
@end
@implementation TIONavigationPanel
- (UIButton *)button:(NSString *)title action:(SEL)action identifier:(NSString *)identifier{UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem];b.configuration=[UIButtonConfiguration tintedButtonConfiguration];[b setTitle:title forState:UIControlStateNormal];b.accessibilityIdentifier=identifier;[b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];[self.stack addArrangedSubview:b];return b;}
- (void)viewDidLoad{
    [super viewDidLoad];self.title=@"多模式导航 · 后台连接";self.view.backgroundColor=TIOPaper();self.view.tintColor=TIOAccent();self.note=@"字幕直传：先获取预览/退出格式，再启动高德导航（模拟或实时），确认眼镜空闲后开启。字幕更新需保持本页前台；实时定位在授权后可后台运行。请勿边驾驶边调试。";self.teleHUD=[TIONavTeleHUD new];self.subtitleHUD=[TIONavSubtitleHUD new];
#ifndef TIO_UI_PREVIEW
    BootstrapKey();
#endif
    self.scroll=[UIScrollView new];self.scroll.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.scroll];
    self.stack=[UIStackView new];self.stack.axis=UILayoutConstraintAxisVertical;self.stack.spacing=12;self.stack.translatesAutoresizingMaskIntoConstraints=NO;[self.scroll addSubview:self.stack];
    [NSLayoutConstraint activateConstraints:@[[self.scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],[self.scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],[self.scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],[self.scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],[self.stack.leadingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.leadingAnchor constant:16],[self.stack.trailingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.trailingAnchor constant:-16],[self.stack.topAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.topAnchor constant:16],[self.stack.bottomAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.bottomAnchor constant:-24],[self.stack.widthAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.widthAnchor constant:-32]]];
    self.statusLabel=[UILabel new]; // Diagnostic text only; not part of the primary layout.
    [self buildWorkspace];
#if TIO_DISPLAY_PHONE
    [self buildRoadControls];
    self.roadMap=[[TIORoadMap alloc]initWithWGS84ToMap:^NSArray *(double lat,double lon){
#if TIO_AMAP_ENABLED
        CLLocationCoordinate2D c=AMapCoordinateConvert(CLLocationCoordinate2DMake(lat,lon),AMapCoordinateTypeGPS);return @[@(c.latitude),@(c.longitude)];
#else
        return @[@(lat),@(lon)]; /* WGS84/无转换兜底：只影响 OSM 路网对齐精度 */
#endif
    }];
    // 用户 2026-11-02 明确要求：矢量小地图/联网取路网不再做开关，导航即自动开启。
    self.roadMap.enabled=YES;
    self.roadMap.allowNetwork=YES;
    [self refreshRoadControls];
#endif
    // Voice flow presents this panel as a bare modal (no research-shell back
    // stack); without an explicit exit the user gets trapped. Always offer one
    // when there is nothing to pop back to.
    if(self.navigationController.viewControllers.count<=1){
        self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc]initWithTitle:@"退出导航页" style:UIBarButtonItemStylePlain target:self action:@selector(voiceDismiss)];
    }
    self.permission=[CLLocationManager new];self.permission.delegate=self;self.navigationBackgroundTask=UIBackgroundTaskInvalid;self.voiceBridgeTask=UIBackgroundTaskInvalid;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:@"TIONavigationChanged" object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stopUser) name:@"TIOResearchClosed" object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(navigationForeground) name:UIApplicationDidBecomeActiveNotification object:nil];
    self.display=TIONavDisplay(@"stopped",0,@"",-1,-1,-1,NO);self.roadSpeedLimit=-1;[self refresh];
}
#if TIO_DISPLAY_PHONE
- (void)buildRoadControls{
    self.roadStatus=[UILabel new];self.roadStatus.numberOfLines=0;self.roadStatus.font=[UIFont systemFontOfSize:12];self.roadStatus.textColor=UIColor.secondaryLabelColor;[self.stack addArrangedSubview:self.roadStatus];
    [self button:@"省际路网包（按省下载 · 离线用）" action:@selector(roadPacksOpen) identifier:@"navigation-road-packs"];
    [self refreshRoadControls];
    [[TIORoadPackManager shared] refreshManifest:^(BOOL ok,NSString *note){ (void)ok;(void)note; }];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshRoadControls) name:@"TIORoadPackChanged" object:nil];
}
- (void)refreshRoadControls{
    if(!self.roadStatus||!self.roadMap)return;
    self.roadStatus.text=[NSString stringWithFormat:@"路网自动开启 · %@",self.roadMap.note];
}
- (void)roadPacksOpen{[self.navigationController pushViewController:[TIORoadPackListController new] animated:YES];}
#endif
- (void)viewWillAppear:(BOOL)animated{[super viewWillAppear:animated];if(!self.timer){__weak typeof(self) weak=self;self.timer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t){[weak tick];}];} [self refresh];}
- (void)viewDidDisappear:(BOOL)animated{
    [super viewDidDisappear:animated];self.pendingMapAction=nil;
    if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive&&!self.isMovingFromParentViewController&&!self.isBeingDismissed&&!self.navigationController.isBeingDismissed)return;
    // Navigation (voice-started or manual) survives this page closing: the
    // shared panel is retained by TIONavigationController, so the timer keeps
    // pumping the glasses HUD off-screen. Reopening the page reattaches to the
    // same session and 结束导航 stops it.
    if(self.active||self.planning){TIOVoiceNavTrace(@"导航页面已退出，导航继续后台运行");return;}
    [self stopUser];[self.timer invalidate];self.timer=nil;
}
- (void)dealloc{if(self.navigationBackgroundTask!=UIBackgroundTaskInvalid)[UIApplication.sharedApplication endBackgroundTask:self.navigationBackgroundTask];if(self.voiceBridgeTask!=UIBackgroundTaskInvalid)[UIApplication.sharedApplication endBackgroundTask:self.voiceBridgeTask];[self.subtitleHUD stop:@"导航页面已销毁"];[self.teleHUD stop:@"导航页面已销毁"];[self.timer invalidate];[NSNotificationCenter.defaultCenter removeObserver:self];}
- (void)refresh{if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self refresh];});return;}NSDictionary *s=TIONavTransportStatus(),*tele=self.teleHUD.status;self.statusLabel.text=[NSString stringWithFormat:@"%@\n常亮：%@ · 已提交%@帧\n通知：%@\n连接／卡片：%@\nKey：%@ · SDK：%@",self.note?:@"",tele[@"note"],tele[@"frames"],s[@"noticeNote"],s[@"note"],ReadNavKey().length?@"已配置（有效性待实际算路）":@"未配置",
#if TIO_AMAP_ENABLED
    @"11.2.100"
#else
    @"此构建未链接（仅离线夹具）"
#endif
    ];NSDictionary *sub=self.subtitleHUD.status;self.statusLabel.text=[NSString stringWithFormat:@"字幕：%@ · 已提交%@帧\n%@\n%@",sub[@"note"],sub[@"frames"],TIOSubtitleNavigationStatus()[@"note"],self.statusLabel.text];
    // 用户反馈③：现场诊断——“详细诊断”弹窗里直接带语音链路阶段、退出补发计数和最近 HUD 事件，
    // 用户截图即可；同一份数据也落在 native-navigation-status.json（Library + Documents 双写）。
    NSDictionary *navDiag=TIONavDiagSnapshot();NSArray *hudEvents=navDiag[@"hudEvents"];NSMutableString *recentHUD=[NSMutableString new];
    for(NSString *e in [hudEvents reverseObjectEnumerator]){if(recentHUD.length>=200)break;[recentHUD appendFormat:@"\n· %@",e];}
    self.statusLabel.text=[NSString stringWithFormat:@"语音阶段：%@ · 后台保持%@\n退出补发：%u/%u%@\n最近HUD事件：%@\n%@",navDiag[@"voiceStage"],self.voicePipelineExpired?@"已到期(待自愈)":(self.voiceBridgeTask!=UIBackgroundTaskInvalid?@"持有中":@"未持有"),(unsigned)[navDiag[@"stopRetryAttempts"] unsignedIntegerValue],(unsigned)[navDiag[@"stopRetryMax"] unsignedIntegerValue],[navDiag[@"stopRetryPending"] boolValue]?@"（补发中）":@"（无）",recentHUD.length?recentHUD:@"（无）",self.statusLabel.text];
#if TIO_AMAP_ENABLED
    self.statusLabel.text=[self.statusLabel.text stringByAppendingFormat:@"\n高德扩展：相机 kind=%ld limit=%ld m=%lu · 红绿灯近=%lu · 事件 kind=%ld m=%lu · 路段限速=%ld · 合成车速=%ld",(long)self.cameraKind,(long)self.cameraLimit,(unsigned long)self.cameraMeters,(unsigned long)self.lightMeters,(long)self.eventKind,(unsigned long)self.eventMeters,(long)self.roadSpeedLimit,(long)self.navSpeedKmh];
#endif
    if(![sub isEqual:self.lastSubtitleDiagnostic]){self.lastSubtitleDiagnostic=sub;NSString *dir=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/TurboIOResearch/subtitle-hud"];[NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];NSMutableDictionary *report=[sub mutableCopy];report[@"time"]=@(NSDate.date.timeIntervalSince1970);[[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[dir stringByAppendingPathComponent:@"navigation.json"] options:NSDataWritingAtomic error:nil];}
    self.hudLabel.text=[NSString stringWithFormat:@"%@\n\n%@  %@\n%@\n%@",self.display[@"mode"]?:@"",self.display[@"turn"]?:@"",self.display[@"distance"]?:@"",self.display[@"road"]?:@"",self.display[@"summary"]?:@""];[self refreshWorkspace];
    if(![tele isEqual:self.lastTeleDiagnostic]){self.lastTeleDiagnostic=tele;NSString *dir=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TurboIOPrivateAddon"];[NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];NSMutableDictionary *d=[tele mutableCopy];d[@"time"]=@([NSDate.date timeIntervalSince1970]);NSString *p=[dir stringByAppendingPathComponent:@"navigation-tele-diagnostic.json"];[[NSJSONSerialization dataWithJSONObject:d options:0 error:nil] writeToFile:p options:NSDataWritingAtomic error:nil];[NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:p error:nil];}}
- (void)setFrame:(NSDictionary *)frame{
#if TIO_DISPLAY_PHONE
    BOOL markerTesting=[frame[@"phase"] isEqual:@"navigating"]&&NSProcessInfo.processInfo.systemUptime<self.hudMarkerTestUntil;
    if(!markerTesting&&self.hudMarkerTestUntil){self.hudMarkerTestUntil=0;[self.roadMap clearMarkerTest];}
    if(![frame[@"phase"] isEqual:@"navigating"]||![frame[@"segment"] isEqual:self.display[@"segment"]])self.crossPixels=nil;
#endif
#if TIO_DISPLAY_PHONE
    if(self.roadMap){ /* 矢量小地图：setFrame 是唯一帧漏斗，decorate 内部自带 navigating/新鲜度门禁 */
        NSMutableDictionary *decorated=[frame mutableCopy];
        for(NSString *k in @[@"tnrScene",@"tnrScene2",@"tnrPose",@"tnrPoseAt"])[decorated removeObjectForKey:k];
        decorated[@"tnrSource"]=self.simulated?@"amap-simulation":@"amap-realtime";
        decorated[@"travel"]=self.sessionTransport==TIONavigationWalk?@"walk":self.sessionTransport==TIONavigationRide?@"ride":@"drive"; /* 自适应缩放基准：步行/骑行/驾驶 */
        if(self.roadLocation){decorated[@"tnrLocation"]=self.roadLocation;decorated[@"tnrLocationAt"]=@(self.roadLocationAt);if(self.navHeadingDeg>=0)decorated[@"navHeading"]=@(self.navHeadingDeg);}
        frame=[self.roadMap decorate:decorated coordinates:self.roadCoordinates];
        // 路网开着但这一帧没出图（定位暂缺/图源未就绪）时告诉会话层「暂缺」，
        // 保留镜片上最后一张图；只有路网开关关闭才让会话清屏（TNR_CLEAR）。
        if(self.roadMap.enabled&&![frame[@"tnrScene"] isKindOfClass:NSData.class]){NSMutableDictionary *held=[frame mutableCopy];held[@"tnrHold"]=@YES;frame=[held copy];}
    }
#endif
    self.display=frame;TIONavOfferDisplay(frame);[self.teleHUD offer:frame at:NSProcessInfo.processInfo.systemUptime];[self.subtitleHUD offer:frame at:NSProcessInfo.processInfo.systemUptime];
#if TIO_DISPLAY_PHONE
    NSDictionary *test=markerTesting?[self.roadMap markerTestFrame:frame]:nil;
    TDPPhoneNavigationOffer(test?:[self displayHUDFrame]);[self autoStartNativeHUDIfNeeded];[self refreshDisplayHUD];
#endif
    [self refresh];}
- (void)tick{
#if TIO_DISPLAY_PHONE
    [self refreshRoadControls]; /* 1Hz 同步路网状态行（请求中/已就绪/失败原因） */
#endif
    if(self.voicePipelineStage!=self.diagVoiceStage){self.diagVoiceStage=self.voicePipelineStage;TIONavDiagHUDEvent(@"语音阶段",TIONavVoiceStageName(self.voicePipelineStage));}
    TIONavDiagSetVoiceStage(TIONavVoiceStageName(self.voicePipelineStage)); /* 诊断 JSON/导航页状态行的“当前语音阶段” */
    [self refreshVoicePipelineState]; // 上镜/失败/停止/超时后释放后台保持与额外定位；额度丢了就补申请
    // Candidate dialog timeout: never leave the user stranded -- default to the
    // nearest candidate and keep navigating.
    if(self.voiceCandidates.count&&NSProcessInfo.processInfo.systemUptime>self.voiceCandidatesExpire){TIOVoiceNavTrace(@"候选30秒未选择：默认最近的，继续导航");[self voicePickCandidate:self.voiceCandidates[0] announced:@"（超时默认最近）"];}
    // Travel-mode follow-up timeout: never leave the user stranded -- apply the
    // distance-aware default (walk nearby, drive far) and keep navigating.
    if(self.voiceAwaitingMode&&NSProcessInfo.processInfo.systemUptime>self.voiceModeExpire){TIOVoiceNavTrace([NSString stringWithFormat:@"出行方式15秒未选择：默认%@，继续算路",TIONavigationModeTitle(self.voiceModeFallback)]);[self voicePickMode:self.voiceModeFallback announced:@"（超时默认）"];}
#if TIO_DISPLAY_PHONE
    if(self.crossPixels&&NSProcessInfo.processInfo.systemUptime-self.crossReceived>12){self.crossPixels=nil;if([self.display[@"phase"] isEqual:@"navigating"])TDPPhoneNavigationOffer([self displayHUDFrame]);}
    if(self.hudMarkerTestUntil&&NSProcessInfo.processInfo.systemUptime>=self.hudMarkerTestUntil)[self setFrame:self.display];
    TDPPhoneNavigationPump();
    [self pumpStopRetries]; // 用户反馈②：退出指令丢失时按 5s 首补、2s/次最多10次补发，镜片不再停在“导航数据已过期”
    [self refreshDisplayHUD];
#endif
    TIONavPump();[self.subtitleHUD pumpAt:NSProcessInfo.processInfo.systemUptime];[self.teleHUD pumpAt:NSProcessInfo.processInfo.systemUptime];[self refresh];if(self.fixture&&self.active){self.fixtureStep++;NSArray *icons=@[@9,@2,@3,@29,@15];NSUInteger i=MIN(self.fixtureStep/4,4);[self setFrame:TIONavDisplay(i==4?@"arrived":@"navigating",[icons[i] integerValue],@"模拟测试道路",MAX(0,160-(NSInteger)self.fixtureStep*10),850,720,YES)];if(i==4){self.fixture=NO;self.active=NO;self.note=@"离线夹具结束；手动停止以清理卡片";[self refresh];}}
    if(self.active&&!self.routeReady&&!self.fixture&&!self.planning&&!self.staleShown&&NSProcessInfo.processInfo.systemUptime-self.lastInfo>15){
      // AMap only speaks when the device moves. For REALTIME nav a standstill
      // (waiting at a light) is normal: keep the last guidance alive -- it
      // preserves HUD-engage freshness AND feeds the lens -- instead of
      // freezing the frame as "stale" and blocking the glasses retry loop.
      if(!self.simulated){self.lastInfo=NSProcessInfo.processInfo.systemUptime;[self setFrame:self.display];}
      else{self.staleShown=YES;[self setFrame:TIONavDisplay(@"stale",0,@"",-1,-1,-1,self.simulated)];}
    }}
- (void)alert:(NSString *)title message:(NSString *)message{UIAlertController *a=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil];}
- (void)configureKey{if(self.initialized){[self alert:@"先重启 App" message:@"SDK 已初始化。本轮不热替换 Key，避免影响已有导航实例；请重启后配置。"] ;return;}UIAlertController *a=[UIAlertController alertControllerWithTitle:@"高德 iOS Key" message:@"绑定当前 App 的 Bundle ID；仅保存于本机钥匙串，不回显旧值。" preferredStyle:UIAlertControllerStyleAlert];[a addTextFieldWithConfigurationHandler:^(UITextField *f){f.placeholder=@"32 位 iOS Key";f.secureTextEntry=YES;f.autocorrectionType=UITextAutocorrectionTypeNo;f.autocapitalizationType=UITextAutocapitalizationTypeNone;}];[a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){self.note=WriteNavKey(a.textFields.firstObject.text)?@"Key 已保存，尚未进行 SDK 鉴权":@"保存失败：检查格式与钥匙串权限";[self refresh];}]];[self presentViewController:a animated:YES completion:nil];}
- (void)consent{
#if TIO_AMAP_ENABLED
    if(!ValidKey(ReadNavKey())){[self alert:@"尚未配置 Key" message:@"请先填写高德 iOS Key。"] ;return;}
    if([NSUserDefaults.standardUserDefaults boolForKey:NavConsent]){[self openMap];return;}
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"启用高德地图与导航？" message:@"提供方：高德软件有限公司。地图、定位与导航会按高德隐私政策处理设备、网络、位置及起终点信息，用于地图、算路与导航。本扩展不保存轨迹，不发送位置给大模型。真实导航需定位授权；点击开始实时导航后会持续使用后台定位，直到停止、到达或关闭导航页面。模拟只使用系统短时后台额度，不启动真实定位。\n请先阅读高德 SDK 隐私政策，再决定是否同意。" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"查看高德隐私政策" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://lbs.amap.com/pages/privacy/"] options:@{} completionHandler:nil];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"不同意" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x){self.pendingMapAction=nil;}]];
    [a addAction:[UIAlertAction actionWithTitle:@"同意并开启地图" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[NSUserDefaults.standardUserDefaults setBool:YES forKey:NavConsent];[self openMap];}]];[self presentViewController:a animated:YES completion:nil];
#else
    [self alert:@"离线预览构建" message:@"此构建不包含高德 SDK。可使用离线显示夹具；不会伪装为真实导航。"];
#endif
}
- (void)refreshConnection{TIONavRefreshConnection();[self refresh];}
- (void)subtitleCheck{[self stopUser];[self.navigationController pushViewController:TIOSubtitleHUDController() animated:YES];}
- (BOOL)canStartSubtitle{
#if TIO_DISPLAY_PHONE
    if([TDPPhoneNavigationStatus()[@"active"] boolValue])return NO;
#endif
    NSDictionary *transport=TIONavTransportStatus();
    return self.active&&!self.fixture&&!self.planning&&!self.rerouting&&NSProcessInfo.processInfo.systemUptime-self.lastInfo<=15&&TIONavSubtitleText(self.display)&&![TIONewsTeleStatus()[@"active"] boolValue]&&![self.teleHUD.status[@"enabled"] boolValue]&&![transport[@"enabled"] boolValue]&&![transport[@"pending"] boolValue]&&![transport[@"noticePending"] boolValue]&&![transport[@"notices"] boolValue];
}
- (void)enableSubtitleHUD{
    if(![self canStartSubtitle]){[self alert:@"先启动高德导航并结束其他显示" message:@"等待手机出现转向指引（模拟或实时均可）；退出提词、导航卡与自动通知。仍不支持离线夹具。"] ;return;}
    if(![TIOSubtitleNavigationStatus()[@"available"] boolValue]){[self alert:@"字幕通道未就绪" message:@"先确认眼镜已连接。当前支持版本使用固化协议或已保存配置；若仍不可用，再在诊断页学习一次新配置。"] ;return;}
    NSUInteger generation=self.generation;BOOL realtime=!self.simulated;UIAlertController *a=[UIAlertController alertControllerWithTitle:@"眼镜当前已回首页且无任务？" message:[NSString stringWithFormat:@"确认录音、智记、提词、字幕、语音对话均已结束后开启。使用字幕纯文字通道，不发送录音启动；发现字幕音频消息就停止。%@。请保持本页面前台，勿边驾驶边操作。",realtime?@"实时导航会话为20分钟保护，到期可重新开启":@"模拟会话为4分钟保护，仅模拟验收"] preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"已确认，开启字幕导航" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){if(generation!=self.generation||![self canStartSubtitle]||!TIOSubtitleConfirmIdle()){self.note=@"未开启：路线或会话状态变化，请先退出已有字幕";[self refresh];return;}[self.subtitleHUD startWithFrame:self.display at:NSProcessInfo.processInfo.systemUptime];[self refresh];[self.scroll setContentOffset:CGPointZero animated:YES];}]];[self presentViewController:a animated:YES completion:nil];
}
- (void)manualHUD{[self stopUser];[self.navigationController pushViewController:TIOManualHUDController() animated:YES];}
- (BOOL)subtitleBlocksOtherDisplay{
#if TIO_DISPLAY_PHONE
 if([TDPPhoneNavigationStatus()[@"active"] boolValue]){[self alert:@"先停止原生HUD传图" message:@"停止后用眼镜实体键回到首页，再开启其他显示通道。"] ;return YES;}
#endif
 NSString *phase=TIOSubtitleNavigationStatus()[@"phase"];
 if([phase isEqual:@"idle"])return NO;
 if([phase isEqual:@"starting"]||[phase isEqual:@"ready"]||[self.subtitleHUD.status[@"enabled"] boolValue]){[self alert:@"请先退出字幕会话" message:@"字幕正在显示。停止字幕后，在字幕显示检查页确认镜片已回首页，再切换其他显示通道。不会自动抢占。"] ;return YES;}
 // A finished session (sim or realtime) leaves stopping/uncertain behind forever
 // unless confirmed. Offer a one-tap reset so this never permanently locks the
 // backup display channels; the caller action is simply tapped again after it.
 UIAlertController *a=[UIAlertController alertControllerWithTitle:@"上次字幕会话未确认退出" message:@"确认镜片已回首页、没有字幕残留后点“确认已退出”，然后重新点刚才的通道按钮。" preferredStyle:UIAlertControllerStyleAlert];
 [a addAction:[UIAlertAction actionWithTitle:@"还没有" style:UIAlertActionStyleCancel handler:nil]];
 [a addAction:[UIAlertAction actionWithTitle:@"确认已退出" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){TIOSubtitleConfirmIdle();[self refresh];}]];
 [self presentViewController:a animated:YES completion:nil];return YES;}
- (void)enableTeleHUD{if([self subtitleBlocksOtherDisplay])return;if(!self.active||!self.simulated||self.fixture||self.planning||NSProcessInfo.processInfo.systemUptime-self.lastInfo>15){[self alert:@"先启动高德模拟导航" message:@"本轮只测真实高德回调→眼镜手动提词，不支持实际道路导航或离线夹具。收到手机模拟转向后再开启。"] ;return;}TIONavEnableNotices(NO);TIONavEnableDisplay(NO);if([self.teleHUD enable]){[self.teleHUD offer:self.display at:NSProcessInfo.processInfo.systemUptime];[self.teleHUD pumpAt:NSProcessInfo.processInfo.systemUptime];}[self refresh];[self.scroll setContentOffset:CGPointZero animated:YES];}
- (void)testNotice{if([self subtitleBlocksOtherDisplay])return;[self.teleHUD stop:@"切换到通知测试"];TIONavTestNotice();[self refresh];[self.scroll setContentOffset:CGPointZero animated:YES];}
- (void)enableNotices{if([self subtitleBlocksOtherDisplay])return;[self.teleHUD stop:@"切换到自动通知"];TIONavEnableNotices(YES);TIONavOfferDisplay(self.display);TIONavPump();[self refresh];[self.scroll setContentOffset:CGPointZero animated:YES];}
- (void)enableGlasses{if([self subtitleBlocksOtherDisplay])return;UIAlertController *a=[UIAlertController alertControllerWithTitle:@"新增／更新专用导航卡？" message:@"只修改本扩展拥有的导航卡，不覆盖天气与待办。整卡连续更新仍需镜片验收。请先用模拟导航测试。" preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[a addAction:[UIAlertAction actionWithTitle:@"启用" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){if([self subtitleBlocksOtherDisplay])return;[self.teleHUD stop:@"切换到仪表盘导航卡"];TIONavEnableDisplay(YES);TIONavOfferDisplay(self.display);TIONavPump();[self refresh];}]];[self presentViewController:a animated:YES completion:nil];}
- (void)halt{
    self.voiceLifelogWasOn=NO;self.voiceSession=NO;self.voiceLocating=NO;
    self.voiceCandidates=nil; // a stopped pipeline never answers a pending choice
    self.voiceAwaitingMode=NO; // ...nor a pending travel-mode question
    self.navigationStarted=NO;self.autoNativeHUD=NO;self.backgroundLocationEnabled=NO;[self endNavigationBackgroundTask];[self endVoiceBridgeTask];
    self.voicePipelineStage=TIONavVoiceStageIdle;self.voicePipelineStarted=0;self.voicePipelineStageAt=0;self.voiceLastSelfHealAt=0;self.voicePipelineExpired=NO;
#if TIO_DISPLAY_PHONE
    TDPPhoneNavigationStop();self.hudIconPixels=nil;self.hudIconType=0;self.crossPixels=nil;self.hudMarkerTestUntil=0;[self.roadMap clearMarkerTest];
    // 用户反馈②：STOP 在途丢失/被挂起打断时镜片会停在最后画面（“导航数据已过期”）。
    // 这里只武装重试窗口，由 tick 每 2 秒幂等补发 TDPPhoneNavigationStop（最多10次）。
    [self armStopRetryWindow:TIONavStopRetryFirstDelay];
#endif
    [self.subtitleHUD stop:@"导航停止／切换路线"];
    [self.teleHUD stop:@"导航停止／切换路线"];
    self.generation++;self.locationGeneration++;self.locating=NO;[self.permission stopUpdatingLocation];self.voiceLocationKept=NO;self.routeReady=NO;self.active=NO;self.planning=NO;self.fixture=NO;self.rerouting=NO;
#if TIO_AMAP_ENABLED
    if(self.manager){BOOL owned=self.manager.delegate==self;[self.manager removeDataRepresentative:self];if(self.nativeHUD)[self.manager removeDataRepresentative:self.nativeHUD];if(owned){self.manager.allowsBackgroundLocationUpdates=NO;self.manager.pausesLocationUpdatesAutomatically=YES;self.manager.delegate=nil;[self.manager stopNavi];self.retiringManagerClass=TIONavigationManagerClass(self.sessionTransport);self.retiringManager=self.manager;}self.manager=nil;if(owned)dispatch_async(dispatch_get_main_queue(),^{[self finishRetiringManager:0];});}
    [self.nativeHUD removeFromSuperview];self.nativeHUD=nil;
    self.map.showsUserLocation=NO;
#endif
}
- (void)stopUser{BOOL wasRunning=self.navigationStarted;[self halt];TIONavEnableNotices(NO);self.note=@"导航更新已停止并请求退出。字幕退出仍需镜片确认；未关闭时用实体按钮。不会自动重新开启。";self.routeSummary.text=@"导航已结束 · 可重新规划路线";self.display=TIONavDisplay(@"stopped",0,@"",-1,-1,-1,self.simulated);[self clearSceneExtensionState];TIONavEnableDisplay(NO);if(wasRunning)TIOVoiceNavTrace(@"导航已结束：镜片导航页60秒无更新会自动息屏（或用眼镜返回键立即退出）；期间立即重测可能需要重试");[self refresh];}
- (void)voiceDismiss{
    // Exiting the page never stops a running session (the shared panel keeps
    // feeding the glasses off-screen); 结束导航 or reopening the page stops it.
    [self dismissViewControllerAnimated:YES completion:nil];
}
#pragma mark Voice entry ("导航去X" → full hands-free navigation)
// Flow per product decision: pause our modules, turn all-day lifelog off
// (remembering it was on), search the destination, plan realtime, auto-begin
// (which auto-engages the glasses HUD). Lifelog toggle is deferred until the
// real glasses-side control interface is identified (echo domain params).
- (void)voiceStart:(NSString *)query{
    if(self.active||self.planning){self.note=@"语音导航：已有导航进行中";TIOVoiceNavTrace(@"忽略：已有导航进行中");[self refresh];return;}
#if TIO_AMAP_ENABLED
    if(!ValidKey(ReadNavKey())){[self fail:@"语音导航不可用：尚未配置高德Key"];TIOVoiceNavTrace(@"中止：高德Key未配置");return;}
    self.voiceSession=YES;self.voiceQuery=[query copy];
    TMMusicPauseForVoice();TWReaderPauseForVoice();
    // Voice flow auto-consents: the user has already approved map privacy in
    // the visible nav page; a headless panel cannot present a consent dialog.
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:NavConsent];
    [self openMap];
    if(!query.length){self.note=@"语音已打开导航；说出「导航去+地点」即可免手开始。";[self refresh];return;}
    // 用户反馈①：从这一刻起持有有界后台保持（单一状态机，见 NavigationBackground.inc）。
    // 定位→搜索→候选/追问→算路全程不再因为锁屏/口袋被挂起而停在半路；上镜成功、失败、
    // 停止或超过总上限后释放。模拟/手动导航永不走到这里，不会被伪装保活。
    [self enterVoiceStage:TIONavVoiceStageLocating title:@"语音链路启动：第1步定位"];
    if(!self.voiceSearch){[AMapSearchAPI updatePrivacyShow:AMapPrivacyShowStatusDidShow privacyInfo:AMapPrivacyInfoStatusDidContain];[AMapSearchAPI updatePrivacyAgree:AMapPrivacyAgreeStatusDidAgree];self.voiceSearch=[AMapSearchAPI new];self.voiceSearch.delegate=self;self.voiceSearch.timeout=18;}
    // Step 1: confirm the current position BEFORE anything else -- the route
    // must originate from a fresh fix, not an SDK fallback. Steps then run in
    // order: 定位 → 终点 → 规划 → 导航.
    CLAuthorizationStatus auth=self.permission.authorizationStatus;
    if(auth==kCLAuthorizationStatusNotDetermined||auth==kCLAuthorizationStatusDenied||auth==kCLAuthorizationStatusRestricted){[self fail:@"语音实时导航需要定位授权：请在系统设置允许定位后重试"];TIOVoiceNavTrace(@"中止：定位未授权");return;}
    // Positioning robustness for the hands-free case (phone possibly locked
    // in a pocket): best accuracy for a fast first fix; background delivery
    // ONLY when the host declares the location background mode -- setting the
    // flag without that entitlement crashes CLLocationManager.
    self.permission.desiredAccuracy=kCLLocationAccuracyBest;
    id bgModes=[NSBundle.mainBundle objectForInfoDictionaryKey:@"UIBackgroundModes"];
    if([bgModes isKindOfClass:NSArray.class]&&[bgModes containsObject:@"location"])self.permission.allowsBackgroundLocationUpdates=YES;
    TIOVoiceNavTrace(UIApplication.sharedApplication.applicationState==UIApplicationStateActive?@"App在前台：定位回调应正常送达":@"App在后台/锁屏：定位依赖后台模式，请保持眼镜连接");
    // Cold-start speed-up: a fresh cached fix (<60s, <=100m) skips waiting for
    // a new GPS search entirely; only cold starts actually run the locator.
    CLLocation *cached=self.permission.location;
    if(cached&&cached.horizontalAccuracy>0&&cached.horizontalAccuracy<=100&&fabs(cached.timestamp.timeIntervalSinceNow)<60){TIOVoiceNavTrace(@"定位：使用60秒内缓存位置，跳过GPS等待");[self voiceFixAcquired:cached];return;}
    self.voiceLocating=YES;[self.permission startUpdatingLocation];
    self.note=@"语音导航 第1步：正在定位当前位置（最多15秒）…";TIOVoiceNavTrace(@"第1步：正在定位（最多15秒）");[self refresh];
    NSUInteger g=self.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(g==self.generation&&self.voiceLocating){self.voiceLocating=NO;[self fail:@"15秒未获得可靠位置：到开阔处重试，或用页面按钮手动规划"];TIOVoiceNavTrace(@"中止：15秒未定位成功");}});
#else
    [self alert:@"语音导航不可用" message:@"此构建未链接高德 SDK。"];
    TIOVoiceCloseAssistantSession(); // release any hijacked chat turn: no fail path runs without AMap
#endif
}
#if TIO_AMAP_ENABLED
// Step 2 (after the position fix): search the spoken destination, LOCAL FIRST.
// Three tiers, each firing only when the previous one found nothing:
//   1) strict POI search AROUND the step-1 fix (50km) -- nearby POIs outrank
//      same-name ones in other cities;
//   2) input tips with location bias -- server-side pinyin fuzzy matching that
//      recovers ASR homophone errors (「金酒公寓」→「金九公寓」);
//   3) nationwide keyword search -- the "user explicitly named a distant place"
//      case, so no city-name parsing is needed.
- (void)voiceSearchDestination{
    if(!self.voiceSession||!self.voiceQuery.length)return;
    if(!self.hasVoiceFix){[self voiceSearchKeywordsNationwide];return;}
    [self enterVoiceStage:TIONavVoiceStageSearching title:@"第2步：本地搜索目的地"];
    AMapPOIAroundSearchRequest *r=[AMapPOIAroundSearchRequest new];r.keywords=self.voiceQuery;r.location=[AMapGeoPoint locationWithLatitude:self.voiceFix.latitude longitude:self.voiceFix.longitude];r.radius=50000;r.offset=10;r.page=1;self.voiceRequest=r;self.voiceSearchAround=YES;
    self.note=[NSString stringWithFormat:@"第2步：已定位。本地搜索「%@」（周边50公里）…",self.voiceQuery];TIOVoiceNavTrace([NSString stringWithFormat:@"第2步：本地搜索「%@」（当前位置周边）",self.voiceQuery]);[self refresh];
    [self.voiceSearch AMapPOIAroundSearch:r];
}
- (void)voiceSearchKeywordsNationwide{
    [self enterVoiceStage:TIONavVoiceStageSearching title:@"第2步：全国搜索目的地"];
    AMapPOIKeywordsSearchRequest *r=[AMapPOIKeywordsSearchRequest new];r.keywords=self.voiceQuery;r.offset=10;r.page=1;self.voiceRequest=r;self.voiceSearchAround=NO;
    self.note=[NSString stringWithFormat:@"第2步：全国搜索目的地“%@”…",self.voiceQuery];TIOVoiceNavTrace([NSString stringWithFormat:@"第2步：全国搜索「%@」",self.voiceQuery]);[self refresh];
    [self.voiceSearch AMapPOIKeywordsSearch:r];
}
// Tier 2: input tips tolerate ASR homophones (server-side pinyin fuzzy). The
// location bias keeps corrections local; cityLimit stays off so an explicitly
// named distant place still surfaces (tier 3 remains as the final net).
- (void)voiceSearchInputTips{
    [self enterVoiceStage:TIONavVoiceStageSearching title:@"第2步：模糊纠错搜索目的地"];
    AMapInputTipsSearchRequest *r=[AMapInputTipsSearchRequest new];r.keywords=self.voiceQuery;if(self.hasVoiceFix)r.location=[AMapGeoPoint locationWithLatitude:self.voiceFix.latitude longitude:self.voiceFix.longitude];self.voiceTipsRequest=r;self.voiceSearchAround=NO;
    self.note=[NSString stringWithFormat:@"第2步：本地无精确结果，模糊纠错搜索「%@」…",self.voiceQuery];TIOVoiceNavTrace([NSString stringWithFormat:@"第2步：输入提示模糊纠错「%@」（同音字容错）",self.voiceQuery]);[self refresh];
    [self.voiceSearch AMapInputTipsSearch:r];
}
// Distance (meters) of a candidate coordinate from the step-1 fix; -1 without a fix.
- (double)voiceDistanceToLat:(double)lat lon:(double)lon{
    if(!self.hasVoiceFix)return -1;
    return hypot((lat-self.voiceFix.latitude)*111000,(lon-self.voiceFix.longitude)*111000*cos(self.voiceFix.latitude*M_PI/180));
}
// Up to 3 located candidates in the shared dialog shape (name/lat/lon/meters/city).
- (NSMutableArray *)voiceCandidatesFromPOIs:(NSArray<AMapPOI *> *)pois{
    NSMutableArray *cands=[NSMutableArray new];
    for(AMapPOI *poi in pois){
        if(!poi.location)continue;
        [cands addObject:@{@"name":poi.name?:@"目的地",@"lat":@(poi.location.latitude),@"lon":@(poi.location.longitude),@"meters":@([self voiceDistanceToLat:poi.location.latitude lon:poi.location.longitude]),@"city":poi.city?:@""}];
        if(cands.count>=3)break;
    }
    return cands;
}
- (NSMutableArray *)voiceCandidatesFromTips:(NSArray<AMapTip *> *)tips{
    NSMutableArray *cands=[NSMutableArray new];
    for(AMapTip *tip in tips){
        if(!tip.location)continue; // non-POI tips (roads, districts) are not navigable
        [cands addObject:@{@"name":tip.name?:@"目的地",@"lat":@(tip.location.latitude),@"lon":@(tip.location.longitude),@"meters":@([self voiceDistanceToLat:tip.location.latitude lon:tip.location.longitude]),@"city":tip.district?:@""}];
        if(cands.count>=3)break;
    }
    return cands;
}
- (void)onPOISearchDone:(AMapPOISearchBaseRequest *)request response:(AMapPOISearchResponse *)response{
    dispatch_async(dispatch_get_main_queue(),^{
        if(request!=self.voiceRequest||!self.voiceSession)return;self.voiceRequest=nil;
        NSMutableArray *cands=[self voiceCandidatesFromPOIs:response.pois];
        if(!cands.count&&self.voiceSearchAround){TIOVoiceNavTrace(@"本地精确搜索无结果：升级输入提示模糊纠错");[self voiceSearchInputTips];return;}
        if(!cands.count){[self fail:[NSString stringWithFormat:@"语音没找到“%@”：请说更完整的名称，或手动搜索",self.voiceQuery?:@""] ];TIOVoiceNavTrace(@"中止：搜索无结果");return;}
        [self voicePresentCandidates:cands];
    });
}
- (void)onInputTipsSearchDone:(AMapInputTipsSearchRequest *)request response:(AMapInputTipsSearchResponse *)response{
    dispatch_async(dispatch_get_main_queue(),^{
        if(request!=self.voiceTipsRequest||!self.voiceSession)return;self.voiceTipsRequest=nil;
        NSMutableArray *cands=[self voiceCandidatesFromTips:response.tips];
        if(!cands.count){TIOVoiceNavTrace(@"模糊纠错也无结果：改全国关键词搜索");[self voiceSearchKeywordsNationwide];return;}
        TIOVoiceNavTrace([NSString stringWithFormat:@"模糊纠错命中%lu个候选",(unsigned long)cands.count]);
        [self voicePresentCandidates:cands];
    });
}
- (void)AMapSearchRequest:(id)request didFailWithError:(NSError *)error{
    dispatch_async(dispatch_get_main_queue(),^{
        if(request==self.voiceTipsRequest){self.voiceTipsRequest=nil;TIOVoiceNavTrace([NSString stringWithFormat:@"模糊纠错失败 code=%ld：改全国关键词搜索",(long)error.code]);[self voiceSearchKeywordsNationwide];return;}
        if(request!=self.voiceRequest||!self.voiceSession)return;self.voiceRequest=nil;[self fail:[NSString stringWithFormat:@"语音搜索失败（code=%ld）：检查网络与Key搜索权限",(long)error.code] ];TIOVoiceNavTrace([NSString stringWithFormat:@"中止：搜索失败 code=%ld",(long)error.code]);});
}
#endif
// -- Candidate dialog: no AMap types below, so non-SDK (offline preview) builds
// still compile -- tick and the global choice accessors reference these methods.
// Shared presentation for POI / input-tips candidates: >1 → stream the list into
// the hijacked assistant reply (the glasses chat window) and wait for 第几个 /
// 都不对 (30s, then the nearest); emit failure → auto-pick the first: never
// strand the user.
- (void)voicePresentCandidates:(NSArray *)cands{
    [self enterVoiceStage:TIONavVoiceStageChoosing title:cands.count>1?@"第2步完成：等待语音选择候选":@"第2步完成：唯一候选，直接选定"];
    if(cands.count>1){
        self.voiceCandidates=cands;self.voiceCandidatesExpire=NSProcessInfo.processInfo.systemUptime+30;
        NSArray *nums=@[@"一",@"二",@"三"];
        NSMutableString *lines=[NSMutableString new];
        for(NSUInteger i=0;i<cands.count;i++){NSDictionary *c=cands[i];double m=[c[@"meters"] doubleValue];
            NSString *city=c[@"city"]; // dictionary subscript yields id; dot-syntax needs a typed local
            NSString *dist=m<0?(city.length?city:@"未知城市"):(m<1000?[NSString stringWithFormat:@"约%.0f米",m]:[NSString stringWithFormat:@"约%.1f公里",m/1000]);
            [lines appendFormat:@"\n%@. %@（%@）",nums[i],c[@"name"],dist];}
        [lines appendString:@"\n说「第几个」选择，不对就说「都不对」，30 秒默认第一个。"];
        if(!TIOAssistantEmit(lines,NO)){
            self.voiceCandidates=nil;TIOVoiceNavTrace(@"聊天框接管不可用：自动选最近候选（兜底）");
            [self voicePickCandidate:cands[0] announced:@"（聊天框不可用，自动选最近）"];return;
        }
        NSMutableString *names=[NSMutableString new];for(NSUInteger i=0;i<cands.count;i++){[names appendString:cands[i][@"name"]?:@""];if(i+1<cands.count)[names appendString:@" / "];}
        self.note=[NSString stringWithFormat:@"第2步：找到%lu个候选（%@），等待语音选择（第几个 / 都不对，30秒默认第一个）",(unsigned long)cands.count,names];
        TIOVoiceNavTrace([NSString stringWithFormat:@"第2步完成：%lu个候选（%@）已流式上镜，等待选择",(unsigned long)cands.count,names]);
        [self refresh];return;
    }
    [self voicePickCandidate:cands[0] announced:@""];
}
// Chosen (or auto-picked) candidate → destination. When the trigger utterance
// did not name a travel mode, ask "怎么去？" first: walk planning rejects long
// distances, so the mode must be the user's spoken choice, never a blind walk
// default. The turn stays OPEN (done:NO) until the mode is answered or the 15s
// timeout applies the distance-aware default (walk ≤3km, else drive).
- (void)voicePickCandidate:(NSDictionary *)candidate announced:(NSString *)suffix{
    self.voiceCandidates=nil;
    NSString *city=candidate[@"city"]; // dictionary subscript yields id; dot-syntax needs a typed local
    [self selectPlace:@{@"name":candidate[@"name"]?:@"目的地",@"address":candidate[@"city"]?:@"",@"lat":candidate[@"lat"],@"lon":candidate[@"lon"]}];
    self.travelMode.selectedSegmentIndex=1; // Position is already confirmed; plan now, auto-begin follows.
    if(self.voiceModeExplicit){
        TIOVoiceNavTrace([NSString stringWithFormat:@"第2步完成：选定「%@」%@（%@），方式=%@（触发语已指定），第3步算路",candidate[@"name"]?:@"",suffix,city.length?city:@"未知城市",TIONavigationModeTitle(self.selectedTransport)]);
        self.note=[NSString stringWithFormat:@"第2步：选定终点「%@」。第3步：规划实时路线…",candidate[@"name"]?:@""];
        [self refresh];[self startWalking];
        // Post-utterance lines render through the choice utterance's own official
        // response (see TIOAssistantInjectNext); the old-turn channel is void here.
        TIOAssistantInjectNext([NSString stringWithFormat:@"好，导航去%@。",candidate[@"name"]?:@"目的地"],YES);
        return;
    }
    double m=[candidate[@"meters"] doubleValue];
    self.voiceModeFallback=(m>=0&&m<=3000)?TIONavigationWalk:TIONavigationDrive;
    self.voiceAwaitingMode=YES;self.voiceModeExpire=NSProcessInfo.processInfo.systemUptime+15;
    TIOVoiceNavTrace([NSString stringWithFormat:@"第2步完成：选定「%@」%@（%@），追问出行方式（15秒默认%@）",candidate[@"name"]?:@"",suffix,city.length?city:@"未知城市",TIONavigationModeTitle(self.voiceModeFallback)]);
    TIOAssistantInjectNext([NSString stringWithFormat:@"好，选定「%@」。怎么去？说「步行」「骑行」或「驾车」，15秒默认%@。",candidate[@"name"]?:@"目的地",TIONavigationModeTitle(self.voiceModeFallback)],NO);
    self.note=[NSString stringWithFormat:@"第2步：选定终点「%@」。等待选择出行方式（步行/骑行/驾车，15秒默认%@）",candidate[@"name"]?:@"",TIONavigationModeTitle(self.voiceModeFallback)];
    [self refresh];
}
// Chosen (or defaulted) travel mode → realtime planning → auto-begin.
- (void)voicePickMode:(NSInteger)mode announced:(NSString *)suffix{
    self.voiceAwaitingMode=NO;
    if(!TIONavigationModeTitle(mode))mode=self.voiceModeFallback;
    self.selectedTransport=mode;self.transportMode.selectedSegmentIndex=mode;
    TIOVoiceNavTrace([NSString stringWithFormat:@"出行方式：%@%@，第3步算路",TIONavigationModeTitle(mode),suffix]);
    if(mode==TIONavigationRide)TIOVoiceNavTrace(@"提示：眼镜原生导航不支持骑行，以手机指引为准");
    self.note=[NSString stringWithFormat:@"第2步完成：%@去「%@」。第3步：规划实时路线…",TIONavigationModeTitle(mode),self.destinationName?:@""];
    [self refresh];[self startWalking];
    TIOAssistantInjectNext([NSString stringWithFormat:@"好，%@去%@，开始规划路线。",TIONavigationModeTitle(mode),self.destinationName?:@"目的地"],YES);
}
// 0-based index from the ASR/NLP choice handler; validates expiry.
- (BOOL)voiceChoose:(NSUInteger)index{
    if(index>=self.voiceCandidates.count)return NO;
    if(NSProcessInfo.processInfo.systemUptime>self.voiceCandidatesExpire){TIOVoiceNavTrace(@"选择超时，已默认最近候选");return NO;}
    [self voicePickCandidate:self.voiceCandidates[index] announced:@"（语音选择）"];
    return YES;
}
// "都不对": drop the list, keep the pipeline idle, and ask the user to re-speak
// a fresh 导航去X (which restarts the search with the corrected destination).
- (void)voiceRejectCandidates{
    self.voiceCandidates=nil;
    self.voiceSession=NO; // 管线回到空闲：释放后台保持与额外定位，等下一次「导航去X」重新武装
    [self enterVoiceStage:TIONavVoiceStageIdle title:@"候选全部排除，等待重新说目的地"];
    TIONavDiagHUDEvent(@"语音链路",@"候选全部排除，链路空闲");
    TIOVoiceNavTrace(@"用户排除全部候选：等待重新说「导航去+地名」");
    TIOAssistantInjectNext(@"好，这些都不对。请重新说「导航去+地名」。",YES); // done:YES closes the turn cleanly
}
#pragma mark 回前台自愈的具体重试（由 NavigationBackground.inc 的自愈策略调用）
// 语音链路被锁屏挂起后，回到前台按已记录阶段各重试一次；失败必须给明确 note+trace，
// 绝不让用户对着“没有反应”的手机干等。手动导航/模拟导航不会进入这些入口。
- (void)voiceRetryLocating{
#if TIO_AMAP_ENABLED
    if(!self.voiceSession||self.hasVoiceFix)return;
    CLAuthorizationStatus auth=self.permission.authorizationStatus;
    if(auth!=kCLAuthorizationStatusAuthorizedAlways&&auth!=kCLAuthorizationStatusAuthorizedWhenInUse){[self fail:@"回前台自愈失败：定位未授权，请允许定位后重新说「导航去…」"];return;}
    self.permission.desiredAccuracy=kCLLocationAccuracyBest;
    id bgModes=[NSBundle.mainBundle objectForInfoDictionaryKey:@"UIBackgroundModes"];
    if([bgModes isKindOfClass:NSArray.class]&&[bgModes containsObject:@"location"])self.permission.allowsBackgroundLocationUpdates=YES;
    self.voiceLocating=YES;[self.permission startUpdatingLocation];
    self.note=@"回前台自愈：正在重新定位当前位置（最多10秒）…";TIOVoiceNavTrace(@"回前台自愈：重新发起定位（最多10秒）");
    TIONavDiagHUDEvent(@"回前台自愈",@"重新定位");
    [self refresh];
    NSUInteger g=self.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(g==self.generation&&self.voiceLocating){self.voiceLocating=NO;[self fail:@"回前台自愈失败：10秒未获得位置，请到开阔处重新说「导航去…」"];}});
#else
    TIOVoiceNavTrace(@"回前台自愈：此构建未链接高德，无法重试定位");
#endif
}
- (void)voiceRetrySearch{
#if TIO_AMAP_ENABLED
    if(!self.voiceSession||!self.voiceQuery.length)return;
    self.voiceRequest=nil;self.voiceTipsRequest=nil; // 丢弃可能永远回不来的旧请求，按记录阶段重发
    TIOVoiceNavTrace(@"回前台自愈：按已记录阶段重发目的地搜索");
    TIONavDiagHUDEvent(@"回前台自愈",@"重发搜索");
    [self voiceSearchDestination];
#else
    TIOVoiceNavTrace(@"回前台自愈：此构建未链接高德，无法重试搜索");
#endif
}
- (void)voiceRetryPlanning{
#if TIO_AMAP_ENABLED
    if(!self.voiceSession||!self.active||!self.planning||!self.manager)return;
    AMapNaviPoint *end=[AMapNaviPoint locationWithLatitude:self.destination.latitude longitude:self.destination.longitude];
    BOOL voiceOrigin=!self.simulated&&self.hasVoiceFix;
    AMapNaviPoint *start=voiceOrigin?[AMapNaviPoint locationWithLatitude:self.voiceFix.latitude longitude:self.voiceFix.longitude]:nil;
    BOOL submitted=TIONavigationCalculate(self.manager,self.sessionTransport,self.simulated,start,end);
    TIOVoiceNavTrace(submitted?@"回前台自愈：已用同一批起终点重新提交算路":@"回前台自愈：重新提交算路失败（引擎忙），请结束导航后重新说");
    TIONavDiagHUDEvent(@"回前台自愈",submitted?@"重新提交算路":@"重提算路失败");
    if(!submitted){self.note=@"回前台自愈未能重新提交算路；请结束导航后重新说「导航去…」";[self refresh];return;}
    NSUInteger g=self.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,45*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(g==self.generation&&self.planning){[self fail:@"45 秒未收到算路结果；已停止，本次结果未知"];}});
#else
    TIOVoiceNavTrace(@"回前台自愈：此构建未链接高德，无法重试算路");
#endif
}
#include "NavigationBackground.inc"
- (void)startFixture{[self halt];self.active=YES;self.fixture=YES;self.simulated=YES;self.fixtureStep=0;self.note=@"离线夹具：模拟转向顺序，不使用 Key、网络或定位";[self setFrame:TIONavDisplay(@"navigating",9,@"模拟测试道路",160,850,720,YES)];}
- (void)startWalking{
#if TIO_AMAP_ENABLED
    [self start:NO];
#else
    [self consent];
#endif
}
- (void)startSimulation{
#if TIO_AMAP_ENABLED
    [self start:YES];
#else
    [self consent];
#endif
}
#if TIO_AMAP_ENABLED
- (void)finishRetiringManager:(NSUInteger)attempt{
    Class cls=self.retiringManagerClass;if(!cls)return;
    if(self.retiringManager.delegate){self.retiringManagerClass=Nil;self.retiringManager=nil;self.note=@"旧引擎已被其他业务使用，不强行销毁。请先结束其他导航。";[self refresh];return;}
    if([(id<TIONavigationManagerFactory>)cls destroyInstance]){self.retiringManagerClass=Nil;self.retiringManager=nil;[self refresh];return;}
    if(attempt<3)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/10),dispatch_get_main_queue(),^{[self finishRetiringManager:attempt+1];});else{self.note=@"旧导航引擎尚未释放，暂不切换；请退出导航页面后重试或重启App。";[self refresh];}
}
- (void)openMap{
    if(!self.initialized){AMapNaviManagerConfig *config=AMapNaviManagerConfig.sharedConfig;[config updatePrivacyShow:AMapPrivacyShowStatusDidShow privacyInfo:AMapPrivacyInfoStatusDidContain];[config updatePrivacyAgree:AMapPrivacyAgreeStatusDidAgree];[MAMapView updatePrivacyShow:AMapPrivacyShowStatusDidShow privacyInfo:AMapPrivacyInfoStatusDidContain];[MAMapView updatePrivacyAgree:AMapPrivacyAgreeStatusDidAgree];AMapServices.sharedServices.apiKey=ReadNavKey();AMapServices.sharedServices.enableHTTPS=YES;self.initialized=YES;
        self.map=[MAMapView new];self.map.delegate=self;self.map.zoomLevel=15;self.map.centerCoordinate=CLLocationCoordinate2DMake(39.9087,116.3975);self.map.translatesAutoresizingMaskIntoConstraints=NO;[self.mapHost insertSubview:self.map atIndex:0];[NSLayoutConstraint activateConstraints:@[[self.map.leadingAnchor constraintEqualToAnchor:self.mapHost.leadingAnchor],[self.map.trailingAnchor constraintEqualToAnchor:self.mapHost.trailingAnchor],[self.map.topAnchor constraintEqualToAnchor:self.mapHost.topAnchor],[self.map.bottomAnchor constraintEqualToAnchor:self.mapHost.bottomAnchor]]];self.mapHint.hidden=YES;}
    if(!self.hasSimulationStart)[self selectSimulationStart:self.map.centerCoordinate name:@"北京默认起点（可改）"];
    self.note=@"单击地图选择终点；也可以搜索。模拟起点独立固定，拖动地图不会改变起点。";[self refresh];
    [self continueMapAction:0];
}
- (void)mapView:(MAMapView *)map didSingleTappedAtCoordinate:(CLLocationCoordinate2D)c{[self selectMapCoordinate:c];}
- (void)mapView:(MAMapView *)map didLongPressedAtCoordinate:(CLLocationCoordinate2D)c{[self selectMapCoordinate:c];}
- (void)start:(BOOL)sim{
    if(!self.initialized){[self consent];TIOVoiceNavTrace(@"算路未提交：地图未初始化");return;}
    if(self.active||self.planning){[self alert:@"请先停止当前导航" message:@"避免两条路线的异步回调互相覆盖。"] ;TIOVoiceNavTrace(@"算路未提交：已有导航进行中");return;}
    if(!self.hasDestination){[self alert:@"先选择终点" message:@"搜索目的地、长按地图选点，或使用更多中的北京演示路线。"] ;TIOVoiceNavTrace(@"算路未提交：终点未生效");return;}
    if(sim){if(!self.hasSimulationStart){[self alert:@"请选择模拟起点" message:@"切换地图上方的“选模拟起点”，然后点击地图。"] ;return;}CLLocation *a=[[CLLocation alloc]initWithLatitude:self.simulationStart.latitude longitude:self.simulationStart.longitude],*b=[[CLLocation alloc]initWithLatitude:self.destination.latitude longitude:self.destination.longitude];if([a distanceFromLocation:b]<30){[self alert:@"起终点距离不足30米" message:@"切换“选模拟起点”后点击另一个位置，或重新选择终点。拖动地图本身不会改变起点。"] ;return;}}
    if(!sim){CLAuthorizationStatus auth=self.permission.authorizationStatus;if(auth==kCLAuthorizationStatusNotDetermined){[self.permission requestWhenInUseAuthorization];self.note=@"允许定位后，请再次规划实时路线";TIOVoiceNavTrace(@"算路未提交：定位权限待授权");[self refresh];return;}if(auth==kCLAuthorizationStatusDenied||auth==kCLAuthorizationStatusRestricted){[self alert:@"定位未授权" message:@"请在系统设置允许定位，或者先使用不需要实际定位的模拟导航。"] ;TIOVoiceNavTrace(@"算路未提交：定位被拒绝");return;}}
    if(self.retiringManagerClass){[self alert:@"正在释放旧导航引擎" message:@"请稍后再规划，不会带着旧路线切换模式。"] ;TIOVoiceNavTrace(@"算路未提交：旧引擎释放中，请稍候再试");return;}
    Class cls=TIONavigationManagerClass(self.selectedTransport);if(!cls){[self alert:@"未知出行方式" message:@"请重新选择步行、骑行或驾车。"] ;TIOVoiceNavTrace(@"算路未提交：出行方式无效");return;}
    id<TIONavigationManager> manager=[(id<TIONavigationManagerFactory>)cls sharedInstance];
    // Reclaim OUR OWN leftovers only: a stale panel still holding the delegate
    // (previous session halted dirty), or a naviMode that never reset. A
    // host-owned delegate (any other class) is never touched -- by design.
    if(manager&&manager.delegate&&(id)manager.delegate!=self&&[manager.delegate isKindOfClass:TIONavigationPanel.class]){TIOVoiceNavTrace(@"引擎被上一导航面板占用，自动回收中");[(TIONavigationPanel *)(id)manager.delegate stopUser];}
    if(manager&&manager.naviMode!=AMapNaviModeNone&&!manager.delegate){TIOVoiceNavTrace(@"引擎导航模式未复位，补发停止指令");[(id<TIONavigationManager>)manager stopNavi];}
    if(!manager||manager.naviMode!=AMapNaviModeNone||(manager.delegate&&(id)manager.delegate!=self)){[self alert:@"导航引擎被占用" message:@"请先结束其他导航。本扩展不会停止宿主已有导航，也不会偷偷退回步行算路。"] ;TIOVoiceNavTrace([NSString stringWithFormat:@"算路未提交：引擎被占用（模式=%ld，委托=%@）",(long)(manager?manager.naviMode:-1),manager.delegate?@"其他对象":@"空"]);return;}
    self.sessionTransport=self.selectedTransport;
    self.manager=manager;manager.delegate=self;[manager addDataRepresentative:self];manager.isUseInternalTTS=NO;manager.screenAlwaysBright=NO;manager.allowsBackgroundLocationUpdates=NO;
#if TIO_DISPLAY_PHONE
    [self attachNativeHUD];
#endif
    self.active=YES;self.planning=YES;self.simulated=sim;self.fixture=NO;self.gpsWeak=NO;self.staleShown=NO;NSUInteger generation=++self.generation;
    self.note=[NSString stringWithFormat:@"%@%@算路中（%@）",TIONavigationModeTitle(self.sessionTransport),sim?@"模拟":@"实时",sim?@"联网，不使用实际定位":@"使用手机定位，开始后支持后台"];[self setFrame:TIONavDisplay(@"planning",0,@"",-1,-1,-1,sim)];
    AMapNaviPoint *end=[AMapNaviPoint locationWithLatitude:self.destination.latitude longitude:self.destination.longitude];
    // Voice realtime passes its step-1 fix as the explicit origin so background
    // planning never waits on the SDK's (pausable) internal location engine;
    // sim keeps its simulation start; manual realtime lets the SDK use the
    // current position (WithEndPoints) as before.
    BOOL voiceOrigin=!sim&&self.voiceSession&&self.hasVoiceFix;
    AMapNaviPoint *start=sim?[AMapNaviPoint locationWithLatitude:self.simulationStart.latitude longitude:self.simulationStart.longitude]:(voiceOrigin?[AMapNaviPoint locationWithLatitude:self.voiceFix.latitude longitude:self.voiceFix.longitude]:nil);
    BOOL submitted=TIONavigationCalculate(manager,self.sessionTransport,sim,start,end);
    if(!sim)self.map.showsUserLocation=YES;
    if(!submitted){[self fail:@"SDK 未接受算路请求，请核对 Key、网络和定位"];if(self.voiceSession)TIOVoiceNavTrace(@"中止：SDK未接受算路请求");return;}
    if(self.voiceSession){TIOVoiceNavTrace(voiceOrigin?@"第3步：算路已提交（以第1步定位为起点，后台安全）":@"第3步：算路请求已提交，等待结果");[self enterVoiceStage:TIONavVoiceStagePlanning title:@"第3步：算路中"];}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,45*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(self.generation==generation&&self.planning){[self fail:@"45 秒未收到算路结果；已停止，本次结果未知"];if(self.voiceSession)TIOVoiceNavTrace(@"中止：45秒未收到算路结果（引擎内部定位可能被暂停）");}});
}
- (void)fail:(NSString *)message{BOOL wasVoice=self.voiceSession;NSString *stage=TIONavVoiceStageName(self.voicePipelineStage);[self halt];self.note=message;[self setFrame:TIONavDisplay(@"error",0,@"",-1,-1,-1,self.simulated)];if(wasVoice){TIONavDiagHUDEvent(@"语音链路中止",stage);TIOAssistantEmit([NSString stringWithFormat:@"\n%@",message],YES);TIOVoiceCloseAssistantSession();}} // voice pipeline over: free the lens (emit BEFORE close, which cancels the owned turn)
- (void)navigationRouteSuccess:(id<TIONavigationManager>)manager{dispatch_async(dispatch_get_main_queue(),^{if(manager!=self.manager||!self.active)return;BOOL first=self.planning;self.planning=NO;self.rerouting=NO;self.lastInfo=NSProcessInfo.processInfo.systemUptime;self.staleShown=NO;[self drawRoute:manager.naviRoute];if(first){self.routeReady=YES;self.note=@"路线已准备，核对地图后点击开始。尚未向眼镜发送导航。";self.routeSummary.text=[NSString stringWithFormat:@"%.1f 公里   ·   约 %ld 分钟",manager.naviRoute.routeLength/1000.0,(long)MAX(1,(manager.naviRoute.routeTime+59)/60)];self.display=TIONavDisplay(@"ready",0,@"",-1,manager.naviRoute.routeLength,manager.naviRoute.routeTime,self.simulated);
        if(self.voiceSession){ // Voice flow: no human at the screen; start as soon as the route exists.
            TIOVoiceNavTrace(@"第3步完成：算路成功，1.2秒后自动开始导航");
            [self enterVoiceStage:TIONavVoiceStageRouteReady title:@"第3步完成：路线就绪"];
            NSUInteger g=self.generation;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{if(g==self.generation&&self.routeReady&&self.voiceSession)[self beginRoute];});
        }}else{self.note=@"已重新规划路线，请以手机指引为准；眼镜显示若已停止需手动开启。";}[self refresh];});}
- (void)navigationManager:(id<TIONavigationManager>)manager onCalculateRouteFailure:(NSError *)error{dispatch_async(dispatch_get_main_queue(),^{if(manager==self.manager&&self.active){[self fail:[NSString stringWithFormat:@"高德算路失败（code=%ld），检查 Key 服务权限／Bundle 绑定、网络与路线",(long)error.code]];if(self.voiceSession)TIOVoiceNavTrace([NSString stringWithFormat:@"中止：算路失败 code=%ld",(long)error.code]);}});}
- (void)navigationManager:(id<TIONavigationManager>)manager error:(NSError *)error{dispatch_async(dispatch_get_main_queue(),^{if(manager==self.manager&&self.active){[self fail:[NSString stringWithFormat:@"高德引擎错误 code=%ld",(long)error.code]];if(self.voiceSession)TIOVoiceNavTrace([NSString stringWithFormat:@"中止：引擎错误 code=%ld",(long)error.code]);}});}
#if TIO_AMAP_ENABLED
// Route-ahead coordinate collection with a DISTANCE budget (~900m): everything
// within reach of the next few turns is included (up to 10 segments / 512
// points), so the lens minimap reads as "the route around here" rather than a
// fixed small number of segments. Rough straight-line cutoff keeps it cheap.
static NSMutableArray *TIONavAheadCoords(NSArray<AMapNaviSegment *> *segments,NSUInteger seg,NSUInteger link,NSUInteger point){
 NSMutableArray *coords=[NSMutableArray new];double lat0=0,lon0=0;BOOL anchored=NO;
 for(NSUInteger si=seg;si<segments.count&&coords.count<512&&si<seg+10;si++){
  NSArray<AMapNaviLink *> *links=segments[si].links;
  for(NSUInteger li=(si==seg?link:0);li<links.count&&coords.count<512;li++){
   NSArray<AMapNaviPoint *> *points=links[li].coordinates;
   for(NSUInteger pi=(si==seg&&li==link?point:0);pi<points.count&&coords.count<512;pi++){AMapNaviPoint *p=points[pi];[coords addObject:@[@(p.latitude),@(p.longitude)]];if(!anchored){anchored=YES;lat0=p.latitude;lon0=p.longitude;}}
  }
  if(coords.count>=8){id c=coords.lastObject;double lat=[c[0] doubleValue],lon=[c[1] doubleValue];if(hypot((lat-lat0)*111000,(lon-lon0)*111000*cos(lat0*M_PI/180))>=900)break;}
 }
 return coords;
}
#endif
- (void)navigationManager:(id<TIONavigationManager>)manager updateNaviInfo:(AMapNaviInfo *)info{
 if(!info)return;
 /* 模拟导航合成车速：高德模拟器不下发有效的 AMapNaviLocation.speed（实测速度读数缺失），
  * 用剩余里程差分推导（1 Hz 本回调驱动，dt 窗口过滤乱帧）。仅模拟会话启用。 */
 if(self.simulated&&self.active&&info.routeRemainDistance>=0&&info.routeRemainTime>=0){
  NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
  if(self.lastSpeedSampleAt>0){
   double dt=now-self.lastSpeedSampleAt;long dm=(long)self.lastRemainingMetersForSpeed-(long)info.routeRemainDistance;
   if(dt>=0.8&&dt<=3.0&&dm>=0&&dm<2000){NSInteger derived=(NSInteger)(dm/dt*3.6+0.5);if(derived>=0&&derived<=511)self.navSpeedKmh=derived;}
  }
  self.lastSpeedSampleAt=now;self.lastRemainingMetersForSpeed=info.routeRemainDistance;
 }
 NSMutableDictionary *frame=[TIONavDisplay(@"navigating",info.iconType,info.nextRoadName,info.segmentRemainDistance,info.routeRemainDistance,info.routeRemainTime,self.simulated) mutableCopy];frame[@"segment"]=@(info.currentSegmentIndex);frame[@"remainingMeters"]=@(info.routeRemainDistance);frame[@"remainingSeconds"]=@(info.routeRemainTime);frame[@"lights"]=@(info.routeRemainTrafficLightCount);
 if(self.navSpeedKmh>=0)frame[@"speedKmh"]=@(self.navSpeedKmh); /* AMapNaviLocation.speed 单位 km/h；喂给 TNV EXT3 尾巴驱动 HUD 限速旁车速读数 */
 if(self.navHeadingDeg>=0)frame[@"navHeading"]=@(self.navHeadingDeg); /* 车头朝上旋转角；不喂则 HUD 旋转 0 度=假北向 */
 NSInteger segment=info.currentSegmentIndex,link=info.currentLinkIndex,point=info.currentPointIndex;
 dispatch_async(dispatch_get_main_queue(),^{if(manager!=self.manager||!self.active||self.routeReady||self.planning||self.rerouting)return;
  NSArray<AMapNaviSegment *> *segments=manager.naviRoute.routeSegments;NSMutableArray *coords=[NSMutableArray new];
  if(segment>=0&&segment<(NSInteger)segments.count&&link>=0&&point>=0)coords=TIONavAheadCoords(segments,(NSUInteger)segment,(NSUInteger)link,(NSUInteger)point);
#if TIO_DISPLAY_PHONE
  // 模拟导航/静止时 updateNaviLocation 可能不报（引擎不驱动模拟定位回调），
  // 矢量小地图的原点与航向改从路线当前点推导——路网不再依赖 GPS 回调。
  if(coords.count>=2&&NSProcessInfo.processInfo.systemUptime-self.roadLocationAt>2){
   self.roadLocation=coords.firstObject;self.roadLocationAt=NSProcessInfo.processInfo.systemUptime;
   double lat0=[coords[0][0] doubleValue],lon0=[coords[0][1] doubleValue],lat1=[coords[1][0] doubleValue],lon1=[coords[1][1] doubleValue];
   double bearing=fmod(atan2((lon1-lon0)*cos(lat0*M_PI/180),lat1-lat0)*180/M_PI+360,360);
   self.roadHeading=bearing;if(self.navHeadingDeg<0)self.navHeadingDeg=(NSInteger)bearing%360;
  }
#endif
  [frame addEntriesFromDictionary:TNVNormalizeCoordinates(coords)];[self applySceneExtensions:frame];self.lastInfo=NSProcessInfo.processInfo.systemUptime;self.staleShown=NO;[self setFrame:frame];
 });
}
- (void)navigationReroute:(id<TIONavigationManager>)manager{dispatch_async(dispatch_get_main_queue(),^{if(manager==self.manager&&self.active){self.rerouting=YES;self.note=@"偏航，等待高德重新规划";[self clearSceneExtensionState];[self setFrame:TIONavDisplay(@"rerouting",0,@"",-1,-1,-1,self.simulated)];}});}
- (void)drawRoute:(AMapNaviRoute *)route{NSArray<AMapNaviPoint *> *points=route.routeCoordinates;if(points.count<2||points.count>100000)return;
 NSMutableArray *roadLL=[NSMutableArray new];NSUInteger roadStride=1+(points.count-1)/4096; /* RoadMap 自带 500m 裁剪，这里只限制 ObjC 数组规模 */
 for(NSUInteger i=0;i<points.count;i+=roadStride)[roadLL addObject:@[@(points[i].latitude),@(points[i].longitude)]];
#if TIO_DISPLAY_PHONE
 self.roadCoordinates=roadLL;
#endif
 CLLocationCoordinate2D *coords=calloc(points.count,sizeof(CLLocationCoordinate2D));if(!coords)return;for(NSUInteger i=0;i<points.count;i++)coords[i]=CLLocationCoordinate2DMake(points[i].latitude,points[i].longitude);if(self.routeLine)[self.map removeOverlay:self.routeLine];self.routeLine=[MAPolyline polylineWithCoordinates:coords count:points.count];free(coords);[self.map addOverlay:self.routeLine];[self.map setVisibleMapRect:self.routeLine.boundingMapRect edgePadding:UIEdgeInsetsMake(30,25,30,25) animated:YES];}
- (MAOverlayRenderer *)mapView:(MAMapView *)map rendererForOverlay:(id<MAOverlay>)overlay{if([overlay isKindOfClass:MAPolyline.class]){MAPolylineRenderer *r=[[MAPolylineRenderer alloc]initWithPolyline:overlay];r.lineWidth=6;r.strokeColor=UIColor.systemIndigoColor;return r;}return nil;}
- (void)navigationManager:(id<TIONavigationManager>)manager updateGPSSignalStrength:(AMapNaviGPSSignalStrength)strength{dispatch_async(dispatch_get_main_queue(),^{if(manager!=self.manager||!self.active||self.simulated)return;self.gpsWeak=strength!=AMapNaviGPSSignalStrengthStrong&&strength!=AMapNaviGPSSignalStrengthSmartPos; // AMap's guidance stream is the authority; only surface a weak-state frame when AMap itself has gone quiet, so live guidance never flickers.
 if(self.gpsWeak&&NSProcessInfo.processInfo.systemUptime-self.lastInfo>15)[self setFrame:TIONavDisplay(@"weak",0,@"",-1,-1,-1,NO)];});}
- (void)arrived:(id<TIONavigationManager>)manager{dispatch_async(dispatch_get_main_queue(),^{if(manager!=self.manager||!self.active)return;[self halt];self.note=@"已到达；导航已停止，10 秒后清理本次导航卡";TIOVoiceNavTrace(@"已到达目的地：导航自动结束，10秒后收尾眼镜显示");[self setFrame:TIONavDisplay(@"arrived",0,@"",0,0,0,self.simulated)];NSUInteger g=self.generation;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(g==self.generation)TIONavEnableDisplay(NO);});});}
- (void)walkManagerOnCalculateRouteSuccess:(AMapNaviWalkManager *)m{[self navigationRouteSuccess:(id)m];}
- (void)walkManager:(AMapNaviWalkManager *)m onCalculateRouteFailure:(NSError *)e{[self navigationManager:(id)m onCalculateRouteFailure:e];}
- (void)walkManager:(AMapNaviWalkManager *)m error:(NSError *)e{[self navigationManager:(id)m error:e];}
- (void)walkManager:(AMapNaviWalkManager *)m updateNaviInfo:(AMapNaviInfo *)info{[self navigationManager:(id)m updateNaviInfo:info];}
- (void)walkManager:(AMapNaviWalkManager *)m updateGPSSignalStrength:(AMapNaviGPSSignalStrength)s{[self navigationManager:(id)m updateGPSSignalStrength:s];}
- (void)walkManagerNeedRecalculateRouteForYaw:(AMapNaviWalkManager *)m{[self navigationReroute:(id)m];}
- (void)walkManagerDidEndEmulatorNavi:(AMapNaviWalkManager *)m{[self arrived:(id)m];}
- (void)walkManagerOnArrivedDestination:(AMapNaviWalkManager *)m{[self arrived:(id)m];}
- (void)rideManagerOnCalculateRouteSuccess:(AMapNaviRideManager *)m{[self navigationRouteSuccess:(id)m];}
- (void)rideManager:(AMapNaviRideManager *)m onCalculateRouteFailure:(NSError *)e{[self navigationManager:(id)m onCalculateRouteFailure:e];}
- (void)rideManager:(AMapNaviRideManager *)m error:(NSError *)e{[self navigationManager:(id)m error:e];}
- (void)rideManager:(AMapNaviRideManager *)m updateNaviInfo:(AMapNaviInfo *)info{[self navigationManager:(id)m updateNaviInfo:info];}
- (void)rideManager:(AMapNaviRideManager *)m updateGPSSignalStrength:(AMapNaviGPSSignalStrength)s{[self navigationManager:(id)m updateGPSSignalStrength:s];}
- (void)rideManagerNeedRecalculateRouteForYaw:(AMapNaviRideManager *)m{[self navigationReroute:(id)m];}
- (void)rideManagerDidEndEmulatorNavi:(AMapNaviRideManager *)m{[self arrived:(id)m];}
- (void)rideManagerOnArrivedDestination:(AMapNaviRideManager *)m{[self arrived:(id)m];}
- (void)driveManagerOnCalculateRouteSuccess:(AMapNaviDriveManager *)m{[self navigationRouteSuccess:(id)m];}
- (void)driveManager:(AMapNaviDriveManager *)m onCalculateRouteFailure:(NSError *)e{[self navigationManager:(id)m onCalculateRouteFailure:e];}
- (void)driveManager:(AMapNaviDriveManager *)m error:(NSError *)e{[self navigationManager:(id)m error:e];}
- (void)driveManager:(AMapNaviDriveManager *)m updateNaviInfo:(AMapNaviInfo *)info{[self navigationManager:(id)m updateNaviInfo:info];}
- (void)driveManager:(AMapNaviDriveManager *)m updateGPSSignalStrength:(AMapNaviGPSSignalStrength)s{[self navigationManager:(id)m updateGPSSignalStrength:s];}
- (void)driveManagerNeedRecalculateRouteForYaw:(AMapNaviDriveManager *)m{[self navigationReroute:(id)m];}
- (void)driveManagerDidEndEmulatorNavi:(AMapNaviDriveManager *)m{[self arrived:(id)m];}
- (void)driveManagerOnArrivedDestination:(AMapNaviDriveManager *)m{[self arrived:(id)m];}
- (void)driveManagerNeedRecalculateRouteForTrafficJam:(AMapNaviDriveManager *)m{[self navigationReroute:(id)m];}
// Extension scene data rides the same TNV frame: bar levels, nearest camera,
// first route event. All sources are standard AMap representable callbacks and
// every refresh goes through setFrame, so stale values survive only until the
// next push and a reroute clears them outright.
- (NSArray<NSNumber *> *)levelsFromTrafficStatus:(NSArray<AMapNaviTrafficStatus *> *)status{
 double coverage[24]={0},at=0;NSInteger best[24]={0};BOOL any=NO;
 for(AMapNaviTrafficStatus *t in status){
  NSInteger length=t.length;if(length<=0)continue;any=YES;NSInteger level=0;
  switch(t.status){case AMapNaviRouteStatusSmooth:case AMapNaviRouteStatusFineOpen:level=1;break;case AMapNaviRouteStatusSlow:level=2;break;case AMapNaviRouteStatusJam:level=3;break;case AMapNaviRouteStatusSeriousJam:level=4;break;default:break;}
  double end=MIN(900,at+length);
  while(at<end){unsigned bucket=(unsigned)(at*24/900);double edge=(bucket+1)*900.0/24,next=MIN(end,edge),span=next-at;
   if(level>0&&(span>coverage[bucket]||(span==coverage[bucket]&&level>best[bucket]))){coverage[bucket]=span;best[bucket]=level;}at=next;
  }
  if(at>=900)break;
 }
 if(!any)return @[];NSMutableArray *levels=[NSMutableArray arrayWithCapacity:24];for(unsigned i=0;i<24;i++)[levels addObject:@(best[i])];return levels;
}
- (void)clearSceneExtensionState{self.trafficBarLevels=nil;self.cameraKind=0;self.cameraLimit=-1;self.cameraMeters=65535;self.eventKind=0;self.eventMeters=65535;self.lightMeters=65535;self.lightDistances=nil;self.cameraList=nil;self.serviceAreas=nil;self.trafficFacilities=nil;self.roadSpeedLimit=-1;self.lastSpeedSampleAt=0;self.lastRemainingMetersForSpeed=0;}
// TNV is a full-scene replace: extension keys must ride EVERY navigating frame,
// otherwise the 1 Hz naviInfo frame wipes the bar/alert lines between callbacks.
- (void)applySceneExtensions:(NSMutableDictionary *)frame{
 if(self.trafficBarLevels)frame[@"barLevels"]=self.trafficBarLevels;
 if(self.lightMeters<65535)frame[@"lightsMeters"]=@(self.lightMeters); /* nearest red-light camera = real distance to a light-controlled junction */
 if(self.lightDistances.count)frame[@"lightsList"]=self.lightDistances; /* per-light glyphs, EXT2 */
 if(self.roadSpeedLimit>=0)frame[@"roadLimit"]=@(self.roadSpeedLimit); /* 0 = 高德明确回报本段无限速；常驻徽章据此隐藏 */
 else if(self.simulated&&self.cameraKind==1&&self.cameraLimit>0&&self.cameraMeters<=1000)frame[@"roadLimit"]=@(self.cameraLimit); /* 模拟导航无路段限速回调：用 1km 内测速相机限速顶位，验收时徽章/超速警报可见 */
 if(self.cameraList.count)frame[@"camList"]=self.cameraList; /* 沿路电子眼全量，钉在路网对应位置 */
 if(self.serviceAreas.count||self.trafficFacilities.count){NSMutableArray *all=[NSMutableArray arrayWithArray:self.serviceAreas?:@[]];[all addObjectsFromArray:self.trafficFacilities?:@[]];
  [all sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"m"] compare:b[@"m"]];}]; /* 近→远 */
  if(all.count>12)[all removeObjectsInRange:NSMakeRange(12,all.count-12)];
  frame[@"facList"]=all;} /* 特殊设施全量：服务区/收费站/检查站/隧道/渡口/警示… */
 if(self.cameraKind){NSMutableDictionary *camera=[@{@"kind":@(self.cameraKind),@"limit":@(self.cameraLimit)} mutableCopy];if(self.cameraMeters<65535)camera[@"m"]=@(self.cameraMeters);frame[@"camera"]=camera;}
 if(self.eventKind){NSMutableDictionary *event=[@{@"kind":@(self.eventKind)} mutableCopy];if(self.eventMeters<65535)event[@"m"]=@(self.eventMeters);frame[@"event"]=event;}}
- (void)offerSceneRefresh{if(![self.display[@"phase"] isEqual:@"navigating"])return;NSMutableDictionary *f=[self.display mutableCopy];[self applySceneExtensions:f];[self setFrame:f];}
- (void)driveManager:(AMapNaviDriveManager *)m updateNaviLocation:(AMapNaviLocation *)loc{dispatch_async(dispatch_get_main_queue(),^{if((id)m!=self.manager||!self.active||!loc)return;self.navLat=loc.coordinate.latitude;self.navLon=loc.coordinate.longitude;if(loc.speed>0&&loc.speed<=511)self.navSpeedKmh=(NSInteger)loc.speed;else if(!self.simulated&&loc.speed==0)self.navSpeedKmh=0; /* 模拟器高频下发 speed=0 的无效值，清零会盖掉 updateNaviInfo 差分合成的车速；真实导航静止才置 0 */if(loc.heading>=0&&loc.heading<360)self.navHeadingDeg=(NSInteger)loc.heading;
#if TIO_DISPLAY_PHONE
self.roadLocation=@[@(loc.coordinate.latitude),@(loc.coordinate.longitude)];if(loc.heading>=0&&loc.heading<360)self.roadHeading=fmod(loc.heading+720,360);self.roadLocationAt=NSProcessInfo.processInfo.systemUptime;
#endif
});}
- (void)walkManager:(AMapNaviWalkManager *)m updateNaviLocation:(AMapNaviLocation *)loc{[self driveManager:(AMapNaviDriveManager *)m updateNaviLocation:loc];} /* 步行导航同样喂速度/航向（id 桥接仅取公共属性） */
- (void)rideManager:(AMapNaviRideManager *)m updateNaviLocation:(AMapNaviLocation *)loc{[self driveManager:(AMapNaviDriveManager *)m updateNaviLocation:loc];}
- (void)driveManager:(AMapNaviDriveManager *)m updateTrafficStatus:(NSArray<AMapNaviTrafficStatus *> *)status{dispatch_async(dispatch_get_main_queue(),^{if((id)m!=self.manager||!self.active)return;self.trafficBarLevels=[self levelsFromTrafficStatus:status];[self offerSceneRefresh];});}
- (void)driveManager:(AMapNaviDriveManager *)m updateCameraInfos:(NSArray<AMapNaviCameraInfo *> *)cams{dispatch_async(dispatch_get_main_queue(),^{if((id)m!=self.manager||!self.active)return;
 /* 测速类（含流动测速）单独跟踪：城市道路闯红灯/监控相机密集，"最近通吃"
  * 会让限速相机永远排不上槽，限速圈因此从不出现。测速相机 1km 内优先占槽，
  * 以外让给其他相机；限速值另有路段限速回调常驻显示，不依赖相机槽。 */
 AMapNaviCameraInfo *speedCam=nil,*nearCam=nil;NSMutableArray<NSNumber *> *lights=[NSMutableArray array];NSInteger lightM=65535;
 for(AMapNaviCameraInfo *c in cams){if(c.distance<0)continue;
  if(c.cameraType==AMapNaviCameraTypeSpeed||c.cameraType==AMapNaviCameraTypeFlowSpeed){if(!speedCam||c.distance<speedCam.distance)speedCam=c;}
  else if(!nearCam||c.distance<nearCam.distance)nearCam=c;
  if(c.cameraType==AMapNaviCameraTypeTrafficLight){if(c.distance<lightM)lightM=c.distance>65534?65534:(NSInteger)c.distance;if(lights.count<8)[lights addObject:@(c.distance>65534?65534:c.distance)];}} /* red-light cameras sit on light-controlled junctions: nearest one approximates lights_m with real data */
 [lights sortUsingSelector:@selector(compare:)]; /* nearest first, matching the wire contract */
 /* 全量相机列表（EXT5 camList）：像真导航一样把每个电子眼钉在路网对应位置，
  * 不再只画"最近一个"。按距离排序，上限 16 个；与单槽 alert 优先级互不干扰。 */
 NSMutableArray *all=[NSMutableArray array];for(AMapNaviCameraInfo *c in cams)if(c.distance>=0)[all addObject:c];
 [all sortUsingComparator:^NSComparisonResult(AMapNaviCameraInfo *a,AMapNaviCameraInfo *b){return a.distance<b.distance?NSOrderedAscending:a.distance>b.distance?NSOrderedDescending:NSOrderedSame;}];
 NSMutableArray *cl=[NSMutableArray array];
 for(AMapNaviCameraInfo *c in all){if(cl.count>=16)break;long k;
  switch(c.cameraType){case AMapNaviCameraTypeSpeed:case AMapNaviCameraTypeFlowSpeed:k=1;break;
  case AMapNaviCameraTypeTrafficLight:continue; /* 红灯相机已由 lightsList 以红绿灯 glyph 呈现，不重复占标 */
  case AMapNaviCameraTypeSurveillance:k=3;break;case AMapNaviCameraTypeIntervalVelocityStart:case AMapNaviCameraTypeIntervalVelocityEnd:k=4;break;default:k=5;}
  [cl addObject:@{@"kind":@(k),@"limit":@(c.cameraSpeed>0?MIN((NSInteger)c.cameraSpeed,200):0),@"m":@(c.distance>65534?65534:c.distance)}];}
 self.cameraList=cl.count?cl:nil;
 AMapNaviCameraInfo *best=(speedCam&&speedCam.distance<=1000)?speedCam:(nearCam?:speedCam);
 NSInteger kind=0,limit=-1;NSUInteger meters=65535;
 if(best){switch(best.cameraType){case AMapNaviCameraTypeSpeed:case AMapNaviCameraTypeFlowSpeed:kind=1;break;case AMapNaviCameraTypeTrafficLight:kind=2;break;case AMapNaviCameraTypeSurveillance:kind=3;break;case AMapNaviCameraTypeIntervalVelocityStart:case AMapNaviCameraTypeIntervalVelocityEnd:kind=4;break;default:kind=5;}
  limit=best.cameraSpeed>0?(NSInteger)best.cameraSpeed:-1;meters=best.distance>65534?65534:(NSUInteger)best.distance;}
 self.cameraKind=kind;self.cameraLimit=limit;self.cameraMeters=meters;self.lightMeters=(NSUInteger)lightM;self.lightDistances=lights.count?lights:nil;[self offerSceneRefresh];});}
- (void)driveManager:(AMapNaviDriveManager *)m onUpdateNaviSpeedLimitSection:(NSInteger)speed{dispatch_async(dispatch_get_main_queue(),^{if((id)m!=self.manager||!self.active)return;self.roadSpeedLimit=speed<0?0:speed;[self offerSceneRefresh];});} /* SDK 9.6+：进入新路段回调限速，无限速路段回 0；常驻徽章的数据源 */
- (void)driveManager:(AMapNaviDriveManager *)m updateTrafficEvents:(NSArray<AMapNaviRouteTrafficEventInfo *> *)events{dispatch_async(dispatch_get_main_queue(),^{if((id)m!=self.manager||!self.active)return;
 NSInteger kind=0;NSUInteger meters=65535;BOOL found=NO; /* nearest event wins, matching the camera rule */
 for(AMapNaviRouteTrafficEventInfo *route in events){for(AMapNaviTrafficEventItem *it in route.infoList){
  NSInteger k=(NSInteger)it.type;if(k<0||k>4)k=0;
  NSUInteger dm=65535;
  if(self.navLat!=0||self.navLon!=0){double dlat=it.coord.latitude-self.navLat,dlon=it.coord.longitude-self.navLon,d=hypot(dlat*111000,dlon*111000*cos(self.navLat*M_PI/180));dm=d>65534?65534:(NSUInteger)d;}
  if(!found||dm<meters){found=YES;kind=k;meters=dm;}}}
 self.eventKind=found?kind:0;self.eventMeters=meters;[self offerSceneRefresh];});}
- (void)driveManager:(AMapNaviDriveManager *)m updateServiceAreaInfos:(NSArray<AMapNaviServiceAreaInfo *> *)infos{dispatch_async(dispatch_get_main_queue(),^{if((id)m!=self.manager||!self.active)return;
 /* 服务区/收费站/检查站（type 0/1/2 → kind 1/2/3，since 5.0.0 回调） */
 NSMutableArray *a=[NSMutableArray array];
 for(AMapNaviServiceAreaInfo *s in infos){if(s.remainDistance<0)continue;
  [a addObject:@{@"kind":@(s.type+1),@"m":@(s.remainDistance>65534?65534:s.remainDistance)}];}
 self.serviceAreas=a.count?a:nil;[self offerSceneRefresh];});}
- (void)driveManager:(AMapNaviDriveManager *)m updateTrafficFacilities:(NSArray<AMapNaviTrafficFacilityInfo *> *)facs{dispatch_async(dispatch_get_main_queue(),^{if((id)m!=self.manager||!self.active)return;
 /* 警示类道路设施（boardcastType → kind 4..12）。相机类（4/5/28/29/92/93/94）由
  * updateCameraInfos 走电子眼链路呈现，这里跳过避免双标。 */
 NSMutableArray *a=[NSMutableArray array];
 for(AMapNaviTrafficFacilityInfo *f in facs){if(f.distance<0)continue;long k;
  switch(f.boardcastType){
   case 58:k=4;break;case 59:k=5;break; /* 隧道/渡口 */
   case 6:case 14:case 53:case 100:k=6;break; /* 事故易发/违章高发 */
   case 22:case 23:case 24:case 25:k=7;break; /* 急弯/反向弯/连续弯 */
   case 21:case 36:case 37:case 38:k=8;break; /* 窄路/窄桥/变窄 */
   case 47:case 48:k=9;break; /* 陡坡 */
   case 12:case 19:case 20:k=10;break; /* 铁路道口 */
   case 16:case 18:k=11;break; /* 村庄/学校 */
   case 4:case 5:case 28:case 29:case 92:case 93:case 94:continue; /* 相机类走电子眼 */
   default:k=12;break;} /* 落石/横风/过水/绕行/慢行/限高等其他警示 */
  [a addObject:@{@"kind":@(k),@"m":@(f.distance>65534?65534:f.distance)}];}
 self.trafficFacilities=a.count?a:nil;[self offerSceneRefresh];});}
#endif
#include "NavigationDisplayHUD.inc"
#include "NavigationWorkspace.inc"
@end
// Passive NLP keyword observer. Fires at most once per 8s; opt-out key
// voiceNavDisabled (default: enabled). Destinations 2-40 chars after the
// trigger word.
static NSTimeInterval LastVoiceNavAt=0;
// Single shared panel: the visible research page and the headless voice flow
// use the SAME instance. A running session therefore survives the page
// closing (the static retains the panel, the timer keeps feeding the glasses)
// and reopening the page reattaches to it, so 结束导航 always works.
static TIONavigationPanel *SharedNavPanel=nil;
// The voice flow is fully headless: no page is opened or presented. The panel
// loads its view off-screen (which initializes the AMap SDK and location), runs
// the search-plan-navigate pipeline, and the glasses HUD engages on its own.
// The voice assistant's own chat UI stays untouched and dismisses normally.
// Every step appends to TIOVoiceNavTrace (shown in 适配与回调) so a silent
// off-screen failure is still diagnosable.
void TIOVoiceNavStop(void){[SharedNavPanel stopUser];}
// Pending candidate dialog state, consumed by Addon.m's ASR/NLP choice parser.
NSUInteger TIOVoiceNavPendingChoices(void){return SharedNavPanel.voiceCandidates.count;}
BOOL TIOVoiceNavChoose(NSUInteger oneBasedIndex){
    if(!oneBasedIndex)return NO;
    __block BOOL ok=NO;
    void (^work)(void)=^{ok=[SharedNavPanel voiceChoose:oneBasedIndex-1];};
    if(NSThread.isMainThread)work();else dispatch_sync(dispatch_get_main_queue(),work);
    return ok;
}
void TIOVoiceNavReject(void){
    void (^work)(void)=^{[SharedNavPanel voiceRejectCandidates];};
    if(NSThread.isMainThread)work();else dispatch_async(dispatch_get_main_queue(),work);
}
// Travel-mode follow-up ("怎么去？"), consumed by Addon.m's ASR/NLP hooks
// exactly like the candidate dialog.
BOOL TIOVoiceNavPendingMode(void){return SharedNavPanel.voiceAwaitingMode;}
// Parse a short spoken mode answer: 步行/骑行/驾车 with colloquial aliases.
// Long utterances are new intents, not mode answers. Returns the mode,
// 0 = not a mode answer, -1 = "随便/都行" (apply the distance-aware fallback).
static NSInteger TIOVoiceParseModeAnswer(NSString *text){
    if(![text isKindOfClass:NSString.class]||!text.length||text.length>20)return 0;
    for(NSString *w in @[@"骑行",@"骑车",@"自行车",@"单车",@"电动车",@"摩托"])if([text rangeOfString:w].location!=NSNotFound)return TIONavigationRide;
    for(NSString *w in @[@"驾车",@"开车",@"自驾",@"打车",@"汽车",@"出租"])if([text rangeOfString:w].location!=NSNotFound)return TIONavigationDrive;
    for(NSString *w in @[@"步行",@"走路",@"徒步",@"走过去"])if([text rangeOfString:w].location!=NSNotFound)return TIONavigationWalk;
    for(NSString *w in @[@"随便",@"都行",@"都可以",@"你定",@"看着办"])if([text rangeOfString:w].location!=NSNotFound)return -1;
    return 0;
}
BOOL TIOVoiceNavChooseMode(NSString *text){
    __block BOOL ok=NO;
    void (^work)(void)=^{
        if(!SharedNavPanel.voiceAwaitingMode)return;
        NSInteger mode=TIOVoiceParseModeAnswer(text);if(!mode)return;
        if(mode<0)mode=SharedNavPanel.voiceModeFallback;
        [SharedNavPanel voicePickMode:mode announced:@"（语音选择）"];ok=YES;
    };
    if(NSThread.isMainThread)work();else dispatch_sync(dispatch_get_main_queue(),work);
    return ok;
}
// Pure matcher shared by the NLP trigger and the reply hijack: normalize the
// utterance (trim, strip trailing punctuation/speech prefixes) and return the
// destination (with trailing travel-mode words removed), or nil if no trigger.
// No side effects, no throttle -- callers decide what to do with a match.
NSString *TIOVoiceNavMatchDestination(NSString *text){
    if(![text isKindOfClass:NSString.class])return nil;
    if([NSUserDefaults.standardUserDefaults boolForKey:@"voiceNavDisabled"])return nil;
    NSString *t=[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while(t.length){unichar c=[t characterAtIndex:t.length-1];if(c==0x3002||c==0xFF01||c==0xFF1F||c==0xFF0C||c==','||c=='.'||c=='!'||c=='?')t=[t substringToIndex:t.length-1];else break;}
    for(NSString *pre in @[@"帮我",@"请你",@"请",@"给我",@"我要帮我"])if([t hasPrefix:pre]){t=[t substringFromIndex:pre.length];break;}
    NSString *destination=nil;
    for(NSString *p in @[@"导航到",@"导航去",@"导航至",@"带我去",@"我要去",@"步行去",@"步行到",@"骑行去",@"骑行到",@"骑车去",@"骑车到",@"自行车去",@"驾车去",@"驾车到",@"开车去",@"开车到",@"自驾去"]){
        NSRange r=[t rangeOfString:p];
        if(r.location!=NSNotFound){
            NSString *d=[t substringFromIndex:r.location+p.length];
            d=[d stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if(d.length>=2&&d.length<=40){destination=d;break;}
        }
    }
    if(!destination)return nil;
    NSArray *trailing=@[@"步行",@"步行方式",@"骑行",@"骑车",@"自行车",@"单车",@"电动车",@"驾车",@"开车",@"自驾",@"打车"];
    for(NSString *w in trailing)while([destination hasSuffix:w])destination=[[destination substringToIndex:destination.length-w.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return destination.length>=2?destination:nil;
}
BOOL TIOVoiceNavMaybeStart(NSString *text){
    if(![text isKindOfClass:NSString.class])return NO;
    if([NSUserDefaults.standardUserDefaults boolForKey:@"voiceNavDisabled"]){TIOVoiceNavTrace(@"忽略：语音导航开关已关闭（导航页-更多里可重新开启）");return NO;}
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    NSString *destination=TIOVoiceNavMatchDestination(text);
    if(!destination){ // Ordinary chat turns miss too; log each distinct text once.
        static NSString *lastMiss=@"";
        if(![text isEqual:lastMiss]){lastMiss=[text copy];TIOVoiceNavTrace([NSString stringWithFormat:@"未命中导航关键词：%@",text]);}
        return NO;
    }
    // Throttle ONLY repeats of the same destination (one turn's NLP deltas echo
    // the same query). A different destination is a fresh user intent: restart
    // even inside the window -- stopUser below clears any pending candidate list.
    static NSString *lastDestination=nil;
    if(now-LastVoiceNavAt<8&&lastDestination&&[destination isEqualToString:lastDestination])return NO;
    // Travel mode: default WALK unless the utterance names ride/drive explicitly
    // (scanned on the raw text; trailing mode words were stripped by the matcher).
    // modeExplicit records whether the user already told us HOW to go -- only then
    // does the panel skip the "怎么去？" follow-up after the destination pick.
    NSInteger voiceMode=TIONavigationWalk;
    NSArray *rides=@[@"骑行",@"骑车",@"自行车",@"单车",@"电动车"],*drives=@[@"驾车",@"开车",@"自驾",@"打车"];
    for(NSString *w in rides)if([text rangeOfString:w].location!=NSNotFound){voiceMode=TIONavigationRide;break;}
    if(voiceMode==TIONavigationWalk)for(NSString *w in drives)if([text rangeOfString:w].location!=NSNotFound){voiceMode=TIONavigationDrive;break;}
    BOOL modeExplicit=voiceMode!=TIONavigationWalk;
    if(!modeExplicit)for(NSString *w in @[@"步行",@"走路",@"徒步"])if([text rangeOfString:w].location!=NSNotFound){modeExplicit=YES;break;}
    LastVoiceNavAt=now;lastDestination=[destination copy];
    TIOVoiceNavTraceReset();
    TIOVoiceNavTrace([NSString stringWithFormat:@"语音命中，终点「%@」，%@（%@）",destination,TIONavigationModeTitle(voiceMode),modeExplicit?@"语音指定":@"选点后追问"]);
    dispatch_async(dispatch_get_main_queue(),^{
        if(SharedNavPanel.active||SharedNavPanel.planning){TIOVoiceNavTrace(@"忽略：已有导航进行中");return;}
        [SharedNavPanel stopUser];
#if TIO_DISPLAY_PHONE
        if([TDPPhoneNavigationStatus()[@"active"] boolValue])TIONavDiagHUDEvent(@"语音触发",@"上一眼镜会话仍在，先等它退出再上镜");
#endif
        TIONavDiagHUDEvent(@"语音触发",TIONavigationModeTitle(voiceMode));
        SharedNavPanel=[TIONavigationPanel new];
        SharedNavPanel.selectedTransport=voiceMode; // Voice-specified travel mode; walk placeholder until the follow-up answers.
        SharedNavPanel.voiceModeExplicit=modeExplicit;
        [SharedNavPanel view]; // Force viewDidLoad: initializes AMap SDK, map, and location.
        [SharedNavPanel viewWillAppear:NO]; // Force the 1s tick timer (lifecycle method never fires off-screen).
        if(voiceMode==TIONavigationRide)TIOVoiceNavTrace(@"提示：眼镜原生导航不支持骑行，以手机指引为准");
        TIOVoiceNavTrace(@"无头导航已启动：定位→搜索→算路→导航");
        [SharedNavPanel voiceStart:destination];
        // No presentViewController. No UI. Glasses HUD appearing is the feedback.
    });
    return YES;
}
// Returns the SAME shared panel every time: opening the page during or after a
// voice navigation reattaches to the live session (visible on the map, and
// 结束导航 actually stops it). Closing the page never stops the session.
// No manual lifecycle calls here: the push itself drives viewWillAppear, and
// headless-created panels already got theirs from the voice flow.
UIViewController *TIONavigationController(void){
    if(!SharedNavPanel)SharedNavPanel=[TIONavigationPanel new];
    return SharedNavPanel;
}
