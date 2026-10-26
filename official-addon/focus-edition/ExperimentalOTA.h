#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Embedded pinned candidate descriptor (candidates/*.json, generated into
// OTACandidate.gen.m). nil when missing or structurally invalid: every
// consumer below then fails closed.
FOUNDATION_EXPORT NSDictionary * _Nullable TIOOTACandidate(void);
// Immutable verified payloads for a single explicitly authorized transfer.
NSDictionary<NSString *,NSData *> * _Nullable TIOCopyExperimentalOTAPayloads(NSURL *directory,NSError **error);
// Fixed reviewed candidate only. Integrity approval never means authorization to flash.
FOUNDATION_EXPORT NSString *TIOExperimentalOTASHA(void);
// 官方 App 按我们 feed 的 downloadUrl 文件名命名解压目录（Strix_OS_<baseVersion>）；
// 从候选描述派生，随底座版本（1.0.4.12/1.0.5.5）自动切换。
FOUNDATION_EXPORT NSString *TIOOTAOfficialDirectoryName(void);
FOUNDATION_EXPORT NSDictionary * _Nullable TIOCheckExperimentalOTA(NSData *data, NSError **error);
FOUNDATION_EXPORT NSDictionary * _Nullable TIOReadExperimentalOTA(NSURL *file, NSError **error);
FOUNDATION_EXPORT NSDictionary * _Nullable TIOImportExperimentalOTA(NSURL *source, NSURL *directory, NSError **error);
// Point-in-time read-only snapshot, NOT a frozen transfer session or flash approval.
FOUNDATION_EXPORT NSDictionary * _Nullable TIOCheckExperimentalOTADirectory(NSURL *directory, NSError **error);
NS_ASSUME_NONNULL_END
