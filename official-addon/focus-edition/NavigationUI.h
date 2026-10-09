#import <UIKit/UIKit.h>
UIViewController *TIONavigationController(void);
// Voice entry: passive ASR keyword observer ("导航到X/导航去X/带我去X").
// Runs fully headless -- no page is opened; the glasses HUD appearing is the
// success feedback. Opt-out preference key: voiceNavDisabled (default: on).
void TIOVoiceNavMaybeStart(NSString *text);
void TIOVoiceNavStop(void);
// Breadcrumb diagnostics for the headless voice pipeline (shown in 适配与回调).
void TIOVoiceNavTrace(NSString *step);
void TIOVoiceNavTraceReset(void);
NSString *TIOVoiceNavTraceStatus(void);
