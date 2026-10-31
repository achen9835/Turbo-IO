# Strix OS 1.0.5.12 · 官方原始固件归档

2026-10-31。**这是官方原厂版本，不含 Turbo IO 自定义改动。不是修改版，也不是 ZIP 重封装。**

**[下载原始 ZIP](Strix-OS-1.0.5.12-original.zip) · [SHA256SUMS](SHA256SUMS) · [1.0.5.5 上一基座](../README.md)**

- 来源：RayNeo AI iOS **1.0.10（258）** 官方升级接口的**真实固件更新响应**；官方 CDN 下载文件原样归档（官方 CDN 文件名 `thirdapk_efd5bb5a679f5fda659401add30434ca.zip`，文件名即官方 MD5）。
- 获取链路：官方直连包（不演回环补丁，App 直连官方升级 API）下载并解压后，经 App 内「导出官方解压目录」全量扫描导出；官方解压目录名 `Strix_OS_1.0.5.12`（随版本变）。
- 大小：**8,769,953 字节**。
- 服务端/原包 MD5：`efd5bb5a679f5fda659401add30434ca`（与官方文件名一致）。
- SHA-256：`b7bfd3cc73528e3e9995ad227dc877c8334d43dc8051436e2d2ccff2ca0b4133`。
- ZIP 共 16 项：15 个原厂负载及 `OtaFileInfo.json`；清单逐项 Md5/Size 全部核对通过（15/15），ZIP 成员与官方解压目录逐字节一致。
- 15 个负载：`nuttx_ap.bin`、`nuttx_apc1.bin`、`nuttx_audio.bin`、`nuttx_bth.bin`、`bt_controller.bin`、`cb_fw_venus.bin`、`images.bin`、`lotties.bin`、`rives.bin`、`fac_test_img.bin`、`ota_installer_progress.bin`、`smf.json`、`pil_algo_up_demo_nand.dll`、`pil_algo_vad_demo.dll`、`pil_algo_wakeup_dll_nand.dll`。

```sh
cd firmware-research/strix-1.0.5.12/stock
shasum -a 256 -c SHA256SUMS
```

## 用途

TAP3（1.0.5.12 基座 + 导航 HUD/刷机增量）的**唯一合法基座原料**；同时是离线翻译问题（官方 1.0.5.5 起的旧基座不带新翻译能力）的官方修复基线。二进制补丁式构建从本 ZIP 的原厂负载出发，仅改 AP，其余负载逐字节原样。

## 恢复原厂

优先使用雷鸟官方 App 的正常固件更新流程。本归档是 OTA 文件，不是整机闪存备份或救砖工具；非开发者不要刷，掉电、中断、误操作均可能损坏设备。

版权仍归雷鸟官方及原权利人，归档不把原厂固件重新许可为本仓库原创开源代码。不包含个人账号、Cookie、Key、设备记录或 Apple 签名材料。
