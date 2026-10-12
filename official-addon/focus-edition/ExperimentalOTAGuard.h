#import <Foundation/Foundation.h>
// Preparation-only interlock. No API exists to release it in a running process.
FOUNDATION_EXPORT BOOL TIOOTAIsEmptyVersionQuery(NSData *payload);
FOUNDATION_EXPORT BOOL TIOOTAPreparationBlocks(NSString *method, NSDictionary *arguments, BOOL preparation);
FOUNDATION_EXPORT BOOL TIOOTAPreparationBuild(void);
FOUNDATION_EXPORT void TIOOTARecordTransportHookReady(void);
FOUNDATION_EXPORT BOOL TIOOTAPreparationProtected(void);
FOUNDATION_EXPORT BOOL TIOOTABlockPreparationCall(id call);
FOUNDATION_EXPORT NSDictionary *TIOOTAGuardStatus(void);
// Silences the official firmware update check by swallowing the business-9
// empty version read (default ON; TIOUpdateCheckSilence=NO restores official).
FOUNDATION_EXPORT BOOL TIOOTAUpdateCheckBlockCall(id call);
