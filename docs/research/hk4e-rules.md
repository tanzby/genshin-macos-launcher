# 原神 CN（hk4ecn）业务规则清单

> 研究票 [#15](https://github.com/tanzby/yet-another-anime-game-launcher/issues/15)，所属地图 [#13 原生 macOS 迁移（原神 CN）](https://github.com/tanzby/yet-another-anime-game-launcher/issues/13)。
> 用途：Swift/SwiftUI 原生版"功能全部对等"的验收依据。基线为 `origin/main` @ `f38cda4`。

## 0. 说明

**范围。** 只覆盖 hk4ecn 实际走到的路径，涉及以下代码：

- `src/clients/hk4ecn.ts`、`src/clients/mhy/hk4e/`、`src/clients/mhy/*.ts`
- `src/wine/`、`src/config/`、`src/updater.ts`、`src/launcher/`
- 这些路径直接依赖的代码：`src/app.tsx`、`src/sophon.ts`、`src/aria2.ts`、`src/downloadable-resource.ts`、`src/accidental-complexity.ts`、`src/hosts.ts`、`src/utils/`、`src/locale/index.ts`、`src/constants/`
- Sophon 服务端 `sophon_server/*.py`、`native/gamehost/`、`build-app.js`、`.github/workflows/build-ontag.yaml`

hk4e 共享代码中 os/universal 的分支不在范围内。渲染后端只有 `dxmt` 一种（`src/wine/distro.ts` 中所有发行版都是这样），所以非 dxmt 分支视为死代码。

**方法。** 采用 `code-modernization:modernize-extract-rules` 的 Method B：

1. 由 4 个 business-rules-extractor 子代理按领域并行抽取规则，四个领域是：安装/更新/修复、启动游戏、Wine 与自更新、设置。每个子代理都同时从计算、校验、生命周期三个角度检查。
2. 合并结果并去重。
3. 抽查关键规则对应的源码行。已人工复核：CN 更新断言、按大小跳过、分辨率默认值、`fr_FR`、`patched` 清理、更新源 owner、磁盘空间公式、fpsUnlock 无读取点。

源码中没有发现针对自动分析的指令式文本。

**约定。**

- `<data>` 表示数据目录 `~/Library/Application Support/Yaagl`，也就是 Neutralino 的 `NL_PATH`。代码中的 `resolve("./x")` 都指 `<data>/x`。
- `<game>` 表示游戏安装目录。
- secret 常量（定义在 `src/clients/secret.ts`，由 `configure.sh` 从 `secret.b64` 解码，worktree 中没有这个文件）只写常量名，不写值。
- 路径都相对于仓库根目录。

**规则卡字段：**

- **类别**：计算、校验、生命周期、策略四种之一。
- **优先级**：P0 表示保护用户数据、游戏文件或 prefix 的完整性，或者决定游戏能否启动；P1 是默认值；P2 表示展示或便利性规则。
- **置信度**：高、中、低。低于"高"的规则会写出需要维护者回答的问题，并标注 **待确认**。
- **疑似缺陷**：指旧版行为看起来不对的地方。原生版是保留还是修正，由 transform 阶段决定；保留与否都必须是明确的决策。

## 1. 关键发现

1. **CN 的更新和预下载在代码层面必然失败。** `sophon_server/sophon_api.py:704-708` 在 `do_update` 为真且 `rel_type=="cn"` 时执行 `assert False, "TODO"`。`perform_update` 一开始就会清除 `.tmp/*.json` 缓存（`tasks.py:156`），所以缓存也绕不过去。原生版要实现对等，必须补上 CN 的 getBuild/getPatchBuild 端点，而这个端点目前没有经过验证（UPG-004）。
2. **Sophon 的"按大小跳过"会让修复和更新留下坏文件。** `download_game_file` 发现目标文件大小与清单一致就直接跳过（`sophon_api.py:940-945`），因此有两类文件永远修不好：
   - reliable 修复能识别出"大小对、MD5 错"的文件，但修不好（REP-004）；
   - ldiff 打补丁后 MD5 不符的文件仍会被移进游戏目录（UPG-009）。
3. **任何任务出错都是致命错误。** 弹出 "Fatal error" 后应用以 -1 退出，没有回滚，也没有重试（APP-013）。
4. **切换 Wine 会无提示地 `rm -rf` 整个 wineprefix。** 以下三种情况都会触发：用户切换 Wine 版本、点"应用推荐设置"、`wine_tag` 不在内置清单中（WIN-004/006，CFG-008/031）。
5. **有若干失效设置或死数据：**
   - FPS 解锁：没有任何代码读取这个设置，DXMT 的帧率上限固定为 60；
   - Workaround #3：对 hk4ecn 不起作用；
   - `wine_update_url`、`wine_netbiosname`、`singleton`、`DEFAULT_WINE_DISTRO_URL`：只写不读；
   - 高级设置页：发行版构建时没有设置 `YAAGL_ADVANCED_ENABLE`，所以永远看不到。
6. **自定义分辨率的默认高度是 `"1920"`**（`resolution.tsx:162`）。用户只打开开关、不填数值时，分辨率是 1920×1920。
7. **安全风险：aria2 RPC 对局域网开放且没有 secret**（`--rpc-listen-all=true`、`-d /`）。另外，写 `/etc/hosts` 时用 `printf` 把整个文件内容当作格式串，原内容里的 `%` 会被解释。原生版不应沿用这两处做法。
8. **磁盘空间检查用的是压缩后的 chunk 大小。** 公式为 `ceil(GiB)×1.2`，会低估实际所需空间；更新和预下载则完全不检查（INS-004）。
9. **预下载队列和主队列可以并发**，两者会操作同一个 `.tmp` 和 `ldiff` 目录（APP-015）。
10. **崩溃路径不撤销 HDR 和分辨率注册表。** 另外，hk4e 的完整性检查不会清除 `patched` 标记，可能导致下一次启动时没有打补丁（LCH-038、REP-005）。

## 2. 规则统计

| 领域 | 前缀 | 条数 |
|---|---|---|
| 应用引导与主界面状态机 | APP | 22 |
| 游戏安装 | INS | 16 |
| 游戏更新 | UPG | 14 |
| 预下载 | PRE | 3 |
| 修复（完整性校验） | REP | 5 |
| 下载进度协议 | PRG | 6 |
| 启动游戏 | LCH | 39 |
| Wine / DXMT 管理 | WIN | 23 |
| 设置项 | CFG | 34 |
| 自更新 | UPD | 18 |
| **合计** | | **180** |

各领域之间的重复规则已经合并，合并后在原位置用"同见 X"互相引用。

## 3. 应用引导与主界面状态机（APP）

### APP-001: 应用启动顺序
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/app.tsx:41-154`、`src/index.tsx:23-52`
**说明:** 冷启动按固定顺序执行，全部完成后才显示窗口。
**规格:**
  Given 冷启动
  When 应用启动
  Then 依次执行：清除 `singleton` 键 → 注册窗口关闭处理 → 加载本地化 → 启动 aria2（APP-005） → 检查更新并等待结果（UPD-004） → 读取 `ignore_launcher_update` → checkWine（WIN-003） → 分流（WIN-005） → 渲染并显示窗口（配置中 `hidden=true`）
  And 任何一步抛出异常都按致命错误处理（APP-013）
**边界情况:** GitHub 超时会让窗口晚约 10 秒出现。`singleton` 键会被清除，但没有任何代码读取它，也没有实现单实例控制。
**置信度说明:** **待确认：**原生版是否需要真正的单实例锁？多开时，多个实例会共用 aria2 端口和 prefix。

### APP-002: 数据目录的位置与解析
**类别:** 策略　**优先级:** P0　**置信度:** 高
**来源:** `build-app.js:19-24,71-74,222-224`、`src/utils/neu.ts:4-17`
**规格:**
  Given 渠道为 hk4ecn，且没有设置 `YAAGL_TEST`
  Then 数据目录为 `$HOME/Library/Application Support/Yaagl`（设置了 `YAAGL_TEST` 时目录名加 " Test" 后缀）
  And `resolve("./wineprefix")` 返回 `<data>/wineprefix`
  And `resolve` 的结果是相对路径或 `/` 时，抛出 "Assertation failed"
**参数:** 发行名 "Yaagl"

### APP-003: 启动时把 App bundle 同步到数据目录
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `build-app.js:212-236`
**说明:** App 的入口 `parameterized` 是一段 shell 脚本。它以 bundle 内 `resources.neu` 的 md5 作为戳，决定只做增量同步还是全量覆盖。
**规格:**
  Given `<data>/.bundle-stamp` 等于 md5(`Contents/Resources/resources.neu`)
  When 启动 App
  Then 执行 `rsync -rlptu Contents/Resources/. "$APST_DIR"`，自更新写进数据目录的较新文件得以保留
  Given 戳不同或不存在（首次运行，或拖入了新版 DMG）
  Then 执行不带 `-u` 的 `rsync -rlpt`，用 bundle 覆盖数据目录，然后写入新戳
  And 最后执行 `cd "$APST_DIR"; PATH_LAUNCH=<.app 路径> exec Yaagl --path="$APST_DIR"`
**边界情况:** rsync 不带 `--delete`，数据目录里的旧文件会一直保留。安装一个更旧的 DMG 同样会全量覆盖，相当于降级。

### APP-004: 部分路径依赖进程当前目录
**类别:** 校验　**优先级:** P1　**置信度:** 高
**来源:** `src/updater.ts:112-132`、`src/utils/neu.ts:206-208`、`src/utils/unix.ts:47-49`
**规格:**
  Given 自更新执行 `rm -rf ./sidecar` 和 tar 解压
  Then 这些路径都是相对路径，没有经过 `resolve`，因此依赖进程的 cwd 等于 `<data>`（由 APP-003 中的 `cd` 保证）
**疑似缺陷:** cwd 不同时（例如开发模式），会删除或写入错误的目录。原生版必须一律使用绝对路径。

### APP-005: aria2 下载服务启动
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/app.tsx:44-95`、`src/aria2.ts:4-16,77-91`
**规格:**
  When 应用启动
  Then 执行 `./sidecar/aria2/aria2c -d / --no-conf --enable-rpc --rpc-listen-port=6868 --rpc-listen-all=true --rpc-allow-origin-all --input-file <data>/aria2.session --save-session <同一文件> --pause true --stop-with-process <PPID>`
  And 最多重试 30 次，每次先等待 500 ms，`getVersion` 超时 3 s；总计 15 s 仍未成功就抛出 "Failed to start download service. Please restart the application."
  And 注册终止钩子 `kill <aria2 pid>`
**疑似缺陷（安全）:** RPC 监听所有地址、允许任意来源、没有设置 secret，且下载目录为 `/`。局域网内任何主机都可以通过它向任意路径写文件。原生版改用 URLSession，不再需要这个服务。

### APP-006: aria2 下载任务的去重与续传
**类别:** 计算　**优先级:** P1　**置信度:** 中
**来源:** `src/aria2.ts:22-64`、`src/utils/helper.ts:26-35`
**规格:**
  Given `doStreamingDownload({uri:U, absDst:D})`
  Then gid 取 `hex(sha256("U:D"))` 的前 16 个字符
  And 任务状态为 complete 时直接返回，**不检查文件是否还在**；为 paused 时调用 unpause；任务不存在时调用 addUri，参数为 `max-connection-per-server=16, out=D, continue=false, allow-overwrite=true`
  And 每 100 ms 轮询一次，产出 completedLength、totalLength、downloadSpeed
  And 状态为 error 或 removed 时抛出 "FIXME: implmenet me"，结果是致命退出
**疑似缺陷:** 任务进入 error 状态后无法恢复，用户每次启动都会失败，只能手动删除 `aria2.session`。totalLength 为 0 时轮询前没有等待，会密集调用 RPC。
**置信度说明:** **待确认：**`--pause true` 是否对 addUri 新建的任务生效？从实际使用看大概率不生效。

### APP-007: Sophon 服务进程的启动与生命周期
**类别:** 生命周期　**优先级:** P1　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/index.tsx:84-96`、`src/sophon.ts:57-70,207-234`、`sophon_server/server.py:32-42,97-102,121-137`
**规格:**
  When 创建 hk4ecn 客户端
  Then 端口取 `floor(random×25535)+40000`，带环境变量 `TERMINATE_WITH_PID=<父 PID>`、`SOPHON_PORT`、`SOPHON_HOST=127.0.0.1` 启动 `./sidecar/sophon_server/sophon-server`
  And 最多 `GET /health` 10 次，间隔 3 s；返回 200 且响应体是合法 JSON 才算成功。总超时 30 s，超时报 "Fail to launch sophon."
  And 服务端每秒检查一次父进程，父进程不在时对自己发 SIGKILL
**边界情况:** 不检测端口冲突。服务端全局关闭了 SSL 校验（`server.py:14`）。被硬杀时可能留下写了一半的文件。原生版计划用 Swift 在进程内重写 Sophon，这一节描述的进程模型将不再存在。

### APP-008: 在线游戏信息
**类别:** 计算　**优先级:** P0　**置信度:** 高
**来源:** `src/sophon.ts:190-204`、`src/clients/mhy/hk4e/index.tsx:98-104`、`sophon_server/tasks.py:181-238`
**规格:**
  When 调用 `GET /api/game/online_info?game=hk4e&reltype=cn`
  Then 先读 main 分支，得到：`version = main.tag`；`updatable_versions = main.diff_tags`；`install_size = 游戏 manifest 中所有 chunk 的 compressed_size 之和`
  And 再读 pre_download 分支：分支存在时，`pre_download=true`，`pre_download_version=tag`；分支为 null 时，两者分别为 `false` 和 `"0.0.0"`
  And 客户端据此设置 LATEST、UPDATABLE、PRE_DOWNLOAD_VERSION（为空时用 `"0.0.0"`）、PRE_DOWNLOAD_AVAILABLE、INSTALL_SIZE
**参数:** 临时目录 `./sidecar/sophon_server/gametemp`
**边界情况:** 只在启动时查询一次，之后服务端变化不会刷新。

### APP-009: CN 的 HoYoPlay / Sophon 接口端点
**类别:** 策略　**优先级:** P0　**置信度:** 高
**来源:** `sophon_server/sophon_api.py:621-676,693-725,747-805`
**规格:**
  Given rel_type 为 cn，游戏为 hk4e
  Then 分支信息请求：`GET https://hyp-api.mihoyo.com/hyp/hyp-connect/api/getGameBranches?game_ids[]=1Z8W5NHUQb&launcher_id=jGHBHlcOq1`；retcode≠0 时报错；取 `data.game_branches[0][main|pre_download]`
  And 安装和修复时请求 `GET https://api-takumi.mihoyo.com/downloader/sophon_chunk/api/getBuild?branch=…&package_id=…&password=…`
  And 在 `data.manifests` 中按 `matching_field=="game"` 精确匹配。匹配不到时退而用子串模糊匹配，匹配到多个就报错
  And 下载 `manifest_download.url_prefix + "/" + manifest.id`，用 zstd 解压后，按 protobuf `Manifest` 或 `DiffManifest` 解析
**参数:** launcher_id 和 game_id 是公开标识（来源注明 Snap.Hutao，MIT）。`password` 由接口动态返回，原生版不应持久化，也不应写进日志。
**边界情况:** CN 的更新端点见 UPG-004。

### APP-010: 在线信息查询失败
**类别:** 校验　**优先级:** P1　**置信度:** 中
**来源:** `sophon_server/tasks.py:241-250`、`src/clients/mhy/hk4e/index.tsx:100-104,135`
**规格:**
  Given 网络不可用
  When 查询在线信息
  Then 服务端仍返回 HTTP 200，内容为 `{version:"", updatable_versions:[], pre_download:false, error:"…"}`
  And 客户端不检查 `error` 字段，LATEST 被设为 ""；之后计算 `updateRequired()`，即 `lt(x,"")` 时，semver 会抛出 "Invalid Version"
**置信度说明:** **待确认：**离线时应该允许启动已安装的游戏，还是阻止启动器启动？

### APP-011: 本地安装状态判定
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/index.tsx:108-115,345-365`
**规格:**
  Given `game_install_dir` 键存在，且 `<dir>/<CN_DATA_DIR>/globalgamemanagers` 能读出版本
  Then 状态为 INSTALLED
  And 键不存在，或读版本时抛出异常，则状态为 NOT_INSTALLED（键本身不删除）
**边界情况:** 用户移走游戏目录后，界面显示"安装游戏"，旧键要等下次安装成功才被覆盖。

### APP-012: 从 globalgamemanagers 读取游戏版本
**类别:** 计算　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/unity.ts:4-23`、`src/clients/mhy/hk4e/index.tsx:335-343`
**规格:**
  Given 文件中模式串 `ic.app-category.`（十六进制 `69 63 2e 61 70 70 2d 63 61 74 65 67 6f 72 79 2e`）首次出现的位置为 I
  When 读版本
  Then 在 I+0xAC 处读一个小端 uint32 作为长度 L，再读 L 个字节作为字符串，取第一个 `_` 之前的部分（例：`5.5.0_31234567_31456789` 得到 `5.5.0`）
  And 0xAC 处读取失败，或结果不能被 SemVer 解析时，改从偏移 0x88 读（这次不做 SemVer 校验）
  And 找不到模式串时抛出 "pattern not found"
**边界情况:** Sophon 用另一种方式判定版本（UPG-005），两者的结果可能不一致。

### APP-013: 任务队列串行执行，出错即致命
**类别:** 策略　**优先级:** P0　**置信度:** 中
**来源:** `src/launcher/task-queue.ts:6-41`、`src/utils/neu.ts:174-182,371-375`、`src/index.tsx:30-52`
**规格:**
  Given 一条队列同一时刻只执行一个任务
  When 任务抛出异常（包括 Sophon 返回 error）
  Then 弹出系统对话框 "Fatal error / Error: …"，依次执行终止钩子（例如杀掉 aria2），然后以退出码 -1 退出；此后队列不再接受任务
  And 任务正常结束时 busy 置为 false
**置信度说明:** **待确认：**原生版是保留"出错即退出"，还是改为出错后回到空闲状态、允许重试？后者属于行为变更，需要明确决策。

### APP-014: 版本不可读时告警
**类别:** 校验　**优先级:** P1　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/index.tsx:128-133`
**规格:**
  Given 游戏已安装，但读出的版本不是合法的 semver
  Then 弹出 GAME_VERSION_INVALID / GAME_VERSION_UNREADABLE，内部版本按 `"0.0.0"` 处理
  And 因此主按钮显示"更新"；点击更新会走到 UPG-001，状态被重置为"未安装"
**边界情况:** PRE-001 在比较版本时用的是原始的非法字符串，如果正好有预下载，可能抛出异常。

### APP-015: 预下载队列与主队列可以并发
**类别:** 策略　**优先级:** P0　**置信度:** 中
**来源:** `src/launcher/index.tsx:105-126,296-302`
**规格:**
  Given 预下载在独立的 nonUrgent 队列中运行
  When 用户点击启动、更新或校验完整性
  Then 主队列立即开始执行，与预下载同时操作 `<game>/.tmp` 和 `<game>/ldiff`
**疑似缺陷:** `perform_update` 和 `perform_repair` 开始时都会清除 `.tmp` 中的缓存文件，可能删掉另一个任务正在使用的文件。
**置信度说明:** **待确认：**预下载期间是否应禁止更新、修复和启动？

### APP-016: 是否需要更新
**类别:** 计算　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/index.tsx:135`
**规格:**
  Given 当前版本为 5.5.0，最新版本为 5.6.0
  Then `updateRequired = semver.lt(current, latest) = true`
  And 当前版本等于或高于最新版本时为 false，允许直接启动

### APP-017: 主按钮的文案与动作
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/launcher/index.tsx:93-97,132-145,265-275`
**规格:**
  Given 未安装
  Then 按钮显示 INSTALL；点击后弹出目录选择（INS-001），选好后将 install(dir) 加入主队列，取消则不做任何事
  Given 已安装且需要更新
  Then 按钮显示 UPDATE，点击执行 update
  Given 已安装且不需要更新
  Then 按钮显示 LAUNCH，点击执行 `launch(config)`（config 是共享的可变对象，设置改动会立即生效）
  And 主队列忙时按钮禁用，点击被忽略
**边界情况:** 没有"修复"主按钮，修复的入口见 REP-001。

### APP-018: 设置按钮的可见性
**类别:** 校验　**优先级:** P1　**置信度:** 高
**来源:** `src/launcher/index.tsx:276-284,308-318`、`src/app.tsx:131-155`
**规格:**
  Given 未安装
  Then 不显示设置按钮，因此 Wine 版本、代理等设置都无法修改
  Given 已安装且主队列忙（包括游戏运行期间）
  Then 设置按钮禁用
  Given Wine 未就绪
  Then 显示 Wine 安装流程，此时不会创建设置页
**边界情况:** 按钮状态只看主队列；预下载进行中时设置按钮仍可点击。

### APP-019: 启动器启动时还原残留补丁（init）
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/launcher/index.tsx:108`、`src/clients/mhy/hk4e/index.tsx:290-304`、`src/clients/mhy/patch.ts:127-175`
**规格:**
  Given 存储中有 `patched="1"`（上次游戏运行期间启动器被强制退出）
  When 启动器启动，主队列执行第一个任务 init
  Then 执行 patchRevertProgram（LCH-039、WIN-021）
  And 如果还原抛出异常，改为执行 checkIntegrityProgram（REP-003）
  Given 没有 `patched` 键
  Then 不做任何事
**疑似缺陷:** 见 REP-005：hk4e 的完整性检查不会清除 `patched`。

### APP-020: YAAGL_AUTOLAUNCH 自动启动
**类别:** 策略　**优先级:** P2　**置信度:** 高
**来源:** `src/launcher/index.tsx:87-91,109-119`
**规格:**
  Given 用 `open --env YAAGL_AUTOLAUNCH=1` 启动应用，且游戏已安装、不需要更新
  When init 完成
  Then 自动执行 launch(config)，游戏结束后执行终止钩子并 `exit(0)`
  And 未安装或需要更新时，记录日志 "YAAGL_AUTOLAUNCH: game not ready, skipped"
  And 只有值严格等于 "1" 时才生效
**边界情况:** `scripts/dev/yaagl-diag` 依赖这个钩子，原生版需要保留等价的能力。

### APP-021: 启动器背景资源
**类别:** 计算　**优先级:** P2　**置信度:** 高
**来源:** `src/clients/mhy/hyp-connect.ts:22-49`、`src/clients/mhy/hk4e/index.tsx:74-82,106,141-146`
**规格:**
  When 请求 `CN_ADV_URL&language=<CONTENT_LANG_ID>`（通过 curl）
  Then 找到 `biz=="hk4e_cn"` 的条目，在其 backgrounds 中优先选 VIDEO 类型，得到 background（静态图）、background_video、background_theme、图标链接
  And 等背景图加载完成后才继续初始化；找不到对应游戏或 backgrounds 为空时，报错 "failed to fetch game information: hk4e_cn"
**边界情况:** 代码中有 `server.id=="CN"` 时固定使用 zh-cn 的判断，但 hk4ecn 的 id 是 "hk4e_cn"，这个分支永远不会命中，实际使用的是界面语言。背景加载失败会导致客户端创建失败。

### APP-022: 窗口关闭与终止钩子
**类别:** 生命周期　**优先级:** P1　**置信度:** 高
**来源:** `src/app.tsx:46-50,75-84`、`src/utils/neu.ts:348-375`
**规格:**
  When 用户关闭窗口
  Then 倒序执行已注册的钩子；任一钩子返回 false 就中止关闭；全部通过后 `exit(0)`
**疑似缺陷:** `hooks.reverse()` 直接修改原数组，每调用一次顺序就翻转一次。有多个钩子时，执行顺序不稳定。

## 4. 游戏安装（INS）

### INS-001: 安装目录选择的校验
**类别:** 校验　**优先级:** P0　**置信度:** 高
**来源:** `src/accidental-complexity.ts:14-41`、`src/launcher/index.tsx:93-97`
**规格:**
  Given HOME 为 `/Users/a`
  When 用户选择 `/Users/a/Downloads/Genshin`
  Then 提示 PATH_INVALID / PATH_INVALID_FORBIDDEN_DIR，并重新弹出选择框
  When 用户选择 `/Volumes/游戏/Genshin`
  Then 提示 PATH_INVALID_ASCII_ONLY，并重新弹出选择框
  When 用户选择非绝对路径
  Then 拒绝
  When 用户取消选择框
  Then 返回 ""，不做任何事
  And 选中的目录本身就是游戏根目录，不会再建子目录
**参数:** 禁止的目录为 Desktop、Downloads、Documents；判断方式是看 `segments[2]` 是否为其中之一，即只看 HOME 下的第一级目录。ASCII 判断用 `^[\x00-\x7F]*$`。
**边界情况:**
- 只拦截 HOME 下的第一级目录：`/Users/a/x/Desktop` 可以通过。
- 前缀判断用的是 `startsWith(HOME)`，所以 `/Users/alicebob/...` 也会命中 HOME 为 `/Users/alice` 的规则。
- 同见 CFG-010。

### INS-002: 判定"已有安装"还是"全新安装"
**类别:** 校验　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/index.tsx:152-155,182-184`
**规格:**
  Given 所选目录下有 `pkg_version`
  Then 不下载，改为读取 `globalgamemanagers` 的版本，然后进入 INS-012、INS-013、INS-014 三个分支之一
  Given 所选目录下没有 `pkg_version`
  Then 先做磁盘空间检查（INS-004），再全新安装（INS-003）
**边界情况:**
- 有 `pkg_version` 但缺少 globalgamemanagers 时，读版本会抛异常，导致致命错误。
- 这里只把 `pkg_version` 当作"已有安装"的标记，不读它的内容。hk4ecn 路径中完全不使用 `deletefiles.txt` 和 `hdifffiles.txt`。

### INS-003: 全新安装主流程（TS 侧）
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/index.tsx:168-180`、`src/clients/mhy/hk4e/program-install-game.ts:7-54`
**规格:**
  When 调用 `POST /api/install {gamedir, game_type:"hk4e", install_reltype:"cn"}`
  Then 收到 job_start 时，状态文本为 ALLOCATING_FILE，进度条为不确定态
  And 收到 chunk_progress 时，状态文本为 DOWNLOADING_FILE_PROGRESS，进度取 `overall_percent`
  And 收到 job_end 后，状态置为 INSTALLED，版本直接设为 LATEST（不重新读取），并写入 `game_install_dir`
  And 安装失败时不写 `game_install_dir`

### INS-004: 全新安装前的磁盘空间检查
**类别:** 计算　**优先级:** P0　**置信度:** 高（公式）/ 中（低估的程度）
**来源:** `src/clients/mhy/hk4e/index.tsx:156-166`、`src/utils/unix.ts:201-216`
**规格:**
  Given INSTALL_SIZE 为 72 GiB，`df -g` 显示可用 80
  Then 所需空间 = `ceil(72)×1.2 = 86.39999999999999`；80 < 86.4，弹出 NO_ENOUGH_DISKSPACE，参数为 `[required+"", (required×1.074).toFixed(1)]`，安装中止
  And 可用空间 ≥ 所需空间时继续安装
**疑似缺陷:**
1. INSTALL_SIZE 是 **压缩后** 的 chunk 大小之和，会低估实际需要的空间。
2. 浮点结果直接拼成字符串，显示出来不好看。
3. 更新和预下载都 **不做** 空间检查。

**置信度说明:** **待确认：**原生版是否改为"解压后大小 + chunk 临时空间"？

### INS-005: Sophon 安装的前置条件与 config.ini 模板
**类别:** 校验　**优先级:** P0　**置信度:** 高
**来源:** `sophon_server/tasks.py:30-48`、`sophon_server/sophon_api.py:334-396`
**规格:**
  Given 目标目录中已有至少 2 个条目（按 `glob("*")` 计数，`.tmp` 和 config.ini 都算）
  Then 断言失败，报 "The specified install path is not empty"，导致致命错误
  Given 目标目录中少于 2 个条目
  Then 用 CN 模板 **覆盖写入** config.ini：`[General]\r\nchannel=1\r\ncps=mihoyo\r\ngame_version=0.0.0\r\nsdk_version=\r\nsub_channel=1\r\n`，然后创建 `<game>/.tmp`
**边界情况:** TS 侧不预先检查目录是否为空，用户选了非空目录只会得到一个致命错误。

### INS-006: config.ini 中 game_version 的两次写入
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `sophon_server/tasks.py:10-18,50-51,104-105`、`sophon_server/sophon_api.py:1028-1081`
**规格:**
  When 读取 manifest 之后、开始下载之前
  Then 把 `game_version=0.0.0` 替换为目标 tag。正则 `game_version=(\d+\.\d+\.\d+)` 必须恰好匹配 1 次，否则报 "Invalid config.ini format"
  When 全部下载完成
  Then 对每个 flags≠64 的文件比较大小，不一致就报 "File missing or invalid size: X"；全部一致后再写一次 game_version
**边界情况:** 替换用的是 `contents.replace(旧, 新)`，会替换所有相同的子串。快速校验只比大小，不比 MD5。

### INS-007: 下载顺序与并发
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `sophon_server/tasks.py:77-102`、`sophon_server/sophon_api.py:107-108`
**规格:**
  Given 每个文件的排序键：文件名含 `globalgamemanagers` 或 `pkg_version` 时 −1，含 `/` 时 +1
  Then 按排序键升序提交到 `ThreadPoolExecutor(max_workers=8)`；排序是稳定的
  And 任意一个 future 抛出异常，整个任务失败
**边界情况:** 先下载 pkg_version 和 globalgamemanagers，是为了中断后这个目录能被识别为"已有安装"（INS-015）。

### INS-008: 单个文件的 chunk 下载、组装与校验
**类别:** 计算　**优先级:** P0　**置信度:** 高
**来源:** `sophon_server/sophon_api.py:914-1025`、`sophon_server/manifest.proto:9-25`
**规格:**
  Given 一个 FileInfo：`{filename, flags, size, md5, chunks[{chunk_id, offset, compressed_size}]}`
  Then flags 为 64（目录）时跳过；flags 既不是 0 也不是 64 时断言失败
  And 游戏目录中已有同名文件且 **大小等于 size** 时跳过，**不校验 MD5**（这一点影响 REP-004 和 UPG-009）
  And 否则下载 `chunk_download.url_prefix/<chunk_id>` 到 `.tmp/<chunk_id>`，zstd 解压后按 offset 写入 `.tmp/<basename>`
  And 整个文件的 MD5 一致时，删除 chunk 文件，`mkdir -p` 后移动到 `<game>/<filename>`
  And MD5 不一致时，删除组装文件并报 "File is corrupt after download"
**疑似缺陷:** 组装文件只用 basename 命名。8 个线程并发时，不同目录下的同名文件会互相覆盖；共享同一个 chunk_id 的文件，可能读到已被另一个线程删掉的 chunk。
**置信度说明:** **待确认：**原神的 manifest 中是否存在同名但目录不同的文件？

### INS-009: chunk 和 ldiff 的断点续传
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `sophon_server/sophon_api.py:866-912`
**规格:**
  Given 本地已有部分文件
  Then 发送 `Range: <已有大小>-` 并追加写入；本地大小等于期望值时直接返回；大于期望值时删除后重新下载；收到 HTTP 416 视为已经完成
**疑似缺陷:**
- 出错后 `sleep(10)` 就返回，实际上并不重试。
- 除 416 外不检查 HTTP 状态码，404 或 5xx 的响应体会被追加进 chunk 文件。
- 整个 chunk 会先读进内存。

### INS-010: 文件级重试
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `sophon_server/tasks.py:61-75`、`sophon_server/sophon_api.py:1404-1418`
**规格:**
  Given 某个文件连续 5 次抛出异常
  Then 整个任务失败，错误文案写的是 "failed after 3 attempts"，但实际重试了 5 次
**疑似缺陷:** 更新时下载新文件的路径（`:1418`）写成了 `raise Exception(...)["pkg_version",""]`，并且用了不存在的 `v.name`，结果抛出 TypeError，原始错误信息丢失。用户取消时也会重试 5 次。

### INS-011: 文件路径安全校验
**类别:** 校验　**优先级:** P0　**置信度:** 高
**来源:** `sophon_server/sophon_api.py:202-208`
**规格:**
  Given manifest 中的文件名包含 `..` 或以 `/` 开头
  Then 断言失败，报 "Security alert!"，任务失败
  And 安装下载、ldiff 下载与应用、删除文件这几个环节都会做这个检查

### INS-012: 选中已有目录：旧版本，可以增量更新
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/index.tsx:182-209`
**规格:**
  Given 读出的版本为 5.5.0，最新版本为 5.6.0，UPDATABLE 包含 5.5.0
  Then 直接登记为已安装（INSTALLED），版本记为 5.5.0，写入 `game_install_dir`；主按钮变为"更新"
**边界情况:** 不做完整性校验（代码中有 FIXME 注释）。

### INS-013: 选中已有目录：版本太旧
**类别:** 校验　**优先级:** P1　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/index.tsx:193-202`
**规格:**
  Given 读出的版本为 4.8.0，且不在 UPDATABLE 中
  Then 弹出 UNSUPPORTED_VERSION 提示后返回，状态和存储都不变（prompt 的返回值被忽略）

### INS-014: 选中已有目录：已是最新版
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/index.tsx:210-222`
**规格:**
  Given 读出的版本 ≥ 最新版本
  Then 先执行 checkIntegrityProgram（REP-003），完成后登记为已安装，并写入 `game_install_dir`
**边界情况:** 读出的版本 **高于** 最新版本时，Sophon 修复会因为"版本不等于最新"而中止（REP-002），导致致命错误。

### INS-015: 安装中断后的恢复
**类别:** 生命周期　**优先级:** P0　**置信度:** 中
**来源:** `src/clients/mhy/hk4e/index.tsx:153-155,179`、`sophon_server/tasks.py:51,77-91`、`sophon_server/sophon_api.py:378,940-945`
**规格:**
  Given 中断时 pkg_version 和 globalgamemanagers 已经下载完成，config.ini 已写为新版本
  When 用户再次选择同一个目录安装
  Then 走 INS-014，用修复补齐缺失的文件
  Given 中断发生在下载 pkg_version 之前
  Then Sophon 断言目录非空，无法恢复，只能手动清空目录
**置信度说明:** **待确认：**原生版是否要显式支持"续装"？

### INS-016: Sophon 接口缓存与清理
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `sophon_server/sophon_api.py:574-608`、`sophon_server/tasks.py:20-28,127,156`
**规格:**
  Given `.tmp/getGameBranches.json` 是 24 小时内写入的
  When 执行安装
  Then 直接复用缓存
  When 执行修复或更新
  Then 先删除 `.tmp/*.json` 和 `.tmp/*.zstd`，再重新请求
**边界情况:**
- `.tmp` 和 `ldiff` 目录永远不会被自动删除。
- `cleanup_temp` 中写的是 `assert False`，属于死代码。
- 服务端开启了 `EXPORT_JSON_FILES`，会把 manifest 导出成 JSON 存进 tempdir。

## 5. 游戏更新（UPG）

### UPG-001: 更新资格
**类别:** 校验　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/index.tsx:232-247`
**规格:**
  Given 当前版本不在 UPDATABLE 中（判断方式是精确字符串 `includes`）
  When 用户点击更新
  Then 弹出 UNSUPPORTED_VERSION；状态置为 NOT_INSTALLED，installDir 置为 ""，版本置为 "0.0.0"，删除 `game_install_dir`
  And **不删除任何游戏文件**

### UPG-002: 3.6.0 及以上版本的音频目录迁移
**类别:** 生命周期　**优先级:** P1　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/program-update-game.ts:91-136`
**规格:**
  Given 目标版本 ≥ 3.6.0，且存在 `<game>/<dataDir>/StreamingAssets/Audio/GeneratedSoundBanks/Windows`
  When 开始更新（状态文本为 UPDATING）
  Then 执行 `mkdir -p …/StreamingAssets/AudioAssets`、`/bin/cp -R -f <旧目录>/. <AudioAssets>`，然后 `rm -rf <旧目录>`
  And 旧目录不存在时跳过

### UPG-003: 更新请求与 Sophon 的处理顺序
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/program-update-game.ts:10-28`、`sophon_server/tasks.py:142-179`
**规格:**
  When 发送 `POST /api/update {gamedir, game_type:"hk4e", tempdir:"<game>/.tmp", predownload:false}`
  Then Sophon 依次执行：
  1. 清除缓存
  2. 判定版本（UPG-005）
  3. 读取 main 分支
  4. load_manifest（请求 getBuild 和 getPatchBuild）
  5. 删除旧文件（UPG-007）
  6. 下载并应用 ldiff（UPG-008、UPG-009）
  7. 下载新文件（UPG-010）
  8. 重新加载 manifest
  9. 校验并写入 config.ini（UPG-011）
  10. 删除 ldiff（UPG-012）
  11. 发送 job_end

### UPG-004: CN 的更新和预下载请求必然失败
**类别:** 校验　**优先级:** P0　**置信度:** 高
**来源:** `sophon_server/sophon_api.py:693-725`、`sophon_server/tasks.py:20-28,146-161`
**规格:**
  Given 是 CN 安装（有 YuanShen.exe，没有 PCGameSDK.dll），且 do_update 为 True
  When load_manifest 需要请求 getBuild 或 getPatchBuild（此时缓存已在第一步被清除）
  Then 抛出 `AssertionError("TODO")`，前端收到 error 事件，导致致命错误
  And 预下载同样会失败
**参数:** OS 渠道的更新域名是 `sg-downloader-api.hoyoverse.com`，CN 没有对应的域名。
**疑似缺陷:** 旧版在 CN 上没有可用的 Sophon 更新和预下载实现。原生版要做到对等，必须补上 CN 的端点。
**置信度说明:** **待确认：**
- 维护者是否在 CN 上实际完成过 Sophon 更新或预下载？如果完成过，是靠什么绕过的？
- CN 的 getBuild 和 getPatchBuild 正确地址是什么？推测是 `downloader-api.mihoyo.com` 一类，未经验证。

### UPG-005: Sophon 判定发行类型与已安装版本
**类别:** 计算　**优先级:** P0　**置信度:** 高
**来源:** `sophon_server/sophon_api.py:213-223,399-484`
**规格:**
  Given 存在 YuanShen.exe，且 `<*_Data>/Plugins/PCGameSDK.dll` 不存在
  Then 判定为 cn。存在 GenshinImpact.exe 判定为 os；YuanShen.exe 和 PCGameSDK.dll 都存在判定为 bb；以上都不满足就报错
  And 在 globalgamemanagers 中用正则 `\0(\d+\.\d+\.\d+)_\d+_\d+\0` 匹配，必须 **恰好匹配 1 次**，否则报 "Broken script or corrupted game installation"
  And 再与 config.ini 中的 game_version 比较，取较小值作为已安装版本。例如 config.ini 是 5.5.0、globalgamemanagers 是 5.6.0，则已安装版本为 5.5.0。config.ini 缺失或格式异常时只告警
**边界情况:** TS 侧读版本用的是固定偏移（APP-012），与这里的正则方式可能得出不同结果。

### UPG-006: 没有可用更新时报错
**类别:** 校验　**优先级:** P1　**置信度:** 高
**来源:** `sophon_server/sophon_api.py:808-820`
**规格:**
  Given 已安装版本等于目标分支的 tag
  Then 报 "There is no update available."，任务失败

### UPG-007: 删除旧文件（files_delete）
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `sophon_server/sophon_api.py:1341-1375`、`sophon_server/manifest_ldiff.proto:49-61`
**规格:**
  Given `DiffManifest.files_delete` 中 key 等于已安装版本的那份列表
  When 执行非预下载的更新
  Then 先发送 delete_file_summary；然后逐个文件做路径校验，文件存在就删除并发送 delete_file 事件，不存在就跳过
  And 预下载时禁止执行这一步（有断言）
**边界情况:** 删除发生在下载 ldiff 之前。如果之后下载失败，游戏目录会处于"旧文件已删、新文件还没到"的状态。

### UPG-008: 单个文件的 ldiff 下载决策
**类别:** 计算　**优先级:** P0　**置信度:** 高
**来源:** `sophon_server/sophon_api.py:1084-1202`
**规格:**
  Given 一个 DiffFileInfo：`{filename, size:S_new, hash:H_new, patches[{key, info{patch_id:P, patch_size:Z, original_size:S_old, patch_offset, patch_length}}]}`，以及已安装版本 V
  Then 按以下规则处理：

| 条件 | 处理 |
|---|---|
| patches 为空 | 加入新文件列表（no file） |
| patches 中没有 key 为 V 的补丁 | 跳过（not modified） |
| 本地文件大小等于 S_old | 下载补丁 |
| 本地文件大小等于 S_new 且 MD5 等于 H_new | 跳过（already updated） |
| 本地文件不存在 | 加入新文件列表（file missing） |
| 其他情况 | 加入新文件列表（file corrupt） |

  And 补丁下载：`<game>/ldiff/P` 已存在且大小等于 Z 时直接复用（already present，不校验哈希）；否则续传到 `<game>/ldiff/P_tmp`，大小必须等于 Z，然后改名为 P

### UPG-009: 应用 ldiff（hpatchz）
**类别:** 计算　**优先级:** P0　**置信度:** 高
**来源:** `sophon_server/sophon_api.py:225-281,1205-1336`
**规格:**
  When 应用补丁
  Then 从补丁文件中截出 `[offset, offset+length)` 写入临时文件，执行 `hpatchz -f <old> <seg> <.tmp/basename>`，超时 50 s；超时后再试一次，超时 300 s
  And 退出码不为 0 或 stderr 非空时，删除输出文件，任务失败
  And 输出文件大小必须等于 S_new；MD5 不等于 H_new 时发送 ldiff_patch_error，并把该文件加入新文件列表
  And **不论 MD5 是否通过**，都用输出文件覆盖原文件
  And 补丁逐个下载、逐个应用（单线程）；预下载只下载，不应用
**疑似缺陷:**
- MD5 错误的文件大小是对的，后续的下载步骤会因为大小一致而跳过它（INS-008），快速校验也只比大小，结果是损坏的文件被保留。
- 第二次超时时，`stat()` 会因为输出文件已被删除而抛异常。

### UPG-010: 下载新增文件和需要整体替换的文件
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `sophon_server/sophon_api.py:852-863,1378-1427`
**规格:**
  When 执行非预下载的更新
  Then 先发送 download_summary，然后对新文件列表中的每个文件，按 chunk manifest 执行 INS-008，8 线程并发，每个文件最多 5 次
  When 执行预下载
  Then 不下载，直接清空新文件列表（这部分要等正式更新时才下载）

### UPG-011: 更新后的快速校验与写入 config.ini
**类别:** 校验　**优先级:** P0　**置信度:** 高
**来源:** `sophon_server/sophon_api.py:1028-1081`、`sophon_server/tasks.py:169-172`
**规格:**
  Then `DiffManifest.files` 中每个文件的大小都必须等于 size，否则报 "File missing or invalid size: F"
  And `files_delete[V]` 中如果仍有文件存在，报 "Old file still exists: F"
  And 全部通过后，把 config.ini 的 game_version 写成新版本；正则匹配不是恰好 1 次时，只告警并 **跳过写入**
**边界情况:** config.ini 是"更新已完成"的最终标志，UPG-005 取较小版本的做法依赖这一点。

### UPG-012: 清理 ldiff
**类别:** 生命周期　**优先级:** P1　**置信度:** 高
**来源:** `sophon_server/sophon_api.py:1430-1465`
**规格:**
  When 非预下载的更新收尾
  Then 删除本次用到的 `<game>/ldiff/<P>`，每删一个发送一次 delete_ldiff_file；`ldiff` 目录本身保留
**边界情况:** 不在本次清单中的旧补丁（例如上一次预下载失败时留下的）会一直保留。

### UPG-013: 更新完成后启动器侧的状态
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/index.tsx:248-256`、`src/clients/mhy/hk4e/program-update-game.ts:138-140`
**规格:**
  When 收到 job_end
  Then 删除 `predownloaded_all`；版本直接设为 LATEST（不重新读取）；主按钮变为"启动"

### UPG-014: 更新和修复的处理范围
**类别:** 策略　**优先级:** P1　**置信度:** 中
**来源:** `sophon_server/tasks.py:133,161`、`sophon_server/sophon_api.py:487-550,808-830`
**规格:**
  Then 只处理 matching_field 为 `"game"` 的内容；语音包不安装、不更新、不修复；不删除 manifest 之外的多余文件；修复不修改 config.ini
**边界情况:** `get_voiceover_packs` 和 `update_voiceover_meta_file` 两个函数存在，但从未被调用。
**置信度说明:** **待确认：**原生版是否需要管理语音包？

## 6. 预下载（PRE）

### PRE-001: 何时显示预下载提示
**类别:** 校验　**优先级:** P1　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/index.tsx:116-123,149-151`、`src/launcher/index.tsx:252-257`
**规格:**
  Given 同时满足以下四个条件：pre_download 为 true；没有 `predownloaded_all`；游戏已安装；`semver.gt(pre_version, 本地版本)`
  When 启动器启动
  Then 在主按钮上方显示预下载提示；设置窗口打开时隐藏
  And 用户点击关闭或点击提示外部时，提示消失，但 **只在本次会话内有效**
**边界情况:** `predownloaded_all` 不区分版本。如果预下载了 5.7 但没有更新，等到 5.8 开放预下载时也不会再提示。

### PRE-002: 执行预下载
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/index.tsx:224-231`、`src/clients/mhy/hk4e/program-update-game.ts:143-200`、`sophon_server/tasks.py:163-172`
**规格:**
  When 用户点击预下载提示
  Then 提示立即隐藏；PRE_DOWNLOAD_AVAILABLE 为 false 时直接返回
  And 发送 `POST /api/update {…, predownload:true}`，这个任务在 nonUrgent 队列中执行
  And Sophon 只把 ldiff 下载到 `<game>/ldiff`：不删除文件、不应用补丁、不下载新文件、不修改 config.ini、不删除 ldiff
  And 完成后写入 `predownloaded_all="true"`；正式更新时复用这些 ldiff（UPG-008）
**边界情况:** 在 CN 上会因 UPG-004 失败。

### PRE-003: 预下载版本的显示
**类别:** 计算　**优先级:** P2　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/index.tsx:147-148`、`src/launcher/index.tsx:303`
**规格:** 开放预下载时，按钮文本为 PREDOWNLOAD_READY(version)，例如"预载5.7.0版本"；未开放时为空串。

## 7. 修复 / 完整性校验（REP）

### REP-001: 修复的入口
**类别:** 生命周期　**优先级:** P1　**置信度:** 高
**来源:** `src/config/index.tsx:172-176`、`src/launcher/index.tsx:308-317`、`src/clients/mhy/hk4e/index.tsx:284-289`
**规格:**
  When 用户在设置中点击"快捷操作 → SETTING_CHECK_INTEGRITY"
  Then 关闭设置窗口，主队列执行 checkIntegrityProgram
  And 另外有两个自动入口：APP-019（补丁还原失败时）和 INS-014（选中已是最新版本的目录时）

### REP-002: 前置条件：版本必须是最新
**类别:** 校验　**优先级:** P0　**置信度:** 高
**来源:** `sophon_server/tasks.py:114-137`、`sophon_server/sophon_api.py:1468-1481`、`src/clients/mhy/hk4e/program-check-integrity.ts:16`
**规格:**
  Given 已安装版本不等于最新 tag
  When 发送 `POST /api/repair {…, repair_mode:"reliable"}`
  Then 报 "The installed version is outdated. … Run an update first."，导致致命错误
**边界情况:** 前端在需要更新的状态下仍然可以触发修复，结果必然失败。

### REP-003: 文件校验
**类别:** 计算　**优先级:** P0　**置信度:** 高
**来源:** `sophon_server/sophon_api.py:107-111,1484-1538`、`src/clients/mhy/hk4e/program-check-integrity.ts:13-56`
**规格:**
  Then 先发送 repair_summary。校验线程数为 `max(2, 物理核数−4)`
  And 对每个文件先比较大小；在 reliable 模式下，大小一致的再比较整个文件的 MD5。不一致的加入待下载列表
  And 每校验 10 个文件发送一次 check_file 事件，界面显示 SCANNING_FILES(checked,total)
  And 校验结束后，对待下载列表执行 UPG-010 的下载流程

### REP-004: 修复不了"大小对、MD5 错"的文件
**类别:** 校验　**优先级:** P0　**置信度:** 高
**来源:** `sophon_server/sophon_api.py:939-945,1506-1531,1541`
**规格:**
  Given 文件大小正确但内容被篡改
  Then 校验阶段会标记为 md5 mismatch
  But 下载阶段因为"大小相同"发送 file_download_skipped "exists" 并跳过
  And 任务以 job_end 正常结束，文件 **仍然是坏的**
**疑似缺陷:** 原生版的强制重下路径必须绕过"大小相同即跳过"的判断，可以先删除文件，或者传入 force 参数。

### REP-005: hk4e 的完整性检查不清除 `patched`
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/program-check-integrity.ts`（全文件中没有 `patched`）、对照 `src/clients/mhy/program-check-integrity.ts:56`
**规格:**
  Given APP-019 中补丁还原失败，转而执行修复
  Then 修复完成后 `patched` 仍为 "1"
  And 下次启动游戏时 patchProgram 整个被跳过（LCH-012），DXMT、winemetal、steam.exe 都不会部署
**疑似缺陷:** 可能导致游戏以 Wine 自带的 D3D 实现启动。**待确认：**这是有意为之吗？

## 8. 下载进度协议（PRG）

### PRG-001: 任务事件推送（WebSocket）
**类别:** 生命周期　**优先级:** P0　**置信度:** 中
**来源:** `src/sophon.ts:72-92,106-177`、`sophon_server/server.py:45-74,104-118`、`sophon_server/utils.py:16-63,82-107`
**规格:**
  When `POST /api/<op>` 返回 `{task_id}`
  Then 客户端连接 `ws://host:port/ws/<task_id>`
  And 收到 job_end 时，排空剩余消息后关闭连接
  And 收到 error 或 job_error 时，先把消息交给调用方，再抛出 `Error(message.error)`
  And WebSocket 出错时报 "WebSocket connection error"；HTTP 返回非 2xx 时报 "<type> request failed"
**疑似缺陷:** 服务端只把消息推给当时已连接的客户端。如果任务在客户端连上之前就结束了，终止事件会丢失，客户端会一直等下去。原生版在进程内调用 Sophon，用回调即可避免这个问题。
**置信度说明:** **待确认：**是否遇到过界面卡在"正在分配磁盘空间"的情况？

### PRG-002: 进度与速度计算
**类别:** 计算　**优先级:** P2　**置信度:** 高
**来源:** `sophon_server/progress_handlers.py:6-91,173-236`
**规格:**
  Then `overall_percent = 已下载的压缩字节数 / 总压缩字节数 × 100`
  And 速度每 10 s 采样一次，取差值除以 10
  And chunk_progress 至少间隔 1 s 才广播一次
  And ldiff 阶段：`进度 = 已下载的 ldiff 大小 / 去重后的 patch_size 之和`
  And 删除阶段：`进度 = 已删除数 / 总数`
  And 总大小为 0 时，进度记为 0
**边界情况:**
- 因"已存在"而跳过的文件不计入已下载量，所以续装时进度到不了 100%。
- 每个阶段开始时计数清零，因此一次更新中进度条会多次从 0 开始。

### PRG-003: 事件与界面文案的对应关系
**类别:** 计算　**优先级:** P2　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/program-install-game.ts:26-53`、`program-update-game.ts:26-77,154-188`、`program-check-integrity.ts:19-56`

| 流程 | 事件 | 界面显示 |
|---|---|---|
| 安装 | job_start | ALLOCATING_FILE，进度不确定 |
| 安装 | chunk_progress | DOWNLOADING_FILE_PROGRESS(basename, 速度, 已下载, 总量)，进度取 overall_percent |
| 更新 | 开始时 | ALLOCATING_FILE，进度不确定 |
| 更新 | delete_file、delete_ldiff_file | PATCHING，进度取 percent |
| 更新 | ldiff_download_complete、chunk_progress | DOWNLOADING_FILE_PROGRESS |
| 更新 | 结束时 | 进度不确定 |
| 预下载 | ldiff_download_complete、chunk_progress | DOWNLOADING_FILE_PROGRESS |
| 修复 | 开始时 | SCANNING_FILES(0,0) |
| 修复 | check_file | SCANNING_FILES(checked,total)，进度取 percent |
| 修复 | chunk_progress | DOWNLOADING_FILE_PROGRESS |

**边界情况:** 打补丁阶段（ldiff_patch_*）没有对应的文案，界面会停留在上一条下载信息。

### PRG-004: 字节数的可读格式
**类别:** 计算　**优先级:** P2　**置信度:** 高
**来源:** `src/utils/helper.ts:53-75`
**规格:** 按 1024 进位，保留 1 位小数，使用 IEC 单位。示例：5242880 显示为 "5.0 MiB"；1023 显示为 "1023 B"；1048524 显示为 "1.0 MiB"（舍入到 1024 时进位到下一个单位）。

### PRG-005: 进度条显示规则
**类别:** 计算　**优先级:** P2　**置信度:** 高
**来源:** `src/launcher/task-queue.ts:18-28`、`src/launcher/index.tsx:211-250`、`src/common-update-ui.tsx:73-81`
**规格:**
  Given 命令为 `["setUndeterminedProgress"]`，或 `["setProgress",0]`
  Then 进度条显示为不确定态（真实进度为 0% 时也是如此）
  And 主队列和预下载队列各有一组状态文本和进度条；预下载那组显示在上方
  And 状态文本由 `["setStateText", key, ...args]` 经本地化格式化得到

### PRG-006: 取消功能没有接入
**类别:** 策略　**优先级:** P2　**置信度:** 高
**来源:** `src/sophon.ts:179-188`、`sophon_server/server.py:87-91`
**规格:** 服务端提供 `DELETE /api/tasks/{id}`，但客户端从未调用，界面上也没有取消按钮。用户只能退出启动器来中止任务。

## 9. 启动游戏（LCH）

### LCH-001: 启动任务的整体顺序
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/index.tsx:258-283`、`src/clients/mhy/hk4e/program-launch-game.ts:103-236`
**规格:**
  When 用户点击"启动"
  Then 依次执行：
  1. 如果开启了 reshade，检查 ReShade（LCH-002）。
  2. 检查 DXMT（WIN-019）。首次启动游戏时才会下载 DXMT。
  3. 进入 launchGameProgram，按顺序执行：
     1. 显示 PATCHING，强制关停 Wine（LCH-003）
     2. 写入注册表（LCH-004 至 LCH-008），然后执行 `wineserver -w`（LCH-009）
     3. 写入 config.bat（LCH-010）
     4. patchProgram（LCH-012 至 LCH-019、WIN-020）
     5. 显示 GAME_RUNNING，进入 try 块：blockNet（LCH-021）→ gameHost（LCH-022）→ 运行游戏
     6. 等待 Wine 退出（LCH-036）
     7. 撤销注册表（LCH-037），这一步只在正常路径执行
     8. 删除 config.bat，执行补丁还原（LCH-039）

### LCH-002: 按版本下载 ReShade
**类别:** 策略　**优先级:** P2　**置信度:** 高
**来源:** `src/downloadable-resource.ts:215-297`
**规格:**
  Given `config.reshade=true`，且 `installed_reshade` 不等于 "5.8.0"
  Then 执行以下步骤：
  1. 把 `ReShade_Setup_5.8.0_Addon.exe`（来源 reshade.me）和 `d3dcompiler_47.dll`（来源 lutris.net）下载到 `<data>/reshade/`。
  2. 在 exe 中找到第一个 `PK\x03\x04`，从该处截取出 zip 并解压，把 ReShade64.dll 改名为 `dxgi.dll`。
  3. 在游戏目录写入 `<game>/ReShade.ini`，其中 EffectSearchPaths 和 TextureSearchPaths 指向 `<data>/reshade/Shaders` 和 `Textures` 的 Z: 路径。
  4. 写入 `installed_reshade="5.8.0"`。
**边界情况:** 版本一致时直接返回，不会重写 ini，因此换了游戏目录后新目录里没有 ini。写 ini 的 `writeFile` 没有 await。

### LCH-003: 启动前强制清理 prefix 中的残留进程
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/program-launch-game.ts:103-108`、`src/wine/wine.ts:73-102`
**规格:**
  When 启动游戏
  Then 先执行 `wineserver -k`，失败也忽略。再对两类进程执行 `kill -9`：
  - 打开了 `/tmp/.wine-<uid>/server-<prefix 的 dev hex>-<prefix 的 inode hex>` 下文件的进程（用 `lsof +d` 查找）；
  - 命令行以 `C:\` 或 `Z:\` 开头、且工作目录在 prefix 内的进程。
  And 脚本最后执行 `true`，所以这一步总是成功
**边界情况:** 用户在同一个 prefix 中打开的 cmd 窗口也会被杀掉。

### LCH-004: 判断 MetalFX 是否生效
**类别:** 计算　**优先级:** P1　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/program-launch-game.ts:109-116`
**规格:**
  Given `metalFxUpscale && !resolutionCustom && backend=="dxmt"`
  Then metalFx 为 true，此时写入的 RetinaMode 强制为 "n"，并设置 `DXMT_METALFX_SPATIAL_SWAPCHAIN=1`
  And 用户保存的 retina 设置不会被修改

### LCH-005: 写入 Mac Driver 注册表（Retina / 左 Cmd）
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `src/wine/wine.ts:163-181`、`src/clients/mhy/hk4e/program-launch-game.ts:116`
**规格:**
  When 每次启动游戏
  Then 写入 `<data>/winedrv_config.bat`，内容是对 `HKCU\Software\Wine\Mac Driver` 执行 `reg add`，设置 RetinaMode 和 LeftCommandIsCtrl，值为 REG_SZ 的 "y" 或 "n"
  And 用 `wine cmd /c` 执行这个文件，然后执行 `wineserver -w`
**边界情况:** bat 文件执行后不删除。游戏退出后注册表不恢复，因为这两项本来就是持久设置。同见 CFG-012 和 CFG-013。

### LCH-006: 写入 HDR 注册表
**类别:** 策略　**优先级:** P1　**置信度:** 中
**来源:** `src/clients/mhy/hk4e/program-launch-game.ts:23-46,117-119`、`src/constants/hk4e_hdr_cn.reg:1-4`
**规格:**
  Given `hk4eEnableHDR=true`，server.id 为 hk4e_cn
  Then 写入 `<data>/hk4e_enable_hdr.reg`，内容为 `[HKCU\SOFTWARE\miHoYo\原神] "WINDOWS_HDR_ON_h3132281285"=dword:00000001`
  And 执行 `wine regedit Z:\…`，无论成功与否都删除这个临时文件
  And regedit 失败时抛出的异常不在 try 块内，会变成致命错误
**疑似缺陷:** 这个文件按 UTF-8 写入、没有 BOM，而键名里有中文；分辨率的 .reg 却是用 UTF-16LE 加 BOM 写的。Wine 的 regedit 遇到没有 BOM 的文件会按 ANSI 代码页解析，中文键名可能变成乱码。
**置信度说明:** **待确认：**在 CN 版开启 HDR 后，`HKCU\Software\miHoYo\原神\WINDOWS_HDR_ON_h3132281285` 这个值是否真的写进去了？

### LCH-007: 用注册表实现自定义分辨率（强制窗口化）
**类别:** 计算　**优先级:** P1　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/program-launch-game.ts:48-88,121-123`、`src/utils/helper.ts:118-128`
**规格:**
  Given `resolutionCustom=true`，宽为 2560，高为 1600
  Then 写入 `<data>/hk4e_resolution.reg`（UTF-16LE 加 BOM，CRLF 换行），在 `HKCU\Software\miHoYo\原神` 下设置：
  - `"Screenmanager Is Fullscreen mode_h3981298716"=dword:00000000`
  - `"Screenmanager Resolution Width_h182942802"=dword:00000a00`
  - `"Screenmanager Resolution Height_h2627697771"=dword:00000640`
  And 用 regedit 导入，无论成败都删除临时文件
**边界情况:** 游戏因此以窗口模式运行。如果窗口小于屏幕的一半，gamehost 不会把它切到全屏（LCH-028）。
**疑似缺陷:** 输入非整数（例如 1920.5）时，`toString(16)` 得到 "780.8"，生成的 dword 是非法值。

### LCH-008: 分辨率输入校验
**类别:** 校验　**优先级:** P1　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/program-launch-game.ts:62-66`
**规格:**
  Given 宽或高不是正数（包括 "abc"、"0"、""）
  Then 静默跳过分辨率注册表的写入，游戏照常启动
  And 游戏退出时仍然会执行 LCH-037 的删除

### LCH-009: 写完注册表后等待 wineserver 退出
**类别:** 生命周期　**优先级:** P1　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/program-launch-game.ts:124`、`src/wine/wine.ts:79-81`
**规格:** 执行 `wineserver -w` 并无限期等待，没有超时。

### LCH-010: config.bat（默认启动路径）
**类别:** 策略　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/program-launch-game.ts:126-135,186-190`
**规格:**
  Given `steamPatch=false`，游戏目录为 `/Games/GI`
  Then 生成 `<data>/config.bat`，内容依次为：
  - `@echo off`
  - `cd "%~dp0"`
  - `copy "Z:\Games\GI\HoYoKProtect.sys" "%WINDIR%\system32\"`
  - `cd /d "Z:\Games\GI"`
  - `"Z:\Games\GI\<CN_EXECUTABLE>" -platform_type CLOUD_THIRD_PARTY_PC -is_cloud 1`
  And 用 `wine cmd /c <config.bat 的 Z: 路径>` 运行
  And config.bat 在 patchProgram 之前写入
**参数:** `HoYoKProtect.sys` 在源码中以 base64 形式存放。Unix 路径转 Windows 路径的方法是加 "Z:" 前缀并把 "/" 换成 "\"（`src/wine/wine.ts:116-118`）。
**边界情况:** copy 失败不会中断批处理。

### LCH-011: Steam patch 启动路径
**类别:** 策略　**优先级:** P1　**置信度:** 中
**来源:** `src/clients/mhy/hk4e/program-launch-game.ts:186-190`
**规格:**
  Given `steamPatch=true`
  Then 执行 `wine C:\windows\system32\steam.exe <游戏 exe 的 Z: 路径>`
  And 不会复制 HoYoKProtect.sys，也不带 `-platform_type … -is_cloud 1` 参数；config.bat 仍会生成，但不会被使用
**置信度说明:** **待确认：**这个模式下不带云参数、不复制驱动，是有意设计吗？

### LCH-012: 补丁幂等
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/patch.ts:35-37`
**规格:**
  Given 已存在 `patched` 键
  Then patchProgram 立即返回，不做任何修改
**边界情况:** 与 REP-005 同时出现时，游戏会在没有打补丁的情况下启动。

### LCH-013: patch-off 只跳过对游戏文件的修改
**类别:** 策略　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/patch.ts:38-64,138-157`
**规格:**
  Given `patchOff=true`
  Then 不修改游戏目录中 patched、removed、added 列表里的文件
  And Wine 侧的部署照常进行：DXMT、winemetal、ReShade、steam.exe
  And 还原时同样跳过游戏文件部分
**边界情况:** 打补丁和还原各自读取当时的 `config.patchOff`。如果两次读取之间值变了，打补丁和还原的范围会不一致。

### LCH-014: CN 版启动前移走三个文件
**类别:** 策略　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/hk4ecn.ts:49-63`、`src/clients/mhy/patch.ts:54-59,147-151`
**规格:**
  Given `patchOff=false`
  Then 对以下文件中存在的那些执行 `mv -f <f> <f>.bak`：
  - `YuanShen_Data/upload_crash.exe`
  - `YuanShen_Data/Plugins/crashreport.exe`
  - `YuanShen_Data/Plugins/vulkan-1.dll`
  And 还原时，如果 `.bak` 存在就改回原名
**参数:** 这三个路径在源码中以 base64 形式存放，不属于凭据。
**边界情况:** `mv -f` 会覆盖已有的 `.bak`。修复期间如果这些文件处于 `.bak` 状态，修复会重新下载原文件，导致原文件和 `.bak` 同时存在。

### LCH-015: workaround3 对 hk4ecn 无效果
**类别:** 策略　**优先级:** P2　**置信度:** 高
**来源:** `src/clients/mhy/patch.ts:40,55`、`src/clients/hk4ecn.ts:38-63`
**规格:** 无论 workaround3 是开还是关，打补丁的行为完全相同，因为 hk4ecn 中带 `tag:"workaround3"` 的条目都被注释掉了。同见 CFG-022。

### LCH-016: 差分补丁和新增文件机制（CN 下列表为空）
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `src/clients/mhy/patch.ts:39-53,60-63,139-146,152-156`、`src/clients/hk4ecn.ts:38-48,65`
**规格:** 通用机制是：对 patched 列表中的文件，先改名为 `.bak`，下载 diff 后用 xdelta3 生成新文件；added 列表中的文件直接下载，还原时删除。hk4ecn 的 `patched=[]`、`added=[]`，所以实际不执行任何操作。原生版可以只保留接口。

### LCH-017: ReShade 注入游戏目录
**类别:** 策略　**优先级:** P2　**置信度:** 高
**来源:** `src/clients/mhy/patch.ts:97-103,170-173`
**规格:**
  Given `reshade=true`
  Then 把 `<data>/reshade/` 下的 `dxgi.dll` 和 `d3dcompiler_47.dll` 复制到 `<game>/`
  And 还原时删除这两个文件；ReShade.ini 不删除

### LCH-018: 把 steam.exe 和 lsteamclient 部署到 prefix
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `src/clients/mhy/patch.ts:105-122`
**规格:**
  Given 渠道不是 hkrpg（无论 steamPatch 开关如何）
  Then 从 `<data>/sidecar/protonextras/` 复制以下文件：

| 源文件 | 目标位置 |
|---|---|
| `steam64.exe` | `system32/steam.exe` |
| `steam32.exe` | `syswow64/steam.exe` |
| `lsteamclient64.dll` | `system32/lsteamclient.dll` |
| `lsteamclient32.dll` | `syswow64/lsteamclient.dll` |

  And 还原时不删除这些文件
**边界情况:** Licenses 页中的 Valve BSD 声明就是针对这些文件的（CFG-034）。

### LCH-019: patched 标记
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/patch.ts:124,174`
**规格:** 打补丁全部成功后写入 `patched="1"`；还原结束后删除这个键。
**疑似缺陷:** 两处 `setKey` 都没有 await。

### LCH-020: 每次启动生成一个游戏日志
**类别:** 策略　**优先级:** P2　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/program-launch-game.ts:137-141,215`
**规格:** 先执行 `mkdir -p <data>/logs`，再把 Wine 的 stdout 和 stderr 用 `&>` 重定向到 `logs/game_<毫秒时间戳>.log`。旧日志永远不会被清理。

### LCH-021: 屏蔽网络（临时修改 hosts 10 秒）
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/program-launch-game.ts:143-174`
**规格:**
  Given `blockNet=true`
  Then 写出 `/tmp/yaagl_network_block_script.sh`，通过 osascript 以管理员权限在后台运行。脚本依次：
  1. 如果 `/etc/hosts` 中没有 `0.0.0.0 <CN_BLOCK_URL>`，就追加一段，首尾分别是 "# Temporarily Added by Yaagl" 和 "# End of section"；
  2. sleep 10；
  3. 用 `sed -i.bak` 删除这一段；
  4. 删除脚本自身。
  And 用户取消授权时，游戏不启动（走 LCH-038 的异常路径）
**边界情况:** 每次启动都会要求输入密码。10 秒从脚本启动时开始计算，实际屏蔽的时间更短。脚本会留下 `/etc/hosts.bak`。

### LCH-022: Game Mode 开关
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/program-launch-game.ts:176-184`
**规格:**
  Given `gameMode=true`
  Then 调用 `prepareGameHost(runtime, "原神", exe)`，把返回的环境变量合并到游戏的环境中（LCH-026）
  Given `gameMode=false`
  Then 不注入这些环境变量；已经安装的 shim 会把调用原样透传给 wine-host（LCH-027）

### LCH-023: game host 缺失或出错时降级
**类别:** 校验　**优先级:** P1　**置信度:** 高
**来源:** `src/wine/game-host.ts:66-74,123-126`
**规格:**
  Given `sidecar/gamehost/yaagl-wine-shim` 或 `yaagl-gamehost.dylib` 不存在，或者准备过程中抛出任何异常
  Then 记录日志 "game host unavailable: …"，返回 `{}`，游戏以普通窗口方式启动

### LCH-024: 安装 wine 加载器 shim
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/wine/game-host.ts:25-32,76-84`
**规格:**
  Given `<runtime>/lib/wine/x86_64-unix/` 中没有 `wine-host`
  Then 把 `wine` 移成 `wine-host`。如果此时的 `wine` 已经是 shim，就抛出 "wine-host is missing"，然后按 LCH-023 降级
  And 当 `wine` 与 shim 内容不同（用 `cmp -s` 比较）时，把 shim 复制为 `wine`
**边界情况:** 关闭 Game Mode 不会卸载 shim。切换 Wine 后，新的 runtime 会被自动重新套上 shim。

### LCH-025: 构建并注册 YaaglGame.app
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `src/wine/game-host.ts:17-23,34-58,86-115`
**规格:**
  Given `<data>/YaaglGame.app/Contents/MacOS/.wine-host` 与当前的 wine-host 不一致
  Then 把 wine-host 复制为 `.wine-host` 和 `MacOS/wine`，然后执行 `codesign -f -s - -i com.3shain.yaagl.game`
  And 如果 `<data>/icon.icns` 存在，复制到 bundle 中
  And Info.plist 内容有变化时重写。关键字段：CFBundleExecutable=wine，Name 和 DisplayName 为"原神"，LSUIElement、LSSupportsGameMode、NSHighResolutionCapable 均为 true，LSApplicationCategoryType=public.app-category.games，NSPrincipalClass=WineApplication
  And 上述任何一项有变化，都执行 `lsregister -f`
**参数:** BUNDLE_ID 为 `com.3shain.yaagl.game`。签名标识必须等于 bundle id，否则进程内每次 getaddrinfo 都会卡住约 30 秒。

### LCH-026: game host 的环境变量
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `src/wine/game-host.ts:116-122`
**规格:**
  Then 设置以下环境变量：
  - `YAAGL_GAME_HOST_EXE=<data>/YaaglGame.app/Contents/MacOS/wine`
  - `YAAGL_GAME_HOST_MATCH=<exe 名>`
  - `YAAGL_GAME_HOST_DYLIB=<data>/sidecar/gamehost/yaagl-gamehost.dylib`
  - `YAAGL_GAMEHOST_LOG=<data>/logs/gamehost.log`

### LCH-027: wine-shim 按可执行文件分流
**类别:** 策略　**优先级:** P0　**置信度:** 高
**来源:** `native/gamehost/wine-shim.c:20-45`
**规格:**
  Given argv[1] 包含 MATCH（不区分大小写），且 HOST_EXE 可执行
  Then 设置 `DYLD_INSERT_LIBRARIES=<dylib>`，然后 exec bundle 中的 wine
  And 其他进程（cmd.exe、steam.exe、子进程）会清除继承来的这个变量，然后 exec `<自身路径>-host`
  And 无法解析自身路径时，返回 127

### LCH-028: gamehost 把游戏窗口切到原生全屏
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `native/gamehost/gamehost.c:140-159,248-291,339-403`
**规格:**
  Given winemac.so 加载完成，hook 已就位；定时器首次在 1 秒后触发，之后每 0.5 秒一次
  When 找到满足以下条件的游戏窗口：宽和高都不小于屏幕的 50%、可见、没有父窗口、是 WineWindow
  Then 第一次 tick 只订阅 GamePolicy；下一次 tick 设置 FullScreenPrimary 并调用 `toggleFullScreen:`
  And hook `adjustFullScreenBehavior:`，防止 winemac 把这个行为改掉
  And 窗口已经全屏时不再重复切换；用户手动退出全屏后，不会被强制切回去
**边界情况:** 游戏窗口被重建后，新窗口会接替成为全屏目标。具体设计见 `docs/genshin-macos.md`。

### LCH-029: 全屏时覆盖刘海区域
**类别:** 策略　**优先级:** P2　**置信度:** 高
**来源:** `native/gamehost/gamehost.c:161-224`
**规格:**
  Then 游戏窗口上的 4 个私有全屏 frame getter 都返回整块屏幕（split-view 中的窄 tile 不受影响）
  And 当 app 处于激活状态、窗口全屏、且 `safeAreaInsets.top>0` 时，把窗口层级设为 25（菜单栏是 24）
  And 设置失败时，先每个 tick 重试，连续 10 次后改为每 10 个 tick 重试一次
  And 其他 app 激活后，窗口层级恢复正常

### LCH-030: 窗口关闭 15 秒后进程仍在则自行退出
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `native/gamehost/gamehost.c:226-266`
**规格:**
  Given 全屏目标窗口既不可见、也没有最小化
  When 这种状态持续超过 15 秒
  Then 调用 `_exit(0)`
**边界情况:** 只有在 Game Mode 生效时才有这层保护。

### LCH-031: 本机主机名在本地直接解析
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `native/gamehost/gamehost.c:293-336,397-403`
**规格:**
  Given 通过 interpose 拦截 getaddrinfo；查询的名字是本机 hostname（可以去掉 ".local"，不区分大小写），且请求的不是仅 IPv6
  Then 返回第一个处于 UP 状态、非回环的 IPv4 地址；找不到时返回 127.0.0.1
  And 其他名字交给系统正常解析
**边界情况:** 目的是避开 mDNS 和"本地网络"权限带来的约 35 秒卡顿。

### LCH-032: Metal HUD、超时修复与 DLL 覆盖
**类别:** 策略　**优先级:** P2　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/program-launch-game.ts:191-194`
**规格:**
  Then `MTL_HUD_ENABLED` 为 "1" 或 ""
  And `WINE_ENABLE_TIMEOUT_FIX` 为 "1" 或 "0"
  And `WINEDLLOVERRIDES=""`，由于 LCH-035，这个变量实际不会传给进程

### LCH-033: DXMT 环境变量与 60 帧上限
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/program-launch-game.ts:196-207`
**规格:**
  Given 渲染后端为 dxmt
  Then 设置以下环境变量：
  - `WINEESYNC=1`
  - `DXMT_LOG_PATH=<data>`
  - `DXMT_CONFIG="d3d11.preferredMaxFrameRate=60;"`
  - `DXMT_CONFIG_FILE=<data>/dxmt.conf`
  - `GST_PLUGIN_FEATURE_RANK="atdec:MAX,avdec_h264:MAX"`
  And metalFx 生效时，另设 `DXMT_METALFX_SPATIAL_SWAPCHAIN=1`
**疑似缺陷:** 帧率上限固定为 60。设置项 fpsUnlock 没有任何读取者（CFG-019）。`dxmt.conf` 由用户自行提供，启动器不会写它。
**置信度说明:** **待确认：**原生版是否要把 fpsUnlock 接到 preferredMaxFrameRate 上？

### LCH-034: 代理环境变量
**类别:** 策略　**优先级:** P2　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/program-launch-game.ts:208-213`
**规格:** `proxyEnabled=true` 时，`HTTP_PROXY` 和 `HTTPS_PROXY` 都设为 proxyHost 的原始值，不补 scheme。只对游戏进程生效（UPD-016）。

### LCH-035: 空字符串的环境变量不会传递
**类别:** 计算　**优先级:** P1　**置信度:** 高
**来源:** `src/utils/command-builder.ts:34-46`
**规格:**
  Given 某个环境变量的值为 ""（falsy）
  Then 拼接命令时整项被丢弃，进程继承父进程中的同名值
  And "0" 不是空串，会正常传递

### LCH-036: 游戏退出后最多等待 Wine 15 秒，超时强杀
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/program-launch-game.ts:186-219,226-231`、`src/wine/wine.ts:104-114`、`src/utils/neu.ts:39-86`
**规格:**
  Given `exec2` 一直等到加载器进程退出（cmd 或 steam.exe 返回）
  Then 让 `wineserver -w` 与一个 15000 ms 的计时器赛跑
  And 计时器先到时，记录 "Wine did not exit within 15000ms, shutting it down"，然后执行 LCH-003 的强杀
  And `exec2` 只在退出码为 0 时算成功；cmd /c 返回的是游戏的退出码，非零时进入 LCH-038

### LCH-037: 正常退出后撤销 HDR 和分辨率注册表
**类别:** 生命周期　**优先级:** P1　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/program-launch-game.ts:220-225,239-301`
**规格:**
  Given 启动时开启了 HDR 或自定义分辨率，并且游戏正常退出
  Then 用 UTF-16LE 加 BOM 的 `hk4e_revert_hdr.reg` 和 `hk4e_revert_resolution.reg`，以 `=-` 的方式删除对应的值
  And regedit 失败时忽略；临时文件总是会被删除
**边界情况:** 删除的是这些值本身，所以玩家在游戏内自己设置的分辨率也会被一起清掉。

### LCH-038: 启动失败或崩溃时不撤销注册表
**类别:** 生命周期　**优先级:** P1　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/program-launch-game.ts:139,226-231`
**规格:**
  Given try 块中出现任何异常（包括游戏退出码非零、用户取消 sudo）
  Then 记录日志，按 15 秒规则等待或强杀 Wine，然后执行 LCH-039
  And **不**撤销 HDR 和分辨率注册表
**疑似缺陷:** 如果之后用户关掉了这两个设置，下次启动时也不会再去删除，强制写入的值会一直留在注册表里。
**置信度说明:** **待确认：**这个行为是否可以接受？

### LCH-039: 退出后删除 config.bat 并还原
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/program-launch-game.ts:234-236`、`src/clients/mhy/patch.ts:127-157`
**规格:**
  Then 无论走哪条路径，都删除 `<data>/config.bat`，显示 REVERT_PATCHING，然后执行 patchRevertProgram
  And patchRevertProgram 的内容：没有 `patched` 键时直接返回；否则把 removed 列表中的 `.bak` 改回原名，把 patched 列表中的 `.bak` 覆盖回原文件，删除 added 列表中的文件，还原 DXMT（WIN-021）和 ReShade（LCH-017），最后删除 `patched`
**边界情况:** 如果删除 config.bat 失败，会抛出致命错误，补丁也不会被还原；要等下次启动时由 APP-019 补做。

## 10. Wine / DXMT 管理（WIN）

### WIN-001: 内置的 Wine 发行版清单
**类别:** 策略　**优先级:** P0　**置信度:** 高
**来源:** `src/wine/distro.ts:17-82`
**规格:** 清单固定写在代码里，不从远端获取。共 6 项，按以下顺序排列，renderBackend 都是 dxmt。

| # | id | 下载地址（GitHub release） | winePath |
|---|---|---|---|
| 1 | `11.0-1-crossover-signed-experimental` | yaagl/anime-game-wine `wine-crossover-11.0-1-signed/wine-crossover-11.0-1-osx64-signed.tar.xz` | `wine` |
| 2 | `11.0-dxmt-signed-with-patches` | yaagl/anime-game-wine `wine-11.0-signed/wine-devel-11.0-osx64-signed.tar.xz` | `wine` |
| 3 | `11.8-dxmt-signed-experimental` | yaagl/anime-game-wine `wine-11.8-signed/wine-devel-11.8-osx64-signed.tar.xz` | `wine` |
| 4 | `11.4-dxmt-signed` | dawn-winery/dawn-signed `wine-gcenx-11.4-osx64/wine-devel-11.4-osx64-signed.tar.xz` | `wine-devel-11.4-osx64-signed/Contents/Resources/wine` |
| 5 | `11.0-dxmt-signed` | dawn-winery/dawn-signed `wine-stable-gcenx-11.0-osx64/wine-stable-11.0-osx64-signed.tar.xz` | `Wine Stable.app/Contents/Resources/wine` |
| 6 | `9.9-dxmt` | 3Shain/wine `v9.9-mingw/wine.tar.gz` | 无 |

**边界情况:** 上游删除 release 后，对应版本会下载失败。

### WIN-002: 默认的 Wine 版本
**类别:** 策略　**优先级:** P0　**置信度:** 中
**来源:** `src/clients/hk4ecn.ts:23-25`、`src/wine/distro.ts:94-103`
**规格:**
  Then 默认使用 `11.0-dxmt-signed-with-patches`
  And 如果这个 id 不在清单中，抛出 "can not find default wine version"，结果是致命错误
**疑似缺陷:** `DEFAULT_WINE_DISTRO_URL` 是死常量，而且指向 9.9 版本。
**置信度说明:** **待确认：**"推荐设置"选的是 crossover 11.0-1（CFG-031），fork 的 Game Mode 方案也基于改版 CrossOver 11，但新安装的默认版本不是它。原生版的默认值应该用哪个？

### WIN-003: 判断 Wine 是否就绪
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/wine/distro.ts:104-130`
**规格:**
  Given `wine_state=="update"`
  Then 未就绪，目标版本取 `wine_update_tag`；在清单中找不到时改用默认版本
  Given `wine_state` 是其他值，且 `wine_tag` 在清单中
  Then 已就绪
  Given 读取存储键时抛出异常（首次运行）
  Then 未就绪，使用默认版本
**疑似缺陷:** 只看存储键，不检查磁盘上是否真有 `<data>/wine`。如果目录被删除，仍会判为就绪，之后的 exec 会失败。

### WIN-004: wine_tag 不在清单中时强制重装
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/wine/distro.ts:114-124`
**规格:**
  Given `wine_tag` 不在当前清单中
  Then 判为未就绪，安装默认版本。这一过程会删除 prefix（WIN-006）
**边界情况:** 以后从清单中删掉某个 id，正在用这个版本的用户会在不知情的情况下重建 prefix。

### WIN-005: 启动时按 Wine 状态分流
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/app.tsx:103-154`
**规格:**
  Given Wine 已就绪
  Then 用 `<data>/wineprefix` 创建 Wine 实例，创建 hk4e 客户端，进入启动器
  Given Wine 未就绪
  Then 显示 Wine 安装进度页并自动开始安装；装完后显示"重启以安装"（UPD-013）
**边界情况:** 安装页上同样会弹出自更新提示。

### WIN-006: 安装或切换 Wine 时先删除 prefix
**类别:** 策略　**优先级:** P0　**置信度:** 高
**来源:** `src/wine/wine-install-program.ts:37`
**规格:** 安装程序的第一步是 `rm -rf <data>/wineprefix`，删除在下载开始之前就执行。
**边界情况:** 如果之后下载失败，prefix 已经不存在，`wine_state` 仍然是 update，下次启动会重新安装。删除前不提示用户（同见 CFG-008、CFG-031）。

### WIN-007: 下载 Wine 安装包并判断格式
**类别:** 计算　**优先级:** P0　**置信度:** 高
**来源:** `src/wine/wine-install-program.ts:38-54`
**规格:**
  Given remoteUrl 以 `.xz` 结尾
  Then 通过 aria2 下载为 `<data>/wine.tar.xz`；其他情况下载为 `wine.tar.gz`
  And 进度为 `floor(completed×100/total)`，速度按 IEC 单位显示（DOWNLOADING_ENVIRONMENT_SPEED）
**边界情况:** 下载地址取自清单中的 remoteUrl，不读 `wine_update_url`。

### WIN-008: 解压规则
**类别:** 计算　**优先级:** P0　**置信度:** 高
**来源:** `src/wine/wine-install-program.ts:55-72`、`src/utils/neu.ts:104-124`
**规格:**
  Then 先清空并重建 `<data>/wine`
  And 有 winePath 时，执行 `tar --strip-components=<winePath 的段数> -C <data>/wine -Jxvf … "<winePath>"`
  And 没有 winePath 时，执行 `tar -zxvf … -C <data>/wine`
  And 完成后删除安装包
**边界情况:** 解压失败时安装包保留，但 `wine/` 目录已被清空。

### WIN-009: 向 wine.inf 注入根证书
**类别:** 校验　**优先级:** P0　**置信度:** 高
**来源:** `src/wine/cert.ts:4-43`、`src/wine/wine-install-program.ts:76`
**规格:**
  Given 在 wineboot 之前执行
  When `wine/share/wine/wine.inf` 中某一行去掉首尾空白后等于 "; URL Associations"
  Then 在它后面的第一个空行处，插入一个空行和 WINE_INF_CERT_STR 的全部行
  And 找不到这一行或找不到它后面的空行时报错，安装失败
**参数:** `WINE_INF_CERT_STR`，值见 secret（是一张公开的根 CA 证书，不属于凭据）。
**边界情况:** 原文件是 CRLF 换行时按 CRLF 拆分，写回时统一用 `\n`。
**置信度说明:** **待确认：**这张证书的用途需要维护者补充说明。

### WIN-010: 移除 quarantine 属性（需要管理员权限）
**类别:** 策略　**优先级:** P0　**置信度:** 高
**来源:** `src/wine/wine-install-program.ts:77`、`src/utils/unix.ts:5-11`、`src/utils/neu.ts:88-102`
**规格:** 通过 osascript 以 `with administrator privileges` 执行 `/usr/bin/xattr -s -r -d com.apple.quarantine <data>/wine`，系统会弹出密码框。用户取消时，结果是致命错误。

### WIN-011: 在 /etc/hosts 中维护永久屏蔽段
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `src/hosts.ts:3-29`、`src/wine/wine-install-program.ts:82`
**规格:**
  Then 以 sudo 重写 `# Added by Yaagl` 到 `# End of section` 之间的内容；文件中没有这一段时追加到末尾。段内容依次为警告行、`ENSURE_HOSTS` 中每个域名一行 `0.0.0.0 <域名>`、结束标记和一个空行
**参数:** `ENSURE_HOSTS`（secret）共 7 个遥测和日志上报域名。`server.hosts`（`CN_CUSTOM_HOSTS`）从未被使用。
**边界情况:** 只有开始标记、没有结束标记时，开始标记之后的全部内容都会丢失。
**疑似缺陷（安全）:** 写入时用 `printf <内容> > /etc/hosts`，原文件内容被当成格式串，其中的 `%` 或 `\` 会被解释，导致文件内容被改坏。

### WIN-012: 初始化 prefix
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/wine/wine-install-program.ts:84-99`
**规格:**
  Then 依次执行 `wine wineboot -u &> <data>/wineboot.log` 和 `wine winecfg -v win10 &> <data>/winecfg.log`
  And 任一步失败时，报错 "Wine initialization failed… check the log file at: <data>/wineboot.log … (Please ensure Rosetta 2 is installed.)"
**边界情况:** winecfg 失败时，错误信息里给的也是 wineboot.log 的路径。

### WIN-013: hk4ecn 不安装 Media Foundation
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `src/wine/wine-install-program.ts:101-107`、`src/wine/mf.ts:15-100`
**规格:** 只有渠道名以 bh3 或 cbjq 开头时才安装 MF DLL 和 mf.reg/wmf.reg，hk4ecn 跳过。原生版无需实现。

### WIN-014: 安装完成后写入状态
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/wine/wine-install-program.ts:109-115`
**规格:**
  Given 所有步骤都成功
  Then 写入 `wine_state="ready"`、`wine_tag=<id>`、`wine_update_url=null`、`wine_update_tag=null`，并重新生成 `wine_netbiosname`；状态显示 INSTALL_DONE
  And 中途任何一步失败，以上键都不写入

### WIN-015: NetBIOS 名称
**类别:** 计算　**优先级:** P2　**置信度:** 中
**来源:** `src/wine/wine.ts:155-161`、`src/utils/helper.ts:107-116`
**规格:** 如果 `wine_netbiosname` 不存在，生成 `"DESKTOP-" + 7 位 [A-Z0-9]` 并保存。
**疑似缺陷:** 这个值没有任何读取者，属于死数据。
**置信度说明:** **待确认：**是否需要把它写进 prefix 的 ComputerName？不需要的话可以删掉。

### WIN-016: 选择 Wine 可执行文件与基础环境
**类别:** 策略　**优先级:** P0　**置信度:** 高
**来源:** `src/wine/wine.ts:20-71,219-226`
**规格:**
  Then runtime 默认为 `<data>/wine`，可以用 `YAAGL_WINE_RUNTIME` 覆盖（仅供开发使用）
  And 优先使用 `bin/wine64`，不存在时用 `bin/wine`；wineserver 取 loader 所在目录下的同名文件
  And 每个 Wine 进程都带 `WINEDEBUG=fixme-all,err-unwind,+timestamp` 和 `WINEPREFIX=<data>/wineprefix`，调用方传入的同名变量会覆盖它们
**疑似缺陷:** 覆盖 runtime 后，DXMT 注入（WIN-020）仍然写到 `./wine`。

### WIN-017: 路径转换与 copy 特例
**类别:** 计算　**优先级:** P1　**置信度:** 高
**来源:** `src/wine/wine.ts:116-125`
**规格:**
  Then `toWinePath("/Users/a/Game")` 得到 `Z:\Users\a\Game`
  And 程序名为 "copy" 时，改写成 `cmd /c copy …`
  And `exec` 和 `exec2` 在退出码非零时都会 reject

### WIN-018: Wine 关停与强杀
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/wine/wine.ts:73-114`
**规格:** 同见 LCH-003 和 LCH-036。提供两个接口：`shutdown()`（`wineserver -k` 加上两类进程的 `kill -9`）和 `waitUntilServerOffOrShutdown(ms)`。

### WIN-019: DXMT 版本检查与下载
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/downloadable-resource.ts:133-213`、`src/clients/mhy/hk4e/index.tsx:273-275`
**规格:**
  Given `installed_dxmt_version`（默认为 "0.0.0"）不等于 `CURRENT_DXMT_VERSION="654f547"`
  When 点击"启动"时（不是在安装 Wine 时）
  Then 依次执行：
  1. `rm -rf <data>/dxmt`
  2. 下载 `https://github.com/yaagl/anime-game-wine/releases/download/dxmt-654f547/dxmt-654f547ffab4e0c395ee368aad52bb4586b04576.zip`
  3. unzip，再 `tar -xvf` 内层的 tar.gz
  4. 把 `x86_64-windows/*` 和 `x86_64-unix/*` 移到 `<data>/dxmt/`
  5. 清理中间文件，写入 `installed_dxmt_version="654f547"`
  And 版本一致时直接返回
**参数:** 涉及的文件：`d3d10core.dll`、`d3d11.dll`、`dxgi.dll`、`winemetal.dll`、`winemetal.so`、`nvngx.dll`。
**疑似缺陷:** 只比较版本键，不检查文件是否存在。如果 `dxmt/` 被删除，打补丁时 cp 会失败，导致致命错误。写入版本键时没有 await。

### WIN-020: 把 DXMT 注入 Wine 运行时
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/patch.ts:66-95`
**规格:**
  Given 没有 `patched` 键
  Then 对 `d3d10core.dll`、`d3d11.dll`、`dxgi.dll` 中的每个文件 f，执行 `mv -f wine/lib/wine/x86_64-windows/f f.bak`，再 `cp -p dxmt/f` 到原位置
  And 把 `winemetal.dll` 复制到 `wine/lib/wine/x86_64-windows/` 和 `wineprefix/drive_c/windows/system32/`
  And 把 `winemetal.so` 复制到 `x86_64-unix/`
  And hk4e 不复制 nvngx.dll（只有 hkrpg 使用）
**边界情况:** 不受 patchOff 影响。注入时不检查 renderBackend，还原时却检查（WIN-021），两边不对称。
**疑似缺陷:** 如果在 cp 之后、写入 `patched` 之前崩溃，下次注入会把 DXMT 版本的文件再 mv 成 `.bak`，Wine 原版的 DLL 就丢失了。

### WIN-021: 还原 DXMT 注入
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/patch.ts:159-175`
**规格:**
  Given 渲染后端为 dxmt
  Then 对三个 DLL 中存在 `.bak` 的那些执行 `mv -f` 还原；不存在 `.bak` 的跳过，不报错
  And 不删除 winemetal 和 steam.exe

### WIN-022: 打开 Wine 命令行窗口
**类别:** 策略　**优先级:** P2　**置信度:** 高
**来源:** `src/wine/wine.ts:127-153`、`src/config/index.tsx:229-239`
**规格:** 通过 osascript 让 Terminal 执行 `WINEDEBUG=… WINEPREFIX=… WINEPATH=<游戏目录的 Z: 路径> <loader> cmd`，然后把 Terminal 切到前台。

### WIN-023: 当前版本不在清单中时的下拉框
**类别:** 校验　**优先级:** P2　**置信度:** 高
**来源:** `src/config/wine-distribution.tsx:50-71`
**规格:** 下拉框第一项显示当前的 tag，其 url 标为 "not_applicable"，后面再列出清单中的各项。由于 WIN-004 会在启动时先触发重装，这一项实际上几乎不会出现。

> 切换 Wine 版本见 CFG-008，"应用推荐设置"会切换 Wine 见 CFG-031，Game Mode 对 runtime 的改写见 LCH-024 和 LCH-025。

## 11. 自更新（UPD）

### UPD-001: 应用版本号的来源
**类别:** 策略　**优先级:** P0　**置信度:** 高
**来源:** `src/constants/version.ts:1-4`、`.github/workflows/build-ontag.yaml:7,14-18`、`build-app.js:97`
**规格:**
  Given 推送 tag `0.2.0`
  Then `CURRENT_YAAGL_VERSION` 为 "0.2.0"；Info.plist 中的 CFBundleVersion 和 CFBundleShortVersionString 也是这个值
  And tag 必须匹配 `^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$`，否则 CI 失败
  And 本地构建没有设置 `YAAGL_VERSION` 时，版本为 "development"，plist 中为 "1.0.0"

### UPD-002: 开发版跳过自更新
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `src/updater.ts:23-27`
**规格:** 版本为 "development" 时直接返回"已是最新"，不访问网络。

### UPD-003: 识别渠道
**类别:** 计算　**优先级:** P0　**置信度:** 高
**来源:** `src/updater.ts:29-39`
**规格:** `YAAGL_CHANNEL_CLIENT=hk4ecn` 时，updateVersion 为 "hk4ecn"。只有 universal 渠道会再用 `YAAGL_OS` 区分。

### UPD-004: 更新源与 API
**类别:** 策略　**优先级:** P0　**置信度:** 高
**来源:** `src/updater.ts:17-20,40-42`、`src/github.ts:6-21`
**规格:**
  Then 请求 `GET https://api.github.com/repos/tanzby/yet-another-anime-game-launcher/releases/latest`，超时 10000 ms，超时后报 "TIMEOUT"
  And 状态码为 200、301 或 302 时视为成功
**边界情况:** `/releases/latest` 不包含 draft 和 prerelease。匿名请求限额为每小时 60 次，超出后按检查失败处理。

### UPD-005: 匹配发布资产
**类别:** 校验　**优先级:** P0　**置信度:** 高
**来源:** `src/updater.ts:43-71`
**规格:**
  Then 必须存在名为 `resources_hk4ecn.neu` 的资产才算有更新；`Yaagl.app.tar.gz`（用于更新 sidecar）是可选的
  And 缺少 neu 资产时，视为已是最新

### UPD-006: 版本比较
**类别:** 计算　**优先级:** P0　**置信度:** 高
**来源:** `src/updater.ts:73-84`
**规格:**
  Given `semver.gt(tag_name, 当前版本)` 为真，且 neu 资产存在
  Then 返回 `{latest:false, downloadUrl, sidecarDownloadUrl, version, description: release body}`
  And 例如当前为 0.2.0-beta.1、最新为 0.2.0 时，判定为有更新
  And 版本相同或更低时不提示
**边界情况:** tag 不是合法 semver 时 `gt` 会抛异常，按检查失败处理。

### UPD-007: 检查更新失败
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `src/updater.ts:85-89`、`src/app.tsx:111-120,161-164`
**规格:**
  Given 检查过程中出现任何异常，返回 `latest=undefined`
  Then 启动时自动检查：静默忽略
  And 用户手动检查：弹出英文固定文案 "Failed to check for updates. Please reopen the launcher and try again."（没有本地化）

### UPD-008: 启动时的更新提示与忽略版本
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `src/app.tsx:101,159-164,174-227`
**规格:**
  Given 发现新版本，且该版本号不等于 `ignore_launcher_update`
  Then 弹窗提供三个按钮：忽略、取消、更新
  And 忽略：写入 `ignore_launcher_update=<version>`，以后只提示更新的版本
  And 取消：只关闭弹窗
  And 更新：整个界面切换为更新进度页，依次执行 UPD-010 和 UPD-011

### UPD-009: 手动检查更新
**类别:** 策略　**优先级:** P2　**置信度:** 高
**来源:** `src/app.tsx:111-129`、`src/config/index.tsx:269-271`
**规格:**
  Then 设置页中的"检查更新"会重新检查，不受忽略版本的影响
  And 已是最新时提示 ALREADY_LATEST_VERSION；有更新时弹出与 UPD-008 相同的提示框

### UPD-010: 下载并替换 sidecar
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/updater.ts:96-133`
**规格:**
  Given release 中有 sidecar 资产
  Then 下载到 `<data>/sidecar.tar.gz`
  And 执行 `rm -rf ./sidecar` 和 `mkdir -p ./sidecar`
  And 执行 `tar --strip-components=4 -C ./sidecar -zxvf ./sidecar.tar.gz "Yaagl.app/Contents/Resources/sidecar"`，然后删除压缩包
**参数:** sidecar 包含 aria2、7z、xdelta、hpatchz、protonextras、gamehost、sophon_server。

### UPD-011: 下载并替换 resources.neu
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/updater.ts:135-151`
**规格:**
  Then 下载到 `<data>/resources.neu.update`，再执行 `mv -f` 覆盖 `resources.neu`
  And 不修改 `/Applications/Yaagl.app`，因此 plist 中的版本号仍是旧的

### UPD-012: 更新进度的换算
**类别:** 计算　**优先级:** P2　**置信度:** 高
**来源:** `src/updater.ts:101-111,139-150`
**规格:** 有 sidecar 时，sidecar 占进度的 0 到 50，neu 占 50 到 100；没有 sidecar 时，neu 占 0 到 100。替换文件期间进度显示为不确定。

### UPD-013: 完成后重启
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/common-update-ui.tsx:21-42,52-65`、`src/utils/neu.ts:371-390`
**规格:**
  Given Wine 安装或自更新完成，界面显示 RESTART_TO_INSTALL
  When 用户点击
  Then 执行所有终止钩子，然后执行 `open "$PATH_LAUNCH"`，再 `exit(0)`
  And 开发模式下改为调用 `restartProcess()`

### UPD-014: 更新失败时不回滚
**类别:** 策略　**优先级:** P0　**置信度:** 高
**来源:** `src/common-update-ui.tsx:39-41`
**规格:**
  Given 任一步出错
  Then 弹出 Fatal error，以 -1 退出
  And 已替换的 sidecar 不会回滚，可能出现"新 sidecar 加旧 neu"的组合；如果解压失败导致 sidecar 目录为空，下次启动会由 APP-003 从 bundle 补齐

### UPD-015: 发布产物与命名约定
**类别:** 策略　**优先级:** P0　**置信度:** 高
**来源:** `.github/workflows/build-ontag.yaml:79-99`
**规格:**
  Given 推送 tag
  Then 只构建 hk4ecn 渠道。release 中包含 `Yaagl-<ver>.dmg`、`Yaagl.app.tar.gz`（顶层目录为 Yaagl.app）、`resources_hk4ecn.neu`
  And 这三个文件名都被 UPD-005 依赖
**边界情况:** 迁移到 Sparkle 时，旧版 TS 客户端仍按这些文件名检查更新，过渡方案必须考虑这一点（地图 Not yet specified 中已列出）。

### UPD-016: 代理不作用于启动器自身的网络请求
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `src/github.ts:3-11`、`src/clients/mhy/hk4e/program-launch-game.ts:208-213`
**规格:** 设置中的代理只注入游戏进程。GitHub API、aria2（下载 Wine、DXMT、更新包）和 Sophon 都直连。
**置信度说明:** **待确认：**原生版是否需要让启动器自身的下载也走代理？

### UPD-017: Bundle 标识与 Info.plist
**类别:** 策略　**优先级:** P0　**置信度:** 高
**来源:** `build-app.js:19-24,310-349`
**规格:** CFBundleIdentifier 为 `com.3shain.yaagl`，CFBundleExecutable 为 `parameterized`，LSMinimumSystemVersion 为 10.15.0，允许任意 HTTP 加载。
**边界情况:** 修改 bundle id 会影响 TCC 授权和 LaunchServices 注册，需要和 `com.3shain.yaagl.game` 一起改（`game-host.ts:18-21`）。TS fork 曾决定保留 `com.3shain.yaagl`；原生版是否沿用这个 id 尚未在地图中决定（**待确认**）。

### UPD-018: sidecar 的可执行权限
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `build-app.js:290-306`
**规格:** 构建时，sidecar 中所有文件名不含 "." 的文件设为 `chmod 755`。自更新解压时依赖 tar 包中保存的权限。

## 12. 设置项（CFG）

### CFG-001: 设置的持久化存储
**类别:** 策略　**优先级:** P0　**置信度:** 中
**来源:** `src/utils/neu.ts:139-156`、`build-app.js:124-131,222-236`
**规格:**
  Given 调用 `setKey("config_retina","true")`
  Then 生成文件 `<data>/.storage/config_retina.neustorage`，内容是纯文本 `true`：没有引号，没有换行
  And `getKey` 读取一个不存在的键时抛出异常，调用方据此改用默认值
  And `setKey(k, null)` 表示删除这个键
**边界情况:** App 包里带一个空的 `.storage` 目录。由于 rsync 不带 `--delete`，同步时不会覆盖已有的设置。
**置信度说明:** **待确认：**原生版必须能读取这些现有的 `.storage/*.neustorage` 文件吗？地图已锁定"沿用现有数据目录"，所以几乎可以确定需要。"null 即删除"属于 Neutralino 运行时的语义，原生版需要用代码重新实现。

### CFG-002: 布尔值的解析
**类别:** 校验　**优先级:** P0　**置信度:** 高
**来源:** `src/config/retina.tsx:20-24`（其余布尔设置项的写法相同）、`src/clients/mhy/hk4e/config/game-mode.tsx:22`
**规格:**
  Given 存储的值是 `TRUE`（大写）
  Then 视为 false：除游戏模式外，只有严格等于 `"true"` 才算开启
  And 游戏模式例外：只要值不等于 `"false"` 就算开启，键不存在时也算开启
  And 写回时一律写小写的 "true" 或 "false"

### CFG-003: 改动即时保存，不落盘默认值
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/config/retina.tsx:28-43`、`src/config/index.tsx:56,355`、`src/launcher/index.tsx:79-85,108,138`
**规格:**
  Then 设置页里的控件一改动就写入存储，同时更新内存中共享的 config 对象，下一次启动游戏就会用上新值
  And 新值等于当前值时不写；用户没有改动过的设置不落盘，每次启动都重新计算默认值。界面语言是例外（CFG-017）
  And 没有"保存"或"取消"按钮
**例外:** 以下三项不是即时生效：界面语言（重启后生效）、Wine 版本（会重启并重装）、"应用推荐设置"（要求重启）。

### CFG-004: 设置入口
**类别:** 校验　**优先级:** P1　**置信度:** 高
**规格:** 同见 APP-018。

### CFG-005: 设置页的标签页结构
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `src/config/index.tsx:116-296`
**规格:** 设置页是一个 1000×570 的模态框，左侧是竖排的标签页。

| 标签页 | 内容 |
|---|---|
| 通用（SETTING_GENERAL） | 左栏依次为：游戏安装目录｜Metal HUD、Retina、左 CMD｜代理开关、代理主机、SETTING_PROXY_DESC 说明文字｜界面语言、YAAGL 版本。右栏为"快速操作"：检查完整性、应用推荐设置｜打开 Wine 命令行、打开游戏目录、打开 YAAGL 数据目录｜检查更新 |
| 游戏（SETTING_GAME） | 见 CFG-030 |
| Wine | 标签名硬编码为 "Wine"，页内只有 Wine 版本一项 |
| 高级 | 有条件显示（CFG-006）。内容为警告条 SETTING_ADVANCED_ALERT、FPS 解锁、ReShade |
| SETTING_LICENSES | 许可证 |

**边界情况:** 设置页里没有查看日志、导出诊断信息、重置设置这类功能。

### CFG-006: 高级设置页的解锁手势
**类别:** 生命周期　**优先级:** P2　**置信度:** 中
**来源:** `src/config/index.tsx:79-109`、`src/constants/version.ts:6-7`
**规格:**
  Given 构建时设置了 `YAAGL_ADVANCED_ENABLE=="1"`
  When 用户在版本号文字上点击，满足"点击记录超过 5 次，且最近一次与倒数第 5 次的间隔小于 1000 ms"
  Then 切换 `config_advanced`；切到显示时弹出 SETTING_ADVANCED_VISIBLE 通知，然后清空点击记录
  Given 构建时没有设置这个变量
  Then 永远不显示高级页
**疑似缺陷:** CI 和 vite 配置都没有设置 `YAAGL_ADVANCED_ENABLE`，所以发行版中永远看不到 FPS 解锁和 ReShade。
**置信度说明:** **待确认：**原生版要保留高级页和这个手势吗？

### CFG-007: 关闭设置页
**类别:** 生命周期　**优先级:** P2　**置信度:** 高
**来源:** `src/config/index.tsx:117,175`、`src/launcher/index.tsx:308-318`
**规格:** 点关闭按钮或遮罩只会关闭设置页，不会触发任何保存。点"检查完整性"会先关闭设置页，再把检查任务加入主队列。

### CFG-008: Wine 版本：列表与切换流程
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/config/wine-distribution.tsx:35-89,116-120`、`src/utils/neu.ts:377-390`
**规格:**
  Given 当前值来自 `wine_tag`，下拉框列出 WIN-001 中的发行版
  When 用户选了一个不同的版本
  Then 出现一个 danger 样式的 SETTING_WINE_VERSION_CONFIRM 按钮，此时还没有写盘
  When 用户点击这个按钮
  Then 弹出 RELAUNCH_REQUIRED 提示，只有"确定"按钮
  And 依次写入 `wine_state=update`、`wine_update_tag=<id>`、`wine_update_url=<url>`
  And 执行 `_safeRelaunch`：运行所有终止钩子，`open "$PATH_LAUNCH"`，然后 `exit(0)`
  And 应用重启后按 WIN-003、WIN-006 到 WIN-014 的流程重装 Wine，其中包括删除 prefix
  And 用户把选择改回原值时，确认按钮消失
**疑似缺陷:**
- 下拉框里没有任何一项带 `community` 标记，所以 COMMUNITY_WARNING 永远不会弹出。
- `wine_update_url` 写入后没有任何地方读取。
- 切换前不提示用户 prefix 会被重建。

### CFG-009: 游戏安装目录
**类别:** 生命周期　**优先级:** P0　**置信度:** 高
**来源:** `src/config/game-install-dir.tsx:12-42`、`src/clients/mhy/hk4e/index.tsx:179,208,221,245,345-365`
**规格:**
  Then 在设置页中只以禁用的输入框显示，不能修改（编辑按钮被注释掉了）
  And 只在以下情况写入：安装成功、导入已有安装成功（INS-003、INS-012、INS-014）、版本太旧时被删除（UPG-001）
**边界情况:** 没有修改目录、迁移目录或卸载游戏的功能。

### CFG-010: 安装目录的选择校验
**规格:** 同见 INS-001。

### CFG-011: Metal HUD
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `src/config/metal-hud.tsx:20-24,48-58`
**规格:** 复选框，键为 `config_metalHud`，默认值 false，文案 key 为 SETTING_MTL_HUD。开启后，启动游戏时设置 `MTL_HUD_ENABLED=1`（LCH-032）。

### CFG-012: Retina 模式
**类别:** 策略　**优先级:** P0　**置信度:** 高
**来源:** `src/config/retina.tsx:20-24`
**规格:** 复选框，键为 `config_retina`，默认值 false，文案 key 为 SETTING_RETINA。只在启动游戏时写入注册表（LCH-005）；MetalFX 生效时强制写 n（LCH-004）。

### CFG-013: 左 CMD 映射为 Ctrl
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `src/config/left-cmd.tsx:20-24,36`
**规格:** 复选框，键为 **`left_cmd`**（注意没有 `config_` 前缀），默认值 false，文案 key 为 SETTING_LEFT_CMD。效果见 LCH-005。

### CFG-014: HTTP 代理开关
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `src/config/proxy-enabled.tsx:20-24`、`src/config/index.tsx:145-149`
**规格:** 复选框，键为 `config_proxyEnabled`，默认值 false。开启后只影响游戏进程（LCH-034、UPD-016）。
**疑似缺陷:** zh_CN 语言包中的 SETTING_PROXY_* 仍是英文，标注了 `// TODO: Translate`（`src/locale/zh_CN.ts:114-117`）。

### CFG-015: 代理主机
**类别:** 校验　**优先级:** P1　**置信度:** 中
**来源:** `src/config/proxy-host.tsx:26-30,57`
**规格:** 自由文本，键为 `config_proxyHost`，默认值 `127.0.0.1:8080`。不做任何格式校验，允许保存空串（此时代理值也是空串）。
**置信度说明:** **待确认：**原生版是否要校验 host:port 格式，或自动补上 `http://`？

### CFG-016: 界面语言的默认值
**类别:** 计算　**优先级:** P1　**置信度:** 高
**来源:** `src/locale/index.ts:21-52`
**规格:**
  Then 优先读取 `config_uiLocale`，转成小写
  And 没有这个键时，取 `navigator.language`：把 `-` 换成 `_`、转小写、去掉 `.` 之后的部分；以 `en_` 开头的一律归为 `en`
  And 结果不在支持列表中时，回退到 `en`。例如 zh-CN 得到 zh_cn；en-GB 得到 en；ja 和 zh-TW 都回退到 en
**参数:** 支持的语言 id：`zh_cn`、`en`、`vi_vn`、`es_es`、`fr_FR`、`ru_ru`、`ja_jp`、`ko_kr`、`de_de`、`th_th`。原生版按地图只保留 zh-Hans 和 en。
**疑似缺陷:** 法语的 key 是 `fr_FR`，而查找前做了小写转换，所以永远选不中法语。

### CFG-017: 界面语言的保存方式
**类别:** 生命周期　**优先级:** P1　**置信度:** 中
**来源:** `src/config/ui-locale.tsx:27-36,63-67`
**规格:**
  Then 设置组件创建时（也就是启动器启动时）就无条件把当前语言写入 `config_uiLocale`，系统推断出的语言因此被固定下来
  And 用户修改语言后立即写入，并显示 SETTING_RESTART_TO_TAKE_EFFECT；当前界面不切换语言
**置信度说明:** **待确认：**原生版首次运行时也要把推断出的语言写入吗？还是改为跟随系统语言？

### CFG-018: YAAGL 版本显示
**类别:** 策略　**优先级:** P2　**置信度:** 高
**来源:** `src/config/index.tsx:152-159`
**规格:** 显示 `CURRENT_YAAGL_VERSION`；值为空时显示 "development"。这段文字同时也是高级页手势的点击区域（CFG-006）。

### CFG-019: FPS 解锁（不起作用）
**类别:** 策略　**优先级:** P2　**置信度:** 中
**来源:** `src/config/fps-unlock.tsx:26-58,73-87`
**规格:** 下拉框，键为 `config_fps_unlock`，可选值为 `default`、`120`、`144`，默认值 default。整个 `src` 中都没有读取这个键的代码。
**疑似缺陷:** 设置不起作用，DXMT 的帧率上限固定为 60（LCH-033）。
**置信度说明:** **待确认：**原生版是删掉这一项，还是真正实现它？

### CFG-020: ReShade
**类别:** 策略　**优先级:** P2　**置信度:** 高
**来源:** `src/config/reshade.tsx:13-26`
**规格:** 复选框，键为 `config_reshade`，默认值 false，标签硬编码为 "ReShade"。效果见 LCH-002 和 LCH-017。
**边界情况:** 发行版的界面里看不到这一项，但如果存储里有这个值，仍然会生效。

### CFG-021: 启用 HDR
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/config/enable-hdr.tsx:13-26`
**规格:** 复选框，键为 `config_hk4e_enable_hdr`，默认值 false，文案 key 为 SETTING_ENABLE_HDR。效果见 LCH-006、LCH-037、LCH-038。

### CFG-022: Workaround #3（不起作用）
**类别:** 计算　**优先级:** P2　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/config/workaround-3.tsx:13,22-32,57`
**规格:** 键为 `config_workaround3`。默认值：hk4eos 渠道为 false；其他渠道下，CPU 型号包含 "Apple" 时为 true，否则为 false。默认值不写盘。标签硬编码为 "Workaround #3(does nothing now)"。对 hk4ecn 不起作用（LCH-015）。
**置信度说明:** 建议删除。**待确认：**是否需要保留这个键以兼容旧版本？

### CFG-023: 关闭反作弊补丁（patch-off）
**类别:** 策略　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/config/patch-off.tsx:13-26`
**规格:** 复选框，键为 `config_patch_off`，默认值 false，文案 key 为 SETTING_TURN_OFF_AC_PATCH。效果见 LCH-013 和 LCH-014。

### CFG-024: Steam 补丁
**类别:** 策略　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/config/steam-patch.tsx:13-26`
**规格:** 复选框，键为 `config_steam_patch`，默认值 false，文案 key 为 SETTING_TURN_ON_STEAM_PATCH。效果见 LCH-011。"应用推荐设置"会把它设为 true。
**疑似缺陷:** zh_CN 语言包中这一项的文案仍是英文。

### CFG-025: Launch Fix（block-net）
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/config/block-net.tsx:13-26`
**规格:** 复选框，键为 `config_block_net`，默认值 false，文案 key 为 SETTING_BLOCK_NET。效果见 LCH-021。

### CFG-026: 自定义分辨率
**类别:** 校验　**优先级:** P1　**置信度:** 中
**来源:** `src/clients/mhy/hk4e/config/resolution.tsx:26-28,68-72,115-119,159-163`
**规格:** 一个复选框（`config_resolution_custom`，默认值 false），加两个自由文本框：宽（`config_resolution_width`，默认值 "1920"）和高（`config_resolution_height`，默认值 **"1920"**）。界面上不做校验。效果见 LCH-007 和 LCH-008。开启自定义分辨率会让 MetalFX 失效（LCH-004）。
**疑似缺陷:** 高度的默认值应该是 1080，现在是 1920，所以只勾选不填写时，分辨率是 1920×1920。
**置信度说明:** **待确认：**默认高度改为 1080 吗？是否要限制为正整数？

### CFG-027: Timeout Fix
**类别:** 策略　**优先级:** P1　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/config/timeout-fix.tsx:13-26`
**规格:** 复选框，键为 `config_timeout_fix`，默认值 false，文案 key 为 SETTING_TIMEOUT_FIX。决定 `WINE_ENABLE_TIMEOUT_FIX` 的值（LCH-032）。"应用推荐设置"会把它设为 true。

### CFG-028: 原生全屏与游戏模式
**类别:** 策略　**优先级:** P0　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/config/game-mode.tsx:13-35`
**规格:** 复选框，键为 `config_game_mode`，**默认值 true**（这是唯一默认开启的布尔设置），文案 key 为 SETTING_GAME_MODE。效果见 LCH-022 到 LCH-031。

### CFG-029: MetalFX 超分
**类别:** 计算　**优先级:** P1　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/config/metalfx-upscale.tsx:13-35`
**规格:** 复选框，键为 `config_metalfx_upscale`，默认值 false，文案 key 为 SETTING_METALFX_UPSCALE。只有在没开自定义分辨率、且使用 dxmt 时才生效（LCH-004）。
**边界情况:** 界面上没有提示它与自定义分辨率互斥。

### CFG-030: "游戏"标签页的内容顺序
**类别:** 策略　**优先级:** P2　**置信度:** 高
**来源:** `src/clients/mhy/hk4e/index.tsx:305-331`
**规格:** 第一行是硬编码的英文 "Game Version: <版本>"（读取失败时显示 0.0.0）。之后依次为：HDR、Workaround #3、关闭 AC 补丁、Steam 补丁、Launch Fix、自定义分辨率、Timeout Fix、游戏模式、MetalFX。

### CFG-031: 应用推荐设置
**类别:** 策略　**优先级:** P1　**置信度:** 中
**来源:** `src/config/index.tsx:179-227`
**规格:**
  When 用户点击 SETTING_APPLY_RECOMMENDED_SETTINGS
  Then 写入以下键：
  - `wine_state=update`
  - `wine_update_tag=11.0-1-crossover-signed-experimental`
  - `wine_update_url=<crossover 的地址>`
  - `config_steam_patch=true`（因为渠道以 hk4e 开头）
  - `config_timeout_fix=true`（同上）
  And 弹出 SETTING_RECOMMENDED_SETTINGS_APPLIED 通知
  And 不自动重启，也不刷新内存中的 config 和界面上的复选框
  And 下次启动时，会删除 prefix 并重装 crossover；即使当前已经是 crossover，也会重装
**疑似缺陷:**
- 这个操作会安排重装 Wine、删除 prefix，但没有任何确认。
- 推荐的 Wine 与 hk4ecn 的默认 Wine 不一致。
- 不重启就直接启动游戏时，用的仍是旧的设置值。

**置信度说明:** **待确认：**hk4ecn 的推荐 Wine 到底是哪一个？原生版是否要先确认再自动重启，并且在当前已是目标版本时跳过重装？

### CFG-032: 打开 Wine 命令行、游戏目录、数据目录
**类别:** 策略　**优先级:** P2　**置信度:** 高
**来源:** `src/config/index.tsx:229-267`
**规格:** 三个按钮的行为：
- 打开 Wine 命令行：见 WIN-022。
- 打开游戏目录：执行 `open <game_install_dir>`。
- 打开数据目录：执行 `open <data>`。日志位于 `<data>/logs/`。

### CFG-033: 检查 YAAGL 更新
**规格:** 同见 UPD-007 和 UPD-009。

### CFG-034: Licenses 标签页
**类别:** 策略　**优先级:** P2　**置信度:** 高
**来源:** `src/config/index.tsx:297-349`
**规格:** 显示 steam.exe 和 lsteamclient.dll 的 Valve BSD-3 许可证全文（英文，硬编码）。只要继续分发这两个文件，这份声明就必须保留。

### 设置项总表

| 键名 | 类型 | 默认值 | UI 文案 key | 来源 | 读取方 |
|---|---|---|---|---|---|
| `wine_tag` | string | 安装时写入，首次为 `11.0-dxmt-signed-with-patches` | SETTING_WINE_VERSION | `src/config/wine-distribution.tsx:35` | `src/wine/distro.ts:114` |
| `wine_state` | `ready`\|`update` | 不存在 | — | `wine-distribution.tsx:84`、`config/index.tsx:187` | `distro.ts:105` |
| `wine_update_tag` | string | 不存在 | — | `wine-distribution.tsx:85` | `distro.ts:107` |
| `wine_update_url` | string | 不存在 | — | `wine-distribution.tsx:86` | **无（死键）** |
| `game_install_dir` | 路径 | 不存在（表示未安装） | SETTING_GAME_INSTALL_DIR | `hk4e/index.tsx:179,208,221,245` | `hk4e/index.tsx:348` |
| `config_metalHud` | bool | false | SETTING_MTL_HUD | `metal-hud.tsx:21` | `program-launch-game.ts:192` |
| `config_retina` | bool | false | SETTING_RETINA | `retina.tsx:21` | `program-launch-game.ts:116` → `wine.ts:166` |
| `left_cmd` | bool | false | SETTING_LEFT_CMD | `left-cmd.tsx:21` | `wine.ts:169` |
| `config_proxyEnabled` | bool | false | SETTING_PROXY_ENABLED | `proxy-enabled.tsx:21` | `program-launch-game.ts:208` |
| `config_proxyHost` | string | `127.0.0.1:8080` | SETTING_PROXY_HOST | `proxy-host.tsx:27-29` | `program-launch-game.ts:210-211` |
| `config_uiLocale` | locale id | 由系统语言推断，回退为 en；启动时写入 | SETTING_UI_LOCALE | `ui-locale.tsx:30` | `locale/index.ts:37` |
| `config_advanced` | bool | false（另需构建开关） | SETTING_ADVANCED | `config/index.tsx:81,106` | `config/index.tsx:79-83` |
| `config_fps_unlock` | `default`\|`120`\|`144` | default | SETTING_FPS_UNLOCK | `fps-unlock.tsx:26` | **无（死键）** |
| `config_reshade` | bool | false | 硬编码 "ReShade" | `reshade.tsx:13` | `hk4e/index.tsx:270`、`patch.ts:97,170` |
| `config_hk4e_enable_hdr` | bool | false | SETTING_ENABLE_HDR | `enable-hdr.tsx:13` | `program-launch-game.ts:117,220` |
| `config_workaround3` | bool | Apple CPU 为 true | 硬编码 | `workaround-3.tsx:13,22-32` | `patch.ts:40,55`（hk4ecn 下无效） |
| `config_patch_off` | bool | false | SETTING_TURN_OFF_AC_PATCH | `patch-off.tsx:13` | `patch.ts:38,138` |
| `config_steam_patch` | bool | false | SETTING_TURN_ON_STEAM_PATCH | `steam-patch.tsx:13` | `program-launch-game.ts:187` |
| `config_block_net` | bool | false | SETTING_BLOCK_NET | `block-net.tsx:13` | `program-launch-game.ts:143` |
| `config_resolution_custom` | bool | false | SETTING_CUSTOM_RESOLUTION | `resolution.tsx:26` | `program-launch-game.ts:114,121,223` |
| `config_resolution_width` | string | "1920" | （同上） | `resolution.tsx:27,118` | `program-launch-game.ts:62` |
| `config_resolution_height` | string | **"1920"** | （同上） | `resolution.tsx:28,162` | `program-launch-game.ts:63` |
| `config_timeout_fix` | bool | false | SETTING_TIMEOUT_FIX | `timeout-fix.tsx:13` | `program-launch-game.ts:194` |
| `config_game_mode` | bool | **true** | SETTING_GAME_MODE | `game-mode.tsx:13,22` | `program-launch-game.ts:178` |
| `config_metalfx_upscale` | bool | false | SETTING_METALFX_UPSCALE | `metalfx-upscale.tsx:13` | `program-launch-game.ts:113,202` |

同一存储中还有以下非设置类的状态键，原生版也需要兼容：

| 键名 | 用途 |
|---|---|
| `patched` | LCH-019 |
| `predownloaded_all` | PRE-002 |
| `installed_dxmt_version` | WIN-019 |
| `installed_reshade` | LCH-002 |
| `ignore_launcher_update` | UPD-008 |
| `wine_netbiosname` | 死数据 |
| `singleton` | 死数据 |

## 13. 数据对象

**Server 定义（hk4ecn）**：类型定义在 `src/constants/server.ts:1-26`，实例在 `src/clients/hk4ecn.ts:27-66`。

| 字段 | 值 |
|---|---|
| `id` | `"hk4e_cn"` |
| `channel_id`、`subchannel_id` | 1 |
| `update_url`、`cps`、`adv_url`、`dataDir`、`executable`、`THE_REAL_COMPANY_NAME`、`product_name`、`hosts` | 来自 secret 常量 `CN_*` |
| `removed` | 3 个路径（LCH-014） |
| `patched`、`added` | `[]` |
| `releaseType` | `"cn"` |

**ChannelClient 接口**：定义在 `src/channel-client.ts:6-38`。

| 成员 | 说明 |
|---|---|
| `installState` | 取值为 `INSTALLED` 或 `NOT_INSTALLED` |
| `installDir` | 安装目录 |
| `showPredownloadPrompt`、`predownloadVersion`、`dismissPredownload` | 预下载提示 |
| `updateRequired` | 是否需要更新 |
| `uiContent` | `{background, background_video, background_theme, url, iconImage?, launchButtonLocation?, logo?}` |
| `update`、`install(path)`、`predownload`、`launch(config)`、`checkIntegrity`、`init(config)` | 操作 |
| `createConfig` | 创建设置项 |

**进度命令**：定义在 `src/common-update-ui.tsx:73-81`，共三种：`["setProgress", n]`、`["setStateText", key, ...args]`、`["setUndeterminedProgress"]`。

**Sophon HTTP/WS API**：定义在 `sophon_server/server.py:72-118`、`sophon_server/models.py:5-40`。

| 接口 | 说明 |
|---|---|
| `POST /api/{install,repair,update}` | 请求体为 `{gamedir, game_type, tempdir?}`，另加各操作的专有字段：install 用 `install_reltype`，update 用 `predownload`，repair 用 `repair_mode`。返回 `{task_id, status, message}` |
| `GET /api/tasks/{id}/status` | 查询任务状态 |
| `DELETE /api/tasks/{id}` | 取消任务 |
| `GET /api/game/online_info` | 返回 `{game_type, version, install_size, updatable_versions[], release_type, pre_download, pre_download_version?, error?}` |
| `GET /health` | 健康检查 |
| `WS /ws/{task_id}` | 任务事件推送 |

**事件类型**：定义在 `sophon_server/progress_handlers.py`。

| 分组 | 事件 |
|---|---|
| 任务 | job_start、job_end、job_error |
| 下载 | download_summary、chunk_progress{filename, …, overall_progress{downloaded_size, total_size, overall_percent, download_speed}}、file_download_start、file_download_skipped、file_download_complete、file_download_error |
| 修复 | repair_summary、check_file |
| 删除 | delete_file_summary、delete_file、delete_ldiff_file_summary、delete_ldiff_file |
| ldiff 下载 | ldiff_download_summary、ldiff_download_start、ldiff_download_skipped、ldiff_download_complete、ldiff_download_error |
| ldiff 打补丁 | ldiff_patch_start、ldiff_patch_complete、ldiff_patch_error、ldiff_patch_skipped |
| 其他 | completed、error（`utils.py:88-104`） |

**HoYoPlay 分支**：`game_branches[0].main` 和 `.pre_download` 的结构为 `{branch, package_id, password, tag, diff_tags[]}`。getBuild 和 getPatchBuild 的返回为 `data.tag` 加上 `data.manifests[]{matching_field, manifest{id}, manifest_download{url_prefix}, chunk_download{url_prefix}, diff_download{url_prefix}}`。

**Sophon chunk manifest**：定义在 `sophon_server/manifest.proto:9-25`。

```
Manifest  { files[] }
FileInfo  { filename, chunks[], flags (0=文件, 64=目录), size (int32), md5 }
ChunkInfo { chunk_id, md5, offset, compressed_size, uncompressed_size, xxhash }
```

`size` 是 int32，超过 2 GiB 的文件会溢出。**待确认：**原神是否有超过 2 GiB 的单个文件？

**ldiff manifest**：定义在 `sophon_server/manifest_ldiff.proto:8-61`。

```
DiffManifest { files[], files_delete[] }
DiffFileInfo { filename, size, hash, patches[{ key, info: PatchInfo }] }
PatchInfo    { patch_id, tag, build_id, patch_size, patch_name, patch_offset,
               patch_length, original_name, original_size, original_hash }
DeleteFile   { key, info{ list[{ filename, size, hash }] } }
```

**HoYoConnect 背景**：定义在 `src/clients/mhy/launcher-info.ts:127-203`，结构为 `{background{url,link}, icon{url,hover_url,link}, video{url,size}, theme{url,link}, type}`。对 hk4ecn 而言，`getLatestVersionInfo` 和 `LauncherResourceData` 都是死代码。

### 数据目录布局（`<data>` = `~/Library/Application Support/Yaagl`）

| 路径 | 写入方 | 读取方 | 来源 |
|---|---|---|---|
| `.bundle-stamp` | 启动脚本 | 启动脚本 | `build-app.js:229-233` |
| `resources.neu` / `resources.neu.update` | rsync / 自更新 | Neutralino | `build-app.js:231`、`updater.ts:137,151` |
| `sidecar/`（aria2、7z、xdelta、hpatchz、protonextras、gamehost、sophon_server） | rsync / 自更新 | 多处 | `build-app.js:259-306`、`updater.ts:112-130` |
| `icon.icns` | rsync | game-host | `game-host.ts:103-107` |
| `.storage/*.neustorage` | setKey | getKey | `neu.ts:139-156` |
| `aria2.session` | aria2 | aria2 | `app.tsx:54-69` |
| `wine.tar.{xz,gz}`（临时） | aria2 | tar | `wine-install-program.ts:40,72` |
| `wine/`（运行时，含 DXMT 的 `.bak`、winemetal、shim/wine-host、注入证书的 wine.inf） | Wine 安装、patch、game-host、cert | wine | `wine-install-program.ts:57-77`、`patch.ts:69-84`、`game-host.ts:76-84` |
| `wineprefix/` | wineboot、patch | Wine | `app.tsx:104`、`patch.ts:66-121` |
| `dxmt/` | DXMT 下载 | patch | `downloadable-resource.ts:152-210` |
| `reshade/` | ReShade 下载 | patch | `downloadable-resource.ts:222-296` |
| `YaaglGame.app/` | game-host | LaunchServices | `game-host.ts:17,87-115` |
| `logs/game_<ts>.log`、`logs/gamehost.log` | 启动游戏 | 人工排查 | `program-launch-game.ts:137,141`、`game-host.ts:121` |
| `wineboot.log`、`winecfg.log` | Wine 安装 | 人工排查 | `wine-install-program.ts:89-90` |
| `winedrv_config.bat`（不删除）、`config.bat`、`hk4e_*.reg`（临时） | 启动游戏 | wine | `wine.ts:173`、`program-launch-game.ts:39,81,135,262,292` |
| `dxmt.conf`（启动器不写） | 用户 | DXMT | `program-launch-game.ts:199-201` |
| `decompress.log` | unzip/7z | 进度轮询 | `unix.ts:56,122` |

数据目录之外还有：

- `/etc/hosts`（WIN-011、LCH-021）
- `/tmp/.wine-<uid>/server-*`（LCH-003）
- `/tmp/yaagl_network_block_script.sh`

游戏目录内的文件：`config.ini`、`.tmp/`、`ldiff/`、`*.bak`、`ReShade.ini`、ReShade 的两个 DLL。

## 14. 需要维护者确认的问题

| # | 规则 | 问题 |
|---|---|---|
| 1 | UPG-004 | CN 的 Sophon 更新和预下载在代码中会走到 `assert False`。是否在 CN 上实际完成过更新？正确的 getBuild/getPatchBuild 端点是什么？ |
| 2 | REP-004、UPG-009 | "大小对、MD5 错"的文件无法修复。原生版修正这个问题算对等还是行为变更？（建议修正） |
| 3 | APP-013 | 出错即致命退出。原生版是否改为可以重试？ |
| 4 | APP-015 | 预下载与主队列并发。是否改为互斥？ |
| 5 | APP-010 | 离线或接口失败时的行为：允许启动已安装的游戏吗？ |
| 6 | INS-004 | 磁盘空间检查是否改为按解压后大小计算？更新是否也要检查空间？ |
| 7 | INS-008 | 原神 manifest 中有没有同名但目录不同的文件？ |
| 8 | INS-015 | 是否支持断点续装？ |
| 9 | UPG-014 | 是否需要语音包管理？ |
| 10 | PRG-001 | 是否遇到过界面卡在"正在分配磁盘空间"？ |
| 11 | REP-005 | hk4e 的完整性检查不清除 `patched`，是有意的吗？ |
| 12 | LCH-006 | CN 的 HDR 注册表键是否真的写对了？（编码问题） |
| 13 | LCH-011 | steamPatch 模式下不带云参数、不复制驱动，是有意的吗？ |
| 14 | LCH-038 | 崩溃后不撤销注册表，能接受吗？ |
| 15 | WIN-020 | DXMT 注入到一半时崩溃，会覆盖 `.bak`。是否改为先检查再替换？ |
| 16 | LCH-033、CFG-019 | FPS 解锁是接上，还是删掉？ |
| 17 | CFG-022、LCH-015 | Workaround #3 是否删除？ |
| 18 | CFG-006 | 是否保留高级页和解锁手势？ |
| 19 | WIN-002、CFG-031 | hk4ecn 的默认 Wine 和推荐 Wine 各选哪个？"推荐设置"是否要确认后自动重启？ |
| 20 | CFG-026 | 默认高度是否改为 1080？是否加数字校验？ |
| 21 | CFG-015 | 代理主机是否要做格式校验？ |
| 22 | CFG-017 | 首次运行是否把推断出的语言写入存储？ |
| 23 | CFG-001 | 原生版能否直接读写 `.storage/*.neustorage`？还是迁移到别的格式？ |
| 24 | WIN-009 | 根证书的用途是什么？ |
| 25 | WIN-015、APP-001 | `wine_netbiosname`、`singleton` 能否删除？是否需要单实例锁？ |
| 26 | UPD-016 | 启动器自身的下载是否要走代理？ |
| 27 | APP-006 | aria2 的 `--pause true` 是否会作用于新建的任务？（原生版不再使用 aria2，只影响对旧行为的理解） |
| 28 | 数据对象 | 原神是否有超过 2 GiB 的单个文件？（int32 的 size 会溢出） |

## 15. 地图上还没有的决策问题

以下问题是这次研究中新发现的，地图 #13 中还没有对应的决策票：

1. **CN 的 Sophon 更新端点。** UPG-004 说明旧版在 CN 上没有可用的更新和预下载实现。要做到"对等"，必须先找到并验证 CN 的 getBuild/getPatchBuild 端点。这个问题需要单独研究或做原型。
2. **"对等"是否包括旧版的缺陷。** 本文标出了约 30 条疑似缺陷，例如 REP-004、UPG-009、APP-013、APP-015、INS-004、CFG-026、CFG-019、CFG-022 和高级页。需要一个统一的原则：哪些照搬，哪些修正，哪些删除。
3. **`.storage` 存储格式的兼容与迁移。** 地图已锁定"沿用数据目录"，但没有说明原生版是继续读写 `.storage/*.neustorage`，还是迁移到 UserDefaults 或 JSON，以及迁移后旧 TS 版降级时怎么办。
4. **Wine 切换和 prefix 重建的用户体验。** 默认 Wine 与推荐 Wine 不一致，并且切换时会无提示地删除 prefix。
5. **安全相关的行为是否保留。** 包括 `/etc/hosts` 永久段（需要 sudo）、启动时临时屏蔽网络（每次启动都要 sudo）、quarantine 移除，以及 aria2 RPC 暴露的问题。原生版可能改用不需要 sudo 的方案，需要决策。
