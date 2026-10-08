# Sparkle 集成调研（原生原神 CN 版）

> 研究票：[#19](https://github.com/tanzby/yet-another-anime-game-launcher/issues/19)，地图 [#13](https://github.com/tanzby/yet-another-anime-game-launcher/issues/13)。
> 调研日期 2026-10-08。Sparkle 当前最新版为 **2.10.0**（2026-09-13）。源码引用固定在 Sparkle `2.x` 分支提交 [`e95f42b`](https://github.com/sparkle-project/Sparkle/tree/e95f42b15686ad547a919ddaef18d75eac9bf5d9)。

## 结论速览

1. **未签名/ad-hoc 签名的 App 可以用 Sparkle 2 自更新**。对 `.app` 更新，Sparkle 只要求「EdDSA 签名有效」或「Apple 代码签名与旧版一致」**二者之一**，所以只靠 EdDSA 就够了。
2. **最大的限制：EdDSA 私钥丢了就无法轮换**。Sparkle 的密钥轮换要靠 Developer ID 签名作信任锚，ad-hoc 签名做不到。私钥一丢，所有用户都只能手动重装。私钥至少要备份两处。
3. Apple Silicon 上的 arm64 代码必须签名，Xcode 默认会 ad-hoc 签名。Sparkle 把 ad-hoc 也算作「已签名」，因此 **以后每个版本都必须带有效的 ad-hoc 签名**（不能去掉签名，签名也不能被打包后处理破坏）。
4. Sparkle 安装更新后会**移除新 App 的 `com.apple.quarantine`**，所以更新后的 App 不会再弹 Gatekeeper。只有用户**首次**从浏览器下载 DMG 安装时，需要在「系统设置 › 隐私与安全性 › 仍要打开」放行一次（macOS 15 已取消右键打开的绕过方式）。
5. 非沙盒 App **不需要 XPC 服务**，可以删掉，安装器和 ad-hoc 签名之间没有已知冲突。Hardened Runtime 要**关掉**，否则库验证会拒绝加载 ad-hoc 签名的 Sparkle.framework。
6. 更新包：**Sparkle 用 zip**（`ditto -c -k --sequesterRsrc --keepParent`），首次安装继续用 DMG。
7. appcast：作为 release 资产上传 `appcast.xml`，`SUFeedURL` 设为 `https://github.com/tanzby/yet-another-anime-game-launcher/releases/latest/download/appcast.xml`。不需要开 Pages，也不需要往受保护分支写入。
8. CI：用 Sparkle 发布包里的 `bin/generate_appcast`，私钥从 GitHub secret 经 stdin 传入（`--ed-key-file -`）。
9. **TS 版用户没法被现有 updater 直接升级到原生版**：TS updater 只会替换数据目录里的 `resources.neu` 和 `sidecar`，不会换 `.app`。需要发一个「桥接版」TS release，由它下载原生 App 并替换 `PATH_LAUNCH` 指向的 `.app`。此外，原生版的 release 里**绝不能**出现名为 `Yaagl.app.tar.gz` 的资产。

---

## 1. 未签名 / ad-hoc 签名的 App 能否用 Sparkle 2

### Sparkle 的校验规则（源码）

`SUUpdateValidator.m` 对 `.app` 更新的规则写在注释里（[L295-L303](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/Sparkle/SUUpdateValidator.m#L295-L304)）：

- 旧版和新版的 (Ed)DSA 公钥相同且签名有效（此时允许更换代码签名身份），**或**
- 旧版和新版的代码签名身份相同且有效。

最后的判定是 `if (passedDSACheck || passedCodeSigning) return YES;`（[L371](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/Sparkle/SUUpdateValidator.m#L371)）。所以**只有 EdDSA、没有 Apple 证书也能通过校验**。

另有两条「策略」检查（`passesBasicUpdatePolicy…`，[L271](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/Sparkle/SUUpdateValidator.m#L271)）：

- 旧版有 EdDSA 公钥、新版没有：拒绝（只允许轮换，不允许删除）。
- **旧版有代码签名、新版没有：拒绝**。报错原文建议「If no Apple Code Signing certificate is available, adhoc signing can be used at minimum」。

还有一条：新版带了代码签名，但签名已损坏（`codeSignatureIsValidAtBundleURL` 失败）时也拒绝，见 [`SUUpdateValidator.m`](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/Sparkle/SUUpdateValidator.m)。

### ad-hoc 签名在 Sparkle 里算什么

- `bundleAtURLIsCodeSigned` 只检查 `SecStaticCodeCreateWithPath` 和 `SecCodeCopyDesignatedRequirement` 有没有返回 `errSecCSUnsigned`，所以 **ad-hoc 签名算「已签名」**（[`SUCodeSigningVerifier.m`](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/Autoupdate/SUCodeSigningVerifier.m#L248)）。
- ad-hoc 签名没有 Team ID（源码注释：「Note this will return nil for ad-hoc or unsigned binaries」，[L285](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/Autoupdate/SUCodeSigningVerifier.m#L285)）。它的 designated requirement 是 cdhash，所以新旧两个版本永远「不匹配」，`passedCodeSigning` 必然为假。**结果是 ad-hoc 版本只能靠 EdDSA 通过校验。**
- Apple Silicon 要求原生 arm64 代码必须签名，ad-hoc 也算（[Apple: macOS Big Sur 11 Universal Apps release notes](https://developer.apple.com/documentation/macos-release-notes/macos-big-sur-11_0_1-universal-apps-release-notes)）。我们只支持 Apple Silicon，所以 App 实际上一定是 ad-hoc 签名，以后每个版本也必须保持**完整、有效**的 ad-hoc 签名。CI 里如果在 Xcode 构建之后又改了 bundle（比如塞文件、改 Info.plist），必须重新 `codesign --force --deep -s -`，否则更新会被当成「签名损坏」拒绝。

### 限制：密钥轮换

- 下载阶段的回退只认 Developer ID：「As fallback for key rotation, check if the archive is Developer ID signed with a team ID that matches the host」（[L80](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/Sparkle/SUUpdateValidator.m#L80)）。
- 官方的 EdDSA 迁移文档也说，Sparkle「uses the matching Apple code signature to trust the change in Sparkle public keys」（[EdDSA migration](https://sparkle-project.org/documentation/eddsa-migration/)）。
- **结论**：我们没有 Developer ID，**EdDSA 私钥实际上不可轮换、不可丢失**。私钥泄露或丢失后，现有用户只能手动下载新版重装。私钥需要离线备份（例如密码管理器加一个离线副本），不能只存在 GitHub secret 里，因为 secret 写入后读不出来。

### Hardened Runtime 和库验证

官方安装文档原文：开启库验证（属于 Hardened Runtime）时，「the system may not let your application load Sparkle if you attempt to sign to run locally via an ad-hoc signature」（[Documentation](https://sparkle-project.org/documentation/)）。我们不做公证，没有理由开 Hardened Runtime，所以设为 `ENABLE_HARDENED_RUNTIME = NO`。

## 2. quarantine、Gatekeeper、安装器 XPC

- **更新路径不触发 Gatekeeper**：`SUPlainInstaller` 在把新 App 移到位后会执行「Release our new app from quarantine」（[L48](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/Autoupdate/SUPlainInstaller.m#L48)），递归删除 `com.apple.quarantine`（[`SUFileManager.m`](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/Sparkle/SUFileManager.m#L120)）。在 macOS 14.4+ 它还会用 `/usr/bin/gktool scan` 预热 Gatekeeper，失败也不影响安装（[L95](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/Autoupdate/SUPlainInstaller.m#L95)）。所以更新后的 ad-hoc App 可以直接启动。
- **首次安装仍然要手动放行**：macOS 15 起「users will no longer be able to Control-click to override Gatekeeper」，必须去「系统设置 › 隐私与安全性」点「仍要打开」（[Apple Developer News](https://developer.apple.com/news/?id=saqachfa)、[Apple 支持：安全地打开 App](https://support.apple.com/en-us/102445)）。这和现在的 TS 版一样，README 和 release 说明里要写清楚（也可以写 `xattr -dr com.apple.quarantine /Applications/Yaagl.app`）。
- **App Translocation**：如果用户直接在 DMG 或「下载」文件夹里运行带 quarantine 的 App，Sparkle 会中止更新并提示「can't be updated if it's running from the location it was downloaded to」（[`SPUUpdateDriver.m` L198](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/Sparkle/SPUUpdateDriver.m#L198)）。用户把 App 拖进 `/Applications` 并放行后，这个问题就不存在了。
- **XPC 服务**：非沙盒 App「should skip this guide unless you are interested in Removing the XPC Services」。`Installer.xpc` 和 `Downloader.xpc` 只给沙盒 App 用（[Sandboxing](https://sparkle-project.org/documentation/sandboxing/)）。我们不开沙盒（要拉起 Wine），所以不设 `SUEnableInstallerLauncherService`，可以在构建后删掉 `Sparkle.framework/…/XPCServices` 以减小体积。删完要重新 ad-hoc 签名，见第 1 节。Sparkle 自带的 helper 已经是「signed with an ad-hoc signature and Hardened Runtime enabled」，Xcode 拷贝 framework 时会重签。
- 如果 `/Applications` 不可写（非管理员用户），Sparkle 会向 launchd 提交一个独立的特权安装进程，并弹出授权框（[Security & reliability](https://sparkle-project.org/documentation/security-and-reliability/)）。这和是否签名无关。

## 3. 更新包：zip 还是 DMG

Sparkle 支持 dmg、zip、tar、Apple Archive（`.aar`）和 pkg（[Documentation](https://sparkle-project.org/documentation/)、[Publishing](https://sparkle-project.org/documentation/publishing/)）。

| | zip（`ditto`） | DMG |
|---|---|---|
| Sparkle 更新 | 推荐：解压快，不需要挂载 | 可以，但要挂载；官方建议用 APFS + lzfse |
| 首次手动安装 | 不直观 | 拖拽到 Applications，体验好 |
| 符号链接 | `ditto -c -k --sequesterRsrc --keepParent Yaagl.app Yaagl-x.y.z.zip` 能保留 | 能保留 |

建议 release 同时附两个资产：`Yaagl-x.y.z.dmg` 给人下载，`Yaagl-x.y.z.zip` 作为 appcast 的 enclosure。官方特别提醒「Make sure symlinks are preserved」，否则 framework 的签名会被破坏，Sparkle 会把更新当成签名损坏拒绝。所以**不要用 `zip -r`**。

delta 更新：`generate_appcast` 能根据目录里的旧归档自动生成 delta（[Publishing](https://sparkle-project.org/documentation/publishing/)）。原生 App 本身不含 Wine（Wine 放在数据目录），体积小，**第一阶段不做 delta**，CI 也就不需要保存历史归档。

## 4. appcast 托管

`SUFeedURL` 可以是任意 HTTPS URL，官方没有限定托管位置（[Documentation](https://sparkle-project.org/documentation/)）。两种做法：

**A. release 资产（推荐）**

- 每个 tag 的 release 都上传 `appcast.xml`，`SUFeedURL = https://github.com/tanzby/yet-another-anime-game-launcher/releases/latest/download/appcast.xml`。GitHub 文档：「To link directly to a download of your latest release asset… the suffix is `/releases/latest/download/asset-name.zip`」（[Linking to releases](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)）。「latest」指最新的非 draft、非 prerelease release（[REST: Get the latest release](https://docs.github.com/en/rest/releases/releases#get-the-latest-release)）。
- appcast 里只放当前这一个版本就够了，Sparkle 只需要最新条目。
- enclosure URL 用 `--download-url-prefix https://github.com/tanzby/yet-another-anime-game-launcher/releases/download/<tag>/` 生成。
- 优点：不用开 Pages，不用往受保护的 `main` 或 `gh-pages` 写入，和现有 `build-ontag.yaml` 一次 `gh release create` 就能对上。
- 缺点：没法做 beta 频道（prerelease 不算 latest），也不能「撤回」：删掉最新 release 后，latest 会自动回退到上一个版本。

**B. GitHub Pages / `gh-pages` 分支**：URL 稳定，可以维护多条目和多频道（`--channel`），但 CI 需要推送 Pages，还要在 workflow 里维护历史 appcast（`generate_appcast` 会复用目录里已有的 appcast）。等确实需要 beta 频道时再切换，切换方法是发一版改了 `SUFeedURL` 的 App。

## 5. EdDSA 密钥和 CI 签名

工具来源：Sparkle release 资产 `Sparkle-2.10.0.tar.xz` 里的 `bin/`（`generate_keys`、`sign_update`、`generate_appcast`）。SwiftPM 用户也能在 `…/artifacts/sparkle/Sparkle/bin/` 找到同样的工具（[Documentation](https://sparkle-project.org/documentation/)）。CI 直接下载 tar.xz 并校验 sha256，比从 DerivedData 里找更稳。

1. **生成（维护者本机执行，一次）**：`generate_keys` 把私钥存进 login Keychain，并打印公钥，公钥写进 `Info.plist` 的 `SUPublicEDKey`。`generate_keys -x private.key` 导出私钥，`-f` 导入（[`generate_keys/main.swift`](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/generate_keys/main.swift#L166)）。
2. **放进 secret**：把 `private.key` 的内容存成仓库 secret，例如 `SPARKLE_ED_PRIVATE_KEY`，然后离线备份 `private.key` 并删除本地明文文件（见第 1 节轮换限制）。
3. **CI 签名**：`generate_appcast` 和 `sign_update` 都支持 `--ed-key-file -`，从 stdin 读私钥，官方示例就是 `echo "$PRIVATE_KEY_SECRET" | ./generate_appcast --ed-key-file - …`（[`generate_appcast/main.swift` L83](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/generate_appcast/main.swift#L83)、[`sign_update/main.swift` L97](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/sign_update/main.swift#L97)）。`-s <key>` 已弃用，新格式的密钥也不支持它。

`build-ontag.yaml` 的示意步骤（`macos-latest`）：

```bash
mkdir -p updates
ditto -c -k --sequesterRsrc --keepParent Yaagl.app "updates/Yaagl-$YAAGL_VERSION.zip"
echo "$SPARKLE_ED_PRIVATE_KEY" | sparkle/bin/generate_appcast --ed-key-file - \
  --download-url-prefix "https://github.com/$GITHUB_REPOSITORY/releases/download/$YAAGL_VERSION/" \
  -o updates/appcast.xml updates/
gh release create "$YAAGL_VERSION" "Yaagl-$YAAGL_VERSION.dmg" "updates/Yaagl-$YAAGL_VERSION.zip" updates/appcast.xml …
```

`generate_appcast` 会从 bundle 里读出 `LSMinimumSystemVersion` 和是否仅 arm64，写进 appcast（见其 `--help` 说明）。它也会校验 ad-hoc 签名是否完整：签名的 bundle 必须通过 `codeSignatureIsValid`（[`ArchiveItem.swift` L219](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/generate_appcast/ArchiveItem.swift#L219)），相当于在 CI 里顺带做了一次签名检查。

版本号：Sparkle 用 `sparkle:version` 对比 `CFBundleVersion`，用 `sparkle:shortVersionString` 显示（[Publishing](https://sparkle-project.org/documentation/publishing/)）。原生 App 的 `CFBundleVersion` 必须单调递增；可以直接用 semver tag（`MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION` 都取 tag），Sparkle 的标准版本比较器能正确处理 `0.2.0 > 0.1.9`。

## 6. SwiftPM 和 XcodeGen

Sparkle 的 `Package.swift` 是一个 `binaryTarget`（预编译 xcframework，`platforms: [.macOS(.v12)]`），不会在本地编译 Sparkle 源码（[`Package.swift`](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/Package.swift)）。XcodeGen 的语法见 [ProjectSpec](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md)；application 目标的 package 依赖默认 `embed: true`。

```yaml
packages:
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: 2.10.0
targets:
  Yaagl:
    type: application
    platform: macOS
    deploymentTarget: "15.0"
    dependencies:
      - package: Sparkle
    settings:
      base:
        CODE_SIGN_IDENTITY: "-"          # ad-hoc
        CODE_SIGN_STYLE: Manual
        DEVELOPMENT_TEAM: ""
        ENABLE_HARDENED_RUNTIME: NO      # 否则库验证拒绝加载 ad-hoc 的 Sparkle
        ARCHS: arm64
    info:
      path: Yaagl/Info.plist
      properties:
        SUFeedURL: https://github.com/tanzby/yet-another-anime-game-launcher/releases/latest/download/appcast.xml
        SUPublicEDKey: <generate_keys 打印的公钥>
        SUEnableAutomaticChecks: true
```

代码侧：SwiftUI 用 `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)`，加一个「检查更新…」菜单项绑定 `checkForUpdates`，这是官方文档里的标准接法（[Documentation](https://sparkle-project.org/documentation/)）。不需要 `SUEnableInstallerLauncherService` 或 `SUEnableDownloaderService`（非沙盒）。`Package.resolved` 要入库，锁定 checksum。

## 7. TS 版用户怎么第一次升级到原生版

### 现有 TS updater 的机制

读 `src/updater.ts`、`src/github.ts` 和 `build-app.js` 得到：

- 它请求 `GET /repos/tanzby/yet-another-anime-game-launcher/releases/latest`，只有**同时满足** `semver.gt(tag, 当前版本)` **并且**存在名为 `resources_hk4ecn.neu` 的资产时，才认为有更新。否则一律当作「已是最新」，不提示任何东西。
- 如果还有 `Yaagl.app.tar.gz`，它会下载并从中解出 `Yaagl.app/Contents/Resources/sidecar`，写到**数据目录**的 `./sidecar`。然后把新的 `resources.neu` 写到数据目录。
- `.app` 本身（Neutralino 二进制、Info.plist）**从不被替换**。启动脚本 `Contents/MacOS/parameterized` 把 bundle 的 Resources rsync 到 `~/Library/Application Support/Yaagl`，然后以 `PATH_LAUNCH=<.app 所在目录>` 启动 Neutralino。

所以**现有 updater 无法把用户直接升级成原生 App**，有两个坑：

1. 原生版 release 不带 `resources_hk4ecn.neu` 时，老用户会**静默停在旧版**，永远不会收到提示。
2. 原生版 release 如果带了名为 `Yaagl.app.tar.gz` 的资产，老 updater 会去里面找 `sidecar` 目录，找不到就报错。**原生版不要用这个资产名。**

### 推荐路径：桥接版 TS release

1. 发**最后一个 TS 版本**（例如 `0.x.y`），它的 `resources.neu` 带「迁移到原生版」逻辑：检查到原生版的 release 后，在 UI 里提示用户，用 aria2 下载原生 `Yaagl-x.y.z.zip`，`ditto -x -k` 解压到临时目录，然后用一个 detached 的 shell 脚本等当前进程退出、替换 `PATH_LAUNCH` 指向的 `Yaagl.app`、`open` 新 App。下载由 aria2 完成，CLI 下载默认不会打 quarantine；脚本里再 `xattr -dr com.apple.quarantine` 一次作为保险。这样原生 App 首次启动不会弹 Gatekeeper。
2. 原生版的每个 release 在过渡期内**额外附一个 `resources_hk4ecn.neu`**，内容就是桥接版的 neu（从桥接 release 用 `gh release download` 拷过来即可，不需要 TS 源码还在仓库里）。这样不管老用户停在哪个 TS 版本，都会先升到桥接版，再迁移到原生版。过渡期结束后去掉这个资产。
3. 原生 App 首次启动时需要容忍数据目录里残留的 TS 文件（`resources.neu`、`sidecar/`、`.bundle-stamp` 等）：沿用 Wine、prefix、设置，清理不再需要的文件。**沿用 bundle id `com.3shain.yaagl`**，这样 Sparkle 和 LaunchServices 会把它当成同一个 App。
4. 兜底：release 说明里写手动方式，即下载 DMG、替换 `/Applications/Yaagl.app`、首次在「隐私与安全性」里放行。

不做桥接的话，只能在最后一个 TS 版本里弹「请手动下载原生版」的提示。这样更简单，但每个老用户都要手动走一遍 Gatekeeper 放行。

## 需要在地图上决定的新问题

- **EdDSA 私钥的保管和备份**：没有 Developer ID，私钥不可轮换，丢了所有用户就只能手动重装。由谁生成、备份在哪，需要维护者拍板。这一步只能由人来做，不应由 agent 创建。
- **TS → 原生的桥接方案**：是否做桥接版自动迁移（推荐），还是只弹手动下载提示。这决定了最后一个 TS 版本要做的工作量，对应地图「从 TS 版 updater 过渡到 Sparkle 的升级路径」。

## 来源

- Sparkle 文档：[Documentation](https://sparkle-project.org/documentation/)、[Publishing](https://sparkle-project.org/documentation/publishing/)、[Sandboxing](https://sparkle-project.org/documentation/sandboxing/)、[EdDSA migration](https://sparkle-project.org/documentation/eddsa-migration/)、[Security & reliability](https://sparkle-project.org/documentation/security-and-reliability/)
- Sparkle 源码（`e95f42b`）：[`SUUpdateValidator.m`](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/Sparkle/SUUpdateValidator.m)、[`SUCodeSigningVerifier.m`](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/Autoupdate/SUCodeSigningVerifier.m)、[`SUPlainInstaller.m`](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/Autoupdate/SUPlainInstaller.m)、[`SUFileManager.m`](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/Sparkle/SUFileManager.m)、[`SPUUpdateDriver.m`](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/Sparkle/SPUUpdateDriver.m)、[`generate_appcast/`](https://github.com/sparkle-project/Sparkle/tree/e95f42b15686ad547a919ddaef18d75eac9bf5d9/generate_appcast)、[`sign_update/main.swift`](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/sign_update/main.swift)、[`generate_keys/main.swift`](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/generate_keys/main.swift)、[`Package.swift`](https://github.com/sparkle-project/Sparkle/blob/e95f42b15686ad547a919ddaef18d75eac9bf5d9/Package.swift)
- Apple：[Gatekeeper changes in macOS Sequoia](https://developer.apple.com/news/?id=saqachfa)、[Safely open apps on your Mac](https://support.apple.com/en-us/102445)、[Universal Apps release notes（arm64 必须签名）](https://developer.apple.com/documentation/macos-release-notes/macos-big-sur-11_0_1-universal-apps-release-notes)
- GitHub：[Linking to releases](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)、[REST: Get the latest release](https://docs.github.com/en/rest/releases/releases#get-the-latest-release)
- XcodeGen：[ProjectSpec](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md)
- 本仓库：`src/updater.ts`、`src/github.ts`、`build-app.js`（启动脚本和 Info.plist）、`.github/workflows/build-ontag.yaml`
