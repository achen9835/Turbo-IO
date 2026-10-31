# TAP3 · Strix OS 1.0.5.12 地址修正版 · 2026-11B 导航会话自愈

2026-11-01 · 非官方、非商业、高风险实验固件。**本修正版目前只完成离线重建、审计与 host 渲染验证，尚未完成真机运行验收。**

旧 TAP3（ZIP SHA-256 `05170b9b4eed38edbf562affaeab21f248394a44702d812440226d5e27a524eb`）直接沿用了大量 1.0.5.5 地址，不能视为完成了 1.0.5.12 移植。**旧摘要已撤销，不要继续刷入，也不要用“文件哈希一致”推断旧包可以运行。**

上一版 `TAP3-2026-11`（ZIP SHA-256 `f68e3edc6d26405ecc89af057813200d44661122f88bc6f66c779c02e2879f9e`，AP `189ce652…`）只完成地址迁移，没有导航会话自愈/失联自退；真机反馈的“镜片冻结在旧帧、退出手机导航后镜片不自退”即出自它。**该包已被 11B 取代，不要继续刷入。**

## 本版修复

- 以精确 1.0.5.12 原厂 AP 为基座，重新核对 40 个补丁点、173 个链接符号和 27 个额外函数/对象/字面量绑定。
- 原厂返回地址由新补丁点机械推导；普通函数用唯一字节指纹、分支重定位指纹和函数簇交叉定位；四个镜像外 C 运行库地址由新 AP 中仍存在的固定指针复核。
- 修正菜单、显示、导航、头部监控、线程、文件和 JSON 等模块使用的旧地址；派生 RAM 地址保留已验证的对象内偏移。
- `port_audit.py` 同时检查 `link.ld` 与 C/汇编源码，旧常量残留会阻止构建。`build.py` 另外要求补丁跳转落在本次模块范围内。
- 仅 AP 内容改变，其余 14 个负载与 1.0.5.12 原厂包逐字节一致；完整 OTA 仍可能写其他分区，不等于只写 AP。

## 2026-11B 导航会话修复（相对 2026-11）

真机反馈：手机一端出现一次瞬态 `TN_UI_FAILED`/`TN_BUSY` 后，固件仍保持旧会话 active，之后新的 `TN_START` 全部被 `TN_BUSY` 拒绝，镜片永久冻结在旧帧；手机退出导航后镜片停在“导航数据已过期”；失联后页面永不自退。本版在 `src/navigation-runtime-v1/nav_runtime.c` 增加三处自愈（wire 格式、60 s 息屏、60 s“导航数据已过期”文案与 `TN_PACKET_MAX` 等既有协议语义均未改动）：

- **陈旧活跃会话可被新 START 接管**：当 `r->active` 且（距最后一次完整 `TN_UPDATE` ≥ `TN_TAKEOVER_MS`=8 s，或链路已静默 ≥ `TN_LINK_MS`=30 s / `tn_disconnect` 已把 `connected` 置 false）且新 `TN_START` 的 `sid` 更大时，先 `tn_local_exit` 释放旧页面，再按原有 START 流程过 `available`/`enter`。仍然在线的会话照旧返回 `TN_BUSY`，只有更大的 sid 才能接管。
- **失联自退**：`tn_tick` 中 `active && !connected` 连续 ≥ `TN_GONE_EXIT_MS`=30 s 时 `tn_local_exit` 关闭导航页并释放常亮；配合 `TN_LINK_MS` 相当于最后一次真实链路后约 60 s 内必退。30 s 内恢复的短暂掉线不会误退，在线但无 UPDATE 的 60 s 息屏/过期语义保持原样。
- **失步 STOP 退页**：`TN_STOP` 且 `sid` 比固件当前 `sid` 更大（手机会话已换代）时直接关页并回 `TN_OK`；更小 sid 的迟到重放仍回 `TN_NO_SESSION`，不会误关新会话。envelope/CRC/paired 校验保持不变。

host 证据：gcc 13.3（ASan+UBSan）编译 `nav_runtime.c nav_visual.c nav_view.c nav_test.c` 全部断言通过，新增用例覆盖 8 s 接管、30 s 失联自退、失步 STOP 退页、旧 sid STOP 不误关、在线无 UPDATE 时 60 s 息屏照旧。另在 `.state/fw-host-render`（不入库）用真实固件渲染代码 + mock `TNWidgets` 证明：收到合法 `TNR_SCENE2` 帧时固件能画出 296×148 全量地图（路网/高亮路线/比例尺/红绿灯等标记），只有未收到矢量帧时才回退成车载语义小路线图。

**未验证风险**：8 s 接管阈值对真实弱网/手机长时间不推 UPDATE 的在线导航是否过于激进，需要真机弱网验证；失联自退最坏约 60 s，若要求“手机退出后立即退页”，仍需手机侧发送 `TN_STOP`（本版把“永不自退”降级为“最多约 60 s 自退”）。

## 当前候选摘要

| 项目 | 值 |
| --- | --- |
| 候选 | `TAP3-2026-11B` |
| ZIP 大小 | 8,893,758 字节 |
| ZIP SHA-256 | `c874225fab7b3722b43d5340203233fbdcffef6a8620acf64304b6eaabc5abec` |
| AP 大小 | 7,547,720 字节 |
| AP SHA-256 | `b0ac2fcf82ca35dc8889987ccd1946b5582e6d2651218e07a739129422e5376e` |
| AP MD5 | `e0ce14d73d9711eaceea36817f052297` |
| 模块大小 | 233,488 字节 |
| 模块 SHA-256 | `5418b8f6d144cd14f5bb095d4f971739d099e18588c7b01ee796e7af8d0b45f7` |
| 清单大小 | 2,700 字节 |
| 清单 SHA-256 | `f3847b6682f678b654ab521a5bcd32634d17b79347684b8be4f5271dacde81f7` |

`candidate-release/candidate-ota.json` 与上述值一致。旧手机缓存不会因为版本数字相同而自动变成新包；交付 IPA 时必须再次核对内嵌 ZIP 的完整 SHA-256。

## 重建与审计

原厂 1.0.5.12 ZIP SHA-256 必须为 `b7bfd3cc73528e3e9995ad227dc877c8334d43dc8051436e2d2ccff2ca0b4133`，原厂 AP SHA-256 必须为 `af701a6525fbf703854b3d63e757734546c20bdb5d50e246867dc6a0565713ae`。旧 1.0.5.5 基座只用于地址指纹对照，不能混作本包的刷写基座。

```sh
python3 port_audit.py
python3 build.py --stock /path/to/Strix-OS-1.0.5.12-original.zip \
  --llvm-bin /path/to/pinned/llvm/bin --out build/reproduced
python3 build.py --stock /path/to/Strix-OS-1.0.5.12-original.zip \
  --audit candidate-release/firmware.zip
```

`address-map.json` 记录每项绑定及证据类型。`python3 port_audit.py --generate` 会重新生成该表；生成后必须人工审查 `manual-masked-*` 项，不能把自动生成当成语义验收。脚本只使用 Python 标准库，不连接手机或眼镜。

本次已验证：200 项地址绑定通过、40 个补丁点通过、同一输入两次全新重建的 module/AP/ZIP 摘要逐字节一致（`.state/fw-11B-build1` 与 `.state/fw-11B-build2`）、旧 TAP3（`05170b9b…`）与上一版 `TAP3-2026-11`（`f68e3edc…`）均因摘要不匹配被 `build.py --audit` 拒绝。iOS Objective-C 测试、IPA 构建和眼镜运行分别验收，不由上述固件结果代替。

## 真机验收边界

手机上传进度、官方“安装成功”或版本号不变均不能证明新 AP 已运行。必须分别确认实际请求负载的覆盖范围、同一眼镜自然重启后的版本/空闲回读，以及镜片中的 Turbo IO 扩展菜单。任何一层缺失都只能记录为结果未知，不能宣称成功或自动重刷。

实验固件可能造成无法启动、失去 OTA 或数据丢失；原厂恢复不是救砖保证。普通用户请保留原厂固件。原厂资料见 [Strix OS 1.0.5.12 归档说明](../strix-1.0.5.12/stock/README.md)。
