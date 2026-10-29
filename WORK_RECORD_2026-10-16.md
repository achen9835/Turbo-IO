# 工作记录：刷固件流程简化 + 固件/手机源码/协议全面审查

日期：2026-10-16 · 执行：Kimi Code · 计划文件：`~/.kimi-code/sessions/.../plans/kate-bishop-moon-girl-donna-troy.md`

> 本文件是会话工作记录，供人工复查。核对方式：`git status --short` + `git diff`（修改的 31 个文件）与下表逐条比对；新增 10 个文件见清单。复查后可删除本文件。

---

## 0. 任务

1. 检查并简化刷固件步骤（原流程繁琐）；
2. 检查固件源码、手机源码、刷写协议，做到万无一失。

批准的方案：双端完整改造（候选描述文件单一事实来源 + 手机端一键向导 + 一条命令离线预检 + 审查修复 + 文档精简 + 测试）。

## 1. 审查范围（本轮通读的源码）

| 区域 | 文件 |
| --- | --- |
| 固件 | `watch-remote/Firmware/remote.c` `remote.h` `remote_native.c` |
| iOS 插件桥 | `watch-remote/Addon/WatchRemoteAddon.m` `WatchGlobalBridge.m` `WatchRemoteGate.m`（+头文件） |
| Watch/共享 | `watch-remote/Watch/RemoteApp.swift` `Shared/RemoteCore.swift` `Phone/ProbeApp.swift` |
| iOS OTA 门禁 | `official-addon/focus-edition/ExperimentalOTA.m/.h` `ExperimentalOTAFlash.m` `ExperimentalOTAGuard.m` `ExperimentalOTAFeed.m` `ExperimentalOTAUI.m` `build.sh` |
| Android OTA | `android-addon/src/.../OtaPackage.java` `OtaSession.java` `OfficialOtaGate.java` `OfficialOtaBridge.java` `OfficialOtaPreparation.java` `OfficialOtaFeed.java` `OtaController.java` `OtaUI.java` `BoundedJson.java` + `tests/`（含 otaflow 桩）+ `addon_assets.py` + `package-official-ota-preparation.py` + `build.sh` |
| 打包 | `official-addon/package.mjs` `package.test.mjs` |
| 协议文档 | `watch-remote/GLOBAL_REMOTE.md` `FIRMWARE_RELEASE.md` `README.md` `firmware-audit.json` `SHA256SUMS` |
| 原厂基线 | `firmware-research/strix-1.0.4.12/stock/archive.py` |
| 构建脚本 | `watch-remote/stage-firmware.py` `stage-addon.py` `embed-companion.py` `project.yml` |
| 测试 | `watch-remote/tests/` 全部（run.sh、global.c、gate.m、bridge.m、host.m、main.swift、audit_firmware.py、test_embed.py） |

## 2. 发现的问题与处理

| # | 位置 | 问题 | 处理 |
| --- | --- | --- | --- |
| F1 | `watch-remote/Firmware/remote_native.c:36` | `control()` 内 `if(j==511)return NULL;` 为不可达死代码，且若第 512 个 timer 非本模块会错误地拒绝创建控制器（遥控整体失效） | 删除该分支；`-m32 -fsyntax-only -Wall -Wextra` 验证通过 |
| P1 | iOS `ExperimentalOTA.m`/`ExperimentalOTAFlash.m:76`/`ExperimentalOTAUI.m` | TFP1 常量硬编码 4 处（ZIP 大小/SHA、15 项 PayloadPins、`n==9300112`、确认字 "TFP1"） | 全部改从候选描述读取 |
| P2 | iOS 流程 | 导入/只下载/核对目录/授权 4 个分散动作 + 官方页 2 步，120s 证据 TTL 迫使用户来回跳 | 新增「★ 核对官方目录并授权一次试刷」一键动作（`checkDirectoryThenAuthorize` + 复用 `promptAuthorize`） |
| P3 | `watch-remote/Addon/WatchGlobalBridge.m consume:` | 会话不符且非 BLOCKED 的回执被静默吞掉，pending 挂到 2s 超时才提示 | 改为立即 `finish blocked`（仍 fail-closed），`tests/bridge.m` 新增 foreign-session 立即收尾断言 |
| A1 | Android `OtaSession.authorize` vs `OfficialOtaGate.arm` | 两套 OTA 实现确认字不一致（`"TAP1"` vs `"TAP1-TEST-01"`） | 统一读 `candidate().confirmToken`（值为 `TAP1-TEST-01`）；旧 OTA-02 路径保留不删 |
| A2 | `android-addon/.../OtaPackage.java` | ZIP/AP 大小、SHA、pins 15 行硬编码 | 新增 `OtaCandidate.java`，全部改从描述读取 |
| A3 | `OfficialOtaBridge.show()` | 4 节 15 步；收尾两个按钮分散，曾致用户未释放保护、官方功能被拦 | 重排为 ①开只下载源 ②一键授权（自动目录核对+预检轮询 `armWhenReady`） ③完成收尾（`finishStep1`→`waitFreshThenConfirm` 两步确认合一）；预检自动执行，手动「只读预检」按钮移除 |
| W1 | `watch-remote/stage-firmware.py:10` | `read_text()`/`write_text()` 未指定编码，Windows(GBK) 下崩溃 | 补 `encoding='utf-8'` |
| W2 | `watch-remote/stage-firmware.py:27-30` | `changed` 用反斜杠路径与字面量断言，Windows 下必失败 | 改 `as_posix()`，JSON 写入也加 utf-8 |
| C1 | TAP1 清单校验技巧 | 还原 AP 行后 canonical SHA 须等于原厂清单（`OtaPackage.verify:41-44`）；TGR1 是诚实清单 | 描述文件增加可选 `manifestRestore{apSize,apMd5,canonicalSHA256}` 字段承载该技巧 |
| — | `OfficialOtaBridge` 等 | 描述缺失时的崩溃路径（NPE/异常穿透到 UI lambda） | init 先 hold 描述、失败即不初始化门禁（allowQueue/allowFile 天然 fail-closed）；status()/按钮加守卫 |

**审查后确认无需改动的部分**：协议帧格式与状态机（两端 type 1-7/9/11 语义一致、varint 限定、slice 预算 51200B/<2000 片/64MB、AP 全覆盖才放行 type 9、journal 先落盘再放行 Mode 2）；`GLOBAL_REMOTE.md` 未动；`tests/audit_firmware.py` 保留可用；`package.mjs` 的 TNV1/TMU1 固定值保留（不在本次候选范围）。

**关于"翻页翻不了"**：静态审查无法闭环根因。嫌疑链：`allowed()` 正向名单/`nav_connection(0x80)`/`nav_folded()`、首次仅唤醒（结果码 1）、wheel 方向字节逐页约定。用现有结果码（0/1/2/7）即可真机定位，协议本身未改。

## 3. 新增文件（10）

| 文件 | 说明 |
| --- | --- |
| `watch-remote/flash_check.py` | 离线预检一条命令：`load_candidate`（结构校验，fail-closed）+ `check`（zip 大小/SHA → 成员集合 → 逐 pins → 清单 JSON/Size/Md5 → AP 预算 → 清单 SHA → 与原厂基线逐字节及 Burn 字段比对）+ CLI（exit 0=GO/1=NO-GO/2=描述无效） |
| `watch-remote/tests/test_flash_check.py` | 11 个用例（正例、zip 篡改、成员篡改、多余成员、清单 MD5 错、AP 超预算、stock 非 AP 改动、stock 烧录字段改动、stock AP 基线不符、描述结构拒绝、CLI 退出码） |
| `watch-remote/candidates/tgr1-global-01.json` | TGR1 描述：zip 9322287/SHA `79e5…`、AP 9593544/SHA `4569…`/MD5 `7959…`、15 pins、token `TGR1`（pins 取自 `firmware-audit.json`） |
| `android-addon/assets/otacandidate.json` | TAP1 描述：zip 9320672/SHA `5ef2…`、AP 9590856/SHA `65e0…`、`manifestRestore`（apSize 9466560/apMd5 `9156…`/canonicalSHA `1619…`）、token `TAP1-TEST-01`（pins 取自原 `OtaPackage.PINS`） |
| `official-addon/focus-edition/candidates/tfp1-focus-04.json` | TFP1 描述：zip 9300112/SHA `ad50…`、AP 9558216/SHA `40b0…`/MD5 `2d5c…`、token `TFP1`（pins 取自原 `PayloadPins()`） |
| `official-addon/focus-edition/gen_otacandidate.py` | 构建期把候选 JSON 生成为 `build/OTACandidate.gen.m`（C 字节数组）；结构校验不过即中止构建 |
| `android-addon/src/com/turboio/addon/OtaCandidate.java` | 描述解析/持有/校验（纯 Java 复用 `BoundedJson`）；`DEFAULT` 未设置时 `require()` 抛异常=fail-closed |
| `android-addon/tests/OtaTestSupport.java` | `holdCandidate()`：测试从 `assets/otacandidate.json` 装载描述 |
| `android-addon/tests/OfficialOtaCandidateTest.java` | 19 项契约测试（字段值、fail-closed、4 种描述篡改拒绝） |
| `android-addon/tests/otaflow/AssetManager.java` | JVM 桩（配合 `Context.getAssets()` 桩，使 `OtaController` 在纯 JVM 可编译） |

## 4. 修改文件（31）

**Android（src）**
- `OfficialOtaBridge.java`（重写，215 行）：init 先 `OtaCandidate.hold`（失败则不初始化=fail-closed）；新增 `loadCandidateAsset`；`status()` 未初始化守卫；一键 `authorize`（目录冻结→发只读 1/2/11→`armWhenReady` 250ms 轮询≤12s，全绿才 arm）；收尾向导 `finishStep1`/`waitFreshThenConfirm`；按钮重排为 ①②③；字符串全部取候选字段。
- `OfficialOtaGate.java`：6 处 `OtaPackage.VERSION/ZIP_SIZE/AP_SIZE` → `candidate()`；`arm` token → `confirmToken`。
- `OtaSession.java`：版本/大小/AP 常量 → `candidate()`；`authorize` token → `confirmToken`。
- `OtaPackage.java`：删除全部常量与 `PINS`；`verify`/`freezeDirectory`/`size`/`slice`/`manifest` 改读候选；修正本人重写时引入的笔误 `java.nio.file.channels`→`java.nio.channels`。
- `OtaController.java`（legacy）：新增 `candidateMissing` 标志与 `readCandidateAsset`；`status/importPackage/prepare/authorize` 守卫；常量 → `candidate()`。
- `OfficialOtaPreparation.java`：init 持描述失败即拒；`status` 候选名兜底；选择 ZIP 按钮守卫。
- `OtaUI.java`：导入/授权按钮守卫 + 确认字 hint 动态化。

**Android（tests/build/资产）**
- `build.sh`：候选测试先行编译+运行；3 处 OTA 编译行加入 `OtaCandidate.java`。
- `addon_assets.py`：允许清单加入 `assets/turboio/otacandidate.json`。
- `OtaTest.java`/`OfficialOtaGateTest.java`/`OfficialOtaFeedTest.java`/`OfficialOtaDirectoryTest.java`/`otaflow/OtaControllerTest.java`/`otaflow/OtaInstallGuardTest.java`：main 首行 `holdCandidate()`；常量引用 → `candidate()`；`"TAP1"` → `confirmToken`。
- `otaflow/Context.java`：+`getAssets()` 桩。

**iOS**
- `ExperimentalOTA.h/.m`（重写）：内嵌描述 extern；`TIOOTACandidate()` 一次性解析+结构校验（schema/hex64/唯一名/含 AP 与清单），无效返回 nil；`TIOCheckExperimentalOTA`/`Read`/`Import`、`PayloadPins`、`TIOCheckExperimentalOTADirectory`、`TIOCopyExperimentalOTAPayloads` 全部候选驱动；任何入口候选无效即拒绝。
- `ExperimentalOTAFlash.m`：type3 `OtaSize`、type5 `OtaVersion`、版本回读判定三处 → 候选字段。
- `ExperimentalOTAUI.m`：标题/说明/AP MD5/确认字候选化；新增第 6 行一键授权（`numberOfRows` 5→6）；`promptAuthorize` 抽取复用。
- `build.sh`：`gen_otacandidate.py` 钩子（`TIO_OTA_CANDIDATE` 可覆盖，默认 tfp1）+ `build/OTACandidate.gen.m` 进编译列表；stage-addon 锚点 `ExperimentalOTA.m` 唯一性验证保持。
- `package.mjs`：新增 `tfp1Candidate()` 读描述；`validateResearchPair` 的 TFP1 身份校验参数化（TNV1/TMU1 不动）。

**watch-remote**
- `Firmware/remote_native.c`：F1 死代码删除（唯一固件改动）。
- `Addon/WatchGlobalBridge.m`：P3 立即收尾。
- `tests/bridge.m`：+foreign session 断言。
- `stage-firmware.py`：W1/W2 两处 Windows 修复。
- `FIRMWARE_RELEASE.md`：刷写兼容条件 → 5 步清单 + `flash_check.py` 用法。
- `README.md`：§4 增加一条命令预检与"换候选只加描述 JSON"说明。

**Android 文档**
- `docs/INSTALL_AND_FLASH.md`：4 节 15 步 → 5 步；收尾两步合一；故障表保留。

## 5. 验证记录（本机 Windows，全部通过）

| 命令 | 结果 |
| --- | --- |
| `python -m unittest discover -s watch-remote/tests -p 'test_*.py'` | 15 项 OK |
| `gcc -std=c11 -Wall -Wextra -Werror -Wno-misleading-indentation remote.c global.c` + 运行 | PASS（carrier/CRC/会话/过期/重放/限频/回绕/close/blocked） |
| `gcc -fsyntax-only -m32 -Wall -Wextra remote_native.c`（staging 树） | 干净通过 |
| `javac/java` 候选契约测试 | 19 项通过 |
| `javac/java` OtaRecoveryGuardTest | 22 项通过 |
| `javac/java` OfficialOtaPreflightPollTest | 132 项通过 |
| `javac` OtaTest/OfficialOtaGateTest/OfficialOtaFeedTest/OfficialOtaDirectoryTest/otaflow（OtaController+桩） | 编译全部通过（运行依赖真机固件 zip，本机无此产物） |
| `node tests/OtaHooksTest.mjs` | 14 断言通过 |
| `node package.test.mjs` | 6 通过 0 失败 |
| `stage-addon.py` 干跑 | 通过，changed 集合与断言一致 |
| `stage-firmware.py` 干跑（修复后） | 通过，仅 2 个预期文件变化 |
| `flash_check.py` CLI 烟测（缺失 zip/篡改场景） | exit 码与 NO-GO 输出正确 |
| 三份描述 `flash_check.load_candidate` 校验 | 结构全部有效 |

## 6. 未覆盖（需在 macOS/真机补验）

1. `watch-remote/tests/run.sh`（Swift 核心 47 项 + bridge/gate ObjC + ASan/UBSan）——本机无 clang/xcrun；
2. `xcodegen`/`xcodebuild` 与 `focus-edition/build.sh` 真机构建——`OTACandidate.gen.m` 嵌入路径未经编译器确认；
3. Android `d8`/APK 组装与真机刷写——`OfficialOtaBridge/Preparation/OtaUI` 为 Android-only，已逐行静态复查但未编译；
4. 依赖真机固件 zip 的 OTA JVM 测试（OtaTest 等 5 个）仅编译验证；
5. 真机逐页输入验收（含"翻页翻不了"闭环）。

## 7. 红线确认（未触碰）

- 未修改官方 App/Dart 可执行逻辑；传输仍走官方 Mode 2；插件只核对字节；
- 未自动点「开始安装」；单次授权 + 确认字 + 人工收尾确认全部保留；
- 未绕过任何哈希/冻结校验；描述文件缺失即 fail-closed（Android 拒初始化、iOS 构建失败、Python 拒绝运行）；
- TGR1 仍标记 CANDIDATE-NOT-APPROVED；`GLOBAL_REMOTE.md` 协议文档未改。
