# 研究：原神 CN 的 Wine/DXMT 启动契约

地图 #13，研究票 #20。依据 `origin/main` 的 `f38cda4`。所有结论都来自源码，引用格式为 `file:line`。目的是让 Swift 版逐项移植，不遗漏行为。

## 0. 名词与目录

- **数据目录**：`~/Library/Application Support/Yaagl`，下文的 `./` 都相对它。App 启动脚本 `parameterized` 把 `Contents/Resources/.` rsync 到这里，`cd` 进去，再以 `--path=$APST_DIR` 启动 Neutralino（`build-app.js:222`、`build-app.js:233`、`build-app.js:236`）。`resolve()` 把相对路径拼到 `NL_PATH` 上（`src/utils/neu.ts:4-17`）。
- **Wine 运行时**：`./wine`。开发时可用 `YAAGL_WINE_RUNTIME` 换成别的目录（`src/wine/wine.ts:24-29`）。
- **Prefix**：`./wineprefix`，写死在 `src/app.tsx:104`。
- **loader**：如果有 `bin/wine64` 就用它，否则用 `bin/wine`（`src/wine/wine.ts:219-226`）。
- **DXMT 文件**：`./dxmt/`。
- **Game Mode 辅助程序**：`./sidecar/gamehost/yaagl-wine-shim` 和 `yaagl-gamehost.dylib`（`src/wine/game-host.ts:15-16`），由 `native/gamehost/build.sh` 构建成 **x86_64**（`native/gamehost/build.sh:15-17`），打包时生成（`build-app.js:282`）。
- **游戏 App 外壳**：`./YaaglGame.app`，bundle id 是 `com.3shain.yaagl.game`（`src/wine/game-host.ts:17-21`）。
- **设置存储**：Neutralino storage，所有 `getKey`/`setKey` 都走 `Neutralino.storage`（`src/utils/neu.ts:139-156`）。文件放在数据目录的 `.storage/`（`neutralino.config.json:19` 允许 `storage.*`）。

## 1. 进程拓扑

```
Yaagl (Neutralino)
 └─ sh -c "<ENV…> <runtime>/bin/wine64 cmd /c Z:\…\config.bat &> logs/game_<ts>.log"   ← Neutralino.os.spawnProcess
      └─ wine64 (loader)  ── 需要时自动拉起 → <runtime>/bin/wineserver（每个 prefix 一个）
           └─ 每个新 Windows 进程：exec <runtime>/lib/wine/x86_64-unix/wine   ← 实际是 yaagl-wine-shim
                ├─ argv[1] 含 YuanShen.exe → setenv DYLD_INSERT_LIBRARIES=gamehost.dylib，
                │                           exec YaaglGame.app/Contents/MacOS/wine（wine-host 的副本）
                └─ 其他（cmd.exe、services、winedevice、explorer、steam.exe…）
                                          → 清掉 DYLD_INSERT_LIBRARIES，exec 同目录的 wine-host
```

- 启动游戏只有一次 `wine.exec2(...)`（`src/clients/mhy/hk4e/program-launch-game.ts:186-216`）。默认用 `cmd /c config.bat`。开启 Steam patch 时改为直接跑 `C:\windows\system32\steam.exe <game>`（同文件 `:187-190`）。
- `exec2` 先用 `build()` 拼出一行带环境变量前缀的 shell 命令，交给 `Neutralino.os.spawnProcess`，再等 `spawnedProcess` 事件里的 `exit`。退出码不为 0 就 reject（`src/utils/neu.ts:39-86`）。日志用 `&> logfile` 重定向（`src/utils/neu.ts:45-48`）。
- 其他 Wine 调用（`reg`/`regedit`/`wineboot`/`winecfg`）走同步的 `exec`，也就是 `Neutralino.os.execCommand`（`src/wine/wine.ts:35-52`、`src/utils/neu.ts:19-37`）。
- wineserver 只直接调用两种：`wineserver -w` 等待 prefix 空闲，`wineserver -k` 杀掉 prefix（`src/wine/wine.ts:73-81`）。
- shim 的逻辑见 `native/gamehost/wine-shim.c:20-45`。它把 argv[0] 改成自身的真实路径，因为 host 要靠它找 `ntdll.so`。匹配用的是 `strcasestr(argv[1], YAAGL_GAME_HOST_MATCH)`，而且要求 `YAAGL_GAME_HOST_EXE` 可执行。所以 steam.exe 本身不会被匹配，它再拉起的 YuanShen.exe 才会。
- 安装 shim 由 `prepareGameHost` 完成（`src/wine/game-host.ts:66-127`）：
  1. 第一次运行时把原 `x86_64-unix/wine` 改名为 `wine-host`。如果 `wine-host` 已不存在、而 loader 位置已经是 shim，就报错，防止把 shim 当成 host 搬走（`:79-83`）。
  2. 内容不同才复制 shim（`:84`）。
  3. `wine-host` 有变化时，重建 `YaaglGame.app/Contents/MacOS/wine`，同时留一份 `.wine-host` 用来比较。然后执行 `codesign -f -s - -i com.3shain.yaagl.game`（`:93-110`）。签名标识符必须等于 bundle id，否则每次 `getaddrinfo` 会卡住约 35 秒（`docs/genshin-macos.md:13`）。
  4. 写 Info.plist（`:34-58`，关键键是 `LSApplicationCategoryType=public.app-category.games`、`LSSupportsGameMode`、`LSUIElement`、`NSPrincipalClass=WineApplication`）。有改动时执行 `lsregister -f`（`:115`）。
  5. 任何失败都返回 `{}`：游戏照常启动，只是没有 Game Mode（`:123-126`）。

## 2. 环境变量

### 2.1 每次 Wine 调用都带

| 变量 | 值 | 来源 |
| --- | --- | --- |
| `WINEDEBUG` | `fixme-all,err-unwind,+timestamp` | 写死，`src/wine/wine.ts:120-125` |
| `WINEPREFIX` | `<数据目录>/wineprefix` | `src/app.tsx:104` |

`build()` 会跳过值为空串的变量（`src/utils/command-builder.ts:40-43`）。所以下表里写成 `""` 的变量等于“不设置”，并不是设成空值。Swift 版要保持同样的语义。

### 2.2 只在启动游戏时设置（`program-launch-game.ts:191-214`）

| 变量 | 值 | 设置项（storage key，默认值） |
| --- | --- | --- |
| `MTL_HUD_ENABLED` | `1` / 不设 | `config_metalHud`，false（`src/config/metal-hud.tsx:21-23`） |
| `WINEDLLOVERRIDES` | 不设（空串） | 写死 |
| `WINE_ENABLE_TIMEOUT_FIX` | `1` / `0` | `config_timeout_fix`，false（`hk4e/config/timeout-fix.tsx:13-25`）。这是改版 Wine 自己的开关 |
| `WINEESYNC` | `1` | 写死 |
| `DXMT_LOG_PATH` | 数据目录 | 写死，仅 dxmt |
| `DXMT_CONFIG` | `d3d11.preferredMaxFrameRate=60;` | 写死 |
| `DXMT_CONFIG_FILE` | `<数据目录>/dxmt.conf` | 写死。代码里没有任何地方生成这个文件，用户可以自己放一个 |
| `DXMT_METALFX_SPATIAL_SWAPCHAIN` | `1` / 不设 | 见 §5 |
| `GST_PLUGIN_FEATURE_RANK` | `atdec:MAX,avdec_h264:MAX` | 写死（过场视频解码） |
| `HTTP_PROXY`、`HTTPS_PROXY` | `config_proxyHost` 的值 | 只在 `config_proxyEnabled=true` 时设置（`src/config/proxy-enabled.tsx:21`、`src/config/proxy-host.tsx:27`） |
| `YAAGL_GAME_HOST_EXE` | `YaaglGame.app/Contents/MacOS/wine` | `config_game_mode`，**默认 true**（`hk4e/config/game-mode.tsx:22`），并且辅助程序存在时才设置 |
| `YAAGL_GAME_HOST_MATCH` | `server.executable`（CN：YuanShen.exe） | 同上，`src/wine/game-host.ts:116-122` |
| `YAAGL_GAME_HOST_DYLIB` | `sidecar/gamehost/yaagl-gamehost.dylib` | 同上。shim 只把它转成 `DYLD_INSERT_LIBRARIES` 交给游戏进程 |
| `YAAGL_GAMEHOST_LOG` | `logs/gamehost.log` | 同上，由 dylib 的构造函数打开（`native/gamehost/gamehost.c:397-403`） |
| `YAAGL_GAMEHOST_DEV` | 仅开发用 | 由 yaagl-diag 设置，dylib 据此加载 dev 伴侣库（`gamehost.c:75-88`） |

`renderBackend` 对 hk4e 的所有发行版都是 `dxmt`（`src/wine/distro.ts:17-78`），所以 `program-launch-game.ts:205-207` 的非 dxmt 分支对原神 CN 是死代码。

### 2.3 不进环境变量、但影响启动的设置

- `config_retina`（默认 false）和 `left_cmd`（默认 false）：写进注册表，见 §3。
- `config_hk4e_enable_hdr`、`config_resolution_custom`/`_width`/`_height`（默认 false/1920/1920）：写进注册表。
- `config_steam_patch`（默认 false）：决定用 cmd 还是 steam.exe 启动。
- `config_block_net`（默认 false）：临时改 `/etc/hosts`，见 §3.4。
- `config_patch_off`、`config_workaround3`：控制是否修改游戏文件（`src/clients/mhy/patch.ts:38-64`）。
- `config_reshade`：复制 reshade 的 DLL 到游戏目录（`patch.ts:97-103`）。
- `config_fps_unlock`：设置页里有这一项（`src/config/index.tsx:71`），但 hk4e 的启动代码**没有读取它**，是死设置。
- `wine_netbiosname`：会生成并保存（`src/wine/wine.ts:155-161`、`wine-install-program.ts:113-114`），但从来没有传给 Wine，也是死数据。

## 3. 启动前准备（按执行顺序）

入口在 `hk4e/index.tsx:258-283`：

1. 开了 reshade 时，执行 `checkAndDownloadReshade`。
2. `checkAndDownloadDXMT`（§6.2），渲染后端是 dxmt 时才执行。
3. 进入 `launchGameProgram`（`program-launch-game.ts:90-237`）：
   1. **`wine.shutdown()`**（`:108`）：先清掉上一次的残留进程，见 §7.2。
   2. **Mac Driver 注册表**（`:112-116` → `src/wine/wine.ts:163-181`）：写一个 `winedrv_config.bat`，用 `cmd /c` 执行两条 `reg add`：`HKCU\Software\Wine\Mac Driver` 下的 `RetinaMode` 和 `LeftCommandIsCtrl`（`y`/`n`）。然后执行 `wineserver -w`。MetalFX 生效时强制 `RetinaMode=n`。
   3. **HDR**（`:117-119`）：把 `src/constants/hk4e_hdr_cn.reg` 写成文件，用 `regedit` 导入，内容是 `HKCU\SOFTWARE\miHoYo\原神\WINDOWS_HDR_ON_h3132281285=dword:1`。这个 .reg 文件是 UTF-16 编码。
   4. **自定义分辨率**（`:121-123`，`:48-88`）：生成 UTF-16LE 编码的 .reg，写入 `Screenmanager Is Fullscreen mode_h3981298716=0`，以及宽和高（十六进制 dword），再用 `regedit` 导入。
   5. 执行 `wineserver -w`（`:124`）。
   6. **生成 `config.bat`**（`:126-135`）：内容依次是：`copy HoYoKProtect.sys` 到 `%WINDIR%\system32\`；`cd /d` 进游戏目录；用 `-platform_type CLOUD_THIRD_PARTY_PC -is_cloud 1` 启动游戏 exe。注意：在 Steam patch 路径下 config.bat **不会被执行**，所以这次复制和这两个启动参数都不会生效（`:187-190`）。
   7. **`patchProgram`**（`src/clients/mhy/patch.ts:29-125`）。key `patched` 已存在时直接跳过：
      - 游戏文件（没有开 patchOff 时）：CN 现在只把 `server.removed` 里的三个文件改名为 `.bak`：`upload_crash.exe`、`crashreport.exe` 和 `vulkan-1.dll`（`src/clients/hk4ecn.ts:49-63`）。`patched` 和 `added` 两个列表都是空的。
      - **DXMT 注入运行时**：`./wine/lib/wine/x86_64-windows/{d3d10core,d3d11,dxgi}.dll` 先改名为 `.bak`，再从 `./dxmt/` 复制新的过去（`patch.ts:69-73`）。`winemetal.dll` 复制到 `x86_64-windows/` 和 `prefix/system32/`，`winemetal.so` 复制到 `x86_64-unix/`（`:76-87`）。路径写死为 `./wine`，**没有遵循 `YAAGL_WINE_RUNTIME`**。
      - **Proton extras**：`sidecar/protonextras/steam{64,32}.exe` 和 `lsteamclient{64,32}.dll` 复制到 `system32/` 和 `syswow64/`（`:105-122`）。
      - 设置 `patched=1`（`:124`）。如果进程崩溃，下次启动时 `init()` 发现 `patched` 存在，就先执行 revert；revert 失败则改为完整性校验（`hk4e/index.tsx:290-304`）。
   8. 执行 `mkdir logs`。
   9. **block-net**（§3.4）。
   10. **`prepareGameHost`**（§1，仅在 `config_game_mode` 打开时执行）。
   11. 启动游戏（§1）。

### 3.4 需要 sudo 的步骤（`osascript … with administrator privileges`）

- **安装 Wine 时**，`ensureHosts(ENSURE_HOSTS)` 用 sudo 重写 `/etc/hosts` 里 `# Added by Yaagl` 到 `# End of section` 之间的内容（`src/hosts.ts:3-29`，`wine-install-program.ts:82`）。
- **block-net**：写一个 `/tmp/yaagl_network_block_script.sh`，用 sudo 在后台执行。脚本往 hosts 里加 `0.0.0.0 <CN_BLOCK_URL>`，`sleep 10` 秒后用 `sed` 删掉（`program-launch-game.ts:143-174`）。
- **安装 Wine 时**，`xattr -s -r -d com.apple.quarantine ./wine` 也走 sudo（`src/utils/unix.ts:5-11`）。
- `runInSudo` 的实现见 `src/utils/neu.ts:88-102`。

## 4. Game Mode 与原生全屏（含刘海区域）

设计文档在 `docs/genshin-macos.md:3-22`，实现分两半：

**(a) 让系统把它认作游戏（isIdentifiedGame）**：游戏进程必须是一个已注册 bundle 里的可执行文件，而且 bundle 声明 `LSApplicationCategoryType=games`。只在未打包的二进制里嵌入 `__info_plist` 不够（`docs/genshin-macos.md:7`）。做法见 §1：shim 把游戏进程改为执行 `YaaglGame.app/Contents/MacOS/wine`。

**(b) 原生全屏（isGameFullscreen）**：由注入的 `gamehost.dylib` 完成（`native/gamehost/gamehost.c`）：

- dylib 只链接 libSystem。它注册 `_dyld_register_func_for_add_image`，等 `winemac.so` 加载后，在主队列上执行 `install()`（`:385-403`），通过 objc runtime 的 `dlsym` 做 swizzle（`:339-383`）。
- **`adjustFullScreenBehavior:`** 被替换：对游戏窗口强制带上 `FullScreenPrimary` 标志，因为 winemac 会把不可缩放窗口的这个标志去掉（`:150-159`）。
- **一个每 0.5 s 触发的 tick**（`:248-291`，计时器在 `:376-381`）：找到可见的、不小于屏幕一半的 `WineWindow`，先订阅 GamePolicy，再在下一个 tick 用 `NSWindow` 的 `toggleFullScreen:` 实现绕过 `WineWindow` 的拒绝逻辑（`:282-285`）。
- **刘海区域**：
  - 覆盖四个私有 getter，`_frameForFullScreenMode`、`_tileFrameForFullScreen`、`_fullScreenTileFrame`、`_visibleTileFrameForFullScreen`，让它们对游戏窗口返回整个屏幕的 frame；窄于屏幕的分屏 tile 保持不变（`:161-182`，在 `:364-375` 用 `class_addMethod` 加到 `WineWindow` 上）。
  - 覆盖 `minimumLevelForActive:`：app 处于激活状态、窗口在全屏中、屏幕的 `safeAreaInsets.top>0` 时，把窗口层级抬到 25，压过 level 24 的菜单栏（`:184-202`）。层级变化时调用 `WineApplicationController adjustWindowLevels`，并带重试和退避（`:203-224`）。
- **GamePolicy 日志**：`GPProcessMonitor` 会输出 `isIdentifiedGame` 和 `isGameFullscreen`，写到 `logs/gamehost.log`（`:111-137`）。
- **getaddrinfo 拦截**：本机 `<host>.local` 的查询直接用网卡地址回答，避免被 Local Network 权限卡约 35 s（`:293-336`，`docs/genshin-macos.md:21`）。
- **卡住的进程自杀**：游戏窗口消失 15 s 后进程还在，就 `_exit(0)`（`:226-266`）。

这些行为都在 **Wine 进程内部**，与启动器用什么语言写无关。Swift 版只需要：构建并分发 x86_64 的 shim 和 dylib；完成 §1 里 `prepareGameHost` 的文件操作、签名和 LaunchServices 注册；设置那四个 `YAAGL_GAME_HOST*` 环境变量。

## 5. MetalFX 与 DXMT 开关

- 设置项是 `config_metalfx_upscale`，默认 false（`hk4e/config/metalfx-upscale.tsx:13-23`）。
- 生效条件：`metalFxUpscale && !resolutionCustom && renderBackend=="dxmt"`（`program-launch-game.ts:112-115`）。生效时：
  - 注册表强制 `RetinaMode=n`（`:116`）；
  - 环境变量 `DXMT_METALFX_SPATIAL_SWAPCHAIN=1`（`:202`）。放大倍数用 DXMT 的默认值 2（`d3d11.metalSpatialUpscaleFactor`，`docs/genshin-macos.md:85-87`），代码没有设置它。
- 其他 DXMT 相关常量：`DXMT_CONFIG=d3d11.preferredMaxFrameRate=60;`、`DXMT_LOG_PATH`、`DXMT_CONFIG_FILE`（§2.2）。
- **`CURRENT_DXMT_VERSION = "654f547"`**（`src/downloadable-resource.ts:142`），已安装的版本记在 storage key `installed_dxmt_version`（`:147`、`:212`）。注意：下载 URL、zip 名、tar 名和解压目录名里都**写死了完整 commit `654f547ffab4e0c395ee368aad52bb4586b04576`**（`:155-191`）。升级 DXMT 时要改五处，Swift 版应该由一个版本描述统一生成这些名字。
- 替换的 DLL 列表 `DXMT_FILES = d3d10core.dll, d3d11.dll, dxgi.dll`（`:133`）。包里还有 `winemetal.dll`、`winemetal.so`、`nvngx.dll`（`:135-140`）。原神不复制 `nvngx`，只有 hkrpg 复制（`patch.ts:89-95`）。

## 6. 下载、解压、版本管理

### 6.1 Wine（`src/wine/distro.ts`、`src/wine/wine-install-program.ts`）

- 发行版列表是内置常量 `YAAGL_BUILTIN_WINE`，共 6 项（`distro.ts:17-78`），**不从网络获取**。每项有 `id`、`remoteUrl`，以及 `attributes.winePath`，即压缩包里 wine 目录的位置，用于 `--strip-components`。
- CN 的默认值是 `DEFAULT_WINE_DISTRO_TAG = "11.0-dxmt-signed-with-patches"`（`src/clients/hk4ecn.ts:25`），下载源为 `yaagl/anime-game-wine` 的 release `wine-11.0-signed`（`distro.ts:28-37`）。`DEFAULT_WINE_DISTRO_URL`（`hk4ecn.ts:23`）已经没人引用。
- **状态机**（`distro.ts:94-131`），涉及的 storage key 有 `wine_state`、`wine_tag`、`wine_update_tag`、`wine_update_url`：
  - `wine_state=="update"`：安装 `wine_update_tag` 对应的发行版，找不到就装默认版本。
  - 否则 `wine_tag` 在列表里，就是 ready；不在列表里，就强制重装默认版本。
  - 没有任何 key（全新安装），就装默认版本。
- **触发升级**：用户在设置里换发行版时，写入 `wine_state=update`、`wine_update_tag`、`wine_update_url`，然后重启 App（`src/config/wine-distribution.tsx:84-87`）。另外有一个“快速操作”按钮，写死切到 `11.0-1-crossover-signed-experimental`，并顺手打开 `config_steam_patch`（`src/config/index.tsx:187-200`）。
- **安装流程**（`wine-install-program.ts:34-116`）：
  1. **`rm -rf wineprefix`**（`:37`）。所以每次换 Wine，prefix 都会被**整个删掉重建**。游戏装在 prefix 外面，不受影响。
  2. 用 aria2 下载到 `./wine.tar.{xz,gz}`（`:39-54`）。
  3. `rm -rf ./wine`，再解压：有 `winePath` 就用 `tar --strip-components=N -C ./wine -Jxvf <tar> <winePath>`（`src/utils/neu.ts:108-124`），没有就整包解压。完成后删除压缩包。
  4. 往 `share/wine/wine.inf` 的 `; URL Associations` 段后插入证书配置 `WINE_INF_CERT_STR`（`src/wine/cert.ts:4-43`，来自 `secret.ts`）。
  5. 用 sudo 去掉 quarantine 属性，再用 sudo 写 `/etc/hosts`（§3.4）。
  6. 执行 `wineboot -u` 和 `winecfg -v win10`，日志写到 `wineboot.log` 和 `winecfg.log`。失败时提示用户安装 Rosetta 2（`:84-99`）。
  7. 写入 `wine_state=ready` 和 `wine_tag`，清空两个 update key，并生成一个新的 `wine_netbiosname`（`:109-114`）。
- 上面的流程不会安装 shim。shim 要到第一次带 Game Mode 启动时才由 `prepareGameHost` 装上（§1）。因为换 Wine 会先删掉 `./wine`，旧的 shim 和 `wine-host` 都会跟着消失，下次启动时自然重新安装。

### 6.2 DXMT（`src/downloadable-resource.ts:144-213`）

`installed_dxmt_version` 不等于 `654f547` 时：`rm -rf ./dxmt` → 用 aria2 下载 `yaagl/anime-game-wine` 的 release `dxmt-654f547` 里的 zip → `doStreamUnzip` → `tar -xvf` 内层的 tar.gz → 把 `x86_64-windows/*` 和 `x86_64-unix/*` 移到 `./dxmt/` 根目录 → 删除中间文件 → 写入版本号。DXMT 每次启动都会注入 Wine 运行时，退出后再撤销（§3、§7.3）。所以升级 DXMT 不需要重装 Wine。

## 7. 游戏退出检测与清理

### 7.1 检测

- 启动器判断游戏退出的**唯一依据**是 `exec2` 返回，也就是 `sh -c "wine64 cmd /c config.bat"` 这整条命令结束（`program-launch-game.ts:186`）。cmd 和 steam.exe 都要等游戏进程退出后才返回（`docs/genshin-macos.md:22`）。
- 启动器**没有超时**。防止卡死要靠 gamehost：窗口关闭 15 s 后，游戏进程自己 `_exit`（§4）。没开 Game Mode 时没有这层保护。
- 非零退出码会让 `exec2` reject，走 catch 分支（`:226-231`）。这个分支同样会清理，但**不会撤销 HDR 和分辨率的注册表改动**。

### 7.2 清理

- `waitUntilServerOffOrShutdown(15000)`：让 `wineserver -w` 和一个 15 s 的计时器竞争。超时就执行 `shutdown()`（`src/wine/wine.ts:105-114`）。
- `shutdown()`（`src/wine/wine.ts:88-102`）：
  1. 执行 `wineserver -k`，失败也忽略。
  2. 用一行 shell 找出属于这个 prefix 的进程，然后 `kill -9`。判断规则有两条：
     - `lsof -t +d /tmp/.wine-<uid>/server-<dev hex>-<inode hex>`，即所有打开了这个 prefix 的 server 目录的进程；
     - 命令行以 `C:\` 或 `Z:\` 开头、而且 cwd 在 prefix 内的进程。这一条用来抓 wineserver 已经死掉后留下的孤儿进程，比如 `winedevice.exe`。
- 撤销注册表（只在正常路径执行）：删除 `WINDOWS_HDR_ON_h3132281285`（`:239-271`），删除三个分辨率值（`:273-301`）。
- 删除 `config.bat`（`:234`）。

### 7.3 撤销补丁（`patch.ts:127-175`）

把游戏文件的 `.bak` 还原回去。DXMT 的三个 DLL 也从 `.bak` 还原；缺少 `.bak` 时跳过，不报错。删除 reshade 的 DLL，设置 `patched=null`。**不会撤销**的有：`winemetal.*`、prefix 里的 `steam.exe` 和 `lsteamclient.dll`、`system32` 里的 `HoYoKProtect.sys`，以及 Wine 目录里的 shim。

### 7.4 启动器退出与自动启动

- 开发用的 `YAAGL_AUTOLAUNCH=1`：启动后执行 `launch()`，然后调用 `shutdown()` 运行终止钩子，再 `exit(0)`（`src/launcher/index.tsx:87-118`）。
- aria2 用 `--stop-with-process <ppid>` 跟随启动器一起退出（`src/app.tsx:56-75`）。Wine 进程没有这类绑定：启动器被强制退出后，Wine 会一直留着，等下次启动前的 `shutdown()` 清理。

## 8. Neutralino 依赖与 Swift 对应

| 步骤 | 现在的实现 | Swift 对应 |
| --- | --- | --- |
| 同步执行命令 `exec` | `Neutralino.os.execCommand(shell 字符串)`（`neu.ts:30`） | `Process`，直接设置 `executableURL`、`arguments`、`environment`，**不经过 shell**。这样就不再需要 `command-builder.ts` 的转义逻辑 |
| 异步执行并等待 `exec2`（启动游戏、wineserver -w） | `os.spawnProcess` 加 `spawnedProcess` 事件（`neu.ts:39-86`） | `Process`，配合 `terminationHandler` 或 `withCheckedContinuation`。日志重定向用 `FileHandle(forWritingAtPath:)` 赋给 `standardOutput`/`standardError`。如果想让 Wine 进程用自己的进程组，或不继承文件描述符，就用 `posix_spawn`，配合 `POSIX_SPAWN_SETPGROUP` 和 `POSIX_SPAWN_CLOEXEC_DEFAULT` |
| 环境继承 | Wine 继承 Neutralino 的环境，cwd 是数据目录（`build-app.js:235-236`） | 从 LaunchServices 启动的 App 环境很精简。要显式设置 `currentDirectoryURL`，并在 `ProcessInfo.processInfo.environment` 的基础上合并变量。值为空串时**删掉这个键**，与 `build()` 的行为一致 |
| 15 s 超时竞争 | `Promise.race`（`wine.ts:105-114`） | `withTaskGroup`，或 `Task.sleep` 加取消 |
| `shutdown()` 里的 `ps`/`lsof`/`awk` 管道 | `sh -c`（`wine.ts:94-101`） | `stat()` 取 dev 和 inode。`proc_listpids` 列进程，`proc_pidinfo(PROC_PIDVNODEPATHINFO)` 读 cwd，`proc_pidinfo(PROC_PIDLISTFDS)` 加 `proc_pidfdinfo(PROC_PIDFDVNODEPATHINFO)` 判断是否打开了 server 目录，`sysctl(KERN_PROCARGS2)` 读命令行，最后 `kill(pid, SIGKILL)`。也可以先保留调用 `/usr/sbin/lsof` 的 `Process` 作为过渡 |
| 设置读写 | `Neutralino.storage` | 地图要求沿用数据目录，所以首个版本必须能读 `.storage/` 里的旧 key（§2 列出的全部 key），并决定迁移到 `UserDefaults` 还是继续用文件 |
| 文件操作（cp/mv/rm/读写/stat/mkdir） | `Neutralino.filesystem` 和一部分 shell（`neu.ts:184-317`） | `FileManager`、`Data`。`cmp -s` 改成按字节或哈希比较 |
| UTF-16LE 的 .reg 文件 | `writeBinary(utf16le(...))` | 先写 BOM `FF FE`，再接 `String.data(using: .utf16LittleEndian)`。现有的 `utf16le()` 会写 BOM（`src/utils/helper.ts:118-126`） |
| 环境变量 | `Neutralino.os.getEnv` | `ProcessInfo.processInfo.environment` |
| sudo（hosts、xattr） | `osascript … with administrator privileges`（`neu.ts:88-102`） | `NSAppleScript` 执行同一段 `do shell script … with administrator privileges`。`xattr` 不必用 sudo，可以对用户自己的文件直接调用 `removexattr(2)` 递归删除。App 不签名，所以用不了 `SMAppService` 或 privileged helper |
| `lsregister -f` | 外部可执行文件 | `LSRegisterURL(url, true)`（CoreServices） |
| `codesign -f -s - -i <id>` | 外部可执行文件 | 没有公开 API，继续通过 `Process` 调用 `/usr/bin/codesign`。这是系统工具，不算 sidecar |
| 打开终端里的 Wine cmd | `osascript tell Terminal`（`wine.ts:127-153`） | `NSAppleScript`，或者用 `NSWorkspace.open` 打开一个 `.command` 文件 |
| 下载（Wine、DXMT） | aria2 sidecar 加 RPC | `URLSessionDownloadTask`，配合 `resumeData` |
| 解压 tar.xz/tar.gz | `/usr/bin/tar`（`neu.ts:104-124`） | 继续通过 `Process` 调用 `/usr/bin/tar`（系统自带 libarchive，支持 xz 和 `--strip-components`） |
| 解压 zip（DXMT） | `doStreamUnzip`（`unix.ts:52-116`），调用外部 unzip | `/usr/bin/ditto -x -k`，或 `/usr/bin/unzip` |
| 消息框、选择目录 | `os.showMessageBox`、`os.showFolderDialog` | `NSAlert`、`NSOpenPanel` |
| 重启 App | `open "$PATH_LAUNCH"` 再 `app.exit`（`neu.ts:377-390`） | `NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: { createsNewApplicationInstance = true })`，然后 `NSApp.terminate` |
| 打开 URL | `os.open` | `NSWorkspace.shared.open(_:)` |
| 日志 | `Neutralino.debug.log` | `os.Logger`，再加一份写到 `logs/` 的文件日志，方便 yaagl-diag 读取 |
| 启动器退出时的清理钩子 | `addTerminationHook` | `NSApplicationDelegate.applicationShouldTerminate` 返回 `.terminateLater`，异步清理完再回复 |

## 9. 给 Swift 版的结论

1. **启动契约本身很小，可以照搬**：固定的环境变量表（§2）、两条注册表 `reg add`、可选的 HDR 和分辨率 regedit、`config.bat` 的三行内容、DXMT 文件的注入和还原、一次 `wine64 cmd /c config.bat`，再加上 15 s 的退出窗口和 `shutdown()`。
2. **Game Mode 和刘海区域的逻辑全部在 Wine 进程内**（shim 和 dylib），Swift 版不需要用 AppKit 重新实现任何全屏行为。启动器只负责准备 `YaaglGame.app`、签名、`LSRegisterURL`，以及传四个环境变量。
3. **shim 和 dylib 必须是 x86_64**，因为它们加载进 Rosetta 下的 Wine。它们不能作为 SwiftPM C target 链接进 arm64 的 App，只能当作单独构建的 x86_64 产物放进 bundle 的 Resources。
4. 外部依赖可以分三类：
   - 可以完全去掉：aria2、shell 转义、`ps`/`lsof`/`awk`、`cmp`、`xattr`、`lsregister`；
   - 保留调用系统工具：`/usr/bin/tar`、`/usr/bin/codesign`、`osascript` 或 `NSAppleScript`（sudo）；
   - 必须作为 bundle 资源随 App 分发：x86_64 shim 和 dylib、`protonextras` 里的 Windows PE 文件。

## 10. 移植时要决定的问题和发现的问题

1. **x86_64 原生辅助程序怎么构建、怎么分发**：用 XcodeGen 里一个 x86_64 的 target，还是在 build phase 里调用 `native/gamehost/build.sh`？“sidecar 全部替换”这条决策需要补充说明：shim、dylib 和 `protonextras/*.exe|dll` 是加载进 Wine 或复制进 prefix 的文件，不是被 shell 出去执行的工具。
2. **Neutralino `.storage` 怎么迁移**：既然沿用数据目录，旧 key 要么继续读，要么在第一次运行时迁移。
3. **`YaaglGame.app` 的 bundle id 是 `com.3shain.yaagl.game`**：地图已决定“与上游彻底分叉”。要不要改名，以及改名会重置 LaunchServices 登记和 TCC 授权，需要定下来（`game-host.ts:18-21`）。
4. **现有 bug 和死代码，是照搬还是修复**：
   - catch 分支不会撤销 HDR 和分辨率注册表（§7.1）；
   - Steam patch 路径不会复制 `HoYoKProtect.sys`，也不会加 cloud 启动参数（§3 第 6 步）；
   - DXMT 注入写死 `./wine`，没有遵循 `YAAGL_WINE_RUNTIME`（§3 第 7 步）；
   - `config_fps_unlock` 和 `wine_netbiosname` 是死设置；
   - `DXMT_CONFIG_FILE` 指向的文件从不生成；
   - 换 Wine 会删掉整个 prefix；
   - 启动器被强制退出后 Wine 会留下孤儿进程。
5. **启动器自己没有超时**，游戏卡住时只能靠 gamehost 自杀，而且只在 Game Mode 打开时才有这层保护。Swift 版要不要加一个启动器侧的看门狗？
6. **Wine 发行版列表**：现在有 6 项，但原神 CN 实际只用 `11.0-dxmt-signed-with-patches` 和 `11.0-1-crossover-signed-experimental`（CrossOver 11）。Swift 版要不要只保留 CN 实际使用的版本，并顺便确定 fork 的发行源（AGENTS.md 的“Fork notes”）？
