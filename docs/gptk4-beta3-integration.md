# GPTK 4.0 beta 3 接入与验收

本文记录原生 launcher 接入 Apple Evaluation Environment for Windows Games 4.0 beta 3 的实现边界和实测证据。GPTK 4 在这里指 D3DMetal 运行库，不是 Wine 发行版。

## 接入结构

- App 默认选择 GPTK 4，可在 Wine 设置页切换 DXMT；选择会持久化，并在下次启动时使用。
- 两个后端共用固定 Wine `11.0-1-crossover-signed-experimental`，但运行时分别安装在数据目录的 `wine/`（DXMT）和 `wine-gptk4-native/`（GPTK 4）。两者使用同一个 `wineprefix/`。安装或重装只替换所选运行时；已识别的 prefix 不会重建，初始化只发生在 prefix 不存在或为空时。代码测试覆盖 prefix 保留；DXMT → GPTK 4 回切后实际登录状态保留（见下方验收）。这个保证针对已经建立原生 marker 的运行时安装和切换；首次原生迁移若没有 `.genshin-launcher-native` marker，会按既有清理契约删除数据根目录下的旧 TS `wineprefix/`，不能把它与后端切换混为一谈。
- DMG 提供的是 GPTK 配套载荷，不包含完整 Wine。App 的 `Contents/Resources/gptk4/lib` 对应 GPTK 包根目录，Wine 安装器把 `external/` 和 `wine/x86_64-{unix,windows}/` 叠加到独立 GPTK 运行时，保留 Wine 自己的其余模块、loader 和链接。
- `scripts/gptk4-files` 是载荷清单，逐项覆盖 `redist/lib` 的 28 个文件和符号链接：D3DMetal.framework（框架二进制、签名资源、Info/version plist、default.metallib 和 DirectX/Metal 编译器库）、`libd3dshared.dylib`，以及 d3d10、d3d11、d3d12、d3d12core、dxgi、nvapi64、nvngx-on-metalfx 七组 Windows DLL/Unix SO 桥接文件与原始链接。构建载荷另保留 DMG 中的 License、Read Me、Acknowledgements 三份 RTF 和来源/哈希记录。
- 构建期从已挂载的官方 DMG 生成忽略目录 `build/gptk4`；Apple 二进制不提交源码仓库，也不 patch 或重签。`scripts/dev/check-gptk4` 检查完整清单、从 Info.plist 识别的 `CFBundleShortVersionString=4.0b3`、链接、Apple 签名和本地生成的哈希记录。`SHA256SUMS` 用于记录这次提取结果，不是 Apple 发布摘要。源码构建在本地载荷存在时打包；发布检查要求 GPTK 载荷。

## 诊断边界

`scripts/diag/genshin-launcher-diag windows <PID>` 会列出该进程的所有窗口及 `onscreen` 状态。非当前桌面或隐藏窗口统一标成 `not-current-or-hidden`，不推断它一定属于另一个 Space。`scripts/diag/genshin-launcher-diag activate <PID> --timeout 秒数` 只查询并激活已有进程；成功要求目标 App 已 active 且窗口真实出现在屏幕上。`run` 内部的 snapshot 也能区分当前可见窗口、存在但不可见的窗口和未创建窗口。这些窗口诊断命令只输出文本，不重建 prefix、不启停游戏，也不保存游戏画面；实现见 `scripts/diag/window-info.swift` 和 `scripts/diag/genshin-launcher-diag`。

## 验收证据

这些证据代表不同层次，不能相互替代：

| 层次 | 当前结果 |
|---|---|
| 资源与构建 | beta 3 载荷已从用户现有挂载卷提取到 ignored `build/gptk4`；版本、Apple 签名、文件/链接清单和哈希已检查。主 worker 已报告 `scripts/dev/macos-check` exit 0（826 tests），Release 构建及最终 `/Applications` bundle 的 `REQUIRE_DXMT=1 REQUIRE_GPTK4=1` 与 deep codesign 检查通过。补齐 `Graphics backend`、`Installing GPTK 4`、`GPTK` 三个 String Catalog 双语条目后，`scripts/dev/macos-check` 重跑 exit 0（826 tests）。随后重新构建 Release 并覆盖安装到 `/Applications`；新包与安装后的包都通过严格 `REQUIRE_DXMT=1 REQUIRE_GPTK4=1 scripts/dev/check-bundle` 和 deep codesign 检查。启动后直接显示"开始游戏"，两个运行时和 prefix 都没有被重装或改动。 |
| 模块映射 | 隔离测试和正式 App 的 GPTK 游戏进程都已观察到加载 D3DMetal 4.0b3。另一次跨 Space 激活已确认目标窗口 active 且 onscreen。这证明运行时模块映射和窗口激活，不代表已进入世界。 |
| 用户 PoC | 用户亲自在隔离验证 prefix 完成登录并进入世界游玩。该 prefix 被完整保留用于 App 验收，原生 marker 有效；代码测试也验证后端切换不删除共享 prefix。 |
| 正式 App 界面 | DXMT 已在 App 中进入世界；约 3 秒移动输入后，画面由坡上站立变为沿前方小路跑动，地形相对位置随之变化，移动已确认。2026-10-17 在设置页把后端切回 GPTK 4 后，用同一共享 prefix 从 App 启动：标题画面直接显示 `CLICK TO BEGIN`，未要求登录；点击后进入大世界，按住 W 3 秒并松开，角色由土路跑入前方草地，树与远景明显拉近，移动已确认。该进程映射 `wine-gptk4-native/lib/external/D3DMetal.framework`（Info.plist 4.0b3）和 `libd3dshared.dylib`，未映射 `winemetal`。验收后用该 prefix 的 `wineserver -k` 关闭游戏，launcher 显示游戏已退出。 |
| Retina | DXMT 与 GPTK 正式 App 的 Wine 注册表均为 `RetinaMode=y`；两者游戏窗的窗口捕获均为 3024×1964、逻辑屏幕为 1512×982。窗口捕获按显示器 2× 缩放取样，只说明窗口以 Retina 尺寸合成，不单独证明游戏后台缓冲为原生 2× 分辨率。GPTK 那次运行后，共享 prefix 中游戏自己的 `Screenmanager Resolution Width/Height` 为 3024×1964，说明 Windows 侧拿到的是 2× 分辨率；该值也可能由手动设置留下，所以只算佐证；更直接的证据见性能一行：两个后端的主 drawable 都是 3024×1964。MetalFX 偏好未设置（默认关），且 `GenshinLaunchRecipe` 只在 DXMT 下注入 MetalFX，GPTK 不依赖它。 |
| 性能 | 2026-10-17 用 `scripts/diag/fps-measure` 在登录着的共享 prefix 上，按 GPTK、DXMT、GPTK、DXMT 的顺序交替测，之后又补跑了 GPTK、GPTK、DXMT 三轮，以及 GPTK、DXMT、GPTK、DXMT 四轮。每轮都从上次退出的位置出发，W 去 S 回，位置大致不变，但不保证逐帧相同。每次运行都按住 W 跑出 15 s，再按住 S 跑回 15 s，统计主游戏 layer 的 drawable `presentedTime`（真实上屏时间，不是 `nextDrawable` 间隔）。两个后端的后台缓冲都是 3024×1964，表明 Retina 2× 渲染真实生效。结果见下表。两者都顶在 60 fps：DXMT 由 recipe 的 `preferredMaxFrameRate=60` 限制；GPTK 受游戏自身上限约束：PC 版游戏内 FPS 只有 30/45/60 三档，当前为 60。要超过 60 只能用改游戏内存的第三方解锁器，有账号风险，因此没有测 60 以上的余量。这个场景下没有"更快"的结论，差别只在帧间隔是否均匀：DXMT 完全均匀，GPTK 在 120 Hz 屏上偶有 8.3/25 ms 交替，14 段里有 3 段出现超过 50 ms 的间隔（每段 2–3 次，最长 83.3 ms），全部出现在 W 段，即往新区域跑的时候。冷缓存未测：两个后端此前都在这一带跑过，着色器缓存是暖的；GPU 跑满的重场景也未测。按键由 HID 事件注入，companion 日志确认收到按下/松开。最后两轮（GPTK、DXMT 各一）用游戏窗截图做了纯数值核验，截图算完即删、没有人工查看：64×64 亮度平均差在静止 1 s 时为 2.4/3.8，按住 W 15 s 后为 22.4/32.8。这说明画面在走动中大幅变化，与在大世界里跑动一致；其余几轮没有这项核验。 |

| 后端 | 次数 | 方向 | fps | p50 | p99 | max | >50 ms | 丢帧 |
|---|---|---|---|---|---|---|---|---|
| GPTK 4.0b3 | 7 | W | 59.9–60.3 | 16.7 ms | 25.0–33.3 ms | 50.0–83.3 ms | 0–3 | 0 |
| GPTK 4.0b3 | 7 | S | 60.3 | 16.7 ms | 25.0 ms | 29.2–37.5 ms | 0 | 0 |
| DXMT | 5 | W | 60.0 | 16.7 ms | 16.7 ms | 16.7 ms | 0 | 0 |
| DXMT | 5 | S | 60.0 | 16.7 ms | 16.7 ms | 16.7 ms | 0 | 0 |

## 分发门槛

本项目是开源、仅用于课程学习的工具，维护者决定随 launcher 分发该载荷。Apple 的 DMG 无法在 runner 上下载，所以维护者把 `scripts/prepare-gptk4` 生成的 `build/gptk4` 打成 `gptk4-4.0b3.tar.xz`（`tar -C build -cJf gptk4-4.0b3.tar.xz gptk4`），上传到 prerelease `gptk4-payload-4.0b3`。该 tag 不匹配 semver，不触发 release，也不影响 `releases/latest` 和 appcast。release job 下载这个资源、校验 workflow 里固定的 sha256、解压到 `build/`，再跑 `scripts/dev/check-gptk4`；之后 `check-bundle` 以 `REQUIRE_GPTK4=1` 检查成品。更换载荷时同时更新资源和固定哈希。

## 实现索引

- 后端、bundle 识别和共享路径：`Sources/Wine/WineInstall.swift`、`Sources/Wine/WineRuntimeInstall.swift`、`Sources/Wine/Wine.swift`。
- 持久设置和 App 装配：`Sources/Launcher/SettingsModel.swift`、`App/Views/SettingsView.swift`、`App/BundledGPTK4.swift`。
- 官方载荷清单和打包检查：`scripts/gptk4-files`、`scripts/prepare-gptk4`、`scripts/dev/check-gptk4`、`scripts/dev/check-bundle`、`project.yml`、`.github/workflows/release.yaml`。
- 跨 Space 文本诊断：`scripts/diag/window-info.swift`、`scripts/diag/genshin-launcher-diag`。
- 跑图帧率：`scripts/diag/fps-measure`、`scripts/diag/holdkey.swift`、`Helpers/gamehost-dev.m` 的 measure 模式。
