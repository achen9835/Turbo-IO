# 工作记录：TAP3-2026-11G 交付与 macOS 迁移首轮真机验收（2026-11-04）

日期：2026-11-04 · 执行：Kimi Code（macOS 本地全链构建 + Wi-Fi 直装）

> 本记录覆盖：Mac 迁移后的首次本地打包-签名-安装闭环、11E→11G 三个固件候选的迭代、
> ios107 离线回归门禁首次全绿、真机验收发现与修复。真机结论以用户验收为准。

## 1. 交付物（哈希钉死）

| 工件 | 标识 |
| --- | --- |
| 手机 IPA（签名版，NAS `TurboIO-signed.ipa`） | CFBundleVersion 264，sha256 `ec9e20d3…159a` |
| 固件候选 | **TAP3-2026-11G**（1.0.5.12 基座，官方 LLVM 19.1.7 重钉） |
| 11G 固件包 | 8,888,678 B，sha256 `9efa5d2e…22dc`；AP `5b5a282f…3a08` |
| 刷机目标 | 眼镜自 11C 升级至 11G（11E/11F 为中间候选，未上机即被取代） |
| 宿主 | 官方 iOS 1.0.10(258) 净化砸壳包（sha256 `e6cc1f1b…`，与 CI 钉一致） |
| 签名 | Apple Distribution: Jiawan Chen (2KUJ26BT63) + Ad Hoc 描述文件（设备 00008150-…） |
| 验收证据 | `docs/screenshots/acceptance-11G-1/2/3.png`（镜片实拍）、`roadmap-preview-11G.png`（host 渲染） |

## 2. 本轮修复（全部经真机验收确认）

### 2.1 固件侧（TAP3-2026-11E→11G）
- **11E**：构建链迁移 macOS——官方 LLVM 19.1.7 重钉哈希（DevEco LLVM 无独立分发渠道；
  repin 走完整审查语义，本机可字节复现）。手机端描述符经 `TIO_OTA_CANDIDATE` 内嵌 11E。
- **11F→11G（路网可见性，真机拍板两次修正）**：
  - 现象：路线与路网在多车道主辅路并行时"一样亮"，观感像逆行（用户录屏 `acceptance-11G-*` 前序视频）。
  - 首次修法（11F）压暗背景灰度到 40-72——**被历史记录否掉**：R3 固件留有真机反馈
    "畅通档(112)亮度不可见"（提到 168），即此屏可见亮度地板 ≈160。
  - 最终修法（11G）：灰度保持可见档 160-185，**背景路网一律虚线（4/4）+ 路线实线 255+光晕**，
    靠样式分层而非亮度分层。host 渲染核对通过。

### 2.2 手机端 ios107（71789ec 从未构建/运行过的债，首次全清）
- **离线回归门禁 16 组全绿**（`.github/workflows/ios-merge.yml` 的 test.py 自 71789ec 加入后从未运行）：
  修复 9 处——编译缺 include、三处陈旧测试期望、fixture 帧尾 POSE 缺失、模拟/真实时钟混用、
  C 预处理器逗号陷阱、API 改名、TCP 时序、版本拒绝语义。其中产品行为修正两处：
  HUD 标记自测路线改前向（原 U 形让标记投影到车后）；其余为测试期望对齐既有设计。
- **构建号门三处（同一根因，均为 CFBundleVersion 递增触发）**：`VersionMatches()` 的
  (version,build)→UUID 查表在 258→259+ 后落空，导致**底栏入口不启动、语音钩子全灭、
  OTA 回环 Feed 拒启（官方更新检查全屏失败卡死）**。修法：HostCompatibility 改为
  LC_UUID∈钉死白名单（版本/构建号降级为查表键）；OTA Feed 1.0.10 门只锁版本号
  （补丁在场由 App.framework 字节校验保证）；Addon 语音钩子校验改细粒度诊断 + 2/4/6/8s 重试。
- **RoadPack 省包两个读取 bug（路网从未真正能用的根因）**：bundled 包名
  `TurboRoadMap-sichuan.pack` 整名过 SafeSlug（大写）被静默跳过；打包器格索引为数据区相对
  偏移而读取端当文件绝对偏移（每格解压全部失败）。host 实证修复后成都片区解出 4110-8000 条路段。
- **导航转向映射补齐**：环岛 17-28 号图标别名（高德素材缺该系列）+ 中文文案，
  13/14/16（服务区/收费站/隧道）、32/33（广场/公园）文案。

### 2.3 工具链/环境（macOS 迁移）
- 便携工具链：Node 26、Flutter 3.47.9、Temurin JDK 17.0.21、Android cmdline-tools+platform-36、
  apktool 3.0.3、XcodeGen 2.46.0、uv 0.13.6、Python 3.13.18、官方 LLVM 19.1.7（`/Users/apple/tools/`）。
- 项目盘为 SMB 网络卷且**不支持符号链接**：venv 必须放本地磁盘（`/Users/apple/venvs/`）；
  小文件操作极慢，打包中间产物一律本地。
- github.com 不可达：gh-proxy/ghfast.top 代理 + TUNA 镜像；多线程分段下载规避单流限速。
- 真机通道：devicectl Wi-Fi 安装（`device process launch --console` 需 get-task-allow，
  Ad Hoc 不行）；应用容器文件可经 `device copy from --domain-type appDataContainer` 拉取诊断 JSON。

## 3. 验收结论（用户 2026-11-04 确认）

- 路网显示正常（虚线背景 + 实线路线分层可辨）；环岛箭头/文字正常；
- 入口/语音钩子/更新检查恢复（`hooks=1; version=1`）；刷机链路 11E→11G 走通。
- 模拟/真实导航同链路，模拟验收结论可外推。

## 4. 遗留
- 79 个 CRLF 行尾污染文件（Windows 拷贝遗留，零实质改动）未处理，建议 `.gitattributes` + 统一行尾。
- 环岛图标为现有素材近似（用户评"丑"），专用素材可后续绘制替换。
- 路况虚线对比度、限速圈显示范围可继续按真机反馈调。
- 11E/11F 候选留在 git 历史中，未上机。
