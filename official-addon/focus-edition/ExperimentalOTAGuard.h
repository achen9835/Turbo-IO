#import <Foundation/Foundation.h>
// Preparation-only interlock. No API exists to release it in a running process.
FOUNDATION_EXPORT BOOL TIOOTAIsEmptyVersionQuery(NSData *payload);
FOUNDATION_EXPORT BOOL TIOOTAPreparationBlocks(NSString *method, NSDictionary *arguments, BOOL preparation);
FOUNDATION_EXPORT BOOL TIOOTAPreparationBuild(void);
FOUNDATION_EXPORT void TIOOTARecordTransportHookReady(void);
FOUNDATION_EXPORT BOOL TIOOTAPreparationProtected(void);
FOUNDATION_EXPORT BOOL TIOOTABlockPreparationCall(id call);
FOUNDATION_EXPORT NSDictionary *TIOOTAGuardStatus(void);
// Update-prompt silencer. Outbound business-9 frames are counted but NEVER
// blocked (blocking jams the official BLE request pipeline); the inbound
// version reply's OsVersion is rewritten to a high value instead (default ON;
// TIOUpdateCheckSilence=NO restores official; armed flash sessions exempted).
FOUNDATION_EXPORT BOOL TIOOTAUpdateCheckBlockCall(id call);
FOUNDATION_EXPORT NSData *TIOOTARewriteVersionReply(NSData *payload);
