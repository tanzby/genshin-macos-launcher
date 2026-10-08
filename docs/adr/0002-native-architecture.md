# 原生 App 的目标架构：七个 SwiftPM target、单向依赖、幂等重跑

原生 Swift 版（地图 #13，票 #22）按下面的模块和缝划分。这是后续骨架（#25）和各模块实现票的前提。前提条件已由其他票定下：macOS 26+、仅 Apple Silicon、Swift 6 strict concurrency、`@Observable`、SwiftPM + XcodeGen、Sophon 用 Swift 重写、只允许 Wine / x86_64 helper / 白名单系统工具作为外部进程（#27）、不兼容 TS 数据（ADR 0001）。

> **修订（地图 #1、票 #2，依据旧仓库 [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) 的决定）：** 删除 ReShade；DXMT 在安装 Wine 时一次装好，运行时不再注入和还原。下文相应段落已改。

## Target 与依赖

仓库根目录的 `Package.swift` 一个包放所有库 target，每个库一个测试 target。XcodeGen 的 `project.yml` 只定义 App 和两个 x86_64 helper，App 依赖这个本地包。

```
YaaglApp (XcodeGen app)   SwiftUI 视图、Sparkle、系统通知、组合根
 ├─> Launcher             LauncherModel / SettingsModel、PrimaryAction.derive、JobCoordinator；定义 GameClient 协议
 │    ├─> Platform        DataDirectory、HostsBlocklist(+AdminShell)、Downloader、日志；定义 ProcessRunning / AdminPrivilege 端口
 │    └─> Wine            WineRuntime(actor)、GameSession(执行 LaunchRecipe、Launch Mutations + journal)、GameHost 准备；游戏无关
 └─> GenshinCN            原神 CN 常量、LaunchRecipe、GenshinCNClient: GameClient（组合 Sophon + Wine + Platform）
      └─> Sophon          SophonClient、已装版本检测；依赖 swift-protobuf、libzstd、CHDiffPatch(C target)
x86_64 helper（XcodeGen target，放进 Contents/Helpers/）: YaaglWineShim、YaaglGameHost，源码在 Helpers/
```

- `Wine → Platform`，`GenshinCN → {Launcher, Sophon, Wine, Platform}`（`GenshinCN` 要实现 `Launcher` 里定义的 `GameClient`，并使用其中的 `LaunchOptions`、`JobProgress` 等值类型；`Launcher` 不依赖 `GenshinCN`，两者只在 `YaaglApp` 的组合根相遇，所以无环），`Launcher → {Platform, Wine}`。`Sophon` 不依赖 `Platform`，只用 URLSession 和文件系统。
- 不设 `Core`（会变成杂物堆）、`Patch`（见术语）、`Updater`（Sparkle 的 `SPUStandardUpdaterController` 本身就是深模块，在 `YaaglApp` 里直接用，appcast 和公钥写在 Info.plist）。
- `Launcher` 与 `YaaglApp` 分开，是因为 App target 无法 `swift test`；业务编排和状态机必须能脱离 UI 测试。
- 游戏无关的东西（数据目录、hosts、Wine 运行时、启动会话的执行）归 `Platform` / `Wine`，由 `Launcher` 直接使用；游戏相关的东西（端点、game_id、可执行文件名、`removed` 列表、hosts 域名、`HoYoKProtect.sys`、`-is_cloud` 参数、HDR 注册表键）归 `GenshinCN`。
- **LaunchRecipe**：`GenshinCN` 把设置快照（`LaunchOptions`）翻译成一个值类型 `LaunchRecipe`：注册表项、`config.bat` 内容、环境变量表、要改动的文件列表、要复制进 prefix 的资源。`Wine.GameSession` 只执行它，因此 `Wine` 完全游戏无关。`.reg`、`.bat`、环境变量表都是纯函数的产物。

## GameClient

`GameClient` 协议由 `Launcher` 定义，`GenshinCNClient` 是生产实现，`FakeGameClient` 是测试实现。两个 adapter，所以这条缝是真的：`Launcher` 的状态机、暂停与继续、错误重试都用 Fake 测试，不拉起 Sophon 或 Wine。接口保持很薄：

```swift
protocol GameClient: Sendable {
  func status() async throws -> GameStatus                       // 本地版本、远端版本、可更新、可预下载
  func run(_ job: GameJob) -> AsyncThrowingStream<JobProgress, Error>   // install / update / preDownload / repair
  func launch(_ options: LaunchOptions) async throws -> LaunchOutcome
  func backgroundImage() async -> BackgroundImage                // 失败不致命，返回内置默认图
}
```

- 错误分类：`GameClientError` 分为网络、磁盘空间不足、校验失败、已取消、需要重装 Wine。`Launcher` 据此决定重试、提示或引导。
- `LaunchOutcome`：正常退出、非零退出（带退出码和日志路径）、启动失败。

保留这个协议是维护者的有意预留（现在只有原神 CN 一个实现）。第二个游戏出现时，以此为起点。

## 状态与并发

- 领域库（`Sophon`、`Wine`、`Platform`、`GenshinCN`）不 import Observation / SwiftUI。共享可变状态放 actor，对外只给 async 函数和 `AsyncStream`。
- `Launcher` 里一个 `@MainActor @Observable LauncherModel` 是主窗口的唯一事实来源，进程内只有一份，在组合根创建并通过 `.environment` 注入。主按钮状态是纯函数 `PrimaryAction.derive(snapshot)`，单独测试。
- 设置是另一个 `@MainActor @Observable SettingsModel`，类型化属性、`didSet` 写入。领域库不读 `UserDefaults`：`Launcher` 启动游戏时把设置快照成值类型 `LaunchOptions` 传入。
- **作业并发（`JobCoordinator`）**：独占作业同时只有一个（Wine 准备、install、update、repair、launch）。预下载可以与启动、运行中重叠（#21 已定：预下载中主按钮仍是「开始游戏」；预下载只写临时目录，不碰游戏文件）。预下载与 install、update、repair 共用同一个游戏目录里的临时目录，所以它们互斥：开始其中任何一个，都先取消预下载并等它停稳（update 会复用已缓存的内容）。退出 App 时有进行中的作业，取消并保存「未完成作业」。游戏运行中退出启动器，先确认，确认后走 shutdown。

## 暂停、继续与进度

- **暂停 = 取消 Task，继续 = 用同样参数重跑同一个操作。** 每个 Sophon 操作幂等。断点就是磁盘上已有的东西：完整 chunk 缓存、已校验的文件、已下完的 ldiff。不维护 chunk 级进度日志，继续时开头有一次磁盘扫描，是接受的代价。唯一持久化的是「有一个未完成作业（种类 + 目标版本）」，存在 `<game>/.yaagl-tmp/job.json`，重启后主按钮据此显示「继续」。
- **取消必须等停稳。** `JobCoordinator` 持有作业的 Task：暂停是 cancel 之后 `await task.value`，作业真正停下后才允许重跑，等待期间 UI 显示「正在暂停…」。`AsyncThrowingStream` 用 `onTermination` 取消内部 Task。zstd 解压、MD5、HDiffPatch 是阻塞的 C 调用，不占协作线程池，放在专用队列执行；在文件边界和 HPatch 输入流的读回调处检查取消（读回调能否作为中断点，由 Sophon 实现票验证）。
- **「已完成」的判据**：续传时，目标文件大小一致即跳过（与 TS 一致）；整文件 MD5 只在 `repair(reliable)` 做。`config.ini` 的版本号在下完并校验之后才写。
- **安装的前置条件**：目录为空，或只含 `.yaagl-tmp`（带 `job.json`）和中断安装留下的半成品。TS 的「必须为空」与幂等重跑冲突，因此放宽。
- **Wine 准备不是持久化的 Pending Job。** 它发生在游戏目录存在之前，状态由 `<data>/wine/` 的版本戳推导：版本戳缺失或与固定版本不一致，就重新准备（下载走 `Downloader` 的 `resumeData`）。只有游戏作业（install、update、preDownload、repair）写 `job.json`。
- **长作业与睡眠**：下载、更新、修复期间持有 `ProcessInfo.beginActivity`，避免 App Nap 和空闲睡眠打断。
- **进度**：`Sophon` 对外只暴露收窄枚举 `SophonProgress`（`preparing`、`downloading(done,total)`、`verifying(done,total)`、`patching(done,total)`、`finalizing`）。操作形状是 `SophonClient.run(_:in:) -> AsyncThrowingStream<SophonProgress, Error>`，取消语义见下。生产端限流，每秒最多 4 条。速度和剩余时间由 `Launcher` 用滑动窗口计算，`Sophon` 不算。`Platform` 的下载（Wine 与 DXMT）有自己的进度类型，`Launcher` 把它们和 `SophonProgress` 一起映射成统一的 `JobProgress`。
- **Sophon 接口**：`onlineInfo() async throws -> OnlineInfo`（最新版本、安装大小、可增量更新的旧版本、`preDownload: 目标版本?`，分支为 null 是 `nil`，不是异常）；已装版本检测（`globalgamemanagers` 正则与 `config.ini` 取较小值）也在 `Sophon`，因为 `config.ini` 由它写。
- **临时目录**：`<game>/.yaagl-tmp`（chunk 缓存、ldiff、组装中文件、`job.json`）。放在游戏目录内，是因为游戏目录可能在外置盘，只有同卷才能原子 rename 移入。TS 的位置也是游戏目录内（`.tmp`、`ldiff`），这里换新名字，并在 Sophon 首次运行时删掉遗留的 `<game>/.tmp` 和 `<game>/ldiff`，但只在该目录里存在 `config.ini` 或 `YuanShen.exe`（即确认是游戏目录）时才删。文件名用完整相对路径，修掉 TS 里按 basename 命名导致撞名的问题。

## 存储、清场与提权

- **偏好**（含游戏目录）用 `UserDefaults`，这是 macOS 惯例，Sparkle 的开关也在这里。`SettingsModel` 的类型化属性用 `didSet` 写入；已实测 `@Observable` 属性上的 `didSet` 同时能触发观察并写入 `UserDefaults`。
- **不设集中的 `state.json`。机器状态跟着它描述的对象走**，对象被清掉时状态自然一起消失，不会出现「状态说有，磁盘上没有」：
  - 原生标记：`<data>/.yaagl-native`，单独的小文件（内容含 `schemaVersion`）。标记不与其他状态共用文件，别的状态损坏不会被误当成「没有标记」而触发清场。
  - Wine 与 DXMT 的版本：DXMT 随 Wine 一次装好，两者共用 `<data>/wine/` 里的版本戳文件，重装时随目录一起消失。
  - 未完成作业与预下载：`<game>/.yaagl-tmp/job.json`。「已预下载」由磁盘上的缓存与目标版本推导，不再单独存布尔值。
  - 都用 `Codable`、原子写入、忽略未知字段。
- **首启清场**在 `Platform` 的 `DataDirectory`：`DataDirectory.prepare()` 没有原生标记就按 ADR 0001 清场，再写入标记，返回已就绪的数据目录值。清场只在标记文件不存在时触发；标记存在但内容不可识别，视为错误并报告，不清场。在它返回之前，其他模块拿不到数据目录路径。
- **提权**：`AdminShell`（进程内 `NSAppleScript`）是 `Platform` 的内部类型，唯一调用方是 `HostsBlocklist`，不对外暴露「以 root 跑任意命令」。`HostsBlocklist.status()` 只读 `/etc/hosts`，不需要权限；`apply()` 弹出密码框。提权脚本只做一件事：`cmp` 确认 `/etc/hosts` 仍等于快照后，`cp` 暂存文件覆盖它（两者都由提权的 `do shell script` 的 shell 执行，不经 `ProcessRunning`，所以不受 `codesign`/`tar`/`ditto` 白名单约束；内容不经 shell 或格式串）。
- `Launcher` 的启动顺序固定：清场 → hosts 检查（不通过则引导，并禁止启动游戏）→ Rosetta 检查（先于 2GB 的 Wine 下载）→ Wine 就绪 → `GameSession.recover()`（先 `wineserver -k` 并清孤儿进程，再重放 journal）→ 读取本地与远端游戏状态。

## Wine 与启动会话

- `Wine` 对外两个东西。`WineRuntime`（actor）：确保已安装固定版本（Wine 与 DXMT 在同一次安装里一起装好）、重装、prefix 初始化、shutdown。`GameSession`：`launch(recipe:game:)` 一次调用里执行 `LaunchRecipe`：写注册表、`config.bat`、Launch Mutations、启动、等待退出、清理。**清理不放 `defer`**：它是异步的（`wineserver -w`、15 秒竞速、`reg delete`），已取消的 Task 里子 await 会立即抛错，所以清理跑在不受取消影响、不抛错的独立上下文里，错误只记日志。
- **崩溃恢复**：改动前先写 mutations journal（数据目录里的小文件，记录要还原的文件改名和注册表原值），正常还原后删除。`Launcher` 启动时调用 `GameSession.recover()`（见启动顺序）重放 journal，取代 TS 的 `patched` 标记。重放按磁盘的实际状态逐项幂等；`.bak` 已存在时拒绝覆盖，避免干净备份被覆盖；DXMT 不在其中：它在安装 Wine 时一次装好，运行时不注入、不还原，所以没有「崩溃丢原版 DLL」；注册表项记录原值，或「原本不存在」。这样「异常退出时是否撤销 HDR / 分辨率注册表」只是 #28 可以直接选的策略，不再是架构问题。
- Game Mode、全屏、刘海区域全在注入 Wine 的 x86_64 shim 与 dylib 里，Swift 不重写；`Wine` 只负责准备 `YaaglGame.app`、`codesign`、`LSRegisterURL` 和传四个 `YAAGL_GAME_HOST*` 环境变量。

## 测试缝

只设两个端口（各有生产实现和测试替身）：`ProcessRunning`（Wine 调用和白名单系统工具都走它，测试记录参数、环境变量、工作目录）和 `AdminPrivilege`。HTTP 不设端口，测试用 `URLProtocol` 打桩，喂录制的 getBuild、manifest、chunk 夹具。文件系统用真实临时目录。节流和速度计算注入 `Clock`。`GameClient` 是第三条缝（见上）。`ProcessRunning` 同时承担白名单系统工具（`codesign`、`tar`、`ditto`）的执行，白名单在生产实现里强制。测不到真实的 Wine 注册表，所以断言的是生成的 `.reg` 文本、`config.bat`、环境变量表（golden file）、命令 argv、文件改动，以及还原后磁盘回到原状。

## 其他行为的位置

- **通知**：`JobCoordinator` 除了更新 `@Observable` 状态，还发出离散的 `JobEvent` 流（更新发布、可预下载、失败）。`@Observable` 会合并中间状态，不适合触发通知。通知代码只在 `YaaglApp`。
- **ReShade**：删除（旧仓库 #28 A7）。不下载、不注入、不复制 DLL，`LaunchRecipe` 里没有对应项；「高级」设置页放什么由设置 UI 票决定，不再有解锁手势。
- **yaagl-diag 与自动启动（TS 的 `YAAGL_AUTOLAUNCH`）**：本票只保证架构上有位置（`Launcher` 暴露可由命令行参数驱动的入口，日志写数据目录 `logs/`），具体方案留给 diag 适配票。
- **HTTP 重试与退避**：`Sophon` 与 `Platform` 各有一份，是十几行的值类型。为保持 `Sophon` 不依赖 `Platform`，接受这点重复。
- **Wine 孤儿进程**：启动器被强杀后 Wine 会残留。`recover()` 在重放 journal 之前先 `wineserver -k` 并清理，避免游戏还在跑时还原游戏文件。

## 术语

- **ldiff**：Sophon 的增量更新文件，一个文件里拼接多个 HDiffPatch 补丁。只在 `Sophon` 内部出现。
- **Launch Mutations**：启动前对游戏文件、Wine 运行时和 prefix 的改动（`.bak` 改名、protonextras、注册表），退出后还原。在 `GameSession` 内部。
- 领域词汇里不单用「Patch」这个词。

## x86_64 helper 的源码位置

`YaaglWineShim` 与 `YaaglGameHost` 的 C 源码放在 `Helpers/`（来自旧仓库 tanzby/yet-another-anime-game-launcher 的 `native/gamehost/`，经骨架票 #25 移入，原生版迁到本仓库时随之迁入）。开发专用的 `gamehost-dev.m`、`turner.c` 继续用 `build.sh --dev`，不进 `project.yml`。

## Considered Options

- 保留暂定的 `Core / Sophon / Patch / Wine / Updater / App`：否决。`Core` 会变成杂物堆；`Patch` 一词同时指 ldiff 和启动改动，各自的归属不同；`Updater` 只是转发 Sparkle。
- 把 `Launcher` 并进 `App`：否决，状态机和编排无法 `swift test`。
- 集中的 `state.json`：否决（架构评审）。未完成作业与预下载描述的是游戏目录里的临时数据，Wine 版本描述的是 `wine/`，集中存放会在清场、重装、换游戏目录后留下孤儿状态；标记与其他状态同文件，文件损坏会被误当成没有标记而白删 Wine。
- 清理放 `defer`：否决，清理是异步的，已取消的 Task 里无法可靠 await。
- chunk 级进度日志：否决，多一份必须与磁盘保持一致的状态；幂等重跑已够用。
- 全部设置放 `UserDefaults` 或全部放数据目录 JSON：否决。偏好和机器状态的生命周期不同。
- 给 HTTP、文件系统都设端口：否决，只会多出仅供测试用的间接层。
- 去掉 `GameClient` 协议：维护者选择保留，作为对第二个游戏的预留。

## 未验证

- ad-hoc 签名、未公证的 App 能否拿到 `UNUserNotificationCenter` 授权（地图 Not yet specified 已记录）。通知相关代码只放在 `YaaglApp`，不影响本架构。
