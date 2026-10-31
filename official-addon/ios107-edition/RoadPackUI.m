#import "RoadPackUI.h"
#import "RoadPack.h"
#import <UIKit/UIKit.h>
/* 省际路网包管理页：清单来自 roadmap-packs Release；单省下载/删除，
 * 一键全部下载（管理器内部串行排队，页面不再并发 26 个请求）。
 * 下载内容只用于 TNR 矢量小地图渲染。
 * 属性走类扩展，避免与 RoadPackUI.h 的主声明重复。 */
@interface TIORoadPackListController ()
@property(nonatomic,copy) NSArray<NSDictionary *> *packs;
@property(nonatomic,strong) NSMutableDictionary<NSString *, NSNumber *> *progress; /* province -> 0..1 */
@property(nonatomic,strong) UIRefreshControl *refresher;
@property(nonatomic,strong) NSMutableSet<NSString *> *batchPacks; /* “全部下载”里尚未完成的省 */
@property(nonatomic) NSUInteger batchFailed;
@end
@implementation TIORoadPackListController
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _packs = @[];
        _progress = [NSMutableDictionary dictionary];
        self.title = @"省际路网包";
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(packChanged:) name:@"TIORoadPackChanged" object:nil];
    }
    return self;
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 64;
    self.refresher = [UIRefreshControl new];
    [self.refresher addTarget:self action:@selector(refresh) forControlEvents:UIControlEventValueChanged];
    [self.tableView addSubview:self.refresher];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]initWithTitle:@"全部下载" style:UIBarButtonItemStylePlain target:self action:@selector(downloadAll)];
    [self refresh];
}
- (void)refresh {
    [self.refresher beginRefreshing];
    __weak typeof(self) weak = self;
    [[TIORoadPackManager shared] refreshManifest:^(BOOL ok, NSString *note) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weak) s = weak; if (!s) return;
            [s.refresher endRefreshing];
            s.packs = [TIORoadPackManager shared].manifest;
            [s.tableView reloadData];
            if (!ok) [s toast:note];
        });
    }];
}
/* 通知由 RoadPack 在主线程发出；完成/删除才 reload，下载进度只改可见 cell。 */
- (void)packChanged:(NSNotification *)n {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self packChanged:n]; }); return; }
    [self.tableView reloadData];
}
- (void)toast:(NSString *)msg {
    if (!msg.length || !self.isViewLoaded || !self.view.window) return; /* 已退出页面/批次收尾时不再弹 */
    if (self.presentedViewController) return;                          /* 避免批量下载时弹窗风暴 */
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return self.packs.count; }
/* 只改这一行的按钮，不 reloadData：进度按 >=5%/200 ms 节流后仍可能每秒数次。 */
- (void)configureAction:(UITableViewCell *)cell forPack:(NSDictionary *)p {
    UIButton *b = (UIButton *)cell.accessoryView;
    if (![b isKindOfClass:UIButton.class]) return;
    NSString *province = p[@"province"];
    NSNumber *prog = self.progress[province];
    if (prog && [prog doubleValue] < 1) {
        b.backgroundColor = UIColor.systemGray5Color;
        b.enabled = NO;
        double v = [prog doubleValue];
        [b setTitle:(v < 0.005 ? @"排队" : [NSString stringWithFormat:@"%.0f%%", v * 100]) forState:UIControlStateNormal];
    } else if ([[TIORoadPackManager shared] packDownloaded:province]) {
        b.backgroundColor = UIColor.systemRedColor;
        [b setTitle:@"删除" forState:UIControlStateNormal];
        b.enabled = YES;
    } else {
        b.backgroundColor = UIColor.systemGray4Color;
        [b setTitle:@"下载" forState:UIControlStateNormal];
        b.enabled = YES;
    }
}
- (void)refreshCellForProvince:(NSString *)province {
    if (!province.length || !self.isViewLoaded || !self.view.window) return;
    for (NSIndexPath *ip in self.tableView.indexPathsForVisibleRows) {
        if (ip.row >= (NSInteger)self.packs.count) continue;
        NSDictionary *p = self.packs[ip.row];
        if (![p[@"province"] isEqual:province]) continue;
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:ip];
        if (cell) [self configureAction:cell forPack:p];
    }
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"pack"];
    if (!cell) {
        cell = [[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"pack"];
        cell.textLabel.font = [UIFont systemFontOfSize:16];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(0, 0, 88, 34);
        b.layer.cornerRadius = 8;
        b.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        b.accessibilityIdentifier = @"road-pack-action";
        [b addTarget:self action:@selector(action:) forControlEvents:UIControlEventTouchUpInside];
        cell.accessoryView = b;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSDictionary *p = self.packs[ip.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%@（%@）", p[@"display"] ?: p[@"province"], p[@"province"]];
    double mb = [p[@"size"] doubleValue] / 1048576.0;
    NSString *built = [p[@"builtAt"] isKindOfClass:NSString.class] ? [p[@"builtAt"] substringToIndex:MIN(10, [p[@"builtAt"] length])] : @"";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%.1f MB · %ld 格 · 数据 %@ · © OpenStreetMap", mb, (long)[p[@"cells"] integerValue], built];
    UIButton *b = (UIButton *)cell.accessoryView;
    b.tag = ip.row;
    [self configureAction:cell forPack:p];
    return cell;
}
- (void)action:(UIButton *)sender {
    if (sender.tag >= (NSInteger)self.packs.count) return;
    NSDictionary *p = self.packs[sender.tag];
    NSString *province = p[@"province"];
    if ([[TIORoadPackManager shared] packDownloaded:province]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"删除路网包"
            message:[NSString stringWithFormat:@"删除 %@ 的离线路网？删除后该省需要重新下载才能离线显示。", p[@"display"] ?: province]
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [[TIORoadPackManager shared] deletePack:province];
            [self.progress removeObjectForKey:province];
            [self.tableView reloadData];
        }]];
        [self presentViewController:a animated:YES completion:nil];
    } else {
        [self startDownload:province];
    }
}
- (void)startDownload:(NSString *)province {
    if (!province.length || self.progress[province]) return;
    self.progress[province] = @0.001; /* 已入队，避免重复点击 */
    [self refreshCellForProvince:province];
    __weak typeof(self) weak = self;
    [[TIORoadPackManager shared] downloadPack:province progress:^(double fraction) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weak) s = weak; if (!s) return;
            s.progress[province] = @(fraction);
            [s refreshCellForProvince:province];
        });
    } done:^(BOOL ok, NSString *note) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weak) s = weak; if (!s) return;
            [s.progress removeObjectForKey:province];
            [s refreshCellForProvince:province];
            if (s.batchPacks) {
                if ([s.batchPacks containsObject:province]) {
                    [s.batchPacks removeObject:province];
                    if (!ok) s.batchFailed++;
                    if (!s.batchPacks.count) {
                        NSUInteger failed = s.batchFailed;
                        s.batchPacks = nil;
                        s.batchFailed = 0;
                        [s toast:failed ? [NSString stringWithFormat:@"全部下载结束：%lu 省失败", (unsigned long)failed] : @"全部下载完成"];
                    }
                    return;
                }
            }
            [s toast:[NSString stringWithFormat:@"%@：%@", province, note]];
        });
    }];
}
/* 管理器内部只有一个下载任务在跑；其余按入队顺序排队，不再一次并发 26 个请求。 */
- (void)downloadAll {
    NSMutableArray<NSString *> *todo = [NSMutableArray array];
    for (NSDictionary *p in self.packs) {
        NSString *province = p[@"province"];
        if (!province.length) continue;
        if (![[TIORoadPackManager shared] packDownloaded:province] && !self.progress[province]) [todo addObject:province];
    }
    if (!todo.count) return;
    self.batchPacks = [NSMutableSet setWithArray:todo];
    self.batchFailed = 0;
    for (NSString *province in todo) [self startDownload:province];
}
@end
