# sidecar 替换可行性（原神 CN）

研究票：[#17](https://github.com/tanzby/yet-another-anime-game-launcher/issues/17)，所属地图：[#13 原生 macOS 迁移（原神 CN）](https://github.com/tanzby/yet-another-anime-game-launcher/issues/13)。
代码基准：`origin/main` @ `f38cda4`。行号均指该提交。

## 结论速览

| 组件 | 原神 CN 是否用到 | 替换方案 | 许可证影响 |
|---|---|---|---|
| `aria2c` | 是，所有非游戏本体的下载（Wine、DXMT、ReShade、MF DLL、自更新） | `URLSession` 下载任务 | 去掉 GPLv2 二进制，无新增义务 |
| `7zz` | **否**（只有 hkrpg、bh3 调用） | 直接删除 | 去掉 LGPL/unRAR 条款 |
| `hpatchz` | **是，间接**：Python Sophon 用它打 ldiff（hdiff）补丁 | HDiffPatch 的 `HPatch` C 源码作为 SwiftPM C target，调 `patch_decompress*` | MIT，随 App 附带版权声明 |
| `xdelta3` | **否**：hk4ecn 的 `patched` 列表为空 | 删除；以后真需要再把 xdelta3 源码作为 C target | Apache-2.0（若引入） |
| `protonextras` | 仅在开启「Steam 补丁」（默认关）时 | 不能变成 Swift：是 Windows PE 文件，原样作为资源打包 | Proton，BSD-3（顶层）+ 各子目录自有许可 |
| `gamehost`（`wine-shim.c`、`gamehost.c`） | 是，Game Mode + 原生全屏（默认开） | **必须保留 C**，改成 SwiftPM/Xcode 的 x86_64 C target 随 App 打包 | 自有代码 |
| `gamehost-dev.m`、`turner.c` | 否，仅 `yaagl-diag` 开发用，不随 App 发布 | `gamehost-dev.m` 可做 x86_64 ObjC target；`turner.c` 是 Windows 程序，仍用 llvm-mingw | 自有代码 |
| Sophon 的 zstd 依赖 | 是（Sophon 分块是 zstd） | zstd C 源码作为 C target（Apple Compression 不支持 zstd） | BSD-3 |
| 系统 `tar`/`unzip`/`md5`/`df` | 是 | Apple `Compression`（xz、raw deflate）+ 小型 Swift tar/zip 读取，或 libarchive C target；`CryptoKit`；`FileManager`/`statfs` | 无 / libarchive 为 BSD-2 |
| 系统 `codesign`、`lsregister` | 是（Game Mode 的 bundle） | `lsregister` → `LSRegisterURL`；**`codesign` 没有公开 API 替代** | — |

## 逐项说明

### aria2（`sidecar/aria2/aria2c`）

- 二进制：aria2 1.37.0，仅 x86_64（`file`），链接 Security/CoreFoundation/libc++。随附 `LICENSE.txt` 为 GPLv2。
- 启动：`src/app.tsx:54-72` 在 App 启动时总是拉起 aria2c 的 JSON-RPC 服务（`--enable-rpc --save-session --stop-with-process`），`src/app.tsx:85-95` 连接，`src/aria2.ts` 用 `libaria2-ts` 包装成 `doStreamingDownload`。
- 原神 CN 路径上的调用者：
  - Wine 运行时下载：`src/wine/wine-install-program.ts:41`
  - Media Foundation DLL：`src/wine/mf.ts:35`（`wine-install-program.ts:106` 调用）
  - DXMT：`src/downloadable-resource.ts:156`（`src/clients/mhy/hk4e/index.tsx:274`）
  - ReShade（可选）：`src/downloadable-resource.ts:235,249`（`hk4e/index.tsx:271`）
  - 自更新：`src/updater.ts:103,135`（迁移后由 Sparkle 取代）
- **游戏本体不走 aria2**：原神的安装/更新/修复全部经 Sophon（`hk4e/program-install-game.ts:19`、`program-update-game.ts:20,148`、`program-check-integrity.ts:13`）。Python Sophon 自己用 pycurl/urllib 下载（`sophon_server/pyproject.toml`、`sophon_api.py:67-68`）。
- 替换：`URLSession` 的 `downloadTask`，`cancel(byProducingResumeData:)` / `downloadTask(withResumeData:)` 支持断点续传（[Apple: URLSessionDownloadTask](https://developer.apple.com/documentation/foundation/urlsessiondownloadtask)）；进度用 delegate 的 `didWriteData`。剩下的文件都是单个几十到几百 MB 的包，不需要 aria2 的多连接分段。Sophon 的分块下载同样用 `URLSession`（细节属于 Sophon 票）。
- 可行性：**完全可替换**。

### 7z（`sidecar/7z/7zz`）

- 7-Zip 21.07，universal。
- 调用者：`src/utils/unix.ts:118-199` 的 `doStreamUn7z`、`extract7z`，只被 `src/clients/mhy/hkrpg/*` 和 `src/clients/mhy/bh3/*` 调用（`grep` 结果）。**原神 CN 不用**。
- 替换：直接删除，不需要替代品。
- 许可证：7-Zip 主体 LGPL-2.1+，带 unRAR 限制（[7-Zip License.txt](https://github.com/ip7z/7zip/blob/main/DOC/License.txt)）；删掉后这些义务一起消失。

### hpatchz（`sidecar/hpatchz/hpatchz`）

- HDiffPatch v4.5.2 的 `hpatchz`，universal，链接系统 libz/libbz2。
- TS 侧：`src/utils/unix.ts:33-45`，只被 bh3/hkrpg/nap 的更新调用。
- **原神 CN 间接依赖**：`build-sophon.sh:2` 把它拷进 `sophon_server/`；`sophon_server/sophon_api.py:60,88-93` 定位它，`sophon_api.py:225-265` 的 `hpatchz_patch_file` 把 ldiff 文件中 `[patch_offset, patch_offset+patch_length)` 一段切到临时文件再 `subprocess` 调 `hpatchz -f old patch new`，`sophon_api.py:1239-1242` 在增量更新时调用。所以 Sophon 用 Swift 重写后**仍需要 HPatch 能力**。
- 替换：把 HDiffPatch 的 `libHDiffPatch/HPatch/patch.c`（+ 头文件）作为 SwiftPM C target，用其 C API `patch_decompress()` / `patch_decompress_with_cache()`（流式）或 `patch_decompress_mem()`；需要哪些解压插件（zlib/bzip2/lzma/zstd）按 Sophon ldiff 实际使用的压缩选，插件代码在 `decompress_plugin_demo.h`（[HDiffPatch README](https://github.com/sisong/HDiffPatch)）。直接从 ldiff 文件按 offset/length 读流，还能省掉 Python 版本的临时文件。
- 许可证：HDiffPatch 为 MIT（[README](https://github.com/sisong/HDiffPatch)、`sidecar/hpatchz/LICENSE.txt`），只需在 App 中附带版权声明。若用 zstd 插件，见下文 zstd。

### xdelta（`sidecar/xdelta/xdelta3`）

- Xdelta 3.1.1，仅 x86_64。**注意**：`otool -L` 显示它链接 `/usr/local/opt/xz/lib/liblzma.5.dylib`（Homebrew 路径），没装 Homebrew xz 的机器上一运行就会加载失败。这是现有的潜在 bug，只是没被触发。
- 调用者：`src/utils/unix.ts:18-31`，唯一用户是 `src/clients/mhy/patch.ts:46`（`patchProgram` 对 `server.patched` 逐个打补丁）。`src/clients/hk4ecn.ts:38-48` 的 `patched` 全部被注释掉，是空数组，所以**原神 CN 实际不调用**。
- 替换：删掉。如果将来 `patched` 又用起来，再把 xdelta3 源码（`xdelta3.c` 单文件编译）作为 C target；3.1 分支是 Apache-2.0（[xdelta release3_1_apl LICENSE](https://github.com/jmacd/xdelta/blob/release3_1_apl/xdelta3/LICENSE)）。

### protonextras（`sidecar/protonextras/`）

- 内容：`steam64.exe`/`steam32.exe`（PE GUI）、`lsteamclient64.dll`/`lsteamclient32.dll`（PE DLL）。`strings` 可见 "Wine builtin DLL"、`PROTON_WAIT_ATTACH`、`__wine_unix_spawnvp`，即 Proton 的 `steam_helper` 与 `lsteamclient`。
- 调用：`src/clients/mhy/patch.ts:105-122` 对非 hkrpg 渠道把它们拷进前缀的 `system32`/`syswow64`；`src/clients/mhy/hk4e/program-launch-game.ts:187-190` 在 `config.steamPatch` 为真时用 `steam.exe` 启动游戏。该设置默认 `false`（`hk4e/config/steam-patch.tsx:25`）。
- 替换：**不能变成 Swift**——它们是在 Wine 里运行的 Windows 程序。Swift 版只需「把这几个文件作为资源打包、启动前拷进前缀」，复制本身用 `FileManager`。
- 许可证：Proton 顶层为 BSD-3（[LICENSE.proton](https://github.com/ValveSoftware/Proton/blob/proton_9.0/LICENSE.proton)），子组件各自目录下有 LICENSE（[Proton LICENSE](https://github.com/ValveSoftware/Proton/blob/proton_9.0/LICENSE)）。仓库里这几个文件**没有附带任何许可证或来源版本说明**，迁移时应补上出处与 LICENSE。

### gamehost（`native/gamehost/` → `sidecar/gamehost/`）

`build-app.js:281-284` 在打包时调用 `native/gamehost/build.sh` 生成，主 checkout 的 `sidecar/gamehost/` 下两个文件均为 **x86_64** Mach-O（Wine 在 Rosetta 下运行）。`src/wine/game-host.ts:66-127`（`prepareGameHost`）在 `hk4e/program-launch-game.ts:178-184` 里调用，「原生全屏 + Game Mode」设置默认开（`docs/genshin-macos.md`）。

- **`wine-shim.c` → `yaagl-wine-shim`**：被拷成 `<wine>/lib/wine/x86_64-unix/wine`（`game-host.ts:76-84`），原 loader 改名 `wine-host`。Wine 为**每个** Windows 进程 exec 这个路径；shim 判断 `argv[1]` 是否含游戏 exe 名，是则设 `DYLD_INSERT_LIBRARIES` 并 exec 已注册的 `YaaglGame.app/Contents/MacOS/wine`，否则 exec `wine-host`（`wine-shim.c:29-42`）。
  - 必须是独立的 x86_64 可执行文件，并且在 Wine 的进程树里被 exec，不在 App 进程内。理论上可以用 Swift 写，但它是每个 Wine 进程都会走的 45 行 exec 跳板，Swift 运行时没有任何好处。**保留 C**，用 SwiftPM（`--arch x86_64`）或 XcodeGen 中 `ARCHS=x86_64` 的 C 目标构建并打进 App。
- **`gamehost.c` → `yaagl-gamehost.dylib`**：通过 `DYLD_INSERT_LIBRARIES` 注入游戏的 Wine 进程（`gamehost.c:1-17`）。它用 `dlsym` 拿 objc runtime，在 `winemac.so` 加载后（`gamehost.c:385-403` 的 dyld image 回调）给 Wine 的 `NSWindow` 子类换实现：私有全屏 frame getter、`minimumLevelForActive:`、`toggleFullScreen:`；还通过 `__DATA,__interpose` 段替换 `getaddrinfo`（`gamehost.c:298-337`）。
  - 头注释写明「只链接 libSystem：Wine host 不能过早加载 AppKit」（`gamehost.c:8-10`）。Swift dylib 即便不 `import AppKit` 也会带入 Swift 运行时与 Foundation 依赖，而 `__interpose` 段、constructor、在 x86_64 Wine 进程里按时机 swizzle，都是 C 层面的事。**必须保留 C**（「用 Swift 替换」= 用 SwiftPM/Xcode 构建 x86_64 C target、随 App 打包）。
- **`gamehost-dev.m`**：开发专用的 ObjC 伴随库，由 `gamehost.c:75-88` 在 `YAAGL_GAMEHOST_DEV` 下 `dlopen`；只给 `scripts/dev/yaagl-diag --autoplay` 用，不随 App 发布（`docs/genshin-macos.md:39`）。可作为 x86_64 ObjC target 构建，不影响产品。
- **`turner.c`**：Windows 控制台程序（`#include <windows.h>`，`SendInput`），由 `build.sh:25-28` 用 llvm-mingw 编译，`yaagl-diag:451-496` 在前缀里运行。**不可能是 Swift，也不能用 SwiftPM 构建**；保持 dev-only 的 mingw 构建。
- **`build.sh`**：迁移后由 SwiftPM/XcodeGen 的 x86_64 target 取代（`--dev` 部分可保留脚本或另建 target）。

`prepareGameHost` 同时依赖两个系统二进制：
- `codesign -f -s - -i com.3shain.yaagl.game`（`game-host.ts:100-102`）：给运行时下载的 `wine-host` 副本做 ad-hoc 签名，签名 identifier 必须等于 bundle id，否则每次 `getaddrinfo` 卡约 35 s。**这一步没有公开 API**（Security 框架只有校验类公开 API，签名在 `codesign` 工具里），而被签的文件来自运行时下载的 Wine，无法在构建期完成。
- `lsregister -f`（`game-host.ts:115`）：可换成公开 API `LSRegisterURL(_:_:)`（[Apple](https://developer.apple.com/documentation/coreservices/1446350-lsregisterurl)）。

## 其他「shell 出去」的系统命令（原神 CN 路径）

| 用途 | 现状 | Swift 替代 |
|---|---|---|
| Wine `.tar.xz` 解包 | `src/utils/neu.ts:104-124` 调 `/usr/bin/tar`（发行版均为 `.tar.xz`，`src/wine/distro.ts:21-52`） | Apple `Compression` 的 `COMPRESSION_LZMA` 只解 XZ 容器内的 LZMA2，正好对应 `.xz`（[Apple](https://developer.apple.com/documentation/compression/compression_lzma)），再加一个支持 ustar/pax、符号链接、权限位的 Swift tar 读取器；或 libarchive C target |
| DXMT/ReShade `.zip` 解包 | `src/utils/unix.ts:52-116` 调 `/usr/bin/unzip` | `COMPRESSION_ZLIB` 是 raw DEFLATE（RFC 1951，[Apple](https://developer.apple.com/documentation/compression/compression_zlib)），正是 zip 的 method 8，加一个读中央目录的 Swift zip 读取器；或 libarchive C target |
| 文件 md5 | `src/utils/unix.ts:13-16`（`unity.ts:34`） | `CryptoKit.Insecure.MD5` |
| 磁盘剩余空间 | `src/utils/unix.ts:201-216`（`df`） | `URLResourceValues.volumeAvailableCapacityForImportantUsage` |
| 自更新 tar.gz | `src/updater.ts:112-130` | Sparkle 自带 |

Apple Archive 框架面向自有的 `.aar` 格式（[Apple Archive](https://developer.apple.com/documentation/applearchive)），文档没有列出 zip/tar 读取，**不适用**。libarchive 是 BSD-2（[COPYING](https://github.com/libarchive/libarchive/blob/master/COPYING)），但 vendoring 要带上 xz/zlib 等依赖，复杂度不小。原神 CN 只需「解一个 tar.xz + 两个 zip」，推荐 Compression + 小型 Swift 读取器；macOS 自带的 `/usr/lib/libarchive.2.dylib` 在 SDK 里没有头文件，不算公开 API。

## Sophon 相关的 C 依赖

- Sophon 分块是 zstd（`sophon_api.py:32,72`）。Apple Compression 的算法里没有 zstd（[compression_algorithm](https://developer.apple.com/documentation/compression/compression_algorithm)），需要把 zstd 的解码源码作为 C target。zstd 为 BSD-3（[LICENSE](https://github.com/facebook/zstd/blob/dev/LICENSE)，仓库另有 GPLv2 可选，选 BSD 即可）。
- ldiff 打补丁用 HPatch C target（见上）。

## 必须保留为非 Swift 的部分

1. `wine-shim.c`、`gamehost.c`：x86_64，运行在 Wine 进程树内或注入进去，C 实现，由 SwiftPM/Xcode 构建并打包。
2. `protonextras` 四个 PE 文件：Windows 二进制，作为资源打包。
3. `turner.c`（dev-only）：Windows 程序，llvm-mingw 构建。
4. HPatch、zstd：C 库，作为 SwiftPM C target 链接（符合已定决策）。
5. `/usr/bin/codesign`：没有公开 API 可替代，见下面的新决策问题。

## 新发现、需要决策的问题

1. **`codesign` 仍要 shell 出去**。Game Mode 要求给运行时下载的 `wine-host` 副本做 ad-hoc 签名并指定 identifier，没有公开 API。与「不再 shell 出外部二进制」冲突。可选方向：把 `/usr/bin/codesign` 这类系统自带工具列为例外；或者改成在 Wine 发行包构建时预先放好签名过的 bundle 副本（需要改 Wine 发行流程）。
2. **构建双架构**：App 定为仅 Apple Silicon（arm64），但 gamehost 两个产物必须是 x86_64。SwiftPM 一次构建只出一个架构，需要在 `project.yml`/构建脚本中单独定义 x86_64 目标并拷进 `Resources`。
3. **protonextras 来源不明**：仓库没有版本号和许可证文件。迁移时需要确认来源版本并补上 LICENSE，或者判断「Steam 补丁」（默认关）是否值得保留。
4. 现有 `xdelta3` 依赖 Homebrew 的 liblzma，是一个潜在 bug（原神 CN 不触发，删掉即可）。
