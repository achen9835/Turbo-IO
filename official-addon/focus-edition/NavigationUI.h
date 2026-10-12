#import <UIKit/UIKit.h>
UIViewController *TIONavigationController(void);
// Voice entry: passive NLP keyword observer ("导航到X/导航去X/带我去X").
// Runs fully headless -- no page is opened; the glasses HUD appearing is the
// success feedback. Opt-out preference key: voiceNavDisabled (default: on).
BOOL TIOVoiceNavMaybeStart(NSString *text); // YES = a NEW voice navigation dispatched.
void TIOVoiceNavStop(void);
// Breadcrumb diagnostics for the headless voice pipeline (shown in 适配与回调).
void TIOVoiceNavTrace(NSString *step);
void TIOVoiceNavTraceReset(void);
NSString *TIOVoiceNavTraceStatus(void);
// Multi-turn voice destination choice: when a search yields several local
// candidates they are streamed into the hijacked assistant chat window (the
// "聊天框") and the panel waits for "第几个" (30s, then defaults to the first).
NSUInteger TIOVoiceNavPendingChoices(void); // 0 = nothing awaiting a choice
BOOL TIOVoiceNavChoose(NSUInteger oneBasedIndex); // YES = consumed a live pending choice
void TIOVoiceNavReject(void); // 用户说「都不对」：清空候选并提示重说（不启动导航）
NSString *TIOVoiceNavMatchDestination(NSString *text); // pure matcher: destination after normalization, nil = no nav trigger
// Assistant-session lifecycle helpers (implemented in Addon.m).
void TIOVoiceCloseAssistantSession(void); // official stop entry; frees the lens
BOOL TIOAssistantEmit(NSString *piece,BOOL done); // append to the hijacked reply; NO = no owned turn (fall back)
