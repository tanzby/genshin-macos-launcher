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

## 卡顿归因（2026-10-18，已查明）

结论先行：GPTK 的「卡」由三件事叠加，前两件已有证据并已处理或说明，第三件是 GPTK 自身的开销。

1. **帧节奏不均（持续存在，已修）**：GPTK 默认在 120 Hz 屏上 60 fps 时，present 间隔是 8.3 ms 和 25 ms 交替（一轮 15 s：<12.5 ms 416 次，<29.2 ms 432 次，16.7 ms 附近仅 58 次），DXMT 则是 901 次全是 16.7 ms。D3DMetal 没有帧率目标时一做完就 present。设 `D3DM_MAX_FPS=60` 后同一场景 901/903 次全是 16.7 ms，p99 从 25.0 降到 16.7 ms，GPU 利用率不变（93%）。`GenshinLaunchRecipe` 现在对 GPTK 设 `D3DM_MAX_FPS` 为帧率上限（60，解锁帧率时 120）。解锁到 120 后 GPU 跑满（96–100%），只有约 86 fps，间隔 8.3/16.7 ms 是 GPU 受限的自然结果，`D3DM_MAX_FPS=120` 对它没有影响。
2. **运行中编译新着色器（偶发的 >50 ms 卡顿）**：此前「暖缓存下 GPTK 仍卡、缓存没有增长」的两个前提都不对。D3DMetal 在**退出时**才把 `bytecode_cache.bin`、`stage_cache.bin` 写回（文件 mtime 在游戏关闭的那一刻），0.25 s 轮询看不到增长；而且每次在没走过的地方都会新增条目。证据（同一台机器，GPTK，同一条 W 去 S 回的路线，连续四轮）：

| 轮次 | 本轮缓存增长（bytecode+stage） | >50 ms 卡顿 | 卡顿归因 |
|---|---|---|---|
| 1 | +0.72 MB | 2 | 2 次 GPU 背压（渲染线程在等已提交的帧） |
| 2 | +1.9 MB | 5 | 4 次与 Metal 编译服务的 XPC 请求重合，1 次背压 |
| 3 | +0.13 MB | 0 | — |
| 4 | 0 | 1（54 ms） | GPU 利用率 ≥90%，栈上只见游戏自己的代码 |

   卡顿数跟本轮新编译的着色器量同升同降：缓存稳定后就几乎没有卡顿。进程内栈采样（见下）在卡顿当下抓到的线程里有 `MTLCompilerScheduler` → `xpc_connection_send_message_with_reply_sync`（等待 Metal 编译服务）和 `libmetalirconverter` 的 LLVM 优化 pass（DXIL → Metal IR 转换）。这是 D3DMetal 自己的运行期编译，和 DXMT 冷缓存时的行为同类。所以先前把「GPTK 暖缓存 14 次卡顿」和「DXMT 暖缓存 0 次」放在一起比，混杂了两个后端缓存覆盖的路线不同。冷缓存对比里两者本来就都卡（GPTK 4 次，DXMT 6 次）。
3. **GPU 利用率高约 10 个百分点（2026-10-18 查明：不是 GPTK 多做了活）**：同一路线、60 fps、3024×1964，`ioreg` 的 Device Utilization GPTK 87–94%，DXMT 76–84%，但这个数字不是负载。证据：
   - **吞吐相同**：解锁到 120 后两边都 GPU 跑满（100%），实际帧率 GPTK 87–99 fps，DXMT 80–92 fps，GPTK 不比 DXMT 慢。
   - **利用率与负载脱钩**：关 Retina（1512×982，像素数 1/4），GPTK 反而是 91–92%，DXMT 82–87%（高于 Retina 下的 76–81%）。GPU 降频后同样的活占的百分比更高，所以这个指标只能在同频下比，不能当成本。
   - **xctrace Metal System Trace**（两边各录 40 s，同一路线，导出 `metal-gpu-intervals`）：wine 进程各通道时间之和 GPTK 约 90%（Vertex 8、Fragment 63、Compute 19），DXMT 约 99%（Vertex 10.5、Fragment 62、Compute 27）；每帧 pass 数相近（render encoder 约 154k 对 161k，GPTK 的 compute/blit 更少，没有多出的拷贝或 blit）。区别在重叠：各通道合并后的忙时 GPTK 82%，DXMT 70%，即 DXMT 把 compute 与 fragment 叠在一起跑，D3DMetal 更多串行。这是 D3DMetal 的调度方式，不是多出来的工作。
   - **旋钮无效**（GPTK，60 fps，同路线，利用率 87–92%）：`D3DM_IGNORE_D3D11_RENDER_BARRIERS=1`、`D3DM_MTL4=1`、`D3DM_BOUNDS_CHECK=1` 都与基线（88–89%）无差别；`D3DM_BOUNDS_CHECK=0` 同样 87–89%，但改变了着色器，这一轮重新编译，卡顿升到 13 次（`compile`），所以不用。GPU 背压卡顿因此仍偶发（每轮 0–2 次），launcher 无可调项；Retina 关闭可降分辨率，但 GPTK 利用率没降，不值得作为建议。

### 方法与数据来源

每一层 tracing 都加在开发工具里（Debug 模式下才写日志），按顺序加，每加一层就跑一次限时测量：

- 进程内卡顿栈采样（`Helpers/gamehost-dev.m`）：watchdog 线程发现渲染层 45 ms 没有取 drawable，就逐个挂起游戏线程、沿 `rbp` 链读栈、恢复，每次卡顿抓 8 次，写到 `GENSHIN_LAUNCHER_GAMEHOST_STALLS`。不用 `sample`：它启动加符号化要数百毫秒，卡顿早已过去。`nd:` 行记录 `nextDrawable` 本身的耗时，所有运行里都没有超过 10 ms 的，所以不是 drawable 获取阻塞。
- `scripts/diag/stall-report` 按栈分类（shader-convert、compiler-xpc、io、gpu-backpressure、windows-code）并与 `hitch:` 行按时间对齐。
- `scripts/diag/proc-cpu.swift`：每 50 ms 记录 `MTLCompilerService` 的累计 CPU 时间，卡顿窗口内增长 ≥20 ms 记为 `cause=compile`。
- `fps-measure` 额外记录每轮前后的 `*_cache.bin` 大小、present 间隔分布（`pacing:`）、`FPS_MEASURE_ENV` 传环境变量、`FPS_MEASURE_XCTRACE=<模板>` 限时录 xctrace。
- xctrace「Metal System Trace」可以 attach 到 Wine 进程（`--attach <pid>` 成功，导出 `metal-gpu-intervals`、`ca-client-present-request` 等表）。但录制本身带来每 5 s 一次约 100 ms 的周期性卡顿，所以它只用来确认可用，不用来做归因；这一轮没有得出需要它的结论。

没做或没查到的：
- GPU 背压卡顿里，具体是哪个 draw 让 GPU 慢，没有往下查（需要 Xcode 的 GPU 帧捕获，Wine 进程下未验证）。xctrace 的 `metal-gpu-counter-intervals`（带宽）表每份 3.7 GB，没有导出；通道忙时对比已足以排除多余工作。
- 「新着色器何时编译」没有在 `D3DMetal` 里下钩子计时；证据是栈和缓存增长的相关，不是逐次调用计时。
- 每种情况样本量小（GPTK 4 轮、DXMT 2 轮），数字只作定性判断。

### 优化与建议

- 已做：GPTK 设 `D3DM_MAX_FPS`，帧节奏变均匀（见上）。端到端用本分支构建出的 App 可执行文件（没有手动设环境变量）复测：一轮 15 s 的 W 和 S 各 903–908 次 present，全部是 16.7 ms，p99 16.7 ms，0 次 >50 ms，GPU 利用率 87–89%。
- 不做：GPTK 的「预热缓存」没有可行办法，缓存内容取决于玩家走过的路线，且只在退出时写回；因此游戏被强杀或崩溃时当次新增的着色器会丢，下次进同一区域再卡一次。launcher 的正常退出路径应继续让 Wine 正常结束。
- DXMT 的缓存目录要在更新、Wine 升级和 launcher 的清理逻辑里保持不失效。

## 分发门槛

本项目是开源、仅用于课程学习的工具，维护者决定随 launcher 分发该载荷。Apple 的 DMG 无法在 runner 上下载，所以维护者把 `scripts/prepare-gptk4` 生成的 `build/gptk4` 打成 `gptk4-4.0b3.tar.xz`（`tar -C build -cJf gptk4-4.0b3.tar.xz gptk4`），上传到 prerelease `gptk4-payload-4.0b3`。该 tag 不匹配 semver，不触发 release，也不影响 `releases/latest` 和 appcast。release job 下载这个资源、校验 workflow 里固定的 sha256、解压到 `build/`，再跑 `scripts/dev/check-gptk4`；之后 `check-bundle` 以 `REQUIRE_GPTK4=1` 检查成品。更换载荷时同时更新资源和固定哈希。

## 实现索引

- 后端、bundle 识别和共享路径：`Sources/Wine/WineInstall.swift`、`Sources/Wine/WineRuntimeInstall.swift`、`Sources/Wine/Wine.swift`。
- 持久设置和 App 装配：`Sources/Launcher/SettingsModel.swift`、`App/Views/SettingsView.swift`、`App/BundledGPTK4.swift`。
- 官方载荷清单和打包检查：`scripts/gptk4-files`、`scripts/prepare-gptk4`、`scripts/dev/check-gptk4`、`scripts/dev/check-bundle`、`project.yml`、`.github/workflows/release.yaml`。
- 跨 Space 文本诊断：`scripts/diag/window-info.swift`、`scripts/diag/genshin-launcher-diag`。
- 跑图帧率：`scripts/diag/fps-measure`、`scripts/diag/holdkey.swift`、`Helpers/gamehost-dev.m` 的 measure 模式。
