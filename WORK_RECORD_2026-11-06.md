# 工作记录：导航限速常驻显示 + 红绿灯加粗（TAP3-2026-11H / ios107）（2026-11-06）

日期：2026-11-06 · 执行：Kimi Code（macOS 本地：固件重钉构建 + host 渲染 + 离线门禁 16 组）

> 起因：用户真机实拍（`docs/screenshots/` 未存，会话内 11-06 照片）——导航页**全程无限速显示**，
> 红绿灯标记"不太清晰"。照片可见 60km/h 车速、路网/路名/比例尺均正常，左侧无限速任何元素，
> 地图无相机/红绿灯标记。11G 记录遗留第 3 条"限速圈显示范围可继续按真机反馈调"即指此现象。

## 1. 根因（调查结论，先因后果）

1. **限速从未显示（主因）**：手机端从未接入高德 Navi SDK 9.6+ 的**路段限速回调**
   `driveManager:onUpdateNaviSpeedLimitSection:`（进入新路段即回调当前路段限速，无限速回 0）——
   这是"当前道路限速"的唯一实时数据源。现有实现只靠**电子眼（摄像头）**数据，且是
   **"最近相机通吃"单槽**：城市路口密集的闯红灯/监控相机一旦最近，带限速值的测速相机
   永远排不进单槽；叠加固件侧限速圈 ≤700m 门限 + `cameraSpeed>0` 才有数字，
   限速信息三重过滤后等于不存在。
2. **红绿灯不清晰（次因）**：红绿灯只有地图上一个 7×9px、1px 细框的小图标（灰度 180、≤700m）；
   协议 EXT2 逐盏通道（`lightsList`，最多 8 盏）手机端**从未填充**。

## 2. 修复内容

### 2.1 共享协议（两份拷贝同步：`official-addon/ios107-edition/` 与 `strix-1.0.5.12-tvp2/`）
- 新增场景尾巴 **EXT4 = 57 字节** = EXT3 + `u8 road_limit`（255=未上报，0=本段无限速，其余=km/h）。
- `valid/decode/encode` 三处同步；手机编码按"有 road_limit 发 EXT4，否则按旧规则降级 EXT3/EXT2/EXT"，
  旧固件收到的包字节级不变。
- 注：固件侧 `tn_encode` 本就不写扩展尾巴（仅供 nav_test 基础回环），保持原样。

### 2.2 手机端 ios107
- `NavigationUI.m`：
  - 新增 `roadSpeedLimit` 状态与 `onUpdateNaviSpeedLimitSection:` 回调（-1=未上报）；
    `applySceneExtensions` 每帧携带 `roadLimit`（TNV 全量替换语义，随帧存活）。
  - `updateCameraInfos:` 改造：测速类（`Speed` + `FlowSpeed` 流动测速）单独跟踪，
    **1km 内优先占槽**；超出让位其他相机。修复"测速相机永无出槽机会"。
  - 逐盏红绿灯：闯红灯相机距离排序后填 `lightsList`（≤8，EXT2）。
  - 诊断行追加"路段限速=%ld"，区分"高德没给数据"与"镜片没画"。
- `NativeNavigation.m`：`TNVScene` 解析 `roadLimit`（0…200 合法，0 合法=无限速）。
- `RoadMap.m`：HUD 标记自测帧加 `roadLimit=60`（用户可自测常驻徽章）；
  `NavigationDisplayHUD.inc` 自测说明同步。

### 2.3 固件 strix-1.0.5.12-tvp2（11G→11H）
- `nav_runtime.h/.c`：EXT4 解码 + 校验（>200 且≠255 拒帧）。
- `nav_visual.h/.c`：`road_limit` 传入 TNVisual。
- `nav_view.h/.c`：新增**常驻限速徽章**画布（30×20，置于车速右侧 (148,44)）：
  圆环+2× 数字（>99 时 1×）；`road_limit` 为 0/255 时清空隐藏；stale 变暗。
  地图内限速圈（相机触发、≤700m）保持原有语义不动。
- 红绿灯地图标记加粗：1px 细框 → 3px 粗框 + 3×3 灯点，整体 7×9 → 13×15，
  占位/避让半径 3→6（距离文字自动让位）。

### 2.4 超速警报（同日追加：用户问"测速点/超速提醒应该有吧"）
- 判定：车速（EXT3 `speed_kmh`）> 有效限速；有效限速优先取**路段限速**（EXT4
  `road_limit`），未上报时回落到占槽测速相机的限速值（`camera_kind=SPEED &&
  camera_limit>0`）——路段限速回调没覆盖的路段也能警报。两者皆无则不判。
- 表现：**限速徽章 1Hz 双相闪烁**——空心常显牌 ↔ 实心圆盘+镂空数字，一眼区分。
  在 `tn_view_map_tick`（33ms 常驻节拍）里就地重写徽章缓冲并重推同一指针，
  与矢量图双缓冲翻转无关（新增 `badge_shown` 记录 widget 实际挂载的帧）；
  整帧重绘后相位复位，恢复常速自动回到常显。
- 手机端零改动（车速/限速字段此前已有）；手机导航语音仍是静音设计
  （`isUseInternalTTS=NO`），本轮未加 TTS 播报——眼镜闪烁即超速提醒。

### 2.5 沿路电子眼全量钉在路网（同日追加：用户要求"像真导航一样固定在路网图"）
- 协议再增 **EXT5** = EXT4 + `u8 cam_count` + `cam[16]{u8 kind, u8 limit, u16 m}`
  （手机按距离排序发送沿路全部电子眼，最多 16 个；闯红灯相机不进列表——已由
  红绿灯 glyph 呈现，避免同点双标）。
- 固件 `map_markers` 重写：取消固定 700m 门槛，改为**画布门**——标记钉在沿路
  真实位置（`tnr_route_ahead` 按距离投影），投影落在地图可视范围外才不画；
  地图能看多远就能看到多远，随地图滚动自然出现/身后消失。单槽 `camera` 仅在
  无 camList 时兜底。逐类图标：测速=限速圈+数字、监控=小环+心点、区间=双环、
  其他=微环、红绿灯/事件维持原样；避让表扩容到 52 格并加越界守卫。
- HUD 标记自测帧同步带 camList（测速60@50m/监控@140m/区间80@260m）。

### 2.6 顺带修复（既有债务）
- `HostCompatibilityTests.m` 第 13 行陈旧期望：076ee87 把身份校验改为
  "LC_UUID∈钉死白名单（版本/构建号仅查表键）"后，该断言（钉死 UUID 不得匹配其他版本 info）
  与新语义矛盾、**host 组必红**。按新语义改写（同一钉死 UUID 对任意 info 均匹配），
  未匹配的版本/构建组合仍断言 `TIOHostExpectedUUID` 返回 nil。

## 3. 验证证据

- 固件单测（host clang 等价 `.state/fw-host-render/run_host_tests.sh`）：
  `nav_test` PASS（codec/竞态/50000 畸形包等）；`nav_view_test` PASS
  （14 分配失败注入、徽章 60 有墨 / 0 与 255 隐藏断言、1000 次更新）。
- ios107 离线回归门禁 **16 组全绿**（含 replay 组新增 EXT4 编码→校验回环、
  road_limit=201 拒帧、markerTestFrame road_limit=60 断言）。
  运行环境注意：SMB 项目盘不可执行二进制，测试在 `/tmp/ios107-run` 副本跑，
  `--firmware/--stock/--builder` 显式指向项目盘。
- host 渲染（真实 nav_view.c/nav_map.c）：`build/tests/tap3-nav-preview.png` 人工核对——
  左侧 "42km/h" 右侧圆环 60 常驻徽章清晰；地图限速圈 60、加粗红绿灯（60m/140m）、
  事故三角、拥堵虚线、路名/比例尺无重叠。
- 固件候选 **TAP3-2026-11H** 重钉构建 + 地址审计通过（patchSites 40、symbolBindings 173、
  externalBindings 27 与 11G 一致；APBytes 7539976→7540424，增量 448B = 徽章缓冲+绘制码）。
- ios107 dylib（CI 同款开关组合 + `TIO_OTA_CANDIDATE`=11H）：
  `build/image-rx-lab/TurboIOPrivateAddon.dylib`，sha256 `80bbac29…e5e5`。

## 4. 交付物（哈希钉死）

| 工件 | 标识 |
| --- | --- |
| 固件候选 | **TAP3-2026-11H**（1.0.5.12 基座，含限速徽章+超速警报+沿路电子眼最终重钉） |
| 11H 固件包 | 8,889,732 B，sha256 `cdff01b0…1625`；AP 7,541,512 B `c884f400…f105` |
| OTA 描述符 | `candidate-release/candidate-ota.json`（已更新，内嵌 11H） |
| dylib | sha256 `101b42a9…524b`（内嵌 11H 描述符） |
| host 预览 | `build/tests/tap3-nav-preview.png`（沿路电子眼全量+画布门人工核对） |

## 6. 交付前复查（2026-11-06 晚）

- **协议双拷贝**：`valid()` 与 `decode_scene()` 手机/固件逐字节一致；EXT5 偏移
  （e[56] 计数、e[57+4i] 三字段）两侧相同；`TN_SCENE_EXT5=122` 算术两侧相同。
- **固件链**：verification.json / candidate-ota.json / firmware.zip 实文件三方哈希一致；
  `build-inputs.json` 88 个源码钉全部匹配工作区（`@generated-animation` 为构建期
  生成桩，按设计免钉）；patchSites 40、symbolBindings 173/27 与 11G 完全相同——
  本轮纯模块内代码+数据，无新增桩点/导入；**注释级改动重钉后固件包字节级复现**
  （确定性构建正面证据）。
- **数组边界**：`mk[22]`（相机≤16 + 事件/灯让位守卫）、`taken[52]`（含 nt<48/50/51
  守卫）、投影画布门 ±10px 内全部绘制函数自带边界裁剪。
- **dylib 链**：内嵌描述符逐字节等于 candidate-ota.json（codeName/zip/ap 三键核验）。
- **测试**：固件 nav_test + nav_view_test PASS；ios107 离线门禁 16 组全绿（最终树）。

## 5. 待真机验收（用户）

1. iPhone 安装新 IPA（需走 NAS 签名链重签合并 IPA；本轮未重跑签名/安装——
   证书与 NAS 在上一轮的交互流程中）。
2. 眼镜 OTA 刷 11H（手机 IPA 内嵌描述符已指向 11H）。
3. 验收点：
   - 导航中车速右侧常驻限速圆环（进无限速路段应消失）；
   - **超速时限速徽章 1Hz 双相闪烁**（空心牌 ↔ 实心圆盘），回到限速内自动恢复；
   - **沿路电子眼钉在路网对应位置**：多个测速（限速圈+数字）/监控（小环）/区间（双环）
     沿路线排开，随地图滚动出现与消失，不再到 700m 内才突然出现；
   - 接近路口红绿灯图标明显加粗、可逐盏出现；
   - 手机"详细诊断"行应有"路段限速=xx"读数——若始终 -1，说明高德未回报该路段数据
     （徽章不显示属数据侧，非显示侧）；
   - 回归：HUD 标记测试（含徽章 60）、路网/环岛/入口/语音钩子、退出 ≤10s。
4. 兼容提醒：**新 IPA + 旧 11G 固件**时 EXT4 帧会被旧固件拒收（帧被拒，会话保留）——
   必须 IPA 与 11H 配套上机；若需灰度过渡，先刷 11H 再装 IPA。

## 7. 调查（非修复）：官方"AI 字幕与翻译/离线翻译"打开即报云端错误

**症状**：用户在官方 App 打开"实时字幕（离线翻译）"即提示云端错误，完全不可用。

**调查链**（证据均取自钉死哈希的宿主 IPA `docs/RayNeo_AI_1.0.10_258…`）：
- 发现页"AI 字幕与翻译"入口是 webview 引导页（`flutter_assets/assets/config/discover_page_config_baseline.json`），
  真功能为原生 caption 模块（`caption/glasses_caption_service.dart` 等 Dart 路径 + `icon_network_error.png` 错误 UI）。
- 中文 UI 文案不在 AOT 二进制内（`字幕/翻译/云端错误` 全包 0 命中），随远程配置下发。
- 翻译引擎为 **Timekettle SDK**（`TmkTranslationSDK.framework`，`verifyAuth()/offline_auth_enabled/token/license`），
  云端 `https://api-rayneo.timekettle.co`（**网络可达**，404 on root 属正常）；离线模式需先经云端鉴权+拉取模型清单
  （SDK 内残留开发默认值 `http://192.168.0.232:10001/tmk-models/current_release` 与裸 IP `:18080`）。
- 本构建为**测试环境构建**：引导页全部指向 `test.rayneo.cn`、`umeng-integration-test`、`dc-t.api.leiniao.com`；
  对照 dc-o/dc-t/xr-api-t/xr-api-p/file-ffalcon CDN **网络层全部可达**（xr-api-p 401=需鉴权，正常）。

**结论（高置信）**：报错是**服务端业务级失败**（鉴权/许可/配置被测试后端拒绝或接口已下线），
不是本地代码问题、不是网络连通性问题；与我们的注入无关（本扩展从不 hook NSURLSession/ASR/音频引擎，
官方功能跑的是与原版完全相同的代码路径，原版设备上应同样报错）。

**未定案**：具体是哪一支请求报错——需真机抓包（mitmproxy/控制台日志）确认 Timekettle 鉴权还是 RayNeo 配置接口。
**现成替代**：我方"本地翻译与字幕"（`local-translation/`，Apple 翻译/Hy-MT2 本地模型 + Parakeet 离线 ASR，
字幕走原厂纯显示通道）已在 ios107 构建编入：研究目录 → 随身应用 → 本地翻译与字幕，零云端依赖。

## 8. 交付执行（2026-11-06 晚）：打包 + 签名 + Wi-Fi 直装

- 打包器：`/Users/apple/build/pkg3/pack.mjs`（复刻 11-04 现场 pkg2 推导出的变换，
  固件钉 11H `cdff01b0…`；committed 的 package.mjs 门禁与"集成版 dylib + 11H + 自定义 bundle"
  组合不兼容，未改动仓库脚本，新打包器留在本地构建区）。
- dylib 按 app.aurora7070.potato6444 重建（`701685e7…`）；CFBundleVersion 264→265；
  描述文件/证书/设备同 11-04（证书 SHA1 从钥匙串运行时读取）。
- 产物：`/Users/apple/build/pkg3/TurboIO-signed.ipa`，sha256 `cf21c1c0…7a07`，
  codesign --verify --deep --strict 通过，内嵌 TurboWeReadCandidate.zip=11H。
- 安装：`devicectl device install app` Wi-Fi 直装成功（iPhone17 Pro Max，
  UDID 00008150-000E021C1E0B401C，bundle app.aurora7070.potato6444）。

**待用户**：App 内刷机入口把眼镜升到 11H → 验收清单见 §5.3（限速徽章/超速闪烁/
沿路电子眼/HUD 标记测试/详细诊断读数）。

## 9. 追加修复（真机反馈）：模拟导航无速度读数 + 模拟无路段限速

**现象**：11H 上机后实时导航速度正常；模拟导航无速度、无限速徽章；用户问骑行/步行速度。

**根因**：
- 高德 `startEmulatorNavi` 模拟器不下发有效的 `AMapNaviLocation.speed` → 车速读数恒 0/缺失（11G 即如此，非本轮回归）。
- `onUpdateNaviSpeedLimitSection:` 依赖真实路段匹配，模拟导航不下发 → 路段限速徽章无数据源。
- 骑行/步行：`walkManager/rideManager updateNaviLocation:` 本就桥接喂车速（速度正常显示）；但电子眼/路段限速回调为驾车 Delegate 专属，骑行步行天生没有测速圈/限速徽章。

**修复（手机端 only，固件不变无需重刷）**：
- `updateNaviInfo:`（1 Hz）模拟会话用剩余里程差分合成车速（dt 0.8–3s 窗口过滤）。
- 模拟导航且路段限速未上报时，用 1km 内测速相机限速顶 `roadLimit`（仅模拟，徽章/超速警报可验收）。
- 采样状态随 `clearSceneExtensionState` 复位。

**交付**：dylib `48164a8a…` → CFBundleVersion 266（`64c38245…`），devicectl 已装。

## 10. 追加修复 2：模拟驾车速度被模拟器零值覆盖（267）

266 上机实测：模拟驾车仍无速度。根因：高德模拟器**高频下发 `AMapNaviLocation.speed=0`**
（位置回调频率高于 1 Hz 的 naviInfo），旧采信条件 `speed>=0` 把 `updateNaviInfo` 差分合成的
车速反复清零。修法：位置回调仅在 `speed>0` 时采信；`speed==0` 仅真实导航接受（静止为真值），
模拟会话忽略零值由差分合成独占。骑行/步行/真实驾车不受影响（>0 路径不变）。
交付：dylib `c88b36b6…` → CFBundleVersion 267（`ff76870a…`），devicectl 已装。固件不变。

## 11. 真机定案：EXT5 帧车速/限速丢失（解码分支遗漏，269+重刷修复）

**症状链**：267 上机后模拟驾车仍无速度；诊断版 268（status 增加 dbgSpeed/dbgLimit/dbgCam +
诊断行"合成车速"）定位：手机合成正常（诊断行有值），上镜会话最后帧 `dbgSpeed=60 dbgCam=5
dbgSim=true`——数据到了会话层。骑行/步行模拟（无相机→EXT3）速度正常，驾车模拟（有相机
→EXT5）速度消失。

**根因**：`nav_runtime.c` `decode_scene()` 里 `speed_kmh` 只判 `EXT3||EXT4`、`road_limit`
只判 `EXT4`，**漏了 EXT5 分支**（手机/固件两份拷贝同错）。EXT5 尾巴包含 EXT3/EXT4 全部字段，
但解码时车速/限速保持默认值 65535/255 → 固件不渲染速度文本与限速徽章。 EXT5 帧本身被接受
（标记正常渲染），所以无拒帧痕迹。11G 无 EXT5 协议故无此症；11H 引入 camList 后驾车场景
（相机>0）必现，步行/骑行无相机走 EXT3 不受影响——与真机现象完全一致。
回归缺口：解码无字段级断言；编码有回环但 valid() 不校验 speed 一致性。

**修复**：两份 `nav_runtime.c` 解码条件补 `||n==base+TN_SCENE_EXT5`（speed 与 road_limit 两处）；
RoadMapTests 增加 EXT5 线格式字节级断言（e[53]=42/e[55]=60/e[56]=3 at base+32+36）。

**交付**：固件重钉 11H（zip 8,889,740 B `059a98e3…95f65`，AP `…` 见 verification.json），
离线门禁 16 组全绿（含新断言）；dylib `f8f63408…`；CFBundleVersion 269（`7944832e…`）
已 devicectl 安装。**需重刷眼镜到新版 11H**（本次固件代码变更，必刷）。

**用户验收（2026-11-06 晚）**：重刷新版 11H 后模拟驾车速度显示恢复（"搞定了"）。
本轮全部交付物闭环：固件 TAP3-2026-11H（`059a98e3…`）+ IPA CFBundleVersion 269
（`7944832e…`）+ 离线门禁 16 组全绿。
