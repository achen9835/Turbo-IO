#import <UIKit/UIKit.h>
UIViewController *TIONavigationController(void);
// Voice entry: passive ASR keyword observer ("导航到X/导航去X/带我去X").
// Runs fully headless -- no page is opened; the glasses HUD appearing is the
// success feedback. Opt-out preference key: voiceNavDisabled (default: on).
BOOL TIOVoiceNavMaybeStart(NSString *text); // YES = a NEW voice navigation dispatched.
void TIOVoiceNavStop(void);
// Breadcrumb diagnostics for the headless voice pipeline (shown in 适配与回调).
void TIOVoiceNavTrace(NSString *step);
void TIOVoiceNavTraceReset(void);
NSString *TIOVoiceNavTraceStatus(void);
// Multi-turn voice destination choice: when a search yields several local
// candidates the panel announces them and waits for "去第几个".
NSString *TIOVoiceNavMatchDestination(NSString *text); // pure matcher: destination after normalization, nil = no nav trigger
// Assistant-session lifecycle helpers (implemented in Addon.m).
void TIOVoiceCloseAssistantSession(void); // official stop entry; frees the lens
