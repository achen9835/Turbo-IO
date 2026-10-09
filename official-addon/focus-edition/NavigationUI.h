#import <UIKit/UIKit.h>
UIViewController *TIONavigationController(void);
// Voice entry: passive ASR keyword observer ("导航到X/导航去X/带我去X/打开导航").
// Opt-out preference key: voiceNavDisabled (feature on by default).
void TIOVoiceNavMaybeStart(NSString *text);
