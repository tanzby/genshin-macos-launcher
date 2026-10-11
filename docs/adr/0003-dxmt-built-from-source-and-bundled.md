# DXMT 从源码构建并随 App 分发，不再在安装 Wine 时下载

地图 #1、票 #63。此前（#10、#27）DXMT 是一个预编译 zip，固定在 `yaagl/anime-game-wine` 的 release（`654f547`），安装 Wine 时和 Wine 压缩包一起下载。这条决定推翻了那一半。

## 为什么

- 真机 diag 里游戏偶发崩溃（#63）：`-[NSTaggedPointerString newComputePipelineStateWithDescriptor:…] unrecognized selector`。根因在 DXMT `654f547` 里：`ArgumentEncodingContext` 的成员 `device_` 声明在 `clear_uav_cmd` 之后，成员按声明顺序初始化，`ClearUAV` 的构造函数经 `getComputePipeline()` 读到还没初始化的 `device_`，是否崩取决于栈上的残留值。上游在 `fb45156`（2026-10-01）修掉。
- 预编译 zip 不在我们手里：yaagl 镜像只有 `654f547` 一个版本，上游 CI 产物 90 天后过期，所以升级 DXMT 要么自己托管二进制，要么依赖别人的发布节奏。
- 把 DXMT 当作固定在某个提交的第三方源码依赖，构建产物进 App，版本与 App 一起走 Sparkle 更新，崩溃修复和升级都是一个提交。

## 决定

- `third_party/dxmt` 是 `3Shain/dxmt` 的 git submodule，固定在一个提交（当前 `e94c312`，上游 main，含 `fb45156`）。升级 = 更新 submodule 指针 + 真机验证。
- `scripts/build-dxmt` 构建出 `build/dxmt/`（`x86_64-windows` 的四个 DLL、`x86_64-unix/winemetal.so`、`VERSION`、许可证文本）。配方照搬上游 CI 的 `build-gcc-release-x86_64-windows-cross` 任务：mingw-w64 交叉编译、LLVM 15.0.7（x86_64 macOS，静态链接进 `winemetal.so`）、Wine `v8.16-3shain` 的头文件树（按 SHA-256 固定）、meson 1.10.0、Xcode 16.1（上游产出可用二进制的那套工具链）。不构建 arm64ec、i386、nvapi、nvngx：App 不安装它们。
- CI：`.github/workflows/dxmt.yaml` 在 `macos-15` 上构建并上传 artifact `dxmt`；PR 和 main 上改动 submodule、脚本或工作流时运行；每周一次定时运行，让缓存不过期（Actions 的缓存 7 天未用即被清）。有两层缓存：构建产物 `build/dxmt` 以 DXMT 提交 + `scripts/build-dxmt` 的哈希 + Xcode 版本为 key，只有换 DXMT 版本或工具链才重新编译，命中时跳过工具链和编译；LLVM 另有一份缓存，换 DXMT 版本时不用重编 LLVM。耗时：都没缓存约 25 分钟，只有 LLVM 缓存约 4 分钟，产物缓存命中约 1 分钟。tag 触发的 release 只能读 main 的缓存，所以 main 上必须先构建过同一个 key。`release.yaml` 调用它，下载 artifact 到 `build/dxmt`，`project.yml` 把它放进 `Yaagl.app/Contents/Resources/dxmt`，`scripts/dev/check-bundle` 在发布构建里强制检查。每个 PR 的 `swift` 检查不构建 DXMT，保持快。
- `Wine` 模块：`WineRuntime` 由组合根注入 `DXMTBundle`（目录 + `VERSION`），`Wine` 不读 `Bundle.main`。安装 Wine 时从 bundle 拷贝 DXMT，不再下载（删掉 zip、sha256、体积、解压、`downloadingDXMT` 进度）。bundle 缺失或不完整在删除任何东西之前抛 `dxmtBundleInvalid`。
- DXMT 现在随 App 更新而变。版本戳里的 DXMT 版本与 App 内的不同、Wine 版本相同时，状态是 `dxmtOutdated`，`ensureInstalled` 只重新拷贝几个文件并改写版本戳，不重装 2 GB 的 Wine，也不动 prefix。App 内没有 DXMT 的构建（开发构建）不比较 DXMT 版本。

## 代价

- 发布构建多一个 CI 任务，冷缓存时多约 25 分钟。
- App 体积增加约 35 MB（DXMT 压缩前 33 MB；`winemetal.so` 静态链接了 LLVM）。
- 许可证：DXMT 是 LGPL-2.1-or-later，`winemetal.so` 内含 LLVM（Apache-2.0 with LLVM Exception）；两份文本随 bundle 分发，`THIRD_PARTY_NOTICES.md` 和 App 的致谢页列出来源。
- 首次成功构建本地 DXMT 后，若已有 `Yaagl.app`，需删除该旧 app 一次；随后 Xcode 会重新打包并签入新生成的 DXMT。
- 本地要构建 App 里的 DXMT 需先 `brew install meson cmake ninja mingw-w64` 并运行 `scripts/build-dxmt`，再 `xcodegen generate`；不运行也能构建 App，只是它装不了 Wine。
