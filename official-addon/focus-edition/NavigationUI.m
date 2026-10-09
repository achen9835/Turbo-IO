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
@property BOOL voiceSession,voiceLifelogWasOn,voiceLocating;
#if TIO_AMAP_ENABLED
@property AMapSearchAPI *voiceSearch;
@property AMapPOIKeywordsSearchRequest *voiceRequest;
#endif
@property NSString *voiceQuery;
@property UIBackgroundTaskIdentifier navigationBackgroundTask;
@property NSUInteger backgroundEpoch;
@property NSString *destinationName;
@property CLLocationCoordinate2D simulationStart;
@property NSUInteger locationGeneration;
#if TIO_DISPLAY_PHONE
@property UIButton *tdpButton;
@property UILabel *tdpStatus;
@property BOOL autoNativeHUD;
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
    // Voice flow presents this panel as a bare modal (no research-shell back
    // stack); without an explicit exit the user gets trapped. Always offer one
    // when there is nothing to pop back to.
    if(self.navigationController.viewControllers.count<=1){
        self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc]initWithTitle:@"退出导航页" style:UIBarButtonItemStylePlain target:self action:@selector(voiceDismiss)];
    }
    self.permission=[CLLocationManager new];self.permission.delegate=self;self.navigationBackgroundTask=UIBackgroundTaskInvalid;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:@"TIONavigationChanged" object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stopUser) name:@"TIOResearchClosed" object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(navigationForeground) name:UIApplicationDidBecomeActiveNotification object:nil];
    self.display=TIONavDisplay(@"stopped",0,@"",-1,-1,-1,NO);[self refresh];
}
- (void)viewWillAppear:(BOOL)animated{[super viewWillAppear:animated];if(!self.timer){__weak typeof(self) weak=self;self.timer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t){[weak tick];}];} [self refresh];}
- (void)viewDidDisappear:(BOOL)animated{[super viewDidDisappear:animated];self.pendingMapAction=nil;if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive&&!self.isMovingFromParentViewController&&!self.isBeingDismissed&&!self.navigationController.isBeingDismissed)return;[self stopUser];[self.timer invalidate];self.timer=nil;}
- (void)dealloc{if(self.navigationBackgroundTask!=UIBackgroundTaskInvalid)[UIApplication.sharedApplication endBackgroundTask:self.navigationBackgroundTask];[self.subtitleHUD stop:@"导航页面已销毁"];[self.teleHUD stop:@"导航页面已销毁"];[self.timer invalidate];[NSNotificationCenter.defaultCenter removeObserver:self];}
- (void)refresh{if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self refresh];});return;}NSDictionary *s=TIONavTransportStatus(),*tele=self.teleHUD.status;self.statusLabel.text=[NSString stringWithFormat:@"%@\n常亮：%@ · 已提交%@帧\n通知：%@\n连接／卡片：%@\nKey：%@ · SDK：%@",self.note?:@"",tele[@"note"],tele[@"frames"],s[@"noticeNote"],s[@"note"],ReadNavKey().length?@"已配置（有效性待实际算路）":@"未配置",
#if TIO_AMAP_ENABLED
    @"11.2.100"
#else
    @"此构建未链接（仅离线夹具）"
#endif
    ];NSDictionary *sub=self.subtitleHUD.status;self.statusLabel.text=[NSString stringWithFormat:@"字幕：%@ · 已提交%@帧\n%@\n%@",sub[@"note"],sub[@"frames"],TIOSubtitleNavigationStatus()[@"note"],self.statusLabel.text];
    if(![sub isEqual:self.lastSubtitleDiagnostic]){self.lastSubtitleDiagnostic=sub;NSString *dir=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/TurboIOResearch/subtitle-hud"];[NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];NSMutableDictionary *report=[sub mutableCopy];report[@"time"]=@(NSDate.date.timeIntervalSince1970);[[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[dir stringByAppendingPathComponent:@"navigation.json"] options:NSDataWritingAtomic error:nil];}
    self.hudLabel.text=[NSString stringWithFormat:@"%@\n\n%@  %@\n%@\n%@",self.display[@"mode"]?:@"",self.display[@"turn"]?:@"",self.display[@"distance"]?:@"",self.display[@"road"]?:@"",self.display[@"summary"]?:@""];[self refreshWorkspace];
    if(![tele isEqual:self.lastTeleDiagnostic]){self.lastTeleDiagnostic=tele;NSString *dir=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TurboIOPrivateAddon"];[NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];NSMutableDictionary *d=[tele mutableCopy];d[@"time"]=@([NSDate.date timeIntervalSince1970]);NSString *p=[dir stringByAppendingPathComponent:@"navigation-tele-diagnostic.json"];[[NSJSONSerialization dataWithJSONObject:d options:0 error:nil] writeToFile:p options:NSDataWritingAtomic error:nil];[NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:p error:nil];}}
- (void)setFrame:(NSDictionary *)frame{
#if TIO_DISPLAY_PHONE
    if(![frame[@"phase"] isEqual:@"navigating"]||![frame[@"segment"] isEqual:self.display[@"segment"]])self.crossPixels=nil;
#endif
    self.display=frame;TIONavOfferDisplay(frame);[self.teleHUD offer:frame at:NSProcessInfo.processInfo.systemUptime];[self.subtitleHUD offer:frame at:NSProcessInfo.processInfo.systemUptime];
#if TIO_DISPLAY_PHONE
    TDPPhoneNavigationOffer([self displayHUDFrame]);[self autoStartNativeHUDIfNeeded];[self refreshDisplayHUD];
#endif
    [self refresh];}
- (void)tick{
#if TIO_DISPLAY_PHONE
    if(self.crossPixels&&NSProcessInfo.processInfo.systemUptime-self.crossReceived>12){self.crossPixels=nil;if([self.display[@"phase"] isEqual:@"navigating"])TDPPhoneNavigationOffer([self displayHUDFrame]);}
    TDPPhoneNavigationPump();[self refreshDisplayHUD];
#endif
    TIONavPump();[self.subtitleHUD pumpAt:NSProcessInfo.processInfo.systemUptime];[self.teleHUD pumpAt:NSProcessInfo.processInfo.systemUptime];[self refresh];if(self.fixture&&self.active){self.fixtureStep++;NSArray *icons=@[@9,@2,@3,@29,@15];NSUInteger i=MIN(self.fixtureStep/4,4);[self setFrame:TIONavDisplay(i==4?@"arrived":@"navigating",[icons[i] integerValue],@"模拟测试道路",MAX(0,160-(NSInteger)self.fixtureStep*10),850,720,YES)];if(i==4){self.fixture=NO;self.active=NO;self.note=@"离线夹具结束；手动停止以清理卡片";[self refresh];}}
    if(self.active&&!self.routeReady&&!self.fixture&&!self.planning&&!self.staleShown&&NSProcessInfo.processInfo.systemUptime-self.lastInfo>15){self.staleShown=YES;[self setFrame:TIONavDisplay(@"stale",0,@"",-1,-1,-1,self.simulated)];}}
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
    if(self.voiceLifelogWasOn){ // Voice flow owns the lifelog it paused; restore or surface honestly.
        if(TIOAOSetAudioSaving(YES))self.note=@"全天智记录音已恢复";
        else self.note=@"智记录音恢复未确认：请到官方页核对并重新开启";
    }
    self.voiceLifelogWasOn=NO;self.voiceSession=NO;self.voiceLocating=NO;
    self.navigationStarted=NO;self.autoNativeHUD=NO;self.backgroundLocationEnabled=NO;[self endNavigationBackgroundTask];
#if TIO_DISPLAY_PHONE
    TDPPhoneNavigationStop();self.hudIconPixels=nil;self.hudIconType=0;self.crossPixels=nil;
#endif
    [self.subtitleHUD stop:@"导航停止／切换路线"];
    [self.teleHUD stop:@"导航停止／切换路线"];
    self.generation++;self.locationGeneration++;self.locating=NO;[self.permission stopUpdatingLocation];self.routeReady=NO;self.active=NO;self.planning=NO;self.fixture=NO;self.rerouting=NO;
#if TIO_AMAP_ENABLED
    if(self.manager){BOOL owned=self.manager.delegate==self;[self.manager removeDataRepresentative:self];if(self.nativeHUD)[self.manager removeDataRepresentative:self.nativeHUD];if(owned){self.manager.allowsBackgroundLocationUpdates=NO;self.manager.pausesLocationUpdatesAutomatically=YES;self.manager.delegate=nil;[self.manager stopNavi];self.retiringManagerClass=TIONavigationManagerClass(self.sessionTransport);self.retiringManager=self.manager;}self.manager=nil;if(owned)dispatch_async(dispatch_get_main_queue(),^{[self finishRetiringManager:0];});}
    [self.nativeHUD removeFromSuperview];self.nativeHUD=nil;
    self.map.showsUserLocation=NO;
#endif
}
- (void)stopUser{[self halt];TIONavEnableNotices(NO);self.note=@"导航更新已停止并请求退出。字幕退出仍需镜片确认；未关闭时用实体按钮。不会自动重新开启。";self.routeSummary.text=@"导航已结束 · 可重新规划路线";self.display=TIONavDisplay(@"stopped",0,@"",-1,-1,-1,self.simulated);TIONavEnableDisplay(NO);[self refresh];}
- (void)voiceDismiss{
    [self stopUser];
    [self dismissViewControllerAnimated:YES completion:nil]; // also stops the modal that presented us
}
#pragma mark Voice entry ("导航去X" → full hands-free navigation)
// Flow per product decision: pause our modules, turn all-day lifelog off
// (remembering it was on), search the destination, plan realtime, auto-begin
// (which auto-engages the glasses HUD); arrival/stop restores the lifelog.
- (void)voiceStart:(NSString *)query{
    if(self.active||self.planning){self.note=@"语音导航：已有导航进行中，忽略新的语音指令";[self refresh];return;}
#if TIO_AMAP_ENABLED
    if(!ValidKey(ReadNavKey())){[self alert:@"语音导航不可用" message:@"尚未配置高德 Key；请在右上角更多里设置后再试。"] ;return;}
    self.voiceSession=YES;self.voiceQuery=[query copy];
    TMMusicPauseForVoice();TWReaderPauseForVoice();
    NSDictionary *ao=TIOAOStatus();
    BOOL lifelogOn=[ao isKindOfClass:NSDictionary.class]&&[ao[@"dumpEnabled"] boolValue];
    if(lifelogOn){
        BOOL off=TIOAOSetAudioSaving(NO);
        NSDictionary *after=TIOAOStatus();
        // Readback decides: only promise auto-restore for a state we actually changed.
        self.voiceLifelogWasOn=off&&[after isKindOfClass:NSDictionary.class]&&![after[@"dumpEnabled"] boolValue];
        if(!self.voiceLifelogWasOn)self.note=@"智记关闭未生效（该接口可能不控制眼镜端智记）；导航继续，结束后不做自动恢复";
    }
    if(![NSUserDefaults.standardUserDefaults boolForKey:NavConsent]){[self alert:@"语音导航需要先同意一次地图隐私" message:@"请在页面上点击“开启地图”完成一次同意，之后语音即可全程免手。"] ;self.voiceSession=NO;return;}
    [self openMap];
    if(!query.length){self.note=@"语音已打开导航；说出「导航去+地点」即可免手开始。";[self refresh];return;}
    if(!self.voiceSearch){[AMapSearchAPI updatePrivacyShow:AMapPrivacyShowStatusDidShow privacyInfo:AMapPrivacyInfoStatusDidContain];[AMapSearchAPI updatePrivacyAgree:AMapPrivacyAgreeStatusDidAgree];self.voiceSearch=[AMapSearchAPI new];self.voiceSearch.delegate=self;self.voiceSearch.timeout=18;}
    // Step 1: confirm the current position BEFORE anything else -- the route
    // must originate from a fresh fix, not an SDK fallback. Steps then run in
    // order: 定位 → 终点 → 规划 → 导航.
    CLAuthorizationStatus auth=self.permission.authorizationStatus;
    if(auth==kCLAuthorizationStatusNotDetermined||auth==kCLAuthorizationStatusDenied||auth==kCLAuthorizationStatusRestricted){[self fail:@"语音实时导航需要定位授权：请在系统设置允许定位后重试"] ;return;}
    self.voiceLocating=YES;self.map.showsUserLocation=YES;
    self.note=@"语音导航 第1步：正在定位当前位置（最多15秒）…";[self refresh];
    NSUInteger g=self.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(g==self.generation&&self.voiceLocating){self.voiceLocating=NO;[self fail:@”15秒未获得可靠位置：到开阔处重试，或用页面按钮手动规划”];}});
#else
    [self alert:@"语音导航不可用" message:@"此构建未链接高德 SDK。"];
#endif
}
#if TIO_AMAP_ENABLED
// Step 2 (after the position fix): search the spoken destination.
- (void)voiceSearchDestination{
    if(!self.voiceSession||!self.voiceQuery.length)return;
    AMapPOIKeywordsSearchRequest *r=[AMapPOIKeywordsSearchRequest new];r.keywords=self.voiceQuery;r.offset=10;r.page=1;self.voiceRequest=r;
    self.note=[NSString stringWithFormat:@"第2步：已定位。搜索目的地“%@”…",self.voiceQuery];[self refresh];
    [self.voiceSearch AMapPOIKeywordsSearch:r];
}
- (void)onPOISearchDone:(AMapPOISearchBaseRequest *)request response:(AMapPOISearchResponse *)response{
    dispatch_async(dispatch_get_main_queue(),^{
        if(request!=self.voiceRequest||!self.voiceSession)return;self.voiceRequest=nil;
        NSArray<AMapPOI *> *pois=response.pois;AMapPOI *first=nil;for(AMapPOI *poi in pois)if(poi.location){first=poi;break;}
        if(!first){[self fail:[NSString stringWithFormat:@"语音没找到“%@”：请说更完整的名称，或手动搜索",self.voiceQuery?:@""] ] ;return;}
        [self selectPlace:@{@"name":first.name?:@"目的地",@"address":[NSString stringWithFormat:@"%@ %@ %@",first.city?:@"",first.district?:@"",first.address?:@""],@"lat":@(first.location.latitude),@"lon":@(first.location.longitude)}];
        self.travelMode.selectedSegmentIndex=1; // Position is already confirmed; plan now, auto-begin follows.
        self.note=[NSString stringWithFormat:@"第2步：选定终点「%@」（搜索第一位）。第3步：规划实时路线…",first.name?:@""];
        [self refresh];[self startWalking];
    });
}
- (void)AMapSearchRequest:(id)request didFailWithError:(NSError *)error{
    dispatch_async(dispatch_get_main_queue(),^{if(request!=self.voiceRequest||!self.voiceSession)return;self.voiceRequest=nil;[self fail:[NSString stringWithFormat:@"语音搜索失败（code=%ld）：检查网络与Key搜索权限",(long)error.code] ] ;});
}
#endif
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
    if(!self.initialized){[self consent];return;}
    if(self.active||self.planning){[self alert:@"请先停止当前导航" message:@"避免两条路线的异步回调互相覆盖。"] ;return;}
    if(!self.hasDestination){[self alert:@"先选择终点" message:@"搜索目的地、长按地图选点，或使用更多中的北京演示路线。"] ;return;}
    if(sim){if(!self.hasSimulationStart){[self alert:@"请选择模拟起点" message:@"切换地图上方的“选模拟起点”，然后点击地图。"] ;return;}CLLocation *a=[[CLLocation alloc]initWithLatitude:self.simulationStart.latitude longitude:self.simulationStart.longitude],*b=[[CLLocation alloc]initWithLatitude:self.destination.latitude longitude:self.destination.longitude];if([a distanceFromLocation:b]<30){[self alert:@"起终点距离不足30米" message:@"切换“选模拟起点”后点击另一个位置，或重新选择终点。拖动地图本身不会改变起点。"] ;return;}}
    if(!sim){CLAuthorizationStatus auth=self.permission.authorizationStatus;if(auth==kCLAuthorizationStatusNotDetermined){[self.permission requestWhenInUseAuthorization];self.note=@"允许定位后，请再次规划实时路线";[self refresh];return;}if(auth==kCLAuthorizationStatusDenied||auth==kCLAuthorizationStatusRestricted){[self alert:@"定位未授权" message:@"请在系统设置允许定位，或者先使用不需要实际定位的模拟导航。"] ;return;}}
    if(self.retiringManagerClass){[self alert:@"正在释放旧导航引擎" message:@"请稍后再规划，不会带着旧路线切换模式。"] ;return;}
    Class cls=TIONavigationManagerClass(self.selectedTransport);if(!cls){[self alert:@"未知出行方式" message:@"请重新选择步行、骑行或驾车。"] ;return;}
    id<TIONavigationManager> manager=[(id<TIONavigationManagerFactory>)cls sharedInstance];if(!manager||manager.naviMode!=AMapNaviModeNone||(manager.delegate&&manager.delegate!=self)){[self alert:@"导航引擎被占用" message:@"请先结束其他导航。本扩展不会停止宿主已有导航，也不会偷偷退回步行算路。"] ;return;}
    self.sessionTransport=self.selectedTransport;
    self.manager=manager;manager.delegate=self;[manager addDataRepresentative:self];manager.isUseInternalTTS=NO;manager.screenAlwaysBright=NO;manager.allowsBackgroundLocationUpdates=NO;
#if TIO_DISPLAY_PHONE
    [self attachNativeHUD];
#endif
    self.active=YES;self.planning=YES;self.simulated=sim;self.fixture=NO;self.gpsWeak=NO;self.staleShown=NO;NSUInteger generation=++self.generation;
    self.note=[NSString stringWithFormat:@"%@%@算路中（%@）",TIONavigationModeTitle(self.sessionTransport),sim?@"模拟":@"实时",sim?@"联网，不使用实际定位":@"使用手机定位，开始后支持后台"];[self setFrame:TIONavDisplay(@"planning",0,@"",-1,-1,-1,sim)];
    AMapNaviPoint *end=[AMapNaviPoint locationWithLatitude:self.destination.latitude longitude:self.destination.longitude];
    BOOL submitted=TIONavigationCalculate(manager,self.sessionTransport,sim,[AMapNaviPoint locationWithLatitude:self.simulationStart.latitude longitude:self.simulationStart.longitude],end);
    if(!sim)self.map.showsUserLocation=YES;
    if(!submitted){[self fail:@"SDK 未接受算路请求，请核对 Key、网络和定位"] ;return;}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,45*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(self.generation==generation&&self.planning)[self fail:@"45 秒未收到算路结果；已停止，本次结果未知"] ;});
}
- (void)fail:(NSString *)message{[self halt];self.note=message;[self setFrame:TIONavDisplay(@"error",0,@"",-1,-1,-1,self.simulated)];}
- (void)navigationRouteSuccess:(id<TIONavigationManager>)manager{dispatch_async(dispatch_get_main_queue(),^{if(manager!=self.manager||!self.active)return;BOOL first=self.planning;self.planning=NO;self.rerouting=NO;self.lastInfo=NSProcessInfo.processInfo.systemUptime;self.staleShown=NO;[self drawRoute:manager.naviRoute];if(first){self.routeReady=YES;self.note=@"路线已准备，核对地图后点击开始。尚未向眼镜发送导航。";self.routeSummary.text=[NSString stringWithFormat:@"%.1f 公里   ·   约 %ld 分钟",manager.naviRoute.routeLength/1000.0,(long)MAX(1,(manager.naviRoute.routeTime+59)/60)];self.display=TIONavDisplay(@"ready",0,@"",-1,manager.naviRoute.routeLength,manager.naviRoute.routeTime,self.simulated);
        if(self.voiceSession){ // Voice flow: no human at the screen; start as soon as the route exists.
            NSUInteger g=self.generation;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{if(g==self.generation&&self.routeReady&&self.voiceSession)[self beginRoute];});
        }}else{self.note=@"已重新规划路线，请以手机指引为准；眼镜显示若已停止需手动开启。";}[self refresh];});}
- (void)navigationManager:(id<TIONavigationManager>)manager onCalculateRouteFailure:(NSError *)error{dispatch_async(dispatch_get_main_queue(),^{if(manager==self.manager&&self.active)[self fail:[NSString stringWithFormat:@"高德算路失败（code=%ld），检查 Key 服务权限／Bundle 绑定、网络与路线",(long)error.code]];});}
- (void)navigationManager:(id<TIONavigationManager>)manager error:(NSError *)error{dispatch_async(dispatch_get_main_queue(),^{if(manager==self.manager&&self.active)[self fail:[NSString stringWithFormat:@"高德引擎错误 code=%ld",(long)error.code]];});}
- (void)navigationManager:(id<TIONavigationManager>)manager updateNaviInfo:(AMapNaviInfo *)info{
 if(!info)return;NSMutableDictionary *frame=[TIONavDisplay(@"navigating",info.iconType,info.nextRoadName,info.segmentRemainDistance,info.routeRemainDistance,info.routeRemainTime,self.simulated) mutableCopy];frame[@"segment"]=@(info.currentSegmentIndex);frame[@"remainingMeters"]=@(info.routeRemainDistance);frame[@"remainingSeconds"]=@(info.routeRemainTime);
 NSInteger segment=info.currentSegmentIndex,link=info.currentLinkIndex,point=info.currentPointIndex;
 dispatch_async(dispatch_get_main_queue(),^{if(manager!=self.manager||!self.active||self.routeReady||self.planning||self.rerouting)return;
  NSArray<AMapNaviSegment *> *segments=manager.naviRoute.routeSegments;NSMutableArray *coords=[NSMutableArray new];
  if(segment>=0&&segment<(NSInteger)segments.count&&link>=0&&point>=0){
   for(NSUInteger si=(NSUInteger)segment;si<MIN(segments.count,(NSUInteger)segment+2)&&coords.count<512;si++){
    NSArray<AMapNaviLink *> *links=segments[si].links;
    for(NSUInteger li=si==(NSUInteger)segment?(NSUInteger)link:0;li<links.count&&coords.count<512;li++){
     NSArray<AMapNaviPoint *> *points=links[li].coordinates;
     for(NSUInteger pi=si==(NSUInteger)segment&&li==(NSUInteger)link?(NSUInteger)point:0;pi<points.count&&coords.count<512;pi++){AMapNaviPoint *p=points[pi];[coords addObject:@[@(p.latitude),@(p.longitude)]];}
    }
   }
  }
  [frame addEntriesFromDictionary:TNVNormalizeCoordinates(coords)];self.lastInfo=NSProcessInfo.processInfo.systemUptime;self.staleShown=NO;[self setFrame:frame];
 });
}
- (void)navigationReroute:(id<TIONavigationManager>)manager{dispatch_async(dispatch_get_main_queue(),^{if(manager==self.manager&&self.active){self.rerouting=YES;self.note=@"偏航，等待高德重新规划";[self setFrame:TIONavDisplay(@"rerouting",0,@"",-1,-1,-1,self.simulated)];}});}
- (void)drawRoute:(AMapNaviRoute *)route{NSArray<AMapNaviPoint *> *points=route.routeCoordinates;if(points.count<2||points.count>100000)return;CLLocationCoordinate2D *coords=calloc(points.count,sizeof(CLLocationCoordinate2D));if(!coords)return;for(NSUInteger i=0;i<points.count;i++)coords[i]=CLLocationCoordinate2DMake(points[i].latitude,points[i].longitude);if(self.routeLine)[self.map removeOverlay:self.routeLine];self.routeLine=[MAPolyline polylineWithCoordinates:coords count:points.count];free(coords);[self.map addOverlay:self.routeLine];[self.map setVisibleMapRect:self.routeLine.boundingMapRect edgePadding:UIEdgeInsetsMake(30,25,30,25) animated:YES];}
- (MAOverlayRenderer *)mapView:(MAMapView *)map rendererForOverlay:(id<MAOverlay>)overlay{if([overlay isKindOfClass:MAPolyline.class]){MAPolylineRenderer *r=[[MAPolylineRenderer alloc]initWithPolyline:overlay];r.lineWidth=6;r.strokeColor=UIColor.systemIndigoColor;return r;}return nil;}
- (void)navigationManager:(id<TIONavigationManager>)manager updateGPSSignalStrength:(AMapNaviGPSSignalStrength)strength{dispatch_async(dispatch_get_main_queue(),^{if(manager!=self.manager||!self.active||self.simulated)return;self.gpsWeak=strength!=AMapNaviGPSSignalStrengthStrong&&strength!=AMapNaviGPSSignalStrengthSmartPos; // AMap's guidance stream is the authority; only surface a weak-state frame when AMap itself has gone quiet, so live guidance never flickers.
 if(self.gpsWeak&&NSProcessInfo.processInfo.systemUptime-self.lastInfo>15)[self setFrame:TIONavDisplay(@"weak",0,@"",-1,-1,-1,NO)];});}
- (void)arrived:(id<TIONavigationManager>)manager{dispatch_async(dispatch_get_main_queue(),^{if(manager!=self.manager||!self.active)return;[self halt];self.note=@"已到达；导航已停止，10 秒后清理本次导航卡";[self setFrame:TIONavDisplay(@"arrived",0,@"",0,0,0,self.simulated)];NSUInteger g=self.generation;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(g==self.generation)TIONavEnableDisplay(NO);});});}
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
#endif
#include "NavigationDisplayHUD.inc"
#include "NavigationWorkspace.inc"
@end
// Passive ASR keyword observer. Fires at most once per 8s; opt-out key
// voiceNavDisabled (default: enabled). Destinations 2-40 chars after the
// trigger prefix; bare "打开导航/开始导航" opens the panel without a query.
static NSTimeInterval LastVoiceNavAt=0;
void TIOVoiceNavMaybeStart(NSString *text){
    if(![text isKindOfClass:NSString.class])return;
    if([NSUserDefaults.standardUserDefaults boolForKey:@"voiceNavDisabled"])return;
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    if(now-LastVoiceNavAt<8)return;
    NSString *t=[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while(t.length){unichar c=[t characterAtIndex:t.length-1];if(c==0x3002||c==0xFF01||c==0xFF1F||c==0xFF0C||c==','||c=='.'||c=='!'||c=='?')t=[t substringToIndex:t.length-1];else break;}
    NSString *destination=nil;
    for(NSString *p in @[@"导航到",@"导航去",@"导航至",@"带我去",@"我要去"])if([t hasPrefix:p]){NSString *d=[t substringFromIndex:p.length];if(d.length>=2&&d.length<=40)destination=d;break;}
    if(!destination&&([t hasPrefix:@"打开导航"]||[t hasPrefix:@"开始导航"]))destination=@"";
    if(!destination)return;
    LastVoiceNavAt=now;
    dispatch_async(dispatch_get_main_queue(),^{
        UIWindow *w=nil;for(UIWindowScene *s in UIApplication.sharedApplication.connectedScenes)if(s.activationState==UISceneActivationStateForegroundActive)for(UIWindow *win in s.windows)if(win.isKeyWindow)w=win;
        UIViewController *top=w.rootViewController;if(!top)return;
        while(top.presentedViewController&&!top.presentedViewController.isBeingDismissed)top=top.presentedViewController;
        for(UIViewController *v in top.navigationController?(top.navigationController.viewControllers):@[])if([NSStringFromClass(v.class) containsString:@"Navigation"]){top=v;break;}
        TIONavigationPanel *panel=[TIONavigationPanel new];
        UINavigationController *nav=[[UINavigationController alloc]initWithRootViewController:panel];
        nav.modalPresentationStyle=UIModalPresentationFullScreen;
        [top presentViewController:nav animated:YES completion:^{[panel voiceStart:destination];}];
    });
}
UIViewController *TIONavigationController(void){return [TIONavigationPanel new];}
