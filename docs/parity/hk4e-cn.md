# 原神 CN 对等清单

旧 TS 版（`tanzby/yet-another-anime-game-launcher`，已归档）180 条业务规则在原生版里怎么办。它是「原生版能完全替代 TS 版」的验收依据，术语见 `CONTEXT.md` 的「对等清单」。

- **规则来源**：[`docs/research/hk4e-rules.md`](../research/hk4e-rules.md)（只读研究来源，含每条规则的规格和边界情况）。
- **锚点**：规则 ID + 基线 commit `f38cda4`（旧仓库 `origin/main`）。不用 `file:line`，TS 代码以后会消失。
- **依据**里的 `#N` 都指旧仓库的票，链接指向 `https://github.com/tanzby/yet-another-anime-game-launcher/issues/N`。ADR 指本仓库 `docs/adr/`。

## 处置

每条规则恰好一个处置：

| 处置 | 含义 | 条数 |
|---|---|---|
| 照搬 | 行为不变，按旧行为验收 | 55 |
| 改写 | 被后来的决定改变，按新行为验收 | 88 |
| 作废 | 旧机制已不存在，不验收 | 37 |

有意照搬的特殊项：LCH-011 的实测回退分支、UPG-014 语音包不管、WIN-009 根证书。有意放弃：UPG-002 音频目录迁移。[#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) 的 C 组（APP-004、APP-022、INS-008/009/010、PRG-001、WIN-016/019 等）是负面用例：旧版的缺陷在新版里必须不再出现。与 ADR 0002 冲突时以 #28 为准：ReShade 整个删除，DXMT 在安装 Wine 时一次装好。

## 验收层

| 层 | 内容 |
|---|---|
| 单元 | `swift test`：纯逻辑；Sophon 用 `URLProtocol` 打桩和离线夹具；LaunchRecipe 的 `.reg`、`config.bat`、环境变量表、hosts 段用 golden 文件 |
| 组件 | `swift test`：Launcher / SettingsModel / JobCoordinator + `FakeGameClient`，不拉起 Sophon 或 Wine |
| diag | 真机 `yaagl-diag`：看 Wine 进程、窗口、`gamehost.log`、prefix（游戏运行时行为，只能在这一层验证） |
| 线上 | 只读的线上契约测试（getGameBranches / getBuild / getPatchBuild + 一个最小 chunk），独立 workflow，非 PR 必过项 |

「对应测试」一列先留空，由各模块实现票填入。测试名带规则 ID（如 `APP_011_…`）；覆盖脚本 `scripts/dev/parity-coverage` 核对每个「照搬/改写」ID 至少被一个测试或 diag 检查项引用（见下）。

## 1.0.0 发布门槛

原生版 1.0.0 正式发布需要同时满足：

1. 单元和组件测试全绿。
2. 覆盖脚本显示每个「照搬/改写」ID 都有测试或 diag 检查项。
3. 一次真机 diag 通过：首启清场 + Wine 安装 + hosts 引导；启动进主界面 + Game Mode / 全屏 / 刘海；退出还原 + 注册表验证；安装暂停 / 继续（限时）。
4. 线上契约冒烟通过。若 CI 跑机打不通 api-takumi，改为本地 `YAAGL_LIVE=1`，作为发版前检查项。

真实 CN ldiff 更新**不阻塞**发布（TS 版也做不到），靠夹具和线上契约覆盖。

## 覆盖脚本

`scripts/dev/parity-coverage` 解析本清单，取处置为「照搬/改写」的 ID，在 `Tests/**/*.swift` 里含 `func ` 或 `@Test` 的行（测试名，注释不算）以及 `Diag/`、`scripts/diag/`（diag 检查项，目录存在时）里找引用。`APP-011` 与 `APP_011` 等价。

- **报告模式**（默认）：列出未覆盖的 ID，退出码 0。各模块票还在补测试时 CI 用这个模式，已接入 `scripts/dev/macos-check`（因此也是 CI 和 pre-push）。
- **严格模式**（`--strict` 或 `PARITY_STRICT=1`）：有任何未覆盖 ID 就失败。**1.0.0 发布前必须在严格模式下通过**，这是发布门槛第 2 项；发布 workflow 对正式版本（不带 `-rc.N` 后缀）显式用 `--strict`，所以 `1.0.0` 打 tag 时覆盖不全会被卡住，`1.0.0-rc.N` 只报告、不阻塞（rc 要先用来验证 Sparkle 更新）；最后一张模块票合并后，再在 CI 的 `swift` job 设 `PARITY_STRICT=1`，让日常 PR 也严格。
- 两种模式都会在结构性错误时失败：清单行重复或处置不是照搬/改写/作废，或测试引用了清单里不存在的 ID。引用「作废」规则只警告。
- 脚本是命名核对，不证明测试被执行：块注释、套件级 `@Suite(.disabled)` 之类的边角不处理，由发布门槛第 1 项「测试全绿」和 code review 兜底。
- 脚本不看「对应测试」列，它只保证覆盖；该列是给人读的索引，由各票填写。

## 清单（基线 `f38cda4`）

| 规则 ID | 标题 | 处置 | 依据 | 验收层 | 对应测试 |
|---|---|---|---|---|---|
| APP-001 | 应用启动顺序 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B20 删死数据 / ADR 0002 启动顺序 | 组件 |  |
| APP-002 | 数据目录的位置与解析 | 改写 | ADR 0001/0002 / [#27](https://github.com/tanzby/yet-another-anime-game-launcher/issues/27) (removexattr 不提权) | 组件 | `APP_002_*`（DataDirectoryTests） |
| APP-003 | 启动时把 App bundle 同步到数据目录 | 作废 | [#17](https://github.com/tanzby/yet-another-anime-game-launcher/issues/17)/[#13](https://github.com/tanzby/yet-another-anime-game-launcher/issues/13) 无 sidecar/Neutralino | — |  |
| APP-004 | 部分路径依赖进程当前目录 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) C 负面用例 | 组件 |  |
| APP-005 | aria2 下载服务启动 | 作废 | [#17](https://github.com/tanzby/yet-another-anime-game-launcher/issues/17)/[#13](https://github.com/tanzby/yet-another-anime-game-launcher/issues/13) 无 sidecar/Neutralino | — |  |
| APP-006 | aria2 下载任务的去重与续传 | 作废 | [#17](https://github.com/tanzby/yet-another-anime-game-launcher/issues/17)/[#13](https://github.com/tanzby/yet-another-anime-game-launcher/issues/13) 无 sidecar/Neutralino | — |  |
| APP-007 | Sophon 服务进程的启动与生命周期 | 作废 | [#17](https://github.com/tanzby/yet-another-anime-game-launcher/issues/17)/[#13](https://github.com/tanzby/yet-another-anime-game-launcher/issues/13) 无 sidecar/Neutralino | — |  |
| APP-008 | 在线游戏信息 | 改写 | [#26](https://github.com/tanzby/yet-another-anime-game-launcher/issues/26) 端点/缓存 | 组件、线上 | `APP_008_*`（SophonProtocolTests、SophonManifestTests） |
| APP-009 | CN 的 HoYoPlay / Sophon 接口端点 | 改写 | [#26](https://github.com/tanzby/yet-another-anime-game-launcher/issues/26) 端点/缓存 | 组件、线上 | `APP_009_*`（SophonProtocolTests、SophonManifestTests、SophonLiveContractTests） |
| APP-010 | 在线信息查询失败 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A1-A3 | 组件、线上 | `APP_010_*` |
| APP-011 | 本地安装状态判定 | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 单元 |  |
| APP-012 | 从 globalgamemanagers 读取游戏版本 | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 单元 |  |
| APP-013 | 任务队列串行执行，出错即致命 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A1-A3 | 组件 | `APP_013_*` |
| APP-014 | 版本不可读时告警 | 照搬 | 行为不变（流程由 Launcher + Fake GameClient 承载） | 组件 |  |
| APP-015 | 预下载队列与主队列可以并发 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A1-A3 | 组件 | `APP_015_*` |
| APP-016 | 是否需要更新 | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 组件 |  |
| APP-017 | 主按钮的文案与动作 | 改写 | [#21](https://github.com/tanzby/yet-another-anime-game-launcher/issues/21) SwiftUI 主界面 / 设置窗口重新设计 | 组件 |  |
| APP-018 | 设置按钮的可见性 | 改写 | [#21](https://github.com/tanzby/yet-another-anime-game-launcher/issues/21) SwiftUI 主界面 / 设置窗口重新设计 | 组件 |  |
| APP-019 | 启动器启动时还原残留补丁（init） | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B12：启动时 GameSession.recover() 自愈 | 组件 |  |
| APP-020 | YAAGL_AUTOLAUNCH 自动启动 | 改写 | ADR 0002 命令行入口，diag 适配票 | 组件 |  |
| APP-021 | 启动器背景资源 | 改写 | [#21](https://github.com/tanzby/yet-another-anime-game-launcher/issues/21) SwiftUI 主界面 / 设置窗口重新设计 | 组件 |  |
| APP-022 | 窗口关闭与终止钩子 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) C 负面用例 | 组件 |  |
| CFG-001 | 设置的持久化存储 | 改写 | [#29](https://github.com/tanzby/yet-another-anime-game-launcher/issues/29)/ADR 0001 | 组件 |  |
| CFG-002 | 布尔值的解析 | 作废 | [#13](https://github.com/tanzby/yet-another-anime-game-launcher/issues/13) 设置改 UserDefaults 类型化属性（无字符串布尔） | — |  |
| CFG-003 | 改动即时保存，不落盘默认值 | 作废 | [#13](https://github.com/tanzby/yet-another-anime-game-launcher/issues/13) 设置改 UserDefaults 类型化属性（无字符串布尔） | — |  |
| CFG-004 | 设置入口 | 改写 | [#21](https://github.com/tanzby/yet-another-anime-game-launcher/issues/21) SwiftUI 主界面 / 设置窗口重新设计 | 组件 |  |
| CFG-005 | 设置页的标签页结构 | 改写 | [#21](https://github.com/tanzby/yet-another-anime-game-launcher/issues/21) SwiftUI 主界面 / 设置窗口重新设计 | 组件 |  |
| CFG-006 | 高级设置页的解锁手势 | 作废 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A7 删 ReShade/高级页手势（ADR 0002 已按此修订） | — |  |
| CFG-007 | 关闭设置页 | 改写 | [#21](https://github.com/tanzby/yet-another-anime-game-launcher/issues/21) SwiftUI 主界面 / 设置窗口重新设计 | 组件 |  |
| CFG-008 | Wine 版本：列表与切换流程 | 改写 | [#29](https://github.com/tanzby/yet-another-anime-game-launcher/issues/29)/ADR 0001 | 组件 |  |
| CFG-009 | 游戏安装目录 | 照搬 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A9 保留的用户偏好 | 组件 |  |
| CFG-010 | 安装目录的选择校验 | 改写 | [#21](https://github.com/tanzby/yet-another-anime-game-launcher/issues/21) SwiftUI 主界面 / 设置窗口重新设计 | 组件 |  |
| CFG-011 | Metal HUD | 照搬 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A9 保留的用户偏好 | 组件 |  |
| CFG-012 | Retina 模式 | 照搬 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A9 保留的用户偏好 | 组件 |  |
| CFG-013 | 左 CMD 映射为 Ctrl | 照搬 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A9 保留的用户偏好 | 组件 |  |
| CFG-014 | HTTP 代理开关 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B17 | 组件 |  |
| CFG-015 | 代理主机 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B17 | 组件 |  |
| CFG-016 | 界面语言的默认值 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A10 语言跟随系统 | 组件 |  |
| CFG-017 | 界面语言的保存方式 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A10 语言跟随系统 | 组件 |  |
| CFG-018 | YAAGL 版本显示 | 改写 | [#21](https://github.com/tanzby/yet-another-anime-game-launcher/issues/21) SwiftUI 主界面 / 设置窗口重新设计 | 组件 |  |
| CFG-019 | FPS 解锁（不起作用） | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A6 删 FPS，DXMT 固定 60 | 组件 |  |
| CFG-020 | ReShade | 作废 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A7 删 ReShade（ADR 0002 已按此修订） | — |  |
| CFG-021 | 启用 HDR | 照搬 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A9 保留的用户偏好 | 组件 |  |
| CFG-022 | Workaround #3（不起作用） | 作废 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A9 删除的开关 | — |  |
| CFG-023 | 关闭反作弊补丁（patch-off） | 作废 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A9 删除的开关 | — |  |
| CFG-024 | Steam 补丁 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A9 固定开启 | 组件 |  |
| CFG-025 | Launch Fix（block-net） | 作废 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A9 删除的开关 | — |  |
| CFG-026 | 自定义分辨率 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B16 | 组件 |  |
| CFG-027 | Timeout Fix | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A9 固定开启 | 组件 |  |
| CFG-028 | 原生全屏与游戏模式 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A9 固定开启 | 组件 |  |
| CFG-029 | MetalFX 超分 | 照搬 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A9 保留的用户偏好 | 组件 |  |
| CFG-030 | "游戏"标签页的内容顺序 | 改写 | [#21](https://github.com/tanzby/yet-another-anime-game-launcher/issues/21) SwiftUI 主界面 / 设置窗口重新设计 | 组件 |  |
| CFG-031 | 应用推荐设置 | 作废 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A8 删推荐设置按钮 | — |  |
| CFG-032 | 打开 Wine 命令行、游戏目录、数据目录 | 改写 | [#21](https://github.com/tanzby/yet-another-anime-game-launcher/issues/21) SwiftUI 主界面 / 设置窗口重新设计 | 组件 |  |
| CFG-033 | 检查 YAAGL 更新 | 作废 | [#19](https://github.com/tanzby/yet-another-anime-game-launcher/issues/19) Sparkle | — |  |
| CFG-034 | Licenses 标签页 | 改写 | [#21](https://github.com/tanzby/yet-another-anime-game-launcher/issues/21) SwiftUI 主界面 / 设置窗口重新设计 | 组件 |  |
| INS-001 | 安装目录选择的校验 | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 组件 |  |
| INS-002 | 判定"已有安装"还是"全新安装" | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 组件 |  |
| INS-003 | 全新安装主流程（TS 侧） | 照搬 | 行为不变（流程由 Launcher + Fake GameClient 承载） | 组件 |  |
| INS-004 | 全新安装前的磁盘空间检查 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A4 | 组件 | `INS_004_*` |
| INS-005 | Sophon 安装的前置条件与 config.ini 模板 | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 单元 |  |
| INS-006 | config.ini 中 game_version 的两次写入 | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 单元 |  |
| INS-007 | 下载顺序与并发 | 照搬 | 行为不变（流程由 Launcher + Fake GameClient 承载） | 组件 | `INS_007_*`（SophonDownloaderTests） |
| INS-008 | 单个文件的 chunk 下载、组装与校验 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) C 负面用例 | 单元 | `INS_008_*`（SophonDownloaderTests） |
| INS-009 | chunk 和 ldiff 的断点续传 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) C 负面用例 | 单元 | `INS_009_*`（SophonDownloaderTests） |
| INS-010 | 文件级重试 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) C 负面用例 | 单元 | `INS_010_*`（SophonDownloaderTests） |
| INS-011 | 文件路径安全校验 | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 单元 | `INS_011_*`（SophonDownloaderTests） |
| INS-012 | 选中已有目录：旧版本，可以增量更新 | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 组件 |  |
| INS-013 | 选中已有目录：版本太旧 | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 组件 |  |
| INS-014 | 选中已有目录：已是最新版 | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 组件 |  |
| INS-015 | 安装中断后的恢复 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) C32 / ADR 0002 暂停继续 | 组件 | `INS_015_*`（Launcher 侧 job.json 与续跑） |
| INS-016 | Sophon 接口缓存与清理 | 改写 | [#26](https://github.com/tanzby/yet-another-anime-game-launcher/issues/26) 端点/缓存 | 单元 |  |
| LCH-001 | 启动任务的整体顺序 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B12/A7：无 ReShade 步骤，DXMT 随 Wine 装好，还原改为 journal（ADR 0002 已修订） | 单元 | GameSessionLaunchTests |
| LCH-002 | 按版本下载 ReShade | 作废 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A7 删 ReShade（ADR 0002 已按此修订） | — |  |
| LCH-003 | 启动前强制清理 prefix 中的残留进程 | 照搬 | TS 行为不变；LaunchRecipe/GameSession 重做 | diag | GameSessionLaunchTests、GameSessionMutationTests |
| LCH-004 | 判断 MetalFX 是否生效 | 照搬 | TS 行为不变；LaunchRecipe/GameSession 重做 | diag | GenshinLaunchRecipeTests |
| LCH-005 | 写入 Mac Driver 注册表（Retina / 左 Cmd） | 照搬 | TS 行为不变；LaunchRecipe/GameSession 重做 | diag | GameSessionLaunchTests、GenshinLaunchRecipeTests |
| LCH-006 | 写入 HDR 注册表 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B13 | diag | GenshinLaunchRecipeTests |
| LCH-007 | 用注册表实现自定义分辨率（强制窗口化） | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B13 | diag | GenshinLaunchRecipeTests |
| LCH-008 | 分辨率输入校验 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B16 | 单元 |  |
| LCH-009 | 写完注册表后等待 wineserver 退出 | 照搬 | TS 行为不变；LaunchRecipe/GameSession 重做 | diag | GameSessionLaunchTests |
| LCH-010 | config.bat（默认启动路径） | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B14/A9：Steam patch 固定开启，旧的非 Steam 默认路径不再是启动路径；config.bat 仅作 Steam 路径的载体 | 单元 | GameSessionLaunchTests、GenshinLaunchRecipeTests |
| LCH-011 | Steam patch 启动路径 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B14（含实测回退分支） | diag | GenshinLaunchRecipeTests（启动行 golden；真机回退分支仍走 diag） |
| LCH-012 | 补丁幂等 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B12：启动前准备幂等，.bak 存在则不覆盖 | 单元 | GameSessionMutationTests |
| LCH-013 | patch-off 只跳过对游戏文件的修改 | 作废 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A9 删除的开关 | — |  |
| LCH-014 | CN 版启动前移走三个文件 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B12/A9：补丁永远应用（无 patch-off）；`.bak` 已存在时不覆盖，启动时自愈 | 单元 | GameSessionMutationTests、GenshinLaunchRecipeTests |
| LCH-015 | workaround3 对 hk4ecn 无效果 | 作废 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A9 删除的开关 | — |  |
| LCH-016 | 差分补丁和新增文件机制（CN 下列表为空） | 作废 | 死/开发便利/无版本选择 UI/空列表 | — |  |
| LCH-017 | ReShade 注入游戏目录 | 作废 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A7 删 ReShade（ADR 0002 已按此修订） | — |  |
| LCH-018 | 把 steam.exe 和 lsteamclient 部署到 prefix | 照搬 | TS 行为不变；LaunchRecipe/GameSession 重做 | diag | GameSessionMutationTests、GenshinLaunchRecipeTests |
| LCH-019 | patched 标记 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B12：无 patched 标记，状态只看文件系统和 journal | 单元 | GameSessionMutationTests |
| LCH-020 | 每次启动生成一个游戏日志 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B18 | 单元 | GameSessionMutationTests |
| LCH-021 | 屏蔽网络（临时修改 hosts 10 秒） | 改写 | [#29](https://github.com/tanzby/yet-another-anime-game-launcher/issues/29)/ADR 0001 | 单元 | `LCH_021_*`（HostsBlocklistTests） |
| LCH-022 | Game Mode 开关 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A9：Game Mode 固定开启，无关闭分支；仅保留 LCH-023 的失败降级 | diag | GameHostTests |
| LCH-023 | game host 缺失或出错时降级 | 照搬 | TS 行为不变；LaunchRecipe/GameSession 重做 | diag | GameHostTests |
| LCH-024 | 安装 wine 加载器 shim | 照搬 | x86_64 shim/host 原样搬 (ADR 0002)；只能 E2E | diag | GameHostTests |
| LCH-025 | 构建并注册 YaaglGame.app | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A11：游戏包装 App 使用新 bundle id，codesign 标识符必须与之相同 | diag | GameHostTests |
| LCH-026 | game host 的环境变量 | 照搬 | TS 行为不变；LaunchRecipe/GameSession 重做 | diag | GameHostTests、GenshinLaunchRecipeTests |
| LCH-027 | wine-shim 按可执行文件分流 | 照搬 | x86_64 shim/host 原样搬 (ADR 0002)；只能 E2E | diag |  |
| LCH-028 | gamehost 把游戏窗口切到原生全屏 | 照搬 | x86_64 shim/host 原样搬 (ADR 0002)；只能 E2E | diag |  |
| LCH-029 | 全屏时覆盖刘海区域 | 照搬 | x86_64 shim/host 原样搬 (ADR 0002)；只能 E2E | diag |  |
| LCH-030 | 窗口关闭 15 秒后进程仍在则自行退出 | 照搬 | x86_64 shim/host 原样搬 (ADR 0002)；只能 E2E | diag |  |
| LCH-031 | 本机主机名在本地直接解析 | 照搬 | TS 行为不变；LaunchRecipe/GameSession 重做 | 单元 |  |
| LCH-032 | Metal HUD、超时修复与 DLL 覆盖 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A9：Timeout Fix 固定开启，`WINE_ENABLE_TIMEOUT_FIX` 恒为启用值 | diag | GenshinLaunchRecipeTests |
| LCH-033 | DXMT 环境变量与 60 帧上限 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A6 删 FPS，DXMT 固定 60 | 单元 | GenshinLaunchRecipeTests |
| LCH-034 | 代理环境变量 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B17 | 单元 | GenshinLaunchRecipeTests |
| LCH-035 | 空字符串的环境变量不会传递 | 照搬 | TS 行为不变；LaunchRecipe/GameSession 重做 | 单元 | GameSessionLaunchTests |
| LCH-036 | 游戏退出后最多等待 Wine 15 秒，超时强杀 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B15 | diag | GameSessionLaunchTests（启动超时、退出等待与强杀）；`LCH_036_*`（Launcher 的 120 s 启动超时）|
| LCH-037 | 正常退出后撤销 HDR 和分辨率注册表 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B16 | 单元 | GameSessionLaunchTests |
| LCH-038 | 启动失败或崩溃时不撤销注册表 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B12：崩溃残留由 recover() 与幂等写入自愈 | 单元 | GameSessionLaunchTests、GameSessionMutationTests |
| LCH-039 | 退出后删除 config.bat 并还原 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B12：只删除 config.bat 并按 journal 还原游戏文件，无 DXMT/ReShade/patched 还原 | 单元 | GameSessionLaunchTests |
| PRE-001 | 何时显示预下载提示 | 改写 | [#26](https://github.com/tanzby/yet-another-anime-game-launcher/issues/26) | 组件、线上 | `PRE_001_*`（SophonUpdaterTests：按目标版本的预下载记录；提示显示逻辑属 Launcher） |
| PRE-002 | 执行预下载 | 改写 | [#26](https://github.com/tanzby/yet-another-anime-game-launcher/issues/26) | 组件、线上 | `PRE_002_*`（SophonUpdaterTests）、`PRE_002_live_*` |
| PRE-003 | 预下载版本的显示 | 照搬 | 行为不变（流程由 Launcher + Fake GameClient 承载） | 组件 |  |
| PRG-001 | 任务事件推送（WebSocket） | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) C 负面用例 | 单元 |  |
| PRG-002 | 进度与速度计算 | 改写 | [#21](https://github.com/tanzby/yet-another-anime-game-launcher/issues/21) SwiftUI 主界面 / 设置窗口重新设计 | 单元 |  |
| PRG-003 | 事件与界面文案的对应关系 | 改写 | [#21](https://github.com/tanzby/yet-another-anime-game-launcher/issues/21) SwiftUI 主界面 / 设置窗口重新设计 | 单元 |  |
| PRG-004 | 字节数的可读格式 | 改写 | [#21](https://github.com/tanzby/yet-another-anime-game-launcher/issues/21) SwiftUI 主界面 / 设置窗口重新设计 | 单元 |  |
| PRG-005 | 进度条显示规则 | 改写 | [#21](https://github.com/tanzby/yet-another-anime-game-launcher/issues/21) SwiftUI 主界面 / 设置窗口重新设计 | 单元 |  |
| PRG-006 | 取消功能没有接入 | 改写 | [#21](https://github.com/tanzby/yet-another-anime-game-launcher/issues/21) SwiftUI 主界面 / 设置窗口重新设计 | 单元 | `PRG_006_*` |
| REP-001 | 修复的入口 | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 单元 |  |
| REP-002 | 前置条件：版本必须是最新 | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 单元 | `REP_002_*`（Launcher 侧前置条件） |
| REP-003 | 文件校验 | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 单元 | `REP_003_*`（SophonDownloaderTests） |
| REP-004 | 修复不了"大小对、MD5 错"的文件 | 改写 | [#26](https://github.com/tanzby/yet-another-anime-game-launcher/issues/26) | 单元 | `REP_004_*`（SophonDownloaderTests） |
| REP-005 | hk4e 的完整性检查不清除 `patched` | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B12：DXMT 不再注入，修复后无需清标记 | 单元 |  |
| UPD-001 | 应用版本号的来源 | 作废 | [#19](https://github.com/tanzby/yet-another-anime-game-launcher/issues/19) Sparkle 取代 TS updater | — |  |
| UPD-002 | 开发版跳过自更新 | 作废 | [#19](https://github.com/tanzby/yet-another-anime-game-launcher/issues/19) Sparkle 取代 TS updater | — |  |
| UPD-003 | 识别渠道 | 作废 | [#19](https://github.com/tanzby/yet-another-anime-game-launcher/issues/19) Sparkle 取代 TS updater | — |  |
| UPD-004 | 更新源与 API | 作废 | [#19](https://github.com/tanzby/yet-another-anime-game-launcher/issues/19) Sparkle 取代 TS updater | — |  |
| UPD-005 | 匹配发布资产 | 作废 | [#19](https://github.com/tanzby/yet-another-anime-game-launcher/issues/19) Sparkle 取代 TS updater | — |  |
| UPD-006 | 版本比较 | 作废 | [#19](https://github.com/tanzby/yet-another-anime-game-launcher/issues/19) Sparkle 取代 TS updater | — |  |
| UPD-007 | 检查更新失败 | 作废 | [#19](https://github.com/tanzby/yet-another-anime-game-launcher/issues/19) Sparkle 取代 TS updater | — |  |
| UPD-008 | 启动时的更新提示与忽略版本 | 作废 | [#19](https://github.com/tanzby/yet-another-anime-game-launcher/issues/19) Sparkle 取代 TS updater | — |  |
| UPD-009 | 手动检查更新 | 作废 | [#19](https://github.com/tanzby/yet-another-anime-game-launcher/issues/19) Sparkle 取代 TS updater | — |  |
| UPD-010 | 下载并替换 sidecar | 作废 | [#19](https://github.com/tanzby/yet-another-anime-game-launcher/issues/19) Sparkle 取代 TS updater | — |  |
| UPD-011 | 下载并替换 resources.neu | 作废 | [#19](https://github.com/tanzby/yet-another-anime-game-launcher/issues/19) Sparkle 取代 TS updater | — |  |
| UPD-012 | 更新进度的换算 | 作废 | [#19](https://github.com/tanzby/yet-another-anime-game-launcher/issues/19) Sparkle 取代 TS updater | — |  |
| UPD-013 | 完成后重启 | 作废 | [#19](https://github.com/tanzby/yet-another-anime-game-launcher/issues/19) Sparkle 取代 TS updater | — |  |
| UPD-014 | 更新失败时不回滚 | 作废 | [#19](https://github.com/tanzby/yet-another-anime-game-launcher/issues/19) Sparkle 取代 TS updater | — |  |
| UPD-015 | 发布产物与命名约定 | 作废 | [#19](https://github.com/tanzby/yet-another-anime-game-launcher/issues/19) Sparkle 取代 TS updater | — |  |
| UPD-016 | 代理不作用于启动器自身的网络请求 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B17 | 单元 |  |
| UPD-017 | Bundle 标识与 Info.plist | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A11 | 单元 |  |
| UPD-018 | sidecar 的可执行权限 | 作废 | [#19](https://github.com/tanzby/yet-another-anime-game-launcher/issues/19) Sparkle 取代 TS updater | — |  |
| UPG-001 | 更新资格 | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 单元 |  |
| UPG-002 | 3.6.0 及以上版本的音频目录迁移 | 作废 | [#26](https://github.com/tanzby/yet-another-anime-game-launcher/issues/26) D3 放弃音频迁移 | — |  |
| UPG-003 | 更新请求与 Sophon 的处理顺序 | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 单元 |  |
| UPG-004 | CN 的更新和预下载请求必然失败 | 改写 | [#26](https://github.com/tanzby/yet-another-anime-game-launcher/issues/26) | 单元、线上 | `UPG_004_*`（SophonProtocolTests）、`APP_009_live_*` |
| UPG-005 | Sophon 判定发行类型与已安装版本 | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 单元 |  |
| UPG-006 | 没有可用更新时报错 | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 单元 |  |
| UPG-007 | 删除旧文件（files_delete） | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 单元 | `UPG_007_*`（SophonUpdaterTests） |
| UPG-008 | 单个文件的 ldiff 下载决策 | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 单元 | `UPG_008_*`（SophonUpdaterTests） |
| UPG-009 | 应用 ldiff（hpatchz） | 改写 | [#26](https://github.com/tanzby/yet-another-anime-game-launcher/issues/26) | 单元 | `UPG_009_*`（SophonUpdaterTests、HDiffPatcherTests）、`UPG_009_live_*` |
| UPG-010 | 下载新增文件和需要整体替换的文件 | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 单元 | `UPG_010_*`（SophonUpdaterTests） |
| UPG-011 | 更新后的快速校验与写入 config.ini | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 单元 | `UPG_011_*`（SophonUpdaterTests：Sophon 侧的大小与旧文件校验；写 config.ini 由 GenshinCN 负责） |
| UPG-012 | 清理 ldiff | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 单元 | `UPG_012_*`（SophonUpdaterTests） |
| UPG-013 | 更新完成后启动器侧的状态 | 照搬 | TS 行为不变，但依 ADR 0002 在 Sophon/Launcher 重做 | 单元 | `UPG_013_*` |
| UPG-014 | 更新和修复的处理范围 | 照搬 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) A5 语音包不管（有意照搬） | 单元 |  |
| WIN-001 | 内置的 Wine 发行版清单 | 改写 | ADR 0001/0002 / [#27](https://github.com/tanzby/yet-another-anime-game-launcher/issues/27) (removexattr 不提权) | 单元 | WineStatusTests（pinned 清单） |
| WIN-002 | 默认的 Wine 版本 | 改写 | [#29](https://github.com/tanzby/yet-another-anime-game-launcher/issues/29)/ADR 0001 | 单元 | WineStatusTests（固定 Wine / DXMT 版本） |
| WIN-003 | 判断 Wine 是否就绪 | 改写 | [#29](https://github.com/tanzby/yet-another-anime-game-launcher/issues/29)/ADR 0001 | 单元 | WineStatusTests（磁盘与版本戳判定） |
| WIN-004 | wine_tag 不在清单中时强制重装 | 改写 | [#29](https://github.com/tanzby/yet-another-anime-game-launcher/issues/29)/ADR 0001 | 单元 | WineStatusTests（旧 tag 即不符；不依赖 shim 文件） |
| WIN-005 | 启动时按 Wine 状态分流 | 改写 | ADR 0001/0002 / [#27](https://github.com/tanzby/yet-another-anime-game-launcher/issues/27) (removexattr 不提权) | 单元 |  |
| WIN-006 | 安装或切换 Wine 时先删除 prefix | 改写 | [#29](https://github.com/tanzby/yet-another-anime-game-launcher/issues/29)/ADR 0001 | 单元 | WineInstallTests（重装先下后删，prefix 一并重建）、WineInstallResumeTests（空间预检在下载与删除之前） |
| WIN-007 | 下载 Wine 安装包并判断格式 | 照搬 | Wine 运行时行为不变 | 单元 | WineInstallTests、WineInstallResumeTests（并行下载、稳定路径）、DownloaderTests、DownloaderResumeTests（Range 续传） |
| WIN-008 | 解压规则 | 照搬 | Wine 运行时行为不变 | 单元 | WineInstallTests、WineInstallResumeTests（失败带 tar/ditto 输出）、SystemProcessRunnerTests |
| WIN-009 | 向 wine.inf 注入根证书 | 照搬 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B19 根证书（有意照搬） | diag | WineInfTests、WineInstallTests |
| WIN-010 | 移除 quarantine 属性（需要管理员权限） | 改写 | ADR 0001/0002 / [#27](https://github.com/tanzby/yet-another-anime-game-launcher/issues/27) (removexattr 不提权) | diag | `WIN_010_*`（QuarantineTests） |
| WIN-011 | 在 /etc/hosts 中维护永久屏蔽段 | 改写 | [#29](https://github.com/tanzby/yet-another-anime-game-launcher/issues/29)/ADR 0001 | diag | `WIN_011_*`（HostsBlocklistTests、TelemetryHostsTests）；真机提权写入由 diag 验收 |
| WIN-012 | 初始化 prefix | 照搬 | Wine 运行时行为不变 | diag | WineInstallTests（wineboot / winecfg argv 与日志；真机仍走 diag） |
| WIN-013 | hk4ecn 不安装 Media Foundation | 作废 | 死/开发便利/无版本选择 UI/空列表 | — |  |
| WIN-014 | 安装完成后写入状态 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B20：删除 wine_netbiosname、wine_update_url 等死数据；状态由 Wine 目录版本戳推导（ADR 0002） | 单元 | WineInstallTests（版本戳最后写入） |
| WIN-015 | NetBIOS 名称 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B20 删死数据 / ADR 0002 启动顺序 | 单元 | WineInstallTests（负面：不写 NetBIOS） |
| WIN-016 | 选择 Wine 可执行文件与基础环境 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) C 负面用例 | diag | LoaderSelectionTests |
| WIN-017 | 路径转换与 copy 特例 | 照搬 | Wine 运行时行为不变 | 单元 | GameSessionLaunchTests（Z: 路径） |
| WIN-018 | Wine 关停与强杀 | 照搬 | Wine 运行时行为不变 | diag | GameSessionMutationTests、ProcessTableTests（prefix 清扫；真机仍走 diag） |
| WIN-019 | DXMT 版本检查与下载 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) C 负面用例 | 单元 | WineStatusTests（DXMT 版本不符即重装） |
| WIN-020 | 把 DXMT 注入 Wine 运行时 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B12：DXMT 装 Wine 时一次装好，不再注入（ADR 0002 已修订） | 单元 | WineInstallTests（DXMT 随 Wine 一次装好） |
| WIN-021 | 还原 DXMT 注入 | 改写 | [#28](https://github.com/tanzby/yet-another-anime-game-launcher/issues/28) B12：DXMT 不再注入，因此无需还原（ADR 0002 已修订） | 单元 | WineInstallTests（无 .bak，无需还原） |
| WIN-022 | 打开 Wine 命令行窗口 | 改写 | [#21](https://github.com/tanzby/yet-another-anime-game-launcher/issues/21) 设置窗口重新设计；保留为开发便利入口（CFG-032） | 组件 |  |
| WIN-023 | 当前版本不在清单中时的下拉框 | 作废 | 死/开发便利/无版本选择 UI/空列表 | — |  |
