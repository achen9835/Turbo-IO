# TAP3 · Strix OS 1.0.5.12 大地图导航恢复版 · 2026-11D

2026-11-02 · 非官方、非商业、高风险实验固件。**11D 已完成离线重建、地址审计、host 单测与实际渲染预览，尚未完成真机运行验收。**

## 11D 导航修复范围

用户实测 11C 的基础转向与文字可显示，但周边路网、限速、红绿灯和 HUD 标记测试不生效。对照 TAP1 成功布局、TAP2 矢量实现及用户选定的效果图后，确认当前版本存在地图绘制只依赖受 `focus_screen_on()` 限制的定时器、首次接收不立即绘制的问题。用户最终明确选择 **296×148 大地图**，不采用此前讨论的“192×144 小地图 + 280×40 独立提示带”。

最终布局：

- 左侧保留 64×64 转向图标、距离、速度、转向提示、目标路名、剩余里程/时间及到达时间；
- 右侧地图位于 `(238,4)`，尺寸为 **296×148**，显示路线、周边路网、道路名、车辆、比例尺及地图内限速/红绿灯/事件标记；
- 合法 SCENE/POSE 到达后立即尝试提交绘制，LVGL 忙碌时由后续 tick 补画，不再让 `focus_screen_on()` 单独决定地图是否显示；
- 接收与绘制分离，已接受但暂忙不能造成重放包被判重复；
- 保留路口 halo 防断线、标签避让、桥隧样式、沿路线弧线的标记、拥堵显示与双缓冲。

预览由真实 `nav_view.c` / `nav_map.c` 渲染函数生成，使用公开深圳 OSM 路网；导航文案、路况和“攀枝花大道/人民路”为指定效果图的演示数据，不冒充当地真实道路名称。已人工核对道路名、路线、车辆、比例尺与地图内路况标记可见且左侧文本不重叠。host 预览不代表眼镜面板或真实导航数据源已验收。

旧 TAP3（ZIP SHA-256 `05170b9b4eed38edbf562affaeab21f248394a44702d812440226d5e27a524eb`）直接沿用了大量 1.0.5.5 地址，不能视为完成了 1.0.5.12 移植。**旧摘要已撤销，不要继续刷入，也不要用“文件哈希一致”推断旧包可以运行。**

## 2026-11-01 11B 启动事故（必须读）

**11B（ZIP `c874225f…`）在真机首启卡雷鸟开机 logo、二次重启提示“刷机失败”，手机端却报安装成功。该包已撤销，不要继续刷入。**

根因不是 nav 业务代码逻辑，而是**构建期的补丁表布局依赖**：11B 修改 `nav_runtime.c` 后模块代码增长，模块内后续符号地址整体后移；而 `build-inputs.json` 中 40 条对原厂 AP 的固定补丁里，有 38 条是跳入模块的 Thumb-2 分支（B.W/BL），其编码仍按旧模块符号地址写死。11B 有 17 条因此跳到错误偏移，启动期 hook 进入错误代码，导致 AP 无法启动——手机端“安装成功”只代表写入完成。

11C 的修复：

- 38 条模块目标补丁新增 `targetSymbol` / `targetOffset` 字段；
- `build.py` 链接完模块后从 ELF 符号表重新计算分支编码：**符号地址漂移或编码过期时直接拒绝构建**，不再静默产出坏包；
- 新增 `build.py --repin`：源码改动后一键重算补丁表、模块/AP/ZIP/清单摘要并更新 `build-inputs.json`、`candidate-ota.json`、`verification.json` 与 `candidate-release/firmware.zip`；
- 11C 构建后逐条验证 **38/38 补丁目标 == 新模块 ELF 符号地址**，且 `after` 字节与成品 AP 逐字节一致。

> 已刷入 11B 且启动失败的设备：先按官方 App / 官方售后流程恢复，**在能稳定进入官方系统前不要反复刷任何自定义包**。本项目不保证救砖。

## 2026-11B 导航会话修复（相对 2026-11，11C 继续保留）

真机反馈：手机一端出现一次瞬态 `TN_UI_FAILED`/`TN_BUSY` 后，固件仍保持旧会话 active，之后新的 `TN_START` 全部被 `TN_BUSY` 拒绝，镜片永久冻结在旧帧；手机退出导航后镜片停在“导航数据已过期”；失联后页面永不自退。相关改动在 `src/navigation-runtime-v1/nav_runtime.c`（wire 格式、60 s 息屏、60 s“导航数据已过期”文案与 `TN_PACKET_MAX` 等既有协议语义均未改动）：

- **陈旧活跃会话可被新 START 接管**：当 `r->active` 且（距最后一次完整 `TN_UPDATE` ≥ `TN_TAKEOVER_MS`=8 s，或链路已静默 ≥ `TN_LINK_MS`=30 s / `tn_disconnect` 已把 `connected` 置 false）且新 `TN_START` 的 `sid` 更大时，先 `tn_local_exit` 释放旧页面，再按原有 START 流程过 `available`/`enter`。仍然在线的会话照旧返回 `TN_BUSY`，只有更大的 sid 才能接管。
- **失联自退**：`tn_tick` 中 `active && !connected` 连续 ≥ `TN_GONE_EXIT_MS`=30 s 时 `tn_local_exit` 关闭导航页并释放常亮；配合 `TN_LINK_MS` 相当于最后一次真实链路后约 60 s 内必退。30 s 内恢复的短暂掉线不会误退，在线但无 UPDATE 的 60 s 息屏/过期语义保持原样。
- **失步 STOP 退页**：`TN_STOP` 且 `sid` 比固件当前 `sid` 更大（手机会话已换代）时直接关页并回 `TN_OK`；更小 sid 的迟到重放仍回 `TN_NO_SESSION`，不会误关新会话。envelope/CRC/paired 校验保持不变。

host 证据：gcc 13.3（ASan+UBSan）编译 `nav_runtime.c nav_visual.c nav_view.c nav_test.c` 全部断言通过，新增用例覆盖 8 s 接管、30 s 失联自退、失步 STOP 退页、旧 sid STOP 不误关、在线无 UPDATE 时 60 s 息屏照旧。另在 `.state/fw-host-render`（不入库）用真实固件渲染代码 + mock `TNWidgets` 证明：收到合法 `TNR_SCENE2` 帧时固件能画出 296×148 全量地图（路网/高亮路线/比例尺/红绿灯等标记），只有未收到矢量帧时才回退成车载语义小路线图。

**未验证风险**：8 s 接管阈值对真实弱网/手机长时间不推 UPDATE 的在线导航是否过于激进，需要真机弱网验证；失联自退最坏约 60 s，若要求“手机退出后立即退页”，仍需手机侧发送 `TN_STOP`（本版把“永不自退”降级为“最多约 60 s 自退”）。

## 当前候选摘要（TAP3-2026-11D · 大地图）

| 项目 | 值 |
| --- | --- |
| 候选 | `TAP3-2026-11D` |
| ZIP 大小 | 8,893,742 字节 |
| ZIP SHA-256 | `5c3385d43926e763ce089d5e202f387fd1344bcf98cf4c04fc74f27787070110` |
| AP 大小 | 7,547,720 字节 |
| AP SHA-256 | `9722323cc741f50617aa445e6278d68d7e02967d08bfc1de7329d5c70d34a4b9` |
| AP MD5 | `ca81f55629a97661be086fb72450c252` |
| 模块大小 | 233,488 字节 |
| 模块 SHA-256 | `69110e0885573477fbd2ad5a59d5f2508a9cb01e402af8e285b0f5089c2cdf55` |
| 清单大小 | 2,700 字节 |
| 清单 SHA-256 | `b8897f5aac1b503533900f7864f20a2d512656e76ba83ba59a74580a2fc9a60d` |

`candidate-release/candidate-ota.json` 与上述值一致。旧手机缓存不会因为版本数字相同而自动变成新包；交付 IPA 时必须再次核对内嵌 ZIP 的完整 SHA-256。

## 重建、重钉与审计

原厂 1.0.5.12 ZIP SHA-256 必须为 `b7bfd3cc73528e3e9995ad227dc877c8334d43dc8051436e2d2ccff2ca0b4133`，原厂 AP SHA-256 必须为 `af701a6525fbf703854b3d63e757734546c20bdb5d50e246867dc6a0565713ae`。旧 1.0.5.5 基座只用于地址指纹对照，不能混作本包的刷写基座。

```sh
python3 port_audit.py
python3 build.py --stock /path/to/Strix-OS-1.0.5.12-original.zip \
  --llvm-bin /path/to/pinned/llvm/bin --out build/reproduced
python3 build.py --stock /path/to/Strix-OS-1.0.5.12-original.zip \
  --audit candidate-release/firmware.zip
# 修改 src/ 下模块源码后，必须重钉补丁表与全部摘要：
python3 build.py --stock /path/to/Strix-OS-1.0.5.12-original.zip \
  --llvm-bin /path/to/pinned/llvm/bin --out build/repin --repin \
  --code-name TAP3-2026-11X --display-name '...'
```

`address-map.json` 记录每项绑定及证据类型。显式 `--repin` 会在完整构建和审计成功后更新已有的源码摘要及补丁表；普通构建不会自行更新这些固定值。`python3 port_audit.py --generate` 会重新生成该表；生成后必须人工审查 `manual-masked-*` 项，不能把自动生成当成语义验收。脚本只使用 Python 标准库，不连接手机或眼镜。

本次已验证：200 项地址绑定通过、40 个补丁点通过、38/38 模块目标补丁重新编码并逐条核对到 11D 模块 ELF 符号地址、同一输入两次全新重建的 module/AP/ZIP 摘要逐字节一致；`nav_runtime` 协议测试与 `nav_view_test` 均通过，含 13 组分配失败、1000 次更新、地图到达即绘制、标签避让和地图内交通标记检查；真实渲染预览已人工查看。旧 TAP3（`05170b9b…`）、`TAP3-2026-11`（`f68e3edc…`）与 `TAP3-2026-11B`（`c874225f…`）均因摘要不匹配被 `build.py --audit` 拒绝。iOS Objective-C 测试、IPA 构建和眼镜运行分别验收，不由上述固件结果代替。

## 真机验收边界

手机上传进度、官方“安装成功”或版本号不变均不能证明新 AP 已运行。必须分别确认实际请求负载的覆盖范围、同一眼镜自然重启后的版本/空闲回读，以及镜片中的 Turbo IO 扩展菜单。任何一层缺失都只能记录为结果未知，不能宣称成功或自动重刷。

实验固件可能造成无法启动、失去 OTA 或数据丢失；原厂恢复不是救砖保证。普通用户请保留原厂固件。原厂资料见 [Strix OS 1.0.5.12 归档说明](../strix-1.0.5.12/stock/README.md)。
