// NavigationVoiceBridge.m — 导航语音链路（ios107 换装）：语音触发、候选追问、
// 出行方式追问、语音选择、注入通道。语义与 focus 线 Addon.m 逐段对应
// （回复接管 461-478 / 选择路由 596-615 / 触发收尾 622-629 / 吞完成 640 /
// 注入通道 196-233 / 选择解析 574-589），只保留导航所需，不迁飞书。
// 引擎状态借道 Addon.m 的 TIOController 回合机制（经 NavBridgeView 视图访问）。
#import "NavigationVoiceBridge.h"
#import "NavigationUI.h"
#import "Core.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>

// TIOController 跨文件最小接口视图（类实现在 Addon.m）：类别声明要求主接口
// 可见，这里补一个仅含导航桥所用访问器的主接口声明；运行期走 Addon.m 已合成
// 的实现。属性一律用消息发送。
@interface TIOController : NSObject
- (id)listener;
- (NSString *)asr;
- (NSString *)sid;
- (id)responseTemplate;
- (void)setResponseTemplate:(id)v;
- (NSString *)emitted;
- (void)setEmitted:(NSString *)v;
- (BOOL)ownsTurn;
- (void)setOwnsTurn:(BOOL)v;
- (BOOL)started;
- (void)setStarted:(BOOL)v;
- (BOOL)responseDone;
- (NSUInteger)generation;
- (void)emitText:(NSString *)text done:(BOOL)done error:(NSString *)error generation:(NSUInteger)gen;
@end

static NSString *VoiceNavTrace=@"";
static __weak TIOController *NavController;
static NSString *PendingInjectText;
static BOOL PendingInjectDone;
static NSUInteger PendingInjectGen;
static NSString *InjectedTurnKey;
static BOOL SwallowOfficialComplete;

// ---- 面包屑诊断（与 focus 线 Addon.m 57-66 同语义） ----
void TIOVoiceNavTrace(NSString *step){
    void (^work)(void)=^{VoiceNavTrace=[VoiceNavTrace stringByAppendingFormat:@"\n· %@",step?:@""];if(VoiceNavTrace.length>1600)VoiceNavTrace=[VoiceNavTrace substringFromIndex:VoiceNavTrace.length-1600];};
    if(NSThread.isMainThread)work();else dispatch_async(dispatch_get_main_queue(),work);
}
void TIOVoiceNavTraceReset(void){
    if(NSThread.isMainThread)VoiceNavTrace=@"";else dispatch_async(dispatch_get_main_queue(),^{VoiceNavTrace=@"";});
}
NSString *TIOVoiceNavTraceStatus(void){return VoiceNavTrace;}

// ---- 官方停止入口（focus 线 exitVoice 259-270 核心动作） ----
void TIOVoiceCloseAssistantSession(void){
    void (^work)(void)=^{
        Class cls=NSClassFromString(@"rayneo_venus_sdk_plugin.VoiceAssistantHelper");
        if(!cls)return;
        id helper=((id(*)(id,SEL))objc_msgSend)(cls,NSSelectorFromString(@"shared"));
        if(!helper)return;
        ((void(*)(id,SEL))objc_msgSend)(helper,NSSelectorFromString(@"stopWorkflow"));
    };
    if(NSThread.isMainThread)work();else dispatch_async(dispatch_get_main_queue(),work);
}

// ---- 纯助手（focus 线 Addon.m 107-108/215-218/235-244/574-589） ----
static id Get(id obj,NSString *key) {if(!obj)return nil;@try{return [obj valueForKey:key];}@catch(NSException *e){return nil;}}
static NSString *String(id obj) {return [obj isKindOfClass:NSString.class]?obj:@"";}
static NSString *TIOTurnKey(id value){
    NSString *sid=String(Get(value,@"sessionId"));
    if(!sid.length)return @"";
    return [NSString stringWithFormat:@"%@|%@|%@",sid,String(Get(value,@"dialogId")),String(Get(value,@"round"))];
}
static id CopyResponse(id source,NSString *answer,BOOL final) {
    // Only use the observed wrapper class. Do not call guessed Swift addresses.
    Class cls=NSClassFromString(@"RayNeoNlpResultWrapper");if(!cls||![source isKindOfClass:cls])return nil;
    id copy=[cls new];
    @try {
        for(NSString *field in @[@"sub",@"dialogId",@"sessionId",@"domain",@"intent",@"round",@"query",@"spoken",@"answer",@"finished",@"offline",@"command",@"hasNextRound",@"rawData"]) {id v=[source valueForKey:field];if(v)[copy setValue:v forKey:field];}
        [copy setValue:answer forKey:@"answer"];[copy setValue:@"" forKey:@"spoken"];[copy setValue:@(final) forKey:@"finished"];
    }@catch(NSException *e){return nil;}
    return copy;
}
static NSInteger TIOParseVoiceChoice(NSString *text,NSUInteger count){
    if(![text isKindOfClass:NSString.class]||!count)return 0;
    if([text rangeOfString:@"最近"].location!=NSNotFound)return 1;
    NSArray *digits=@[@[@"一",@"1"],@[@"二",@"两",@"2"],@[@"三",@"3"]];
    for(NSUInteger n=1;n<=digits.count&&n<=count;n++)for(NSString *d in digits[n-1]){
        if([text rangeOfString:[NSString stringWithFormat:@"第%@个",d]].location!=NSNotFound)return (NSInteger)n;
        if([text rangeOfString:[NSString stringWithFormat:@"第%@",d]].location!=NSNotFound)return (NSInteger)n;
    }
    NSString *t=[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while(t.length){unichar c=[t characterAtIndex:t.length-1];if(c==0x3002||c==0xFF01||c==0xFF1F||c==0xFF0C||c==','||c=='.'||c=='!'||c=='?'||c==0x5427)t=[t substringToIndex:t.length-1];else break;}
    if(t.length&&t.length<=6)for(NSUInteger n=1;n<=digits.count&&n<=count;n++)for(NSString *d in digits[n-1]){
        if([t isEqualToString:d]||[t isEqualToString:[@"去" stringByAppendingString:d]]||[t isEqualToString:[@"要" stringByAppendingString:d]])return (NSInteger)n;
    }
    for(NSString *w in @[@"都不对",@"都不是",@"不对",@"搞错",@"错了",@"重新说",@"重说",@"换一个"])if([text rangeOfString:w].location!=NSNotFound)return -1;
    return 0;
}

// ---- 对话写入通道（focus 线 Addon.m 183-188/374-378 语义） ----
BOOL TIOAssistantEmit(NSString *piece,BOOL done){
    __block BOOL ok=NO;
    void (^work)(void)=^{
        TIOController *c=NavController;
        if(!c||![c ownsTurn]||[c responseDone]||![c listener]||![c responseTemplate])return;
        [c emitText:[[c emitted]?:@"" stringByAppendingString:piece?:@""] done:done error:nil generation:[c generation]];
        ok=YES;
    };
    if(NSThread.isMainThread)work();else dispatch_sync(dispatch_get_main_queue(),work);
    return ok;
}
// ---- 注入通道（focus 线 Addon.m 196-207）：停车库 + 2 秒无官方回包回退旧通道 ----
void TIOAssistantInjectNext(NSString *text,BOOL done){
    void (^work)(void)=^{
        PendingInjectText=[text copy];PendingInjectDone=done;NSUInteger gen=++PendingInjectGen;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            if(PendingInjectText&&gen==PendingInjectGen){PendingInjectText=nil;TIOAssistantEmit(text,done);TIOVoiceNavTrace(@"注入通道2秒无官方回包：回退旧聊天通道");}
        });
    };
    if(NSThread.isMainThread)work();else dispatch_async(dispatch_get_main_queue(),work);
}

// ---- 注入消费（focus 线 Addon.m 224-233；转发/收尾经调用方给的钩子链句柄） ----
static BOOL ConsumePendingInject(id value,TIONavForwardFn forward,TIONavCompleteFn complete){
    if(!PendingInjectText)return NO;
    NSString *text=PendingInjectText;BOOL done=PendingInjectDone;PendingInjectText=nil;PendingInjectGen++;
    id rewritten=CopyResponse(value,text,done);
    if(!rewritten){TIOAssistantEmit(text,done);return YES;}
    InjectedTurnKey=[TIOTurnKey(value) copy];SwallowOfficialComplete=YES;
    forward(rewritten);
    if(done)complete();
    return YES;
}

// ---- NLP 拦截（focus 线 Addon.m 596-615） ----
BOOL TIOVoiceNavNlpIntercept(id listener,SEL cmd,id value,TIONavForwardFn forward,TIONavCompleteFn complete){
    (void)cmd;
    if(!forward||!complete)return NO;
    // 改写轮次的迟到官方回包丢弃——气泡里已经是我们改写后的对话行。
    if(InjectedTurnKey.length&&[InjectedTurnKey isEqualToString:TIOTurnKey(value)])return YES;
    NSString *voiceQuery=Get(value,@"query");
    if([voiceQuery isKindOfClass:NSString.class]&&voiceQuery.length&&!TIOVoiceNavMatchDestination(voiceQuery).length){
        NSUInteger pending=TIOVoiceNavPendingChoices();
        if(pending){
            NSInteger pick=TIOParseVoiceChoice(voiceQuery,pending);
            if(pick>0){TIOVoiceNavTrace([NSString stringWithFormat:@"语音选择（NLP）：第%ld个（共%lu个候选）",(long)pick,(unsigned long)pending]);TIOVoiceNavChoose((NSUInteger)pick);if(ConsumePendingInject(value,forward,complete))return YES;}
            else if(pick<0){TIOVoiceNavTrace(@"语音排除全部候选（NLP）");TIOVoiceNavReject();if(ConsumePendingInject(value,forward,complete))return YES;}
        }
        else if(TIOVoiceNavPendingMode()&&TIOVoiceNavChooseMode(voiceQuery)){TIOVoiceNavTrace([NSString stringWithFormat:@"出行方式（NLP）：%@",voiceQuery]);if(ConsumePendingInject(value,forward,complete))return YES;}
        if(ConsumePendingInject(value,forward,complete)){TIOVoiceNavTrace([NSString stringWithFormat:@"对话行已改写本轮官方回包上镜（q=%@）",voiceQuery]);return YES;}
    }
    return NO;
}

// ---- 触发收尾（focus 线 Addon.m 622-629） ----
void TIOVoiceNavNlpAfter(id value){
    NSString *voiceQuery=Get(value,@"query");
    if(![voiceQuery isKindOfClass:NSString.class])return;
    static NSUInteger lastPending=UINT_MAX;
    NSUInteger pending=TIOVoiceNavPendingChoices();
    if(pending){
        if(lastPending!=pending){TIOVoiceNavTrace(@"候选等待中：说 第几个（本轮官方回复的迟到回包也会流经这里，属正常）");lastPending=pending;}
    }else lastPending=UINT_MAX;
    TIOVoiceNavMaybeStart(voiceQuery);
}

// ---- 完成回调闸（focus 线 Addon.m 640 语义） ----
BOOL TIOVoiceNavCompleteGate(id listener){
    if(SwallowOfficialComplete){SwallowOfficialComplete=NO;TIOVoiceNavTrace(@"改写轮次的官方完成回调已吞掉（收尾由注入通道控制）");return YES;}
    TIOController *c=NavController;
    if(c&&[c listener]==listener&&[c ownsTurn]){TIOVoiceNavTrace(@"自有回合的官方收尾已压制（收尾由接管方控制）");return YES;}
    return NO;
}

// ---- 回复接管（focus 线 Addon.m 461-478）：导航触发词命中即接管本轮助手回复 ----
BOOL TIOVoiceNavReceiveNlp(id controller,id response,id listener){
    if(![controller isKindOfClass:TIOController.class])return NO;
    TIOController *c=controller;
    if(!NavController)NavController=c;
    BOOL offline=[Get(response,@"offline") boolValue];
    NSString *domain=String(Get(response,@"domain")),*intent=String(Get(response,@"intent")),*sub=String(Get(response,@"sub"));
    NSString *nlpQuery=String(Get(response,@"query"));
    if([c listener]==listener&&!offline&&TIOIsEligibleChat(domain,intent,sub,NO,Get(response,@"command")!=nil)){
        NSString *respSid=String(Get(response,@"sessionId"));
        if(!([c sid].length&&respSid.length&&![[c sid] isEqual:respSid])){
            // 先按 NLP query 匹配（总是有），ASR 末轮兜底——ASR 终稿可能晚于首个
            // 回复增量到达，只盯 ASR 会漏接管而触发词照常命中。
            NSString *navDest=TIOVoiceNavMatchDestination(nlpQuery.length?nlpQuery:[c asr]);
            if(navDest.length){
                [c setResponseTemplate:response];[c setOwnsTurn:YES];[c setStarted:YES];[c setEmitted:@""];
                NSUInteger gen=[c generation];
                NSString *say=[NSString stringWithFormat:@"好，正在搜索附近的「%@」。",navDest];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.3*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[c emitText:say done:NO error:nil generation:gen];});
                TIOVoiceNavTrace([NSString stringWithFormat:@"回复接管：助手发言已截断，候选将流式上镜（终点「%@」）",navDest]);
                return YES;
            }
        }
    }
    return NO;
}
