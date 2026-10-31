#import <Foundation/Foundation.h>
NSString *TIONavClip(NSString *text,NSUInteger byteLimit);
NSString *TIONavTurn(NSInteger icon);
NSDictionary *TIONavDisplay(NSString *phase,NSInteger icon,NSString *road,NSInteger distance,NSInteger remaining,NSInteger seconds,BOOL simulated);
NSString *TIONavTimeDetail(NSDictionary *display,NSDate *now);
NSDictionary *TIONavInstall(NSString *identifier,NSDictionary *display);
BOOL TIONavCoordinate(double latitude,double longitude);
// Notification events, not one notification per GPS callback.
NSString *TIONavNoticeKey(NSDictionary *display);
NSDictionary *TIONavNotice(NSString *uid,NSDictionary *display,NSDate *date);
// One in-flight packet. Coalesce updates; ACK only commits the exact submitted frame.
@interface TIONavQueue:NSObject
@property(nonatomic,readonly) NSDictionary *latest;
@property(nonatomic,readonly) NSDictionary *inflight;
@property(nonatomic,readonly) BOOL blocked;
- (void)offer:(NSDictionary *)display;
- (NSDictionary *)takeAt:(NSTimeInterval)now;
- (void)acknowledge:(BOOL)success;
- (void)reset;
@end

// ---- 语音导航后台寿命 / 退出补发 / 挂起自愈（纯策略；mac 离线测试可直接断言） ----
// 无头语音链路阶段：定位→搜索→候选/追问→算路→就绪→启动→上镜。后台保持只覆盖这段，
// 上镜成功、失败、停止或超过总上限就结束（绝不对模拟导航或手动导航伪装保活）。
typedef NS_ENUM(NSInteger,TIONavVoiceStage){
    TIONavVoiceStageIdle=0,
    TIONavVoiceStageLocating,
    TIONavVoiceStageSearching,
    TIONavVoiceStageChoosing,
    TIONavVoiceStagePlanning,
    TIONavVoiceStageRouteReady,
    TIONavVoiceStageStarting,
    TIONavVoiceStageEngaged,
    TIONavVoiceStageFailed
};
static inline NSString *TIONavVoiceStageName(NSInteger stage){
    switch(stage){
        case TIONavVoiceStageLocating:return @"定位";
        case TIONavVoiceStageSearching:return @"搜索目的地";
        case TIONavVoiceStageChoosing:return @"等待选择";
        case TIONavVoiceStagePlanning:return @"算路";
        case TIONavVoiceStageRouteReady:return @"路线就绪";
        case TIONavVoiceStageStarting:return @"启动导航";
        case TIONavVoiceStageEngaged:return @"已上镜";
        case TIONavVoiceStageFailed:return @"失败";
        default:return @"空闲";
    }
}
// 后台保持总上限（秒）：定位15+搜索18×2+候选30+方式15+算路45+上镜窗口45，留余量。
#define TIONavVoiceHoldMaxSeconds 300.0
// 挂起自愈：阶段停滞超过 8 秒且距上次自愈超过 15 秒才重试一次，避免回前台反复重发。
#define TIONavVoiceHealStaleSeconds 8.0
#define TIONavVoiceHealThrottleSeconds 15.0
// 退出补发：halt 后 5 秒仍未确认才补发，之后每 2 秒一次，最多 10 次（不新增协议）。
#define TIONavStopRetryFirstDelay 5.0
#define TIONavStopRetryInterval 2.0
#define TIONavStopRetryMaxAttempts 10
// 有界后台保持判定：只有“无头语音会话 + 未上镜 + 阶段未终结 + 未超总上限”才持有。
static inline BOOL TIONavVoicePipelineShouldHold(BOOL voiceSession,BOOL hudEngaged,NSInteger stage,double pipelineSeconds){
    if(!voiceSession||hudEngaged)return NO;
    if(stage<=TIONavVoiceStageIdle||stage>=TIONavVoiceStageEngaged)return NO;
    return pipelineSeconds>=0&&pipelineSeconds<TIONavVoiceHoldMaxSeconds;
}
typedef NS_ENUM(NSInteger,TIONavVoiceSelfHealAction){
    TIONavVoiceSelfHealNone=0,
    TIONavVoiceSelfHealRelocate,   // 定位停滞：重新发起一次定位
    TIONavVoiceSelfHealResearch,   // 搜索停滞：按已记录阶段重发搜索
    TIONavVoiceSelfHealReplan      // 算路停滞：用同一批起终点重新提交算路
};
// 回前台自愈：只对“阶段停滞且超过节流窗口”的语音链路重试一次；候选/上镜阶段不重试。
static inline TIONavVoiceSelfHealAction TIONavVoiceSelfHealActionFor(NSInteger stage,double stageAgeSeconds,double sinceLastHealSeconds,BOOL planningInFlight){
    if(!(stageAgeSeconds>=TIONavVoiceHealStaleSeconds))return TIONavVoiceSelfHealNone;
    if(sinceLastHealSeconds>=0&&sinceLastHealSeconds<TIONavVoiceHealThrottleSeconds)return TIONavVoiceSelfHealNone;
    switch(stage){
        case TIONavVoiceStageLocating:return TIONavVoiceSelfHealRelocate;
        case TIONavVoiceStageSearching:return TIONavVoiceSelfHealResearch;
        case TIONavVoiceStagePlanning:return planningInFlight?TIONavVoiceSelfHealReplan:TIONavVoiceSelfHealNone;
        default:return TIONavVoiceSelfHealNone;
    }
}
// 退出补发判定：眼镜会话仍 active 且未到上限才继续补发 TDPPhoneNavigationStop（幂等）。
static inline BOOL TIONavStopRetryShouldSend(BOOL sessionActive,unsigned attempts,unsigned maxAttempts){
    if(!sessionActive||!maxAttempts)return NO;
    return attempts<maxAttempts;
}

// ---- HUD / 语音链路诊断环形缓冲（最近16条纯文本：时间 事件 → 结果） ----
// 只保存固定短语与眼镜会话自身 note，绝不含坐标、账号、Key 或设备号；供原生导航状态 JSON
// 与导航页状态行展示，便于用户截图反馈。实现见 NavigationCore.m。
void TIONavDiagHUDEvent(NSString *event,NSString *result);
NSArray<NSString *> *TIONavDiagHUDEvents(NSUInteger limit);
void TIONavDiagSetVoiceStage(NSString *stage);
NSString *TIONavDiagVoiceStage(void);
void TIONavDiagSetStopRetry(unsigned attempts,unsigned maxAttempts,BOOL pending);
void TIONavDiagReset(void);
NSDictionary *TIONavDiagSnapshot(void);
