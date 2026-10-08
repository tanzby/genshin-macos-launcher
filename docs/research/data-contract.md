# 数据目录与设置契约（原神 CN）

研究票 #18，属于地图 #13「原生 macOS 迁移（原神 CN）」。问题：原生 Swift App 要无缝沿用 `~/Library/Application Support/Yaagl`，用户升级后不用重下游戏、不用重建 prefix，需要满足什么契约，哪些东西可以清理。

依据：本仓库源码（`origin/main` f38cda4）、NeutralinoJS v4.11.0 源码（本项目锁定的版本，`neutralino.config.json:49`），以及对维护者本机数据目录的只读查看（2026-10-08，App 版本 0.1.3）。设置值只记录 key 和类型，不记录内容。

## 结论摘要

1. **数据目录是硬编码的 `~/Library/Application Support/Yaagl`**。目录名来自发行名 `Yaagl`（`appDistributionName`），与 bundle id 无关。所有相对路径都以它为根，因为 Neutralino 用 `--path` 指向它，进程 cwd 也是它。
2. **设置就是 `.storage/<key>.neustorage` 文件**，每个 key 一个文件，内容是原始 UTF-8 字符串（不是 JSON，没有换行），文件不存在就表示用默认值。布尔值写成字面量 `true`/`false`。原生 App 直接按这个格式读写即可，不需要迁移。
3. **最危险的契约是 `wine_tag`**：TS 版启动时如果 `wine_tag` 不在内置发行版列表里，就会重装 Wine，而重装会先 `rm -rf wineprefix`。原生 App 的 Wine 列表必须认得现有的 tag（本机是 `11.0-1-crossover-signed-experimental`），否则用户的 prefix 会被删掉。
4. `wine/` 不是原样的发行包：Game Mode 把 `lib/wine/x86_64-unix/wine` 换成了 shim（原文件改名为 `wine-host`），DXMT 的 DLL 也拷进了 `lib/wine/`。原生 App 要么原样接管这些改动，要么用同样的幂等逻辑重做，不能假设 `wine/` 是干净的。
5. **可以安全清理的**：`resources.neu`、`.bundle-stamp`、`neutralinojs.log`、`sidecar/`（等所有 sidecar 都被替换之后），以及 `~/Library/Caches/com.3shain.yaagl`、`~/Library/WebKit/com.3shain.yaagl` 这两个 WKWebView 残留。`wine-gptk4/`、`gptk4/` 只是开发诊断用的，生产代码不读，但它们属于用户，不应自动删除。
6. 原生 App 必须**不开沙盒**：沙盒会把 Application Support 重定向到容器目录，就读不到现有数据了（本来也不做 codesign）。

## 1. 数据目录从哪里来

- `build-app.js` 生成的 `Contents/MacOS/parameterized` 才是真正的 `CFBundleExecutable`（`build-app.js:323-324`）。它：
  - 设 `APST_DIR="$HOME/Library/Application Support/${appDistributionName}"` 并 `mkdir -p`（`build-app.js:222-224`）；
  - 把 `Contents/Resources/.` rsync 到 `APST_DIR`（`resources.neu`、`sidecar/`、`icon.icns`、空的 `.storage/`）。用 `.bundle-stamp` 记录 `resources.neu` 的 md5：md5 没变就用 `-u`（保留应用内更新器写入的新文件），变了就全量覆盖（`build-app.js:229-234`）；
  - `cd "$APST_DIR"`，再用 `--path="$APST_DIR"` 启动 Neutralino 二进制，并把 `.app` 路径放进 `PATH_LAUNCH`（`build-app.js:235-236`）。
- Neutralino 把 `--path` 存为 `appPath`（settings.cpp v4.11.0:143-144），作为 `NL_PATH` 注入页面（settings.cpp:95）。存储、`resources.neu`、日志都用 `joinAppPath` 拼到它下面（storage.cpp:47、resources.cpp:17,45-46、main.cpp:24）。
- TS 侧 `resolve()` 在生产环境把相对路径拼到 `NL_PATH` 上（`src/utils/neu.ts:4-17`）。shell 出去的命令（如 `./sidecar/aria2/aria2c`，`src/app.tsx:58`）靠的是 cwd 等于数据目录。
- 开发模式（`pnpm start`）下 `NL_PATH` 相对于 `NL_CWD`（`src/utils/neu.ts:7-9`），所以数据在仓库目录里，与生产数据分开。

**原生契约**：直接用 `FileManager` 的 `.applicationSupportDirectory` + `"Yaagl"` 拼路径（这个 URL 本身与 bundle id 无关），不要用 bundle id 当子目录名；启动 Wine 和子进程时把 cwd 设成数据目录，因为 DXMT 的 `*_d3d11.log` / `*_dxgi.log` 就写在 cwd 下（见第 2 节）。

## 2. 目录布局（本机实测 + 源码）

| 路径 | 大小 | 作用 / 写入者 | 原生 App 的处理 |
|---|---|---|---|
| `.storage/` | 很小 | Neutralino 键值存储，见第 3 节 | **必须保留并读写** |
| `wine/` | 2.0 GB | Wine 运行时。下载解压位置在 `src/wine/wine-install-program.ts:35,56-68`，运行时路径见 `src/wine/wine.ts:24-28` | **必须保留**；里面有 shim 和 DXMT 改动（见下） |
| `wineprefix/` | 589 MB | `WINEPREFIX`（`src/app.tsx:104`、`src/wine/wine.ts:120-124`）。`dosdevices/` 里有 `c:`、`z:` 和用户挂载卷的符号链接 | **必须保留**，不能重建 |
| `dxmt/` | 42 MB | DXMT 构件。按 `installed_dxmt_version` 判断是否需要重下（`src/downloadable-resource.ts:142-212`） | 保留；版本对不上时可以重下 |
| `YaaglGame.app/` | 436 KB | Game Mode 用的游戏 bundle，`com.3shain.yaagl.game`，`MacOS/wine` 是 `wine-host` 的副本，已用 `lsregister` 注册（`src/wine/game-host.ts:17-21,86-115`） | 保留，或用同样的幂等逻辑重建 |
| `icon.icns` | 380 KB | 从 bundle rsync 而来，`YaaglGame.app` 会拷它（`src/wine/game-host.ts:103-105`） | 原生 App 改为从自己的 bundle 取 |
| `logs/` | 很小 | `game_<ms>.log`（`src/clients/mhy/hk4e/program-launch-game.ts:137-141`）、`gamehost.log`（`src/wine/game-host.ts:121`） | 可继续沿用；旧日志可删 |
| `sidecar/` | 92 MB | aria2、7z、hpatchz、xdelta、sophon_server、gamehost（shim/dylib）、protonextras（steam*.exe、lsteamclient*.dll） | 外部二进制全部替换后可删；**protonextras 的 4 个文件仍是 Steam patch 的输入**（`src/clients/mhy/patch.ts:107-119`），要改为由原生 bundle 提供 |
| `resources.neu` | 1 MB | Neutralino 前端包（resources.cpp:17）；应用内更新器写到这里（`src/updater.ts:137,151`） | Neutralino 残留，可删 |
| `.bundle-stamp` | 33 B | `parameterized` 脚本用的 md5 | 可删 |
| `neutralinojs.log` | 4 MB | Neutralino 日志（main.cpp:24，`neutralino.config.json:14`） | 可删 |
| `aria2.session` | 0 B | aria2 会话（`src/app.tsx:54-55`） | 不再用 aria2 后可删 |
| `winedrv_config.bat` | 很小 | 写 Retina/LeftCmd 注册表时的临时脚本（`src/wine/wine.ts:173-176,190-193`） | 临时文件，可删 |
| `decompress.log`、`*_d3d11.log`、`*_dxgi.log` | 很小或 0 | 解压日志；DXMT 写在 cwd 下的日志 | 可删 |
| `wine-gptk4/`、`gptk4/` | 2.1 GB + 68 MB | 只给开发诊断用（`YAAGL_WINE_RUNTIME`，`src/wine/wine.ts:24-28`；`scripts/dev/yaagl-diag:173,567`） | 生产代码不读；属于用户，不要自动删 |

只会临时出现的文件（启动或安装结束时删除）：`config.bat`、`hk4e_enable_hdr.reg`、`hk4e_resolution.reg`、`hk4e_revert_*.reg`（`src/clients/mhy/hk4e/program-launch-game.ts:39,81,135,234,262,292`），`wine.tar.xz`、`wineboot.log`、`winecfg.log`（`src/wine/wine-install-program.ts:40,89-90`），`sidecar.tar.gz`、`resources.neu.update`（`src/updater.ts:105,137`）。原生 App 启动时可以顺手清掉这些残留。

**游戏目录不在数据目录里**：它是 `game_install_dir` 里存的绝对路径，本机指向一个外部目录（`src/clients/mhy/hk4e/index.tsx:179-245,348`）。版本号从 `<game_install_dir>/<dataDir>` 读取（`src/clients/mhy/hk4e/index.tsx:345-370`，`src/clients/hk4ecn.ts:34`）。

### `wine/` 被改动过

- **Game Mode shim**：`prepareGameHost` 第一次运行时把 `wine/lib/wine/x86_64-unix/wine` 改名为 `wine-host`，再把 `sidecar/gamehost/yaagl-wine-shim` 拷到 `wine` 的位置（`src/wine/game-host.ts:77-84`）。本机实测这两个文件都在。之后每次只比较 shim 是否相同。原生 App 必须：发现 `wine-host` 已经存在时，不能再把当前的 `wine`（也就是 shim）当成原始 host；更新 shim 时只覆盖 `wine`。
- **DXMT**：patch 时把 `dxmt/` 里的 DLL 拷进 `wine/lib/wine/x86_64-windows/`（先备份成 `.bak`），把 `winemetal.so` 拷进 `x86_64-unix/`，把 `winemetal.dll`、`nvngx.dll` 拷进 prefix 的 `system32`（`src/clients/mhy/patch.ts:66-95`）；revert 时把 `.bak` 恢复回来（`src/clients/mhy/patch.ts:159-169`）。

## 3. 设置存储：Neutralino storage

### 格式（NeutralinoJS v4.11.0）

- 目录：`<appPath>/.storage`；文件：`<key>.neustorage`（storage.cpp:17-18,47-48）。
- key 必须匹配 `^[a-zA-Z-_0-9]{1,50}$`（storage.cpp:20,29-35）。
- `getData` 原样返回文件内容；文件不存在就报 `NE_ST_NOSTKEX`（storage.cpp:50-57）。TS 的 `getKeyOrDefault` 和各个 `try/catch` 把这个错误当作“用默认值”（`src/utils/neu.ts:139-152`）。
- `setData` 写入的是字符串本身，不做 JSON 编码（storage.cpp:83-85）。**`data` 为 `null` 或缺失时删除文件**（storage.cpp:79-81，helpers.cpp:95-96）。TS 用 `setKey(key, null)` 删 key（`src/utils/neu.ts:154-156`）。
- 写入不是原子的（直接 `fs::writeFile`）。原生 App 用临时文件 + rename 写入，与这个格式完全兼容。
- 本机实测：布尔值文件就是 4 字节的 `true` 或 5 字节的 `false`，没有换行。

**原生读取规则**：读文件（UTF-8），**不要 trim 也不要 JSON 解析**；文件不存在就用默认值。布尔值按各自的比较方式解析（大多是 `== "true"`；`config_game_mode` 是 `!= "false"`）。写入时布尔值写 `true`/`false`，删除就删文件。

### hk4ecn 用到的 key

“默认值”指文件不存在时的取值。

| key | 类型 | 默认值 | 出处 |
|---|---|---|---|
| `game_install_dir` | 绝对路径字符串 | 不存在 = 未安装 | `src/clients/mhy/hk4e/index.tsx:179,208,221,245,348` |
| `patched` | `"1"` 或不存在 | 不存在 | `src/clients/mhy/patch.ts:35,124,134,174`；启动时如果存在就 revert（`src/clients/mhy/hk4e/index.tsx:290-302`） |
| `predownloaded_all` | `"true"` 或不存在 | 不存在 | `src/clients/mhy/hk4e/index.tsx:119`，`program-update-game.ts:139,199` |
| `wine_state` | `"ready"` 或 `"update"` | 不存在 → 安装 Wine | `src/wine/distro.ts:105`，`src/wine/wine-install-program.ts:109`，`src/config/wine-distribution.tsx:84` |
| `wine_tag` | 发行版 id 字符串 | 不存在 → 安装 Wine | `src/wine/distro.ts:114-127`，`src/wine/wine-install-program.ts:110` |
| `wine_update_tag` / `wine_update_url` | 字符串，只在 `wine_state=update` 时存在 | 不存在 | `src/config/wine-distribution.tsx:85-86`，`src/config/index.tsx:187-195`，`src/wine/wine-install-program.ts:111-112` |
| `wine_netbiosname` | 15 个字符的 `DESKTOP-xxxxxxx` | 不存在就生成并写入；生成后没有任何地方读它（死代码） | `src/wine/wine.ts:155-161`，`src/wine/wine-install-program.ts:113-114` |
| `installed_dxmt_version` | commit 短 hash 字符串 | `"0.0.0"` → 重下 | `src/downloadable-resource.ts:142-147,212` |
| `installed_reshade` | 版本字符串 | `"0.0.0"` | `src/downloadable-resource.ts:215-226,296` |
| `config_uiLocale` | 小写语言 id，如 `zh_cn`、`en` | 按系统语言推断，不认识就用 `en` | `src/locale/index.ts:34-52`，`src/config/ui-locale.tsx:30` |
| `config_retina` | bool | false | `src/config/retina.tsx:21-23` |
| `left_cmd` | bool | false | `src/config/left-cmd.tsx:21-23` |
| `config_metalHud` | bool | false | `src/config/metal-hud.tsx:21-23` |
| `config_fps_unlock` | `"default"`、`"120"` 或 `"144"` | `"default"` | `src/config/fps-unlock.tsx:26,36-38` |
| `config_reshade` | bool | false | `src/config/reshade.tsx:13,23-25` |
| `config_proxyEnabled` | bool | false | `src/config/proxy-enabled.tsx:21-23` |
| `config_proxyHost` | `host:port` 字符串 | `"127.0.0.1:8080"` | `src/config/proxy-host.tsx:27-29` |
| `config_advanced` | bool | false | `src/config/index.tsx:81,106` |
| `ignore_launcher_update` | 版本字符串 | `""` | `src/app.tsx:101,192` |
| `config_workaround3` | bool | Apple CPU（hk4ecn）为 true | `src/clients/mhy/hk4e/config/workaround-3.tsx:22-31` |
| `config_patch_off` | bool | false | `src/clients/mhy/hk4e/config/patch-off.tsx:13,23-25` |
| `config_steam_patch` | bool | false（“推荐设置”会写 true） | `src/clients/mhy/hk4e/config/steam-patch.tsx:13,23-25`，`src/config/index.tsx:197-202` |
| `config_block_net` | bool | false | `src/clients/mhy/hk4e/config/block-net.tsx:13,23-25` |
| `config_hk4e_enable_hdr` | bool | false | `src/clients/mhy/hk4e/config/enable-hdr.tsx:13,22-26` |
| `config_resolution_custom` | bool | false | `src/clients/mhy/hk4e/config/resolution.tsx:26,69-71` |
| `config_resolution_width` / `_height` | 数字字符串 | 都是 `"1920"`（height 的默认值疑似笔误） | `src/clients/mhy/hk4e/config/resolution.tsx:27-28,116-118,160-162` |
| `config_timeout_fix` | bool | false（“推荐设置”会写 true） | `src/clients/mhy/hk4e/config/timeout-fix.tsx:13,23-25` |
| `config_game_mode` | bool | **true**（`!= "false"`） | `src/clients/mhy/hk4e/config/game-mode.tsx:13,22` |
| `config_metalfx_upscale` | bool | false | `src/clients/mhy/hk4e/config/metalfx-upscale.tsx:13,22-23` |
| `singleton` | 已废弃 | 启动时删除 | `src/app.tsx:42` |

本机 `.storage` 里实际有 16 个 key，都在上表中；没有的 key 就是在用默认值，原生 App 不能假设所有 key 都存在。其他渠道独有的 key（`installed_moltenvk_version`、`installed_dxvk_version`、`installed_jadeite_version`、bh3/nap 的预下载 key）在 hk4ecn 的数据目录里不会出现，可以忽略。

注意：
- 原生 App 只保留 zh-Hans 和 en：读到 `zh_cn` 映射成 zh-Hans，其他值都按 en 处理；写回时也用 `zh_cn` / `en`，这样回退到 TS 版仍然能读。
- `patched` 存在说明上次 patch 之后没有正常 revert（例如崩溃）。原生 App 启动时必须先 revert：恢复游戏目录和 `wine/` 里的 `.bak`，再删掉这个 key。否则游戏目录里会一直留着改过的文件。

## 4. bundle id、渠道与数据目录

- 渠道在构建时由 `YAAGL_CHANNEL_CLIENT` 决定。它同时决定 bundle id 和发行名（`build-app.js:19-74`）：hk4ecn 是 `com.3shain.yaagl` / `Yaagl`，hk4eos 是 `.os` / `Yaagl OS`，依此类推；`YAAGL_TEST` 会再加 `.test` / ` Test`。
- **数据目录名来自发行名，不是 bundle id**（`build-app.js:222`）。所以只要发行名还叫 `Yaagl`，改 bundle id 不影响数据目录；反过来，把发行名改成别的就会换到一个新目录。
- bundle id 实际影响的东西：
  - `Info.plist` 的 `CFBundleIdentifier`（`build-app.js:327-328`）；
  - `~/Library/Caches/com.3shain.yaagl`（8.7 MB）和 `~/Library/WebKit/com.3shain.yaagl`：Neutralino 的 WKWebView 缓存。代码不使用 `localStorage` 或 IndexedDB，所以里面没有设置数据；
  - 原生 App 的 `UserDefaults` 域（Sparkle 状态会放在这里）。本机还没有 `~/Library/Preferences/com.3shain.yaagl.plist`，不会冲突；
  - `YaaglGame.app` 用的是另一个 id `com.3shain.yaagl.game`，而且 codesign 的 identifier 必须与它一致，否则每次 `getaddrinfo` 会卡大约 35 秒（`src/wine/game-host.ts:21,99-102`，`docs/genshin-macos.md:13`）。
- 结论：沿用 `com.3shain.yaagl` 能让 macOS 把它当作同一个 App 升级（Dock、登录项、隐私授权都保留），但这不是读到数据的前提。数据目录只认 `Yaagl` 这个名字。

## 5. 原生 App 必须满足的契约

1. 数据根目录固定为 `~/Library/Application Support/Yaagl`；App 不开沙盒；子进程的 cwd 设为数据根目录。
2. 按第 3 节的格式读写 `.storage/*.neustorage`（原始字符串、文件不存在就用默认值、删除就删文件）。保留所有 key 名和取值，这样用户回退到 TS 版仍然能用。
3. Wine 发行版列表必须认得现有的 `wine_tag`（至少 `11.0-1-crossover-signed-experimental` 和 hk4ecn 默认的 `11.0-dxmt-signed-with-patches`）。遇到不认识的 tag 时不能照搬 TS 的“删 prefix 重装”（`src/wine/wine-install-program.ts:37`），否则就违反了“不重建 prefix”的决策。
4. 沿用 `wine/` 和 `wineprefix/`，用 `WINEPREFIX=<root>/wineprefix`。接管 Game Mode shim 时遵守 `wine-host` 规则（第 2 节）。
5. 启动时如果有 `patched`，先执行 revert。
6. `installed_dxmt_version` 等于当前 DXMT 版本时不重下 `dxmt/`。
7. `game_install_dir` 是外部绝对路径，用户可能选在外置卷上。目录不存在时要当作“未安装”处理，不能报错退出。
8. `wine_netbiosname` 目前只生成不使用。原生 App 可以不读它，但也不要删（回退到 TS 版时它会重新生成，无害）。

## 6. 可以清理的 Neutralino 残留

可以安全删除，原生 App 不读：`resources.neu`、`resources.neu.update`、`.bundle-stamp`、`neutralinojs.log`、`aria2.session`、`decompress.log`、`*_d3d11.log`、`*_dxgi.log`、`winedrv_config.bat`、`config.bat`、`*.reg`、`singleton` 这个 key、`~/Library/Caches/com.3shain.yaagl`、`~/Library/WebKit/com.3shain.yaagl`。

等对应功能移植完再删：`sidecar/` 整个目录。注意 `wine/` 里的 shim 是从 `sidecar/gamehost` 拷过去的副本，删掉 sidecar 不会让 Wine 失效，但 protonextras 必须先改由原生 bundle 提供。

不要动：`wine-gptk4/`、`gptk4/`（开发者自己的诊断运行时）、`logs/`（用户可能要拿去排查问题）。

清理应该等原生 App 确认能正常启动、正常读到设置之后再做，并且只在用户不打算回退到 TS 版之后才删 `resources.neu`。如果回退到 TS 版，它的 `parameterized` 脚本发现 `.bundle-stamp` 不匹配，会重新全量 rsync，所以提前删掉也能恢复，但会多一次拷贝。

## 7. 数据目录之外的副作用

- TS 版会用管理员权限改写 `/etc/hosts`（`src/hosts.ts:3-28`，由 `src/wine/wine-install-program.ts:82` 调用）。这不在数据目录里，原生 App 需要决定是否保留这个行为。
- `YaaglGame.app` 注册在 LaunchServices 里（`src/wine/game-host.ts:115`）。如果原生 App 换了 bundle 的位置或 id，要重新注册。
