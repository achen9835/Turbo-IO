#import "KnowledgeClient.h"
#import <Security/Security.h>
// Feishu custom-bot webhook: the simplest notification path. The user creates
// a custom bot in a Feishu group, gets a webhook URL, and this module POSTs
// text messages to it. The message appears in the group as a Feishu
// notification, which the glasses relay natively.
static NSUserDefaults *Settings(void){return [[NSUserDefaults alloc]initWithSuiteName:@"io.turboio.official-knowledge"];}
static NSDictionary *KeyQuery(void){return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:@"io.turboio.official-knowledge",(__bridge id)kSecAttrAccount:@"feishu-webhook"};}
static NSString *StoredWebhook(void){NSMutableDictionary *q=[KeyQuery() mutableCopy];q[(__bridge id)kSecReturnData]=@YES;CFTypeRef out=NULL;if(SecItemCopyMatching((__bridge CFDictionaryRef)q,&out)!=errSecSuccess)return @"";return [[NSString alloc]initWithData:CFBridgingRelease(out) encoding:NSUTF8StringEncoding]?:@"";}
static BOOL StoreWebhook(NSString *url){
    NSDictionary *attrs=@{(__bridge id)kSecValueData:[url dataUsingEncoding:NSUTF8StringEncoding],(__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly};
    OSStatus s=SecItemUpdate((__bridge CFDictionaryRef)KeyQuery(),(__bridge CFDictionaryRef)attrs);
    if(s==errSecItemNotFound){NSMutableDictionary *all=[KeyQuery() mutableCopy];[all addEntriesFromDictionary:attrs];s=SecItemAdd((__bridge CFDictionaryRef)all,NULL);}
    return s==errSecSuccess;
}
NSString *TIOFeishuWebhookURL(void){return StoredWebhook();}
BOOL TIOFeishuEnabled(void){return [Settings() boolForKey:@"feishuEnabled"]&&StoredWebhook().length>0;}
void TIOFeishuSetEnabled(BOOL on){[Settings() setBool:on forKey:@"feishuEnabled"];}
BOOL TIOFeishuConfigure(NSString *webhookURL){
    if(![webhookURL isKindOfClass:NSString.class]||webhookURL.length<20)return NO;
    if(![webhookURL hasPrefix:@"https://open.feishu.cn/open-apis/bot/v2/hook/"]&&![webhookURL hasPrefix:@"https://open.larksuite.com/open-apis/bot/v2/hook/"])return NO;
    return StoreWebhook(webhookURL);
}
void TIOFeishuSend(NSString *text,void(^completion)(NSString *error)){
    if(!text.length){completion(@"empty");return;}
    NSString *url=StoredWebhook();if(!url.length){completion(@"webhook not configured");return;}
    NSDictionary *payload=@{@"msg_type":@"text",@"content":@{@"text":text}};
    NSData *body=[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    r.HTTPMethod=@"POST";r.HTTPBody=body;r.timeoutInterval=15;
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [[[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration] dataTaskWithRequest:r completionHandler:^(NSData *data,NSURLResponse *resp,NSError *err){
        dispatch_async(dispatch_get_main_queue(),^{
            if(err){completion(err.localizedDescription);return;}
            NSInteger code=[resp isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)resp statusCode]:0;
            if(code!=200){completion([NSString stringWithFormat:@"HTTP %ld",(long)code]);return;}
            NSDictionary *j=data.length<=8192?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
            if([j isKindOfClass:NSDictionary.class]&&[j[@"code"] integerValue]!=0){
                completion([NSString stringWithFormat:@"Feishu: %@ (code %ld)",j[@"msg"]?:@"unknown",(long)[j[@"code"] integerValue]]);
                return;
            }
            completion(nil);
        });
    }] resume];
}
