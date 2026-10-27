#import "RoadPack.h"
#import <UIKit/UIKit.h>
/* 省际路网包管理页：清单来自 roadmap-packs Release；单省下载/删除，
 * 一键全部下载。下载内容只用于 TNR 矢量小地图渲染。 */
@interface TIORoadPackListController : UITableViewController
@property(nonatomic,copy) NSArray<NSDictionary *> *packs;
@property(nonatomic,strong) NSMutableDictionary<NSString *, NSNumber *> *progress; /* province -> 0..1 */
@property(nonatomic,strong) UIRefreshControl *refresher;
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
- (void)packChanged:(NSNotification *)n { [self.tableView reloadData]; }
- (void)toast:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return self.packs.count; }
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
    NSString *province = p[@"province"];
    NSNumber *prog = self.progress[province];
    if (prog && [prog doubleValue] < 1) {
        b.backgroundColor = UIColor.systemGray5Color;
        [b setTitle:[NSString stringWithFormat:@"%.0f%%", [prog doubleValue] * 100] forState:UIControlStateNormal];
        b.enabled = NO;
    } else if ([[TIORoadPackManager shared] packDownloaded:province]) {
        b.backgroundColor = UIColor.systemRedColor;
        [b setTitle:@"删除" forState:UIControlStateNormal];
        b.enabled = YES;
    } else {
        b.backgroundColor = UIColor.systemFill;
        [b setTitle:@"下载" forState:UIControlStateNormal];
        b.enabled = YES;
    }
    return cell;
}
- (void)action:(UIButton *)sender {
    if (sender.tag >= (NSInteger)self.packs.count) return;
    NSDictionary *p = self.packs[sender.tag];
    NSString *province = p[@"province];
    if ([[TIORoadPackManager shared] packDownloaded:province]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"删除路网包"
            message:[NSString stringWithFormat:@"删除 %@ 的离线路网？删除后该省需要重新下载才能离线显示。", p[@"display"] ?: province]
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [[TIORoadPackManager shared] deletePack:province];
            [self.tableView reloadData];
        }]];
        [self presentViewController:a animated:YES completion:nil];
    } else {
        [self startDownload:province];
    }
}
- (void)startDownload:(NSString *)province {
    self.progress[province] = @0.001;
    [self.tableView reloadData];
    __weak typeof(self) weak = self;
    [[TIORoadPackManager shared] downloadPack:province progress:^(double fraction) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weak) s = weak; if (!s) return;
            s.progress[province] = @(fraction);
            [s.tableView reloadData];
        });
    } done:^(BOOL ok, NSString *note) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weak) s = weak; if (!s) return;
            [s.progress removeObjectForKey:province];
            [s.tableView reloadData];
            [s toast:[NSString stringWithFormat:@"%@：%@", province, note]];
        });
    }];
}
- (void)downloadAll {
    for (NSDictionary *p in self.packs) {
        NSString *province = p[@"province"];
        if (![[TIORoadPackManager shared] packDownloaded:province] && !self.progress[province]) [self startDownload:province];
    }
}
@end
