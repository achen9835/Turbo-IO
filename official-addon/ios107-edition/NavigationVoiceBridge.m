// NavigationVoiceBridge.m — 导航语音链路的最小桥面（ios107 换装支撑）。
// 原实现住在 focus 线 Addon.m 的语音回合引擎（TIOController）内；ios107 基座
// 保留官方插件自身的语音体系（Addon.m 原样），本文件只提供导航簇所需的桥面：
// · TIOVoiceNavTrace 系——面包屑诊断，照搬 focus 线语义（1600 字环形缓冲、
//   主线程一致性），供无头语音导航失败时定位卡点。
// · TIOVoiceCloseAssistantSession——复刻 focus 线 exitVoice 的核心动作：
//   调用已验证的官方停止入口（VoiceAssistantHelper.shared stopWorkflow），
//   导航真正开始时释放镜片。不涉及自建回复流，无需其 cancel 收尾。
// · TIOAssistantEmit / TIOAssistantInjectNext——依赖 focus 线的劫持回合引擎
//   （TIORequest + hook 面 + 飞书桥），不在换装范围。按头文件契约返回 NO /
//   空操作（"NO = no owned turn (fall back)"）：候选播报退回自动选择，
//   导航主流程（HUD/地图/路线/引导）不受影响。
#import "NavigationUI.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>

static NSString *VoiceNavTrace=@"";

void TIOVoiceNavTrace(NSString *step){
    void (^work)(void)=^{VoiceNavTrace=[VoiceNavTrace stringByAppendingFormat:@"\n· %@",step?:@""];if(VoiceNavTrace.length>1600)VoiceNavTrace=[VoiceNavTrace substringFromIndex:VoiceNavTrace.length-1600];};
    if(NSThread.isMainThread)work();else dispatch_async(dispatch_get_main_queue(),work);
}
void TIOVoiceNavTraceReset(void){
    if(NSThread.isMainThread)VoiceNavTrace=@"";else dispatch_async(dispatch_get_main_queue(),^{VoiceNavTrace=@"";});
}
NSString *TIOVoiceNavTraceStatus(void){return VoiceNavTrace;}

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

BOOL TIOAssistantEmit(NSString *piece,BOOL done){
    (void)piece;(void)done;
    return NO; // 无劫持回合：调用方按契约退回自动选择
}
void TIOAssistantInjectNext(NSString *text,BOOL done){
    (void)text;(void)done;
    TIOVoiceNavTrace(@"候选播报注入通道未随换装迁移：已退回自动选择");
}
