#import <Foundation/Foundation.h>

// NavigationVoiceBridge — 导航语音链路接缝（ios107 换装）。
// 这些入口只被 Addon.m 的语音回合引擎在固定位置调用：无导航对话进行时一律
// 返回 NO / 空操作，官方插件行为不变。逻辑实现见 NavigationVoiceBridge.m。

typedef void (^TIONavForwardFn)(id value);   // 经既有钩子链转发（改写后的回包）
typedef void (^TIONavCompleteFn)(void);      // 经既有钩子链提交收尾

// NLP 回包前拦截：改写轮次迟到回包丢弃、候选/方式语音选择消费、注入通道改写。
// 返回 YES = 本轮已消费，调用方不得再转发原始回包。
BOOL TIOVoiceNavNlpIntercept(id listener, SEL cmd, id value, TIONavForwardFn forward, TIONavCompleteFn complete);

// NLP 转发后的收尾钩：新「导航去Y」触发词重开管线 + 候选等待提示。
void TIOVoiceNavNlpAfter(id value);

// 完成回调闸：吞改写轮次的官方收尾；导航接管回合的官方收尾两模式都压
// （否则官方收尾会在候选流式上镜前提前关页）。返回 YES = 不得转发。
BOOL TIOVoiceNavCompleteGate(id listener);

// 回复接管：导航触发词命中时把本轮助手回复当模板接管（确认语/候选流式上镜）。
// 返回 YES = 本轮已接管，调用方不得转发。
BOOL TIOVoiceNavReceiveNlp(id controller, id response, id listener);
