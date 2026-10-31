// Included in TIONavigationPanel; never changes the host's Bluetooth lifecycle.
- (BOOL)navigationLocationAuthorized {
    CLAuthorizationStatus s=self.permission.authorizationStatus;
    return s==kCLAuthorizationStatusAuthorizedAlways || s==kCLAuthorizationStatusAuthorizedWhenInUse;
}
- (BOOL)navigationLocationModeAvailable {
    id modes=[NSBundle.mainBundle objectForInfoDictionaryKey:@"UIBackgroundModes"];
    return [modes isKindOfClass:NSArray.class] && [modes containsObject:@"location"];
}
- (void)endNavigationBackgroundTask {
    self.backgroundEpoch++;
    UIBackgroundTaskIdentifier task=self.navigationBackgroundTask;
    self.navigationBackgroundTask=UIBackgroundTaskInvalid;
    if(task!=UIBackgroundTaskInvalid)[UIApplication.sharedApplication endBackgroundTask:task];
}
- (void)expireNavigationBackgroundTask:(NSUInteger)epoch {
    if(epoch!=self.backgroundEpoch || self.navigationBackgroundTask==UIBackgroundTaskInvalid)return;
    [self stopUser];
#if TIO_DISPLAY_PHONE
    // 用户反馈②“手机退出导航后镜片还停在导航数据已过期”：模拟后台额度到点时手机导航已停，
    // 但眼镜会话可能仍是 active。立即进入有界退出补发链（2 秒/次、最多 10 次），
    // 而不是等下次回前台。
    [self armStopRetryWindow:0];
#endif
    self.note=@"模拟导航的后台测试时间已结束。回到前台后重新开始；模拟不会用假定位或静音音频保活。";
    [self refresh];
}
#pragma mark 语音链路后台保持（单一状态机）
// 用户反馈①（2026-11）：说“导航去X”后仍必须解锁进 App 才开始。旧实现只有 beginRoute
// 才申请 45 秒后台任务，而 定位(≤15s)→搜索(≤18s×2)→候选/追问(≤30s/15s)→算路(≤45s)
// 这段最长约一分半完全没有后台任务；锁屏/口袋里 App 被系统挂起，管线停在半路，解锁
// 回前台才继续。
// 现在从 voiceStart 起就持有【一个】有界后台任务：关键阶段推进时“先结束后重开”以续期
// （单标识、不双重申请、不泄漏），上镜成功、失败、停止或超过 TIONavVoiceHoldMaxSeconds
// 后结束。只服务无头语音实时导航链路，绝不为模拟导航或手动导航申请后台额度。
- (BOOL)voicePipelineHUDEngaged {
#if TIO_DISPLAY_PHONE
    return [TDPPhoneNavigationStatus()[@"active"] boolValue];
#else
    return NO;
#endif
}
- (BOOL)voicePipelineShouldHold {
    if(!self.voiceSession||self.simulated)return NO; // 模拟/手动导航永不占用语音链路额度
    double total=self.voicePipelineStarted>0?NSProcessInfo.processInfo.systemUptime-self.voicePipelineStarted:-1;
    return TIONavVoicePipelineShouldHold(self.voiceSession,[self voicePipelineHUDEngaged],self.voicePipelineStage,total);
}
- (void)endVoiceBridgeTask {
    self.voiceBridgeEpoch++;
    UIBackgroundTaskIdentifier task=self.voiceBridgeTask;
    self.voiceBridgeTask=UIBackgroundTaskInvalid;
    if(task!=UIBackgroundTaskInvalid)[UIApplication.sharedApplication endBackgroundTask:task];
}
- (void)expireVoiceBridgeTask:(NSUInteger)epoch {
    if(epoch!=self.voiceBridgeEpoch || self.voiceBridgeTask==UIBackgroundTaskInvalid)return;
    [self endVoiceBridgeTask];
    self.voicePipelineExpired=YES;
    // 后台额度被系统收走时 App 通常即将挂起：note+trace 留证据，回前台由自愈补齐。
    [self releaseVoiceLocationForVoicePipeline];
    NSString *stage=TIONavVoiceStageName(self.voicePipelineStage);
    TIOVoiceNavTrace([NSString stringWithFormat:@"语音链路后台保持到期（阶段：%@）：回到App后会按记录阶段自愈重试一次",stage]);
    if(self.voiceSession){
        self.note=[NSString stringWithFormat:@"语音导航后台时间到期（%@）。解锁回到App后会自动重试当前步骤，无需重新说。",stage];
        [self refresh];
    }
}
- (void)beginVoiceBridgeTask {
    // beginRoute 不在本次改动白名单内，但它本来就会调用本方法：在这里把阶段推进到“启动导航”，
    // 既准确反映“已开始导航、等待上镜”，也让后台保持覆盖到上镜窗口。
    if(self.navigationStarted&&self.voiceSession&&self.voicePipelineStage<TIONavVoiceStageStarting){
        self.voicePipelineStage=TIONavVoiceStageStarting;
        self.voicePipelineStageAt=NSProcessInfo.processInfo.systemUptime;
        if(self.voicePipelineStarted<=0)self.voicePipelineStarted=self.voicePipelineStageAt;
        TIOVoiceNavTrace(@"语音链路阶段：导航已启动，等待眼镜上镜");
    }
    // 阶段推进、退后台、或 tick 发现额度丢失时调用。续期 = 先结束旧的再重开唯一的标识。
    if(![self voicePipelineShouldHold]){[self endVoiceBridgeTask];return;}
    // 前台不需要后台额度：有残留就释放（退后台通知会立即重新申请），避免前台空占与误报“到期”。
    if(UIApplication.sharedApplication.applicationState==UIApplicationStateActive){
        if(self.voiceBridgeTask!=UIBackgroundTaskInvalid){[self endVoiceBridgeTask];TIOVoiceNavTrace(@"语音链路后台保持：已回前台，释放后台额度");}
        return;
    }
    NSUInteger epoch=++self.voiceBridgeEpoch;
    UIBackgroundTaskIdentifier old=self.voiceBridgeTask;self.voiceBridgeTask=UIBackgroundTaskInvalid;
    if(old!=UIBackgroundTaskInvalid)[UIApplication.sharedApplication endBackgroundTask:old]; // 单标识续期：不双重申请
    __weak typeof(self) weak=self;
    self.voiceBridgeTask=[UIApplication.sharedApplication beginBackgroundTaskWithName:@"TurboIO voice navigation pipeline" expirationHandler:^{[weak expireVoiceBridgeTask:epoch];}];
    if(self.voiceBridgeTask==UIBackgroundTaskInvalid){self.voicePipelineNextArmAt=NSProcessInfo.processInfo.systemUptime+10;TIOVoiceNavTrace(@"语音链路后台保持：系统暂未授予后台时间，10秒后再试（息屏时可能被挂起，回前台会自愈）");return;}
    self.voicePipelineExpired=NO;
    TIOVoiceNavTrace([NSString stringWithFormat:@"语音链路后台保持：%@（45秒额度，阶段推进会续期，总上限%.0f秒）",TIONavVoiceStageName(self.voicePipelineStage),TIONavVoiceHoldMaxSeconds]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(45*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[weak expireVoiceBridgeTask:epoch];});
}
// 关键阶段推进：记录阶段+时间（自愈按阶段重试），并续期后台保持。
- (void)enterVoiceStage:(NSInteger)stage title:(NSString *)title {
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    NSString *label=title.length?title:TIONavVoiceStageName(stage);
    if(self.voicePipelineStage!=stage||title.length)TIOVoiceNavTrace([NSString stringWithFormat:@"语音链路阶段：%@",label]);
    if(stage==TIONavVoiceStageIdle)self.voicePipelineStarted=0; // 空闲=新一轮链路重新计时
    else if(self.voicePipelineStarted<=0)self.voicePipelineStarted=now;
    self.voicePipelineStage=stage;self.voicePipelineStageAt=now;self.voicePipelineExpired=NO;
    [self beginVoiceBridgeTask];
    [self refresh];
}
// tick 兜底（1Hz）：上镜/失败/停止/超时立即释放后台额度与额外定位；期间额度被系统收走就重申请。
- (void)refreshVoicePipelineState {
    if(!self.voiceSession){
        if(self.voiceBridgeTask!=UIBackgroundTaskInvalid)[self endVoiceBridgeTask];
        [self releaseVoiceLocationForVoicePipeline];
        return;
    }
    if([self voicePipelineHUDEngaged]){
        if(self.voicePipelineStage!=TIONavVoiceStageEngaged)[self enterVoiceStage:TIONavVoiceStageEngaged title:@"眼镜已上镜，语音链路收尾"];
        [self releaseVoiceLocationForVoicePipeline];
        return;
    }
    if(![self voicePipelineShouldHold]){
        if(self.voiceBridgeTask!=UIBackgroundTaskInvalid){[self endVoiceBridgeTask];TIOVoiceNavTrace(@"语音链路后台保持：已到上限/阶段结束，释放后台额度");}
        [self releaseVoiceLocationForVoicePipeline];
        NSString *capNote=@"语音导航后台保持已到上限；请解锁手机回到App，会按当前步骤重试一次。";
        if(self.voicePipelineStarted>0&&!self.navigationStarted&&NSProcessInfo.processInfo.systemUptime-self.voicePipelineStarted>=TIONavVoiceHoldMaxSeconds&&![self.note isEqualToString:capNote]){
            self.note=capNote;[self refresh];
        }
        return;
    }
    if(self.voiceBridgeTask==UIBackgroundTaskInvalid&&NSProcessInfo.processInfo.systemUptime>=self.voicePipelineNextArmAt)[self beginVoiceBridgeTask];
}
// 挂起自愈（回前台调用）：只对“语音会话 + 未上镜 + 阶段停滞”的管线按记录阶段重试一次；
// 手动导航/模拟导航/候选等待一律不碰，且有节流，失败会明确 note+trace，不静默死等。
- (void)voicePipelineSelfHealIfNeeded {
    if(!self.voiceSession||self.navigationStarted||self.simulated)return;
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    double stageAge=self.voicePipelineStageAt>0?now-self.voicePipelineStageAt:1e9;
    double sinceHeal=self.voiceLastSelfHealAt>0?now-self.voiceLastSelfHealAt:1e9;
    TIONavVoiceSelfHealAction action=TIONavVoiceSelfHealActionFor(self.voicePipelineStage,stageAge,sinceHeal,self.planning);
    if(action==TIONavVoiceSelfHealNone)return;
    self.voiceLastSelfHealAt=now;
    NSString *stage=TIONavVoiceStageName(self.voicePipelineStage);
    TIOVoiceNavTrace([NSString stringWithFormat:@"回前台自愈：%@阶段停滞%.0f秒，按记录阶段重试一次",stage,stageAge]);
    if(action==TIONavVoiceSelfHealRelocate)[self voiceRetryLocating];
    else if(action==TIONavVoiceSelfHealResearch)[self voiceRetrySearch];
    else [self voiceRetryPlanning];
}
#pragma mark 语音链路定位保持
// 语音实时导航本来就需要持续定位（用户已授权）。旧实现拿到第1步定位就停
// CLLocationManager，于是“第1步完成→beginRoute/上镜”之间既无后台任务也无任何定位
// 活动，系统最容易挂起。现在语音会话在 HUD 未激活前不让定位空闲；上镜成功/失败/
// 停止/超时后立即收敛（这是真实导航定位，不是音乐/静音音频伪装保活）。
- (BOOL)holdVoiceLocationForVoicePipeline {
    if(!self.voiceSession||self.simulated)return NO;
    if(![self navigationLocationModeAvailable])return NO; // 无 location 后台模式：设 allowsBackgroundLocationUpdates 会崩溃，保持旧行为
    self.permission.allowsBackgroundLocationUpdates=YES;
    self.permission.desiredAccuracy=kCLLocationAccuracyHundredMeters;
    self.permission.distanceFilter=50;
    [self.permission startUpdatingLocation];
    if(!self.voiceLocationKept){self.voiceLocationKept=YES;TIOVoiceNavTrace(@"语音链路定位保持：搜索/算路期间不停定位更新（真实导航定位，避免锁屏挂起；上镜或失败后释放）");}
    return YES;
}
- (void)releaseVoiceLocationForVoicePipeline {
    if(!self.voiceLocationKept)return;
    self.voiceLocationKept=NO;
    [self.permission stopUpdatingLocation];
    TIOVoiceNavTrace(@"语音链路定位保持：已上镜/已停止/已超时，释放额外定位更新");
}
- (void)background {
    // 语音链路在 beginRoute 之前也要保住后台额度，否则搜索/算路会停在半路（用户反馈①）。
    if(self.voiceSession)[self beginVoiceBridgeTask];
    TIONavBackgroundAction action=TIONavBackgroundPolicy(self.navigationStarted,self.fixture,self.simulated,self.backgroundLocationEnabled,[self navigationLocationAuthorized]);
    if(action==TIONavBackgroundIdle)return;
    if(action==TIONavBackgroundStop){[self stopUser];self.note=@"后台导航条件不满足，已停止。请检查定位授权及宿主 location 后台模式。";[self refresh];return;}
    if(action==TIONavBackgroundLocation){self.note=@"后台实时导航中；结束导航会关闭本会话后台定位。请以手机地图及实际路况为准。";[self refresh];return;}
    if(self.navigationBackgroundTask!=UIBackgroundTaskInvalid)return;
    NSUInteger epoch=++self.backgroundEpoch;__weak typeof(self) weak=self;
    self.navigationBackgroundTask=[UIApplication.sharedApplication beginBackgroundTaskWithName:@"TurboIO navigation simulation handoff" expirationHandler:^{[weak expireNavigationBackgroundTask:epoch];}];
    if(self.navigationBackgroundTask==UIBackgroundTaskInvalid){[self stopUser];self.note=@"系统未授予模拟导航后台时间，请在前台测试。";[self refresh];return;}
    self.note=@"模拟导航短时后台测试中（最多25秒，系统可能提前结束）；持续锁屏导航请用已授权的实时路线。";[self refresh];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,25*NSEC_PER_SEC),dispatch_get_main_queue(),^{[weak expireNavigationBackgroundTask:epoch];});
}
- (void)navigationForeground {
    [self endNavigationBackgroundTask];
    if(self.voiceBridgeTask!=UIBackgroundTaskInvalid){[self endVoiceBridgeTask];TIOVoiceNavTrace(@"回前台：释放语音链路后台额度（前台不需要）");}
    if(self.navigationStarted&&!self.simulated&&![self navigationLocationAuthorized]){[self stopUser];self.note=@"定位权限已撤销，导航已停止。";}
    else if(self.navigationStarted)self.note=self.simulated?@"模拟导航继续（前台）":@"实时导航继续；可退后台或锁屏，不要强退App。";
    [self voicePipelineSelfHealIfNeeded]; // 锁屏被挂起后按记录阶段补一次，不静默死等
#if TIO_DISPLAY_PHONE
    // 用户反馈②：手机结束导航后镜片要很久才退出。回前台若手机已不在导航、眼镜会话仍
    // active（STOP 丢了/被挂起打断），立即补发退出并进入 2 秒/次、最多 10 次的有界重试。
    NSDictionary *hud=TDPPhoneNavigationStatus();
    // “手机导航未运行”= 还没 beginRoute（规划/候选/停滞阶段都算），眼镜会话却仍 active。
    if(!self.navigationStarted&&[hud[@"active"] boolValue]){
        TIOVoiceNavTrace([NSString stringWithFormat:@"回前台补发退出：眼镜会话仍在（%@）",hud[@"note"]?:@"状态未知"]);
        // 诊断事件由 NavigationDisplayHUD.inc 的退出补发泵统一记录（本 .inc 需能被
        // 离线测试单文件编译，不能引用 NavigationCore.m 的 C 符号）。
        TDPPhoneNavigationStop();
        [self armStopRetryWindow:0];
    }
#endif
    [self refresh];
}
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    if(manager!=self.permission)return;
    if(self.navigationStarted&&!self.simulated&&![self navigationLocationAuthorized]){
        [self stopUser];self.note=@"定位权限已撤销，导航及本会话后台定位已停止。";[self refresh];
    }
}
// Voice headless flow: CLLocationManager delivers the fix directly; MAMapView's
// didUpdateUserLocation is unreliable when the view is not in any window.
- (void)voiceFixAcquired:(CLLocation *)loc{
    self.voiceLocating=NO;
    if(![self holdVoiceLocationForVoicePipeline])[self.permission stopUpdatingLocation];
    self.note=[NSString stringWithFormat:@"第1步完成：已确认当前位置（±%.0f米）。",loc.horizontalAccuracy];
    self.voiceFix=loc.coordinate;self.hasVoiceFix=YES;
    TIOVoiceNavTrace([NSString stringWithFormat:@"第1步完成：已定位（±%.0f米），坐标将作为算路起点",loc.horizontalAccuracy]);
    [self enterVoiceStage:TIONavVoiceStageSearching title:@"第2步：搜索目的地"];
    [self refresh];[self voiceSearchDestination];
}
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations{
    if(manager!=self.permission||!self.voiceLocating)return;
    CLLocation *loc=[locations lastObject];if(!loc)return;
    if(loc.horizontalAccuracy<0||loc.horizontalAccuracy>200||fabs(loc.timestamp.timeIntervalSinceNow)>15)return;
    [self voiceFixAcquired:loc];
}