# 工作记录：TAP3 导航反馈第二轮（2026-11-01 真机反馈）

日期：2026-11-01 · 执行：DeepSeek Harness（Lead + 三个并行队员）

> 用户已刷入 TAP3-2026-11（1.0.5.12 地址修正版）并安装 daily@27adc5e IPA 后的真机反馈。本记录只说明**本次代码/固件/离线验证**做了什么；真机结论仍待用户下一轮反馈。

## 1. 用户反馈（原文摘要）

1. 语音导航大致恢复，但仍须解锁手机进入 App 才开始导航；
2. 模拟导航镜片数据不随手机信息更新；实际导航估计类似；
3. 路线图很小、路网不可见、红绿灯标记没有；
4. 手机退出导航后，眼镜过一会儿只提示“导航数据已过期”，不会立即退出；
5. 省际路网离线包下载有时闪退。

## 2. 独立定位到的根因

### 2.1 会话瞬态失败 → 冻结死锁（解释 2/4，也放大 1）

- 手机 `TNVSession` 把任何非 OK 回执（含 `TN_BUSY`/`TN_UI_FAILED`）都判为会话死亡；固件侧会话仍 `active`，之后新的 `TN_START` 全部回 `TN_BUSY`，手机自动重试也永远上不了镜。镜片冻结在最后一次成功帧（通常就是 START 帧，只有 32 点示意图）。
- 手机会话换代后 `TN_STOP` 的 sid 与固件不一致（`TN_NO_SESSION`），退出指令永远无效；失联后页面也永不自退，只显示“导航数据已过期”。

### 2.2 矢量小地图场景帧根本没有生成（解释 3）

- `RoadMap.decorate` 开头 `coords.count>512` 直接 return：`NavigationUI.drawRoute` 交给它的是整条高德路线（≤4096 点），真实路线几乎必然 >512 → 整条 TNR 场景帧从不生成，镜片只能画 START 帧里的旧示意图 → 小路线图/无路网/无红绿灯标记。
- 即使生成，高亮路线在 768 点预算下也可能被整条丢弃；长弦会让固件 int32 投影溢出，把标记算到车后。
- 另两个可见性因素：未下载省级包/未授权联网/Overpass 图源在中国大陆常不可达；状态行没有区分“为什么没路网”。

### 2.3 省际路网包下载闪退（解释 5）

- `_downloads` NSMapTable 在主线程与后台 delegate 之间无锁并发；整包（2–24MB，上限 200MB）NSMutableData 全量驻留 + 一次性 SHA-256；单格解压上限 64MB；“全部下载”一次并发 26 个 task；进度回调每块 `reloadData`；`TIORoadPackChanged` 在后台线程通知后 UI 直接 `reloadData`；manifest 出现非字典元素时对 NSString 取下标崩溃。

### 2.4 语音链路后台寿命缺口（解释 1）

- 只有 `beginRoute` 才申请 45 秒后台任务；**定位→搜索→候选/追问→算路** 这段最长约一分半没有任何后台任务，也无持续定位活动。锁屏/口袋里 App 被系统挂起，管线停在半路，解锁进 App 才继续。

## 3. 本次改动

### 3.1 固件（TAP3-2026-11B）

- `nav_runtime.c/h`：陈旧活跃会话可被更大 sid 的新 START 接管（8 秒无完整 UPDATE / 链路静默 30 秒）；失联 `!connected` 连续 30 秒自动关页（配合 30 秒链路超时约 60 秒内必退）；失步 STOP（sid 更大）直接退页，旧 sid 重放仍 `TN_NO_SESSION`。
- 60 秒息屏、“导航数据已过期”文案、wire 格式、`TN_PACKET_MAX` 均未改。
- `nav_test.c` 新增 3 组 host 断言；本机 gcc 13.3 + ASan/UBSan 全 PASS。
- 候选重建：两次全新构建逐字节一致；`build.py --audit`、`port_audit.py` 通过；旧 TAP3（`f68e3edc…`）与撤销包（`05170b9b…`）均被拒。
- host 渲染证据（不入库，`.state/fw-host-render`）：合法 SCENE2 → 296×148 满画布地图/比例尺/标记；无矢量帧 → 中心小路线图（与用户照片一致）。

### 3.2 手机端（ios107-edition）

- `NativeNavigation.m`：`TN_BUSY`/`TN_UI_FAILED` 改为同一包同序列有界重试（4 次）；矢量图帧失败只丢弃该帧、绝不杀导航会话；`TN_STOP` 有界重试（10 次/2 秒，`TN_NO_SESSION` 视为已退出）；超时丢帧不杀会话；status 增加 `acks/transients/mapSends/mapDrops/tries/stopTries/stopped/lastEvent`。
- `RoadMap.m`：decorate 接受 ≤4096 点；高亮路线先裁剪再保形抽稀进 512 点预留预算（端点保留），背景路网填剩余预算；新增 C `tnr_path_budget`（`nav_map.c/h`，端点保留 + 长弦稠密化 ≤128m）；Overpass 三镜像 failover（仍受每会话 6 次/60 秒限制）；note/coverageStatus 区分四种“没路网”原因。
- `RoadPack.m/RoadPackUI.m`：单任务串行下载、流式 .part + 增量 SHA-256、主队列 delegate、删除跨线程 NSMapTable、进度节流、主线程通知、manifest 容错、内存上限收紧（单格 16MB/6000 路段、窗口 8000、cellCache costLimit、常驻包 4 个），全部安全校验保留。
- `NavigationBackground.inc/NavigationUI.m/NavigationDisplayHUD.inc`：无头语音链路单一后台保持状态机（voiceStart 即持有、关键阶段续期、上镜/失败/停止/300秒结束），上镜前持续真实定位；回前台按阶段自愈一次；退出补发（首补 5 秒、每 2 秒、最多 10 次、幂等）覆盖结束导航/模拟后台到期/回前台发现旧会话；模拟/手动导航不占用语音额度。
- `NavigationCore.h/.m + NativeNavigationUI.m`：16 条 HUD 诊断环形缓冲（无坐标/设备号/Key/账号），状态 JSON 双写 `Library/Application Support/TurboIOPrivateAddon/` 与用户可导出的 `Documents/TurboIOResearch/native-navigation-status.json`；导航页状态行显示语音阶段/上镜/退出补发/最近事件。
- `test.py`：补齐 stability/coordinates/replay/session 组的 `nav_map.c/RoadPack.m/-lz` 链接缺口，新增 `map-budget` 纯 C 组与 `background` 组。

## 4. 本机验证

| 检查 | 结果 |
| --- | --- |
| 固件 host 测试（nav_test/nav_view_test，gcc + ASan/UBSan） | PASS（含 8 秒接管、30 秒失联自退、失步 STOP 退页） |
| 地图预算 host 测试（MapBudgetTests.c） | PASS |
| 候选审计 build.py --audit / port_audit.py | 通过（40 补丁点、173+27 地址绑定、14 负载不变） |
| 候选元数据一致性（zip/ap/manifest/payloadPins） | 全部匹配 |
| 两次固件重建 | module/AP/ZIP 逐字节一致 |
| ObjC 机械检查（括号/预处理/@implementation） | 全部通过（非编译） |
| 固件 host 渲染证据 | 合法 SCENE2 全量地图；无帧回退小路线 |

## 5. 未验证 / 仍待真机

1. macOS Objective-C 全量测试与 IPA 构建由 GitHub Actions 执行，本记录提交时尚未产出结果；
2. 真机：语音锁屏启动是否不再需要解锁、模拟 HUD 是否跟帧、地图/路网/红绿灯标记是否出现、退出是否 ≤10 秒（最坏约 60 秒固件自退）、省包下载是否不再闪退；
3. 8 秒接管阈值对真实弱网在线导航是否过于激进；
4. 省级包首次加载 3×3 窗口（最多 8000 路段）主线程耗时尚无真机帧率数据；
5. 用户需导出 `Documents/TurboIOResearch/native-navigation-status.json` 或截图导航页状态作为下一轮证据。

## 6. 发布物

- 固件候选：`TAP3-2026-11B`
  - ZIP 8,893,758 B · sha256 `c874225fab7b3722b43d5340203233fbdcffef6a8620acf64304b6eaabc5abec` · md5 `08b8d7ec0dc460ae47abf083c7f7b2e5`
  - AP 7,547,720 B · sha256 `b0ac2fcf82ca35dc8889987ccd1946b5582e6d2651218e07a739129422e5376e` · md5 `e0ce14d73d9711eaceea36817f052297`
  - 模块 233,488 B · sha256 `5418b8f6d144cd14f5bb095d4f971739d099e18588c7b01ee796e7af8d0b45f7`
- 手机端：与本记录同提交构建的 ad-hoc IPA（由 CI 产出，哈希见构建日志/交付说明）。
- 旧候选 `TAP3-2026-11`（`f68e3edc…`）与更旧 `05170b9b…` 均撤销，不要继续刷入。

## 7. 本次实际交付（2026-11-01 03:0x）

- 构建提交 `90d443f`（daily），CI run 41231110173：dylib 编译、TAP3-2026-11B 嵌入、ad-hoc IPA 打包全部成功。
- IPA：`TurboIO-navselfheal-TAP3-2026-11B.ipa`，SHA-256 `040170a10d2c812cc048dc29fc38c3baa6e7b77c7b85671b8b4c500fba7ac754`。
- IPA 内 `TurboWeReadCandidate.zip` 实测 SHA-256 = `c874225fab7b3722b43d5340203233fbdcffef6a8620acf64304b6eaabc5abec`，与候选描述一致；dylib 含 `TAP3-2026-11B`、`NAVIGATION-PHONE-03-BG`、`tnr_path_budget` 等新标记。
- 交付目录：`D:\Downloads\TurboIO-TAP3-2026-11B-nav\`（IPA、SHA256SUMS、交付说明）。
- 下一步：用户重签安装 + 按交付说明刷入 11B 并做五项实测；回传 `native-navigation-status.json` 与镜片照片。

## 8. 追加：11B 真机启动事故与 TAP3-2026-11C 修复（2026-11-01 晚）

### 8.1 现象

用户刷入 11B 后：第一次重启长时间卡在雷鸟开机图标；第二次重启眼镜提示“刷机失败”，手机端仍显示刷机成功。

### 8.2 根因（已由构建产物静态证明，不依赖猜测）

- 11B 修改 `src/navigation-runtime-v1/nav_runtime.c` 后，模块 `.text` 增长 204 字节（模块 233296→233488 B），其后符号地址整体后移（`.state/fw-repro/module.elf` vs `.state/fw-11B-build1/module.elf` 对比：17 个被补丁引用的符号 +204 B）。
- 原厂 AP 的 40 条固定补丁中有 38 条是跳入模块的 Thumb-2 分支（B.W/BL），`build-inputs.json` 里按旧模块地址写死。11B 有 **17 条分支仍指向旧模块地址**，启动期 hook 跳进错误代码 → AP 无法启动；官方安装器只负责写入，所以手机看到“安装成功”。
- 11 版能启动、11B 不能，仅因为 11B 改了模块源码触发布局漂移；此前的构建/审计只检查“分支落在模块范围内”，没有检查落到哪个函数。

### 8.3 修复（11C）

- 38 条模块目标补丁新增 `targetSymbol` / `targetOffset`；`build.py` 链接 ELF 后从 `llvm-nm` 符号表重新计算分支编码，符号漂移或编码过期直接抛错，不再静默产出坏包。
- 新增 `build.py --repin`：重算补丁表与 module/AP/ZIP/清单摘要，并更新 `build-inputs.json`、`candidate-ota.json`、`verification.json`、`candidate-release/firmware.zip`。
- 11C 由 repin 生成：38/38 补丁目标逐条核对等于新模块 ELF 符号地址，且 `after` 字节与成品 AP 一致；第二次全新构建摘要完全一致；`build.py --audit`/`port_audit.py` 通过；11B 旧包在摘要复核时被拒绝。
- 固件源码与 11B 完全相同（导航会话自愈逻辑不变），差异只在补丁表编码。

### 8.4 新候选 TAP3-2026-11C

| 项目 | 值 |
| --- | --- |
| ZIP | 8,893,750 B · sha256 `d1ac2655abb413b30ec94bed960925f8c44d56fdc8920c311a303e9ed14548aa` · md5 `7f799711bf5469c7860bfdc814a79978` |
| AP | 7,547,720 B · sha256 `b9af8e506ed5cae58e3629cab1c0311697758b2047a6d275267f5e7934f34113` · md5 `fbb09b77626b0aea21abac143ffcc456` |
| 模块 | 233,488 B · sha256 `5418b8f6d144cd14f5bb095d4f971739d099e18588c7b01ee796e7af8d0b45f7` |
| 清单 | 2,700 B · sha256 `e8258b4506536c0f51c2431312bf790bf3fb39556a1545442d5e7e9e602b327e` |

旧 11B（`c874225f…`）撤销；11（`f68e3edc…`）与 05170b9b 继续撤销。

### 8.5 已刷 11B 且启动失败设备的处理边界

- 本项目不保证救砖。优先走官方雷鸟 App 的重新升级/售后恢复；若官方 App 无法连接或设备无法进入系统，应停止自行刷写并联系官方售后。
- 在设备恢复为可启动的官方系统之前，不要通过旧 IPA 再次刷入 11B；旧 IPA 内仍嵌 11B 候选。
- 恢复后可安装新 IPA（内嵌 11C），在诊断页确认候选 ZIP 为 `d1ac2655…` 后再决定是否试刷。

### 8.6 教训

- “构建成功 + 摘要可复现 + 分支在模块范围内”不等于可启动：补丁表是**布局耦合**产物，任何模块源码改动都必须重新生成补丁编码并逐条核对符号。
- 后续 TAP2（`strix-1.0.5.5-tvp2`）等使用同一补丁机制的树，改动模块源码时也必须移植本 guard/repin 流程，否则有同样风险。

### 8.7 11C 实际交付（2026-11-01 晚）

- 构建提交 `c4ba116`；CI run 41317226443 成功；11C IPA = `TurboIO-navselfheal-TAP3-2026-11C.ipa`，SHA-256 `3750564506b9de74ad36a5a7b94175fdfc20434352b34142fa4cf78c147cdfb1`。
- 已核对 IPA 内 `TurboWeReadCandidate.zip` = 11C 固件 `d1ac2655…`（8,893,750 B）；dylib 含 `TAP3-2026-11C`/`NAVIGATION-PHONE-03-BG`/`tnr_path_budget` 标记。
- 交付目录 `D:\Downloads\TurboIO-TAP3-2026-11C-nav`（IPA、SHA256SUMS、交付与恢复说明）；旧 11B 目录已加“已撤销”警示。
- 当前阻塞：用户设备因 11B 启动失败，需先按官方 App/售后恢复；11C 真机验收仍未开始。
