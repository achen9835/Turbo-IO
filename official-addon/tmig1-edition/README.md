# TMIG1 · RayNeo AI iOS 1.0.6（218）插件适配

2026-10-14 · 实验性预发布，**不提供预签名/合并 IPA 或代签**。普通用户使用官方 App 与原厂固件。

**[TMIG1 实测原样固件与完整说明](../../firmware-research/strix-1.0.5.5/README.md)**

私用整合版已在 **iPhone 17 Pro Max / iOS 27.0.1 / 官方 App 1.0.6（218）/ Strix OS 1.0.5.5** 刷入、进入并由用户确认兼容。公开源码保留完整 UI、各协议、情境英语与严格 OTA，移除私人配置及微信读书网页正文适配，并在本机重新编译通过；**不把公开派生包描述为已重新安装、全量回归的私用原样 IPA**。固件 ZIP 则与实刷原样一致。

## 包含与不包含

- 首页、仪表盘编辑、应用广场、原生导航/音乐/阅读/番茄、Watch 手机桥接、诊断和自有模型/TTS 等集成源码；各第三方服务要用户自行配置。
- [情境英语](context-english-v1/README.md)：已有官方智记缓存、本机选段、模型授权、题库校验、TEL1 发送和回执、自动备题及复习记录；自动配置默认关闭。
- **Dots：开发中，尚未完成**。保留接口/UI 原型，但不包含实际 Mac/Server Bridge、ChatGPT 会话、认证、订阅或隧道配置，不能开箱即用。
- 公开微信读书提供书架/统计、小封面、TXT/EPUB；**无网页正文适配及 Cookie 入口**。私人账号和登录不随源码公开。
- 本机 TTS 不需要云 Key；移除了作者专属云 TTS endpoint。云端 TTS 需使用者自行扩展/配置，空 endpoint 不应发起请求。
- 本地翻译通过已公开的可选动态模块接入，模型不附带；Watch App 也按[独立文档](../../watch-remote/README.md)自行构建/签名，不凭手机入口推断手表已安装。
- 固件不含已回退的 TBL1 亮度补丁；亮度兼容入口不代表新增手动锁定能力已存在。

## 先构建扩展

需要 macOS、Xcode iPhoneOS SDK、Node.js，使用自己的签名配置。地图依赖沿用仓库固定 SDK 获取脚本与许可：

```sh
node official-addon/setup-amap.mjs --accept-sdk-terms
TIO_AMAP_ENABLED=1 TIO_AMAP_SDK_ROOT=/absolute/Turbo-IO/official-addon/build/amap-sdk \
TIO_OTA_FLASH_ENABLED=1 TIO_IMAGE_RX_LAB=1 TIO_IMAGE_RX_WIDE=1 \
TIO_DISPLAY_PHONE=1 TIO_DISPLAY_FLASH=1 \
bash official-addon/tmig1-edition/build.sh embedded com.rayneo.venus.pub
```

输出 `official-addon/tmig1-edition/build/image-rx-lab/TurboIOPrivateAddon.dylib`。这是与 TMIG1 固定匹配的 opt-in 构建；编译启用实验入口**不授予刷写权限**。不要与其他 Turbo IO dylib 同时加载。

## 用自己的宿主输入与签名打包

必须提供合法可用、未加密、thin arm64 的官方 **1.0.6（218）Runner.app**，以及自己的 profile/证书/设备。可从[原厂 1.0.6 去签名 IPA Release](https://github.com/Turbo1123/Turbo-IO/releases/tag/rayneo-ios-1.0.6-218)按[校验说明](../../official-apps/ios/1.0.6/README.md)解压取得输入；它没有 Turbo IO，也不是可直接安装的个人签名包。旧 1.0.5 输入不能换版本字符串硬套。

打包器核对宿主主程序 UUID、App.framework 精确 SHA-256、TMIG1 ZIP 哈希与扩展符号；精确允许原始签名保留版与上述未签名 Release 的两个固定 App.framework 哈希，其他输入仍拒绝。只修改两条升级查询字符串，保持 Dart 对象长度/头部/缓存哈希；没有放宽固件或 OTA 校验。**不要使用主目录旧 `official-addon/package.mjs` 打包本版。**

```sh
node official-addon/tmig1-edition/package.mjs \
  --app /absolute/Runner.app \
  --addon /absolute/Turbo-IO/official-addon/tmig1-edition/build/image-rx-lab/TurboIOPrivateAddon.dylib \
  --profile /absolute/your.mobileprovision \
  --identity YOUR_CERTIFICATE_SHA1 --device YOUR_DEVICE_ID \
  --bundle com.rayneo.venus.pub --product iPhone18,2 \
  --amap-sdk-root /absolute/Turbo-IO/official-addon/build/amap-sdk \
  --experimental-ota TMIG1 \
  --firmware /absolute/StrixOS-1.0.5.5-TurboIO-TMIG1-CANDIDATE-NOT-APPROVED.zip \
  --out /absolute/new-private-package
```

`--product` 是自己的实际机型，示例 iPhone18,2 对应本轮 17 Pro Max。脚本不合成官方推送、Apple 登录或 App Groups 权限；自签身份与官方身份不同，这些能力仍需自己的授权与验收。不要把签名结果/报告/描述文件推回 GitHub。原始输入与输出分离，脚本不安装、不刷写。

如果输入已有其他嵌入扩展或 Watch App，需要分别正确签名，不把历史私人签名复制当成通用安装方案。公开打包路径本轮做本机构建、宿主补丁与正反向门禁检查；没有把公开派生 IPA 安装到用户设备再次验证所有系统权限。

## 下载、刷写和收尾

完整一次操作见[固件教程](../../firmware-research/strix-1.0.5.5/README.md#开发者刷写步骤完整一次操作)：关闭自动更新 → 15 分钟只下载 → 官方软件就绪 → 全目录核对 → 两分钟内版本回读并授权 → 立即在官方页开始。升级期间不强退、不重启、不重复发送；完成且自然重启回首页后才重开手机 App 结束升级保护。

旧 Android GUARD-07 / iOS FOCUS-04 / TLC1 固定门禁不兼容本候选。本版并未提供支持导入任意原厂/第三方 ZIP 的通用刷机工具。停止/超时与未知结果必须区分，不删安全检查来强刷。

## 隐私与风险

不含用户 Cookie、模型 Key、API 密钥、Apple 开发者信息、签名材料、私人智记或会话。使用者自主配置和授权服务；涉及云生成时，选中的片段会发到其选定模型，需先审阅目的地与数据范围。Dots、网络服务、后台常驻及头控交互都不以入口存在代表验收。

实验包可能无法启动、失去连接/OTA 或损坏设备，不保证回滚和救砖。原厂版权不变，原创源码沿用仓库非商业许可证，第三方依赖仍遵守各自许可。
