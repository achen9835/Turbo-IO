#import "KnowledgeUI.h"
#import "KnowledgeClient.h"
#import "ResearchUI.h"
// Feishu webhook bot notification: one field (webhook URL), one toggle,
// one test button. Messages sent here appear in the user's Feishu group
// chat as notifications, which the glasses relay natively.
@interface TIOFeishuPanel:UITableViewController
@property(nonatomic,copy) NSString *status;
@end
@implementation TIOFeishuPanel
- (void)viewDidLoad{[super viewDidLoad];self.title=@"飞书通知";TIOStyleResearchTable(self);self.status=TIOFeishuEnabled()?@"已启用":@"未启用";self.tableView.tableHeaderView=TIOFeatureHeader(@"飞书 Webhook 通知",@"语音提问的结果发送到飞书群，眼镜通过飞书通知看到回答。",@"paperplane");}
- (void)alert:(NSString *)t{UIAlertController *a=[UIAlertController alertControllerWithTitle:@"飞书通知" message:t preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t{return 1;}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s{return 3;}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s{return @"配置";}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s{return @"在飞书群里添加「自定义机器人」，把生成的 Webhook 地址粘贴到上面。语音提问后，结果会发到该群并触发通知。地址仅存本机钥匙串。";}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip{
    UITableViewCell *c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];TIOStyleResearchCell(c);c.textLabel.numberOfLines=0;c.detailTextLabel.numberOfLines=0;
    if(ip.row==0){c.textLabel.text=@"启用飞书通知";UISwitch *s=[UISwitch new];s.on=TIOFeishuEnabled();[s addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];c.accessoryView=s;c.detailTextLabel.text=TIOFeishuEnabled()?@"语音结果自动发送到飞书群":@"关闭时不发送";}
    else if(ip.row==1){c.textLabel.text=@"Webhook 地址";NSString *u=TIOFeishuWebhookURL();c.detailTextLabel.text=u.length?[u stringByReplacingOccurrencesOfString:@"https://open.feishu.cn/open-apis/bot/v2/hook/" withString:@"…hook/"]:@"点击配置";c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;}
    else{c.textLabel.text=@"发送测试消息";c.detailTextLabel.text=self.status;c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;}
    return c;
}
- (void)toggle:(UISwitch *)s{
    TIOFeishuSetEnabled(s.on);
    if(s.on&&!TIOFeishuEnabled()){s.on=NO;[self alert:@"请先配置 Webhook 地址。"];return;}
    self.status=s.on?@"已启用":@"未启用";[self.tableView reloadData];
}
- (void)configure{
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"飞书 Webhook" message:@"飞书群 → 设置 → 群机器人 → 添加自定义机器人 → 复制 Webhook 地址" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f){f.text=TIOFeishuWebhookURL();f.placeholder=@"https://open.feishu.cn/open-apis/bot/v2/hook/…";f.autocapitalizationType=UITextAutocapitalizationTypeNone;f.autocorrectionType=UITextAutocorrectionTypeNo;}];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
        NSString *url=a.textFields[0].text?:@"";
        if(url.length&&!TIOFeishuConfigure(url)){[self alert:@"地址无效。需要 https://open.feishu.cn/open-apis/bot/v2/hook/… 格式。"];return;}
        [self.tableView reloadData];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip{[t deselectRowAtIndexPath:ip animated:YES];
    if(ip.row==1)[self configure];
    else if(ip.row==2){
        self.status=@"发送中…";[self.tableView reloadData];
        TIOFeishuSend(@"TurboIO 飞书通知测试 ✅ 语音提问的结果会发到这个群。",^(NSString *error){
            self.status=error?[NSString stringWithFormat:@"失败：%@",error]:@"发送成功 ✅";
            [self.tableView reloadData];
        });
    }
}
@end
void TIOOpenKnowledge(UIViewController *host){[host.navigationController pushViewController:[[TIOFeishuPanel alloc]initWithStyle:UITableViewStyleInsetGrouped] animated:YES];}
