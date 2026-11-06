// Included inside TIONavigationPanel. Uses the same pinned SDK manager, no second navigation engine.
#if TIO_DISPLAY_PHONE
- (NSDictionary *)displayHUDFrame{return self.display;}
// A live subtitle session (starting/ready) owns the glasses channel. A leftover
// stopping/uncertain phase never auto-returns to idle and must not permanently
// lock the native HUD; toggleDisplayHUD resets it behind an explicit user
// confirmation that the lens is back home.
- (BOOL)subtitleTrialBlocksNative{
 NSString *phase=TIOSubtitleNavigationStatus()[@"phase"];
 return [phase isEqual:@"starting"]||[phase isEqual:@"ready"]||[self.subtitleHUD.status[@"enabled"] boolValue];
}
- (BOOL)canStartDisplayHUD{
 NSDictionary *t=TIONavTransportStatus();
 // AMap's guidance stream is the authority on when turn data is valid; the
 // remaining gates are freshness (lastInfo) and live channel conflicts.
 return self.active&&!self.routeReady&&!self.fixture&&!self.planning&&!self.rerouting&&NSProcessInfo.processInfo.systemUptime-self.lastInfo<=15&&[self.display[@"phase"] isEqual:@"navigating"]&&![self subtitleTrialBlocksNative]&&![self.teleHUD.status[@"enabled"] boolValue]&&![TIONewsTeleStatus()[@"active"] boolValue]&&![t[@"enabled"] boolValue]&&![t[@"pending"] boolValue]&&![t[@"notices"] boolValue]&&![t[@"noticePending"] boolValue];
}
// Realtime navigation engages the native HUD by itself once AMap turn guidance
// exists -- no manual tap. "Start accepted" is only "START sent": the glasses'
// verdict (q.active) arrives asynchronously and a rejection used to die in the
// session note. So this loop checks the LIVE session status every 2s, re-pushes
// until the glasses actually render (up to ~90s, covering the 60s lens cooldown
// after a previous navigation), and surfaces the glasses' own rejection reason.
// A user who stops the HUD mid-session is never fought (toggleDisplayHUD clears).
- (void)autoStartNativeHUDIfNeeded{
 if(!self.autoNativeHUD)return;
 NSDictionary *s=TDPPhoneNavigationStatus();
 // 会话活着时只复位尝试计数、保持武装：中途任何一次传输超时/拒绝都会让
 // 会话死掉（active 翻 NO），武装保住的重试循环就是「冻结后自动重新上镜」
 // 的自愈路径（真机 2026-10-30：模拟不跟帧/停不掉，皆因会话死后无恢复）。
 // 用户手动停止（toggleDisplayHUD）与结束导航（halt）都会解除武装，不会抢。
 if([s[@"active"] boolValue]){
  self.autoNativeHUDAttempts=0;
  if(self.voiceSession&&self.voicePipelineStage!=TIONavVoiceStageEngaged){
   [self enterVoiceStage:TIONavVoiceStageEngaged title:@"眼镜已上镜，语音链路收尾"]; // 同时结束后台保持
   TIONavDiagHUDEvent(@"上镜",s[@"note"]);
  }else if(self.voiceBridgeTask!=UIBackgroundTaskInvalid)[self endVoiceBridgeTask];
  [self releaseVoiceLocationForVoicePipeline]; // 上镜后导航定位由高德实时导航接管，释放语音链路的额外定位
  TIONavDiagSetVoiceStage(TIONavVoiceStageName(self.voicePipelineStage));
  return;}
 if(![self canStartDisplayHUD])return;
 NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
 if(now<self.autoNativeHUDNextAt)return;
 self.autoNativeHUDNextAt=now+2;self.autoNativeHUDAttempts++;
 if(self.autoNativeHUDAttempts>150){self.autoNativeHUD=NO;TIOVoiceNavTrace([NSString stringWithFormat:@"眼镜HUD：自动开启放弃（150次未激活，最后状态：%@）",s[@"note"]?:@"未知"]);TIONavDiagHUDEvent(@"上镜放弃",s[@"note"]);[self releaseVoiceLocationForVoicePipeline];return;}
 if(TDPPhoneNavigationStart([self displayHUDFrame])){
  TIOVoiceNavTrace(@"眼镜HUD：START已发送，2秒后核实眼镜是否激活");
  TIONavDiagHUDEvent(@"START发送",[NSString stringWithFormat:@"第%lu次",(unsigned long)self.autoNativeHUDAttempts]);
  // The verdict lands asynchronously (the session is "active" while in flight
  // and flips off on a glasses rejection), so verify twice: at 2s and 5s.
  // Anything not live re-arms the loop for another push.
  NSUInteger g=self.generation;
  void(^verify)(void)=^{
   if(g!=self.generation||!self.active)return;
   NSDictionary *v=TDPPhoneNavigationStatus();
   if(![v[@"active"] boolValue]){TIOVoiceNavTrace([NSString stringWithFormat:@"眼镜HUD：未上镜（%@），重新上镜",v[@"note"]?:@"原因未知"]);TIONavDiagHUDEvent(@"未上镜",v[@"note"]);}};
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),verify);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),verify);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(8.5*NSEC_PER_SEC)),dispatch_get_main_queue(),verify); // 8.5s covers the protocol's 8s reply deadline.
  return;}
 NSString *st=s[@"note"]?:@"未知";
 if(!TIOProtocolDevice().length)st=@"眼镜通道未就绪：设备号未知，点亮手机/打开App后自动重试";
 NSString *why=TNVRefusalReason();
 if(why.length)st=[st stringByAppendingFormat:@"；具体原因：%@",why];
 if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)st=[st stringByAppendingString:@"；App在后台（重试循环依赖锁屏桥接存活）"];
 TIOVoiceNavTrace([NSString stringWithFormat:@"眼镜HUD：开启请求被拒（第%lu次，2秒后重试；状态：%@）",(unsigned long)self.autoNativeHUDAttempts,st]);
 TIONavDiagHUDEvent(@"START被拒",why.length?why:st); // 相邻重复原因由环形缓冲去重，不会刷屏
}
- (void)buildDisplayHUD{
 UILabel *title=[self navLabel:@"眼镜原生导航 · TNV1" size:16 weight:UIFontWeightSemibold];[self.lensCard addArrangedSubview:title];
 TNVSetAlways(YES); /* 用户 2026-11-02 要求：常亮强制开启，不再做占位置的开关 */
 self.tdpPreview=[UIImageView new];self.tdpPreview.contentMode=UIViewContentModeScaleAspectFit;self.tdpPreview.backgroundColor=UIColor.blackColor;self.tdpPreview.clipsToBounds=YES;self.tdpPreview.layer.cornerRadius=10;[self.tdpPreview.heightAnchor constraintEqualToAnchor:self.tdpPreview.widthAnchor multiplier:0.25].active=YES;[self.lensCard addArrangedSubview:self.tdpPreview];
 self.tdpStatus=[self navLabel:@"需要支持 TNV1 的实验固件；以实际道路指示为准" size:12 weight:UIFontWeightRegular];self.tdpStatus.accessibilityIdentifier=@"navigation-tdp-status";[self.lensCard addArrangedSubview:self.tdpStatus];
 self.tdpButton=[self navAction:@"开启眼镜原生导航" icon:@"arrow.triangle.turn.up.right.diamond" selector:@selector(toggleDisplayHUD) primary:YES];self.tdpButton.accessibilityIdentifier=@"navigation-tdp-enable";[self.lensCard addArrangedSubview:self.tdpButton];
}
- (void)refreshDisplayHUD{
 if(!self.tdpButton)return;NSDictionary *s=TDPPhoneNavigationStatus();BOOL on=[s[@"active"] boolValue];
 BOOL can=[self canStartDisplayHUD];
 UIButtonConfiguration *c=self.tdpButton.configuration;c.title=on?@"停止并退出眼镜导航":@"开启眼镜原生导航";self.tdpButton.configuration=c;self.tdpButton.enabled=on||can;
 // The disabled state must explain itself. Realtime nav needs reliable GPS
 // (Strong/SmartPos) before turn guidance exists; a dead gray button with no
 // reason reads as a bug, which is exactly how this was reported.
 NSString *hint=@"";
 if(!on&&!can&&self.active){
  if(![self.display[@"phase"] isEqual:@"navigating"]||NSProcessInfo.processInfo.systemUptime-self.lastInfo>15)
   hint=self.autoNativeHUD?@"ⓘ 定位中：手机出现转向指引后，眼镜原生导航将自动开启\n\n":@"ⓘ 等待手机出现转向指引后可开启\n\n";
 }
 // 第一页只留 3 行关键状态；完整事件时间线移到「详细诊断」。
 NSDictionary *diag=TIONavDiagSnapshot();
 unsigned attempts=[diag[@"stopRetryAttempts"] unsignedIntegerValue],maxAttempts=[diag[@"stopRetryMax"] unsignedIntegerValue];
 NSString *stopLine=attempts?[NSString stringWithFormat:@"退出补发 %u/%u",attempts,maxAttempts]:@"退出补发 0";
 if(![diag[@"stopRetryPending"] boolValue]&&attempts)stopLine=[stopLine stringByAppendingString:@" · 已确认"];
 self.tdpStatus.text=[hint stringByAppendingFormat:@"%@\n已确认 %@ 个快照 · %@ · 语音阶段：%@\n%@",s[@"note"],s[@"snapshots"]?:@0,TNVAlways()?@"常亮":@"60秒无更新息屏",diag[@"voiceStage"],stopLine];
 NSDictionary *tnv=TDPPhoneNavigationStatus();
 NSString *mapReason=tnv[@"mapReason"];
 self.tdpStatus.text=[self.tdpStatus.text stringByAppendingFormat:@"\n矢量帧 %@ · 发 %lu / 丢 %lu%@%@", [tnv[@"mapMode"] boolValue]?@"已生成":@"未生成",(unsigned long)[tnv[@"mapSends"] unsignedIntegerValue],(unsigned long)[tnv[@"mapDrops"] unsignedIntegerValue],[tnv[@"minSent"] boolValue]?@" · 已降级":@"",mapReason.length?[@" · " stringByAppendingString:mapReason]:@""];
 self.tdpPreview.hidden=YES; // Old pixel renderer is not an accurate TNV1 preview.
}
- (void)hudMarkerTest{
    if(![TDPPhoneNavigationStatus()[@"active"] boolValue]||![self.display[@"phase"] isEqual:@"navigating"]){[self alert:@"请先确认眼镜已进入原生导航" message:@"测试使用20秒独立场景，不改变手机上的真实路线。只有镜片已进入导航才能验证接收与绘制。"];return;}
    NSDictionary *test=[self.roadMap markerTestFrame:self.display];
    if(!test){[self alert:@"无法创建测试场景" message:@"请先停止当前导航，再重新开启后重试。"];return;}
    self.hudMarkerTestUntil=NSProcessInfo.processInfo.systemUptime+20;
    TDPPhoneNavigationOffer(test);
    self.note=@"20 秒 HUD 独立测试已排队：左侧车速旁常驻限速徽章（圆环 60）、限速圈 60（50m）、红绿灯 20m、事故 90m、拥堵档位。请观察左侧车速行与右侧地图；结束后自动恢复真实导航。测试不代表高德已提供这些真实数据。";
    TIONavDiagHUDEvent(@"HUD标记测试",@"20秒独立场景已排队；限速徽章60/限速圈50m/红绿灯20m/事故90m");
    [self refresh];
}
- (void)toggleDisplayHUD{
 if([TDPPhoneNavigationStatus()[@"active"] boolValue]){self.autoNativeHUD=NO;TDPPhoneNavigationStop();[self armStopRetryWindow:0];TIONavDiagHUDEvent(@"手动停止",@"用户点停止并退出眼镜导航");[self refreshDisplayHUD];return;} // Explicit user stop: the auto-engager must never fight back.
 if(![self canStartDisplayHUD]){[self alert:@"先开始高德导航" message:@"等待转向和距离出现，并先结束字幕、提词、录音及其他眼镜任务。"] ;return;}
 NSUInteger g=self.generation;
 // A previous subtitle session (sim or realtime) can leave stopping/uncertain
 // behind; it never self-resets. Fold the lens-home confirmation into this
 // dialog so one tap clears it instead of permanently gating the native HUD.
 NSString *subtitlePhase=TIOSubtitleNavigationStatus()[@"phase"];
 BOOL subtitleLeftover=![subtitlePhase isEqual:@"idle"]&&![self subtitleTrialBlocksNative];
 NSString *message=@"需TNV1专用固件。眼镜在首页即可，收到START后自动进入第九项导航；不要同时运行录音、语音或其他显示任务。本轮请先用模拟路线验收。";
 if(subtitleLeftover)message=[message stringByAppendingString:@"\n检测到上次字幕会话未确认退出：请同时确认镜片已回首页、没有字幕残留，再开始。"];
 UIAlertController *a=[UIAlertController alertControllerWithTitle:@"开启原生导航？" message:message preferredStyle:UIAlertControllerStyleAlert];
 [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
 [a addAction:[UIAlertAction actionWithTitle:@"已确认，开始" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){if(g!=self.generation)return;if(subtitleLeftover)TIOSubtitleConfirmIdle();if(![self canStartDisplayHUD])return;BOOL ok=TDPPhoneNavigationStart([self displayHUDFrame]);if(ok){self.autoNativeHUD=YES;self.autoNativeHUDAttempts=0;self.autoNativeHUDNextAt=0; /* 手动开启成功同样纳入自愈：会话中途死掉会自动重新上镜 */}else [self alert:@"HUD未开启" message:@"请确认连接和无在途文件，再查看状态；不会自动重试。" ] ;[self refreshDisplayHUD];}]];[self presentViewController:a animated:YES completion:nil];
}
#if TIO_AMAP_ENABLED
- (void)attachNativeHUD{
 if(self.sessionTransport==TIONavigationRide)return; // Native HUD advertises walk/drive, not ride.
 self.nativeHUD=[[AMapNaviHUDView alloc]initWithFrame:CGRectMake(0,0,320,180)];self.nativeHUD.isLandscape=YES;self.nativeHUD.isMirror=NO;self.nativeHUD.showRemainDistance=YES;self.nativeHUD.showRemainTime=YES;
 [self.nativeHUD.heightAnchor constraintEqualToConstant:180].active=YES;[self.lensCard addArrangedSubview:self.nativeHUD];[self.manager addDataRepresentative:self.nativeHUD];
}
- (void)driveManager:(AMapNaviDriveManager *)m updateTurnIconImage:(UIImage *)image turnIconType:(AMapNaviIconType)type{
 dispatch_async(dispatch_get_main_queue(),^{if((id)m!=self.manager||!self.active||self.rerouting||self.planning)return;self.hudIconPixels=TDPHUDImagePixels(image,NO);self.hudIconType=type;self.iconReceivedCount++;TDPPhoneNavigationOffer([self displayHUDFrame]);[self refreshDisplayHUD];});
}
- (void)driveManager:(AMapNaviDriveManager *)m showCrossImage:(UIImage *)image{
 dispatch_async(dispatch_get_main_queue(),^{if((id)m!=self.manager||!self.active||self.rerouting||self.planning)return;self.crossPixels=TDPHUDImagePixels(image,YES);self.crossReceived=NSProcessInfo.processInfo.systemUptime;self.crossReceivedCount++;TDPPhoneNavigationOffer([self displayHUDFrame]);[self refreshDisplayHUD];});
}
- (void)driveManagerHideCrossImage:(AMapNaviDriveManager *)m{
 dispatch_async(dispatch_get_main_queue(),^{if((id)m!=self.manager)return;self.crossPixels=nil;TDPPhoneNavigationOffer([self displayHUDFrame]);[self refreshDisplayHUD];});
}
#endif
#pragma mark 退出补发（用户反馈②：手机结束导航后镜片很久才退出，且只停在“导航数据已过期”）
// NativeNavigation 内部已把 TN_STOP 改成有界重试（10 次/2 秒，TN_NO_SESSION 视为已退出）；
// 上层只负责“反复、幂等调用 TDPPhoneNavigationStop”，由既有 1Hz tick 驱动，不新开 timer。
- (void)endStopRetryWindow {
 unsigned attempts=(unsigned)self.stopRetryAttempts;
 self.stopRetryArmed=NO;self.stopRetryAttempts=0;self.stopRetryNextAt=0;
 TIONavDiagSetStopRetry(attempts,(unsigned)TIONavStopRetryMaxAttempts,NO); // 保留最后一次补发计数作为现场证据
}
- (void)armStopRetryWindow:(NSTimeInterval)firstDelay {
 // 只在眼镜会话仍 active 时武装；记录当时的会话号，之后一旦出现新会话就停止补发，
 // 这样既不会把旧会话留在镜片上，也绝不会打断用户新开的导航。
 NSDictionary *s=TDPPhoneNavigationStatus();
 BOOL active=[s[@"active"] boolValue];
 self.stopRetryArmed=active;
 self.stopRetryAttempts=0;
 self.stopRetryNextAt=NSProcessInfo.processInfo.systemUptime+MAX(0,firstDelay);
 self.stopRetrySessionId=[s[@"session"] unsignedLongLongValue];
 TIONavDiagSetStopRetry(0,active?(unsigned)TIONavStopRetryMaxAttempts:0,active);
}
- (void)pumpStopRetries {
 if(!self.stopRetryArmed)return;
 NSDictionary *s=TDPPhoneNavigationStatus();
 BOOL active=[s[@"active"] boolValue],stopped=[s[@"stopped"] boolValue];
 unsigned long long sid=[s[@"session"] unsignedLongLongValue];
 if(sid&&self.stopRetrySessionId&&sid!=self.stopRetrySessionId){
  [self endStopRetryWindow];TIOVoiceNavTrace(@"退出补发：检测到新的眼镜会话，停止补发（不打断新导航）");return;
 }
 if(!TIONavStopRetryShouldSend(active,(unsigned)self.stopRetryAttempts,TIONavStopRetryMaxAttempts)||stopped){
  unsigned attempts=(unsigned)self.stopRetryAttempts;
  [self endStopRetryWindow];
  if(!active){
   if(attempts){TIOVoiceNavTrace(@"退出补发：眼镜已确认退出");TIONavDiagHUDEvent(@"退出补发",@"眼镜已确认退出");}
  }else if(stopped){TIOVoiceNavTrace(@"退出补发：眼镜未确认退出，请用眼镜返回键退出导航页");TIONavDiagHUDEvent(@"退出补发",@"会话放弃；需眼镜返回键");}
  else{TIOVoiceNavTrace(@"退出补发：已达 10 次上限仍未确认，请用眼镜返回键强制退出");TIONavDiagHUDEvent(@"退出补发",@"补发上限；需眼镜返回键");}
  return;
 }
 NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
 if(now<self.stopRetryNextAt)return;
 self.stopRetryAttempts++;self.stopRetryNextAt=now+TIONavStopRetryInterval;
 TDPPhoneNavigationStop(); // 幂等：只保证退出请求一定被再次送达（协议不变）
 TIONavDiagSetStopRetry((unsigned)self.stopRetryAttempts,(unsigned)TIONavStopRetryMaxAttempts,YES);
 NSString *line=[NSString stringWithFormat:@"%lu/%lu",(unsigned long)self.stopRetryAttempts,(unsigned long)TIONavStopRetryMaxAttempts];
 TIOVoiceNavTrace([NSString stringWithFormat:@"退出补发：%@（%@）",line,s[@"note"]?:@"状态未知"]);
 TIONavDiagHUDEvent(@"退出补发",line);
}
#endif
