# 原生版不兼容 TS 版数据：首启静默清场，Wine 固定为一个版本

原生 Swift 版（地图 #13）仍然使用 `~/Library/Application Support/Yaagl` 作为数据目录，但只是沿用这个位置，**不沿用里面的内容**。TS 版不再维护，也不支持从原生版回退，所以维护者决定允许 breaking：原生版在数据目录写入自己的版本标记，启动时如果没有这个标记，就不经确认直接删除 `.storage/`、`wine/`、`wineprefix/`、`dxmt/`、`YaaglGame.app`、`sidecar/` 和 Neutralino 残留，设置从默认值开始，Wine 重新下载。`wine-gptk4/`、`gptk4/`、`logs/` 不动。游戏目录在数据目录之外，也不动，用户重新选一次即可继续使用。

这条决定推翻了 #18 研究得出的两条契约：一是继续读写 `.neustorage`，二是 Wine 列表必须认得现有的 `wine_tag`。之所以不做迁移，是因为不读旧状态，就不需要去推断旧 `wine/` 被打过哪些 shim 和 DXMT 补丁，也不需要承担 `.neustorage` 字符串格式的历史包袱。代价是每个老用户要重下一次 Wine（约 2GB），并且重新选择设置。

## 相关决定（#29）

- **Wine**：只提供一个固定版本 `11.0-1-crossover-signed-experimental`，写死在 App 里，运行时下载到 `wine/`，不打进 `.app`，暂时不做切换 UI。只要版本标记和固定版本不一致，或者 `wine/` 不可用，就删掉 `wine/` 和 `wineprefix/` 整体重装。
- **遥测 hosts**：这一项不是游戏运行的必要条件，但默认必须启用，不提供开关。首次打开 App 时引导用户点「屏蔽」，通过 `NSAppleScript` 的 `with administrator privileges` 提权，在 `/etc/hosts` 里写入 `# Added by Yaagl` … `# End of section` 这一段。域名列表照搬 TS 版，去掉绝区零那一项。之后每次打开 App 都检查这一段，缺失或内容不一致就不允许启动游戏。
- **`config_block_net`**（启动时临时屏蔽 dispatch 10 秒）删除。

## Considered Options

- 继续读写 `.neustorage`，并支持回退到 TS 版：被否决，因为 TS 版不再维护。
- 只做一次性设置导入：被否决，维护者希望从头开始。
- 换 Wine 时保留 prefix，只跑 `wineboot -u`：被否决，整体重装更简单，状态也更干净。
- 改用新的数据目录名：被否决，旧目录会白占 2.7GB，需要用户手动删除。
