#import <Foundation/Foundation.h>
// Feishu webhook bot notification: send a text message to a group chat via
// a custom-bot webhook URL. No OAuth, no tokens, just POST the URL.
FOUNDATION_EXPORT NSString *TIOFeishuWebhookURL(void);
FOUNDATION_EXPORT BOOL TIOFeishuEnabled(void);
FOUNDATION_EXPORT void TIOFeishuSetEnabled(BOOL on);
FOUNDATION_EXPORT BOOL TIOFeishuConfigure(NSString *webhookURL);
FOUNDATION_EXPORT void TIOFeishuSend(NSString *text,void(^completion)(NSString *error));
