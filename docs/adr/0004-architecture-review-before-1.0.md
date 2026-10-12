# 1.0.0 前的架构审查：边界守住了，做几处不改行为的整理，其余留到之后

地图 #1。维护者要求在 1.0.0 之前审查整个仓库的架构（Sophon / Platform / Wine / GenshinCN / Launcher 的边界、App 组合根、可测试性、命名），只做高价值、低风险、不改行为的升级。mattpocock-skills 的 `ask-matt` 和 `improve-codebase-architecture` 标了 `disable-model-invocation`，会话里无法调用，所以这次是按 ADR 0002 逐条核对代码后的判断。

## 核对结果：ADR 0002 的边界成立

- 依赖是单向的：`Wine → Platform`，`Launcher → {Platform, Wine}`，`GenshinCN → {Launcher, Sophon, Wine, Platform}`，`Sophon` 不依赖其他本地 target。`Package.swift` 与 ADR 一致。
- 领域库不 import SwiftUI / AppKit；只有 `Launcher` 的模型 import `Observation`，这是 ADR 规定的。
- `UserDefaults` 只在 `SettingsModel` 和 `EventNotifier` 里，都通过初始化参数注入。
- 三条缝都有两个实现：`GameClient`（`GenshinCNClient` + Fake）、`WinePreparing`（`WineRuntime` + Fake）、`ProcessRunning`（`SystemProcessRunner` + Fake）。
- 外部进程只有 Wine、x86_64 helper 和 `codesign` / `tar` / `ditto`。

## 做了什么

| 改动 | 为什么 | PR |
|---|---|---|
| `Launcher/Launcher.swift`（一个文件装了客户端协议、启动步骤、主按钮三件事，名字还和模块重名）按概念拆成 `GameClient.swift`、`StartupSteps.swift`、`PrimaryAction.swift`；`LauncherModel.swift` 里的 `LauncherPhase` / `LauncherError` / `JobEvent` 搬到 `LauncherState.swift`，`LaunchGate` 单独成文件 | 找东西不用翻 700 行文件；只移动代码，不改类型 | 本 PR |
| `SettingsModel.Resolution` 与 `LaunchOptions.Resolution` 是一模一样的两份定义，改成类型别名 | 少一份重复和一次手工转换；`SettingsModel.Resolution` 这个名字照旧可用 | 本 PR |
| `GenshinCNClient.bundled` 的 `bundle` 参数默认值是 `.main`，领域库里出现了 `Bundle.main` | ADR 0002 要求只有组合根知道主 bundle；去掉默认值，由 `GenshinLauncherApp` 显式传入 | 本 PR |

## 决定放到 1.0.0 之后

这些价值不低，但要碰很多文件或并发语义，1.0.0 之前不值得冒险：

- [#73](https://github.com/tanzby/genshin-macos-launcher/issues/73)：收窄各模块的 `public` 接口，顺手合并 `GenshinLaunchSettings.Resolution`。
- [#74](https://github.com/tanzby/genshin-macos-launcher/issues/74)：把 `SophonDownloader`、`LauncherModel`、`GameSession` 里混在一起的职责拆成独立类型（`JobCoordinator` 在 ADR 0002 里有名字，代码里还没有独立类型）。
- [#75](https://github.com/tanzby/genshin-macos-launcher/issues/75)：共用的测试支持 target。（已完成，PR #89）
- [#76](https://github.com/tanzby/genshin-macos-launcher/issues/76)：`AutoLaunch` / `DiagLog` 移出产品库。（已完成，`Diagnostics` target，PR #90）
