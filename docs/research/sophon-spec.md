# Sophon 协议规格（原神 CN）

研究票：[#16](https://github.com/tanzby/yet-another-anime-game-launcher/issues/16)，所属地图 [#13](https://github.com/tanzby/yet-another-anime-game-launcher/issues/13)。

范围：原神 CN（`game_type=hk4e`，`rel_type=cn`）在现有 TS 版中通过 Python `sophon_server` 用到的全部 Sophon 行为。依据是仓库源码（`file:line` 均指 `origin/main` @ f38cda4）；依赖库的事实来自它们的官方仓库。**本文不含任何 key、password、game_id 或 launcher_id 的值**，URL 中的这些值都用 `{占位符}` 表示，真实值请看所引用的源码行。

---

## 0. 结论速览

1. 协议分四层：`getGameBranches`（拿 `package_id`/`password`/`tag`）→ `getBuild` / `getPatchBuild`（拿 manifest 与 chunk/diff 的 URL 前缀）→ zstd 压缩的 protobuf manifest → 按 id 下载的 chunk（zstd）或 ldiff（HDiffPatch）。
2. **现有代码里原神 CN 的「更新」和「预下载」根本走不通**：`make_getBuild_url` 在 `do_update` 且 `rel_type == "cn"` 时直接 `assert False, "TODO"`（`sophon_server/sophon_api.py:704-708`）。CN 只有安装、修复、在线信息查询这三条路径可用。CN 的 `getPatchBuild` 主机名在仓库里不存在，Swift 版必须先补上这个事实（见 §9「新的决策问题」）。
3. 文件组装：按 `ChunkInfo.offset` 把 zstd 解压后的 chunk 写进临时文件，整文件 MD5 对上 `FileInfo.md5` 后移入游戏目录。chunk 级 md5/xxhash 字段 Python 没有用。
4. ldiff：一个 ldiff 文件里拼接了多个 HDiffPatch 补丁，按 `patch_offset`/`patch_length` 切出一段，交给 `hpatchz`（v4.5.2，含 zstd/lzma/zlib/bz2 解压插件）打补丁，再按新文件 MD5 校验，失败回退到 chunk 下载。
5. Swift 依赖建议：`apple/swift-protobuf`（manifest）、`facebook/zstd`（官方仓库自带 `Package.swift`）、`sisong/HDiffPatch`（MIT，C 源码作为 SwiftPM C target 链接，替代 `hpatchz` 外部二进制）、CryptoKit `Insecure.MD5`、URLSession。xxHash 可选。
6. Python 实现有一批 bug 和隐患（临时文件按 basename 命名会撞名、出错只重试不退避、HTTP 错误体会被当成数据写入、`int32 size`、关闭 TLS 校验等），Swift 版不要照抄，见 §8。

---

## 1. 现有架构（被替换的东西）

- TS 端在 `127.0.0.1` 的随机端口（40000–65535）拉起 `./sidecar/sophon_server/sophon-server`，环境变量 `SOPHON_PORT`、`SOPHON_HOST`、`TERMINATE_WITH_PID`（`src/clients/mhy/hk4e/index.tsx:84-96`）。30 秒内用 `/health` 探活，每 3 秒重试，最多 10 次（`src/sophon.ts:207-234`）。
- sidecar 是 Nuitka 打包的 FastAPI（`sophon_server/server.py`），把 `hpatchz` 作为数据文件打进去（`build-sophon.sh:2,16`）。父进程消失后自杀（`server.py:32-42`）。
- 本地 HTTP 接口（Swift 版不再需要，仅供对照行为）：

| 方法 | 路径 | 作用 | 代码 |
|---|---|---|---|
| POST | `/api/{install\|repair\|update}` | 起任务，返回 `task_id` | `server.py:72-74`，请求体 `models.py:5-17` |
| GET | `/api/tasks/{id}/status` | 轮询状态 | `server.py:76-84` |
| DELETE | `/api/tasks/{id}` | 设置取消事件 | `server.py:87-91` |
| GET | `/api/game/online_info?reltype=&game=` | 最新版本、安装大小、可更新版本、预下载 | `server.py:93-95`，`tasks.py:181-250` |
| WS | `/ws/{task_id}` | 进度事件流 | `server.py:104-118`，`utils.py` |

Swift 版里这些都变成进程内的 async API，进度事件变成 `AsyncStream`。

---

## 2. 远端 API

### 2.1 getGameBranches（鉴权材料）

```
GET {HYP_CONNECT_CN}/getGameBranches?game_ids[]={GAME_ID}&launcher_id={LAUNCHER_ID}
```

- `{HYP_CONNECT_CN}`：CN 的 hyp-connect API 基址（`sophon_api.py:633`；OS 是另一台主机，`:631`）。
- `{GAME_ID}` / `{LAUNCHER_ID}`：CN 原神的值在 `sophon_api.py:650-656`（注释说明来自 Snap.Hutao，MIT）。
- 响应：`{retcode, message, data}`，`retcode != 0` 即失败（`sophon_api.py:611-618`）。
- 取 `data.game_branches[0][branch]`，`branch` 是 `"main"` 或 `"pre_download"`（`sophon_api.py:354,674`）。用到的字段：
  - `branch`、`package_id`、`password`：拼 getBuild URL（`:717-722`）。`password` 是服务端下发的下载凭据，**不要写日志、不要落盘到用户可见处**（Python 会把整个 JSON 缓存到临时目录，见 §6）。
  - `tag`：服务端版本号 `MAJOR.MINOR.PATCH`（`:678`）。
  - `diff_tags`：可增量更新的旧版本列表，TS 用来判断能否更新（`tasks.py:202`，`index.tsx:100,196,233`）。
- 预下载是否存在：`pre_download` 分支为 `null` 时触发 `assert`，被 `fetch_online_game_info` 捕获为 `pre_download=false`（`sophon_api.py:675-676`，`tasks.py:209-220`）。Swift 版应把「分支为 null」作为正常的 `nil`，而不是异常。
- `getGameConfigs`、`getGameChannelSDKs` 在代码里是 `if False` 的死代码（`sophon_api.py:681-690`），不需要。

### 2.2 getBuild / getPatchBuild

```
GET  https://{SOPHON_HOST}/downloader/sophon_chunk/api/getBuild?branch={BRANCH}&package_id={PACKAGE_ID}&password={PASSWORD}
POST https://{SOPHON_PATCH_HOST}/downloader/sophon_chunk/api/getPatchBuild?branch=...&package_id=...&password=...   (空 body)
```

- 组装在 `sophon_api.py:693-725`。主机选择取决于 `OPT.do_update` 而不是 `api_file`：
  - 非更新（安装、修复、在线信息）：CN 用 takumi 的 API 主机（`:713`）。
  - 更新：OS 用 downloader-api 主机（`:706`），**CN 是 `assert False, "TODO"`（`:707-708`）**。注意这一分支对 getBuild 和 getPatchBuild 都生效，所以 CN 更新连 getBuild 都拿不到。
- getPatchBuild 必须用 POST（`:736-738`，`load_cached_api_file` 在 `POST_data != None` 时发 POST，`:597-601`）。
- 响应里用到的字段（`sophon_api.py:747-805`，`:946`，`:1190`）：
  - `data.tag`：该 build 的版本号。
  - `data.manifests[]`，每项：
    - `matching_field`：分类名。原神 CN 只用 `"game"`（`tasks.py:50,104,133,161,170`）。语音包分类（`en-us` 等）代码支持但 TS 从不请求，CN 安装后语音由游戏内下载。
    - `manifest.id`：manifest 文件名；`manifest_download.url_prefix`：manifest 下载前缀。
    - `chunk_download.url_prefix`：chunk 下载前缀（getBuild）。
    - `diff_download.url_prefix`：ldiff 下载前缀（getPatchBuild）。
  - 分类匹配：先精确匹配，非 `"main"` 时再子串模糊匹配，多个命中即报错（`:756-774`）。
- **未核实**：响应里可能还有 `url_suffix`、压缩类型、`stats`（总大小）之类字段，Python 不读。Swift 版建模时应宽松解码（未知字段忽略），并在实现票里抓一次真实响应确认（需维护者同意后再发请求）。

### 2.3 Manifest 下载与解析

- URL：`{manifest_download.url_prefix}/{manifest.id}`（`sophon_api.py:780`）。
- 内容：一个 zstd 帧，解压后是 protobuf。chunk 用 `manifest.proto` 的 `Manifest`，diff 用 `manifest_ldiff.proto` 的 `DiffManifest`（`:782-792`）。
- `manifest.proto`（`sophon_server/manifest.proto:7-26`）：

| 消息.字段 | 号 | 类型 | 含义 |
|---|---|---|---|
| `Manifest.files` | 1 | repeated FileInfo | |
| `FileInfo.filename` | 1 | string | 相对游戏目录的路径（`/` 分隔） |
| `FileInfo.chunks` | 2 | repeated ChunkInfo | |
| `FileInfo.flags` | 3 | int32 | 0 = 文件，64 = 目录；其他值 Python 直接 assert 失败（`sophon_api.py:925-931`） |
| `FileInfo.size` | 4 | int32 | 整文件大小（**int32，>2 GiB 会溢出**，见 §8） |
| `FileInfo.md5` | 5 | string | 整文件 MD5（小写 hex） |
| `ChunkInfo.chunk_id` | 1 | string | chunk 文件名，也是 URL 后缀 |
| `ChunkInfo.md5` | 2 | string | 解压后 chunk 的 MD5（Python 未使用） |
| `ChunkInfo.offset` | 3 | uint64 | 在目标文件中的写入偏移 |
| `ChunkInfo.compressed_size` | 4 | uint32 | 下载大小 |
| `ChunkInfo.uncompressed_size` | 5 | uint32 | 解压后大小 |
| `ChunkInfo.xxhash` | 6 | uint64 | 压缩数据的 xxhash（Python 未使用，具体变体未核实） |

- `manifest_ldiff.proto`（`sophon_server/manifest_ldiff.proto:8-61`）：

| 消息.字段 | 号 | 类型 | 含义 |
|---|---|---|---|
| `DiffManifest.files` | 1 | repeated DiffFileInfo | |
| `DiffManifest.files_delete` | 2 | repeated DeleteFile | 按旧版本分组的删除清单 |
| `DiffFileInfo.filename/size/hash` | 1/2/3 | string/int32/string | 新文件路径、大小、补丁后 MD5 |
| `DiffFileInfo.patches` | 4 | repeated Patch | 按旧版本号索引 |
| `Patch.key` / `Patch.info` | 1/2 | string / PatchInfo | `key` = 旧版本号，如 `"5.5.0"` |
| `PatchInfo.patch_id` | 1 | string | ldiff 文件名，也是 URL 后缀 |
| `PatchInfo.tag/build_id/patch_name` | 2/3/5 | string | 未使用 |
| `PatchInfo.patch_size` | 4 | int64 | 整个 ldiff 文件大小 |
| `PatchInfo.patch_offset/patch_length` | 6/7 | int64 | 本文件补丁在 ldiff 中的区段 |
| `PatchInfo.original_name/size/hash` | 8/9/10 | string/int64/string | 旧文件路径、大小、MD5 |
| `DeleteFile.key/info` | 1/2 | string / DeleteFiles | |
| `DeleteFiles.list` | 1 | repeated DeleteFileInfo(filename, size, hash) | |

  `patches` 为空表示该文件需要整文件下载（新文件）；有 `patches` 但没有当前版本的 key 表示未修改（`sophon_api.py:1084-1096,1108-1131`）。

- 两个 `.proto` 都是社区逆向所得（文件头注明来源），不是官方规格。swift-protobuf 对未知字段会保留、不会报错，所以服务端加字段不会破坏解析。

### 2.4 Chunk 与 ldiff 下载

- chunk：`GET {chunk_download.url_prefix}/{chunk_id}`（`sophon_api.py:946,980`）。
- ldiff：`GET {diff_download.url_prefix}/{patch_id}`（`:1190-1191`）。
- 均支持 `Range: bytes={已有字节}-` 续传；`416` 视为已下完（`:866-912`）。

---

## 3. 安装（full install，chunk 模式）

流程（`sophon_server/tasks.py:30-112`，`sophon_api.py:372-396,914-1025`）：

1. 游戏目录必须为空（允许一个 `config.ini`，`sophon_api.py:376-378`）。写入 CN 模板 `config.ini`：`channel=1`、`cps=mihoyo`、`game_version=0.0.0`、`sub_channel=1`，CRLF 换行（`:383-395`）。
2. `getGameBranches` → `getBuild` → `game` 分类 manifest。
3. **立即把 `config.ini` 的版本改成服务端 tag**（`tasks.py:51`），然后才开始下载。这意味着中断的安装会留下一个声称是最新版本的 `config.ini`；TS 端靠 `pkg_version` 是否存在判断「已安装」（`index.tsx:156-157`），所以 Swift 版应改为下载完成后再写版本。
4. 下载大小 = 所有 chunk 的 `compressed_size` 之和（`sophon_api.py:852-863`）。TS 用它 ×1.2 做磁盘空间检查（`index.tsx:158-168`）。
5. 文件排序：路径不含 `/` 的优先，含 `globalgamemanagers` 或 `pkg_version` 的更优先（`tasks.py:77-100`），这样中断后也能识别版本。
6. 8 线程并发，每个文件一个任务，每个文件最多 5 次尝试（`tasks.py:61-75,93-102`，`WORKER_CNT = 8` 在 `sophon_api.py:108`）。
7. 单文件（`download_game_file`，`sophon_api.py:914-1025`）：
   - `flags == 64`：目录项，跳过。
   - 目标文件大小已等于 `size`：跳过（**只比大小，不比 MD5**）。
   - 临时文件 `tempdir/{basename}`；若其大小已等于 `size`，直接去校验（「下完没移走」的情况）。
   - 否则以 `wb` 截断打开，逐 chunk：下载到 `tempdir/{chunk_id}`（已完整则跳过）→ zstd 整块解压 → `seek(offset)` 写入。
   - 整文件 MD5 对比 `FileInfo.md5`，失败删临时文件并抛错（外层重试）。
   - 删掉本文件的 chunk 缓存，`shutil.move` 到游戏目录（自动建父目录）。
8. 全部完成后重新拉 manifest，做「快速完整性检查」：每个非目录文件大小必须等于 manifest（`sophon_api.py:1042-1051`），再写 `config.ini` 版本（`:1074-1081`）。
9. 没有生成 `Audio_*_pkg_version`，也不写 `audio_lang_14`（`update_voiceover_meta_file` 在 `:518-550`，没有调用方）。

**压缩格式**：chunk 和 manifest 都是标准 zstd 帧，Python 用 `zstandard.ZstdDecompressor().stream_reader(...).read()`（`:783-792,983-985`），没有字典。

---

## 4. 增量更新（ldiff 模式）

> 以下描述的是 Python 对 OS 服的实现。CN 在 `sophon_api.py:708` 断言失败，从未跑通过。

流程（`tasks.py:142-179`）：

1. 识别发行类型：有 `YuanShen.exe` 且没有 `{Data}/Plugins/PCGameSDK.dll` 即 `cn`（`sophon_api.py:411-418`）。
2. 已装版本 = min(`{Data}/globalgamemanagers` 中正则 `\0(\d+\.\d+\.\d+)_\d+_\d+\0` 唯一匹配, `config.ini` 的 `game_version`)（`:437-446,459-484`）。理由是 `config.ini` 最后写。
3. 清掉临时目录里缓存的 `.json`/`.zstd`（`tasks.py:20-28,156`）。
4. 拉 getBuild（chunk manifest）与 getPatchBuild（diff manifest），都选 `game`。若已装版本等于 getBuild 的 tag，报「没有更新」（`sophon_api.py:815-830`）。
5. 非预下载时**先删旧文件**：`files_delete` 里 `key == 已装版本` 的 `list`，逐个删除（`:1341-1375`）。
6. ldiff 下载与打补丁，逐文件串行（`apply_or_prepare_ldiff_files`，`:1264-1336`）：
   - 总下载量按 `patch_id` 去重求和（`:1276-1294`）。
   - `_download_ldiff_file`（`:1099-1202`）的判定顺序：
     1. `patches` 为空 → 加入新文件列表（chunk 下载）。
     2. 没有当前版本的 `Patch` → 未修改，跳过。
     3. 游戏文件大小 == `original_size` → 可以打补丁（**不校验 original_hash**）。
     4. 大小 == 新 `size` 且 MD5 == 新 `hash` → 已经是新版，跳过。
     5. 文件不存在 → 加入新文件列表。
     6. 否则视为损坏 → 加入新文件列表。
     7. `{gamedir}/ldiff/{patch_id}` 大小已等于 `patch_size` → 已下载，复用。
     8. 否则下载到 `{patch_id}_tmp`，大小对上后改名。
   - 同一个 `patch_id` 被多个文件共用，下载一次即可（靠第 7 步的大小判断）。
   - `_apply_ldiff_file`（`:1205-1261`）：从 ldiff 读出 `[patch_offset, patch_offset+patch_length)` 写入临时文件（hpatchz 不接受尾随数据，`:236-243`），执行 `hpatchz -f old patch tmp/{basename}`，超时 50 s，超时后再以 300 s 重试一次（`:1239-1242`）。退出码非 0 或 stderr 非空即失败（`:262-267`）。之后断言大小、比对 MD5；MD5 不符则加入新文件列表（但**仍然会把错误文件 move 进游戏目录**，`:1247-1261`）。
7. 新文件下载：对新文件列表用 chunk 流程下载（`diff_download_new_files`，`:1378-1427`）。
8. 重新拉 manifest，快速检查：diff manifest 里每个文件大小正确、删除清单里的文件都已不存在（`:1053-1072`），写 `config.ini` 版本。
9. 删除本次用到的 ldiff 文件（`:1430-1465`）。TS 随后清掉 `predownloaded_all`（`program-update-game.ts:139`）。

**ldiff 补丁格式**：HDiffPatch 的 diff 数据。仓库带的 `sidecar/hpatchz/hpatchz` 为 `HDiffPatch::hpatchz v4.5.2`，编入了 zstd、lzma/lzma2、zlib、bz2 解压插件（对二进制做 `strings` 得到）。具体用哪种压缩、是否为 `-SD` 单压缩格式，未核实；Swift 版链接 HDiffPatch 时应启用 zstd 与 lzma 插件以覆盖已知情况，并在实现票里用真实 ldiff 测一次。

**TS 端额外步骤**：更新到 ≥ 3.6.0 时把 `StreamingAssets/Audio/GeneratedSoundBanks/Windows` 挪到 `StreamingAssets/AudioAssets`（`program-update-game.ts:92-136`）。这是早年遗留迁移，对当前 CN 用户基本无意义，可以在 Swift 版放弃（需决策确认）。

---

## 5. 预下载

- `branch = "pre_download"`（`sophon_api.py:354`）。在线信息查询时用它判断是否有预下载及其版本（`tasks.py:209-220`）。
- 只做第 6 步的 ldiff 下载，不删旧文件、不打补丁、不下新文件（`:1210,1301,1314,1383-1386`）。ldiff 留在 `{gamedir}/ldiff/`。
- 之后正式更新时，第 6.7 步按大小命中已下载的 ldiff，跳过下载。
- TS 用设置键 `predownloaded_all` 记录「已预下载」（`program-update-game.ts:199`），提示条件见 `index.tsx:116-123`。
- 预下载**不预取新文件的 chunk**，正式更新时这部分仍要现下（`:1383-1386`）。官方启动器会预取，这是能力差距。
- 同样因 `sophon_api.py:708`，CN 预下载目前不可用。

---

## 6. 修复（完整性检查）

`repair_by_category`（`sophon_api.py:1468-1541`），TS 总是用 `reliable`（`program-check-integrity.ts:16`）：

1. 清缓存、拉 getBuild（走非更新主机，所以 CN 可用）。已装版本 != 服务端 tag 时报错要求先更新（`:1479-1480`）。
2. 用 `max(2, 物理核数 - 4)` 个线程（`:111`）逐文件检查：`quick` 只比大小；`reliable` 大小对了再比 MD5（`:1503-1512`）。目录项（`flags == 64`）的 manifest 大小为 0，而目录的 stat 大小（或不存在时的 -1）通常不为 0，会被误判为需修复，随后在下载时被跳过，只是多一条无用的待修复记录。
3. 需修复的文件加入列表，走新文件 chunk 下载（`:1541`）。
4. 修复不改 `config.ini`。

TS 在以下场景调用修复：选择已有的、版本为最新的目录时（`index.tsx:205-210`）；用户手动检查；`init` 中补丁回滚失败时（`index.tsx:283-301`）。

---

## 7. 临时目录、缓存、断点、重试、取消、进度

### 临时目录与缓存

- 默认 `{gamedir}/.tmp`（`tasks.py:39-42,122-125,151-154`；TS 显式传 `{gamedir}/.tmp`，`program-update-game.ts:19`）。ldiff 放在 `{gamedir}/ldiff`（`sophon_api.py:1273`）。
- API JSON 和 manifest 按文件名缓存 24 小时（`sophon_api.py:574-608`）；安装不清缓存，更新和修复开始前清（`tasks.py:127,156`）。缓存的 getGameBranches JSON 里含 `password`。
- 开发用的 `EXPORT_JSON_FILES = True`（`:114`）会把每个 manifest 导出成 JSON 放在临时目录。生产里没必要。
- 在线信息查询用相对路径 `./sidecar/sophon_server/gametemp` 作临时目录，用完删除（`tasks.py:188-208,222`）。

### 断点续传

- 粒度是 chunk：已完整的 `tempdir/{chunk_id}` 不重下，不完整的用 HTTP Range 续传（`sophon_api.py:866-912`）。目标文件每次尝试都以 `wb` 截断重组（`:967`）。
- ldiff 以 `{patch_id}_tmp` 续传，完成后改名（`:1179-1199`）。
- 已在游戏目录且大小正确的文件直接跳过，所以重跑安装就是「续传」。

### 错误与重试

- HTTP 层：pycurl 出错后 `sleep(10)` 然后 `return`（`:900-909`），**并没有在本层重试**，也没有写入；随后对缺失/不完整 chunk 解压失败，由文件级循环兜底。
- 文件级：最多 5 次，无退避（`tasks.py:61-75`，`sophon_api.py:1404-1418`）。任一文件 5 次失败，`future.result()` 抛出，整个任务失败（其他线程继续跑完已提交的任务）。
- HTTP 非 2xx（除 416）会被当成正文追加写入 chunk 文件（`:894-912` 没检查状态码），只能靠整文件 MD5 发现。
- hpatchz：超时 50 s → 300 s；其他失败直接抛错（§4）。

### 取消

- 安装、修复检查取消事件（`tasks.py:66-68`，`sophon_api.py:970-973,1409-1411,1498-1501`）；**更新完全不接取消**（`tasks.py:166-167` 没传 `cancel_event`）。TS 也从未调用取消（`src/sophon.ts:179-188` 注释「Partial support」）。

### 进度事件

全部是 WebSocket JSON，`type` 字段区分（`sophon_server/progress_handlers.py`）；`chunk_progress` 节流到每秒最多一条（`:6,70-91`），`check_file` 每 10 个文件一条（`:142-156`）。速度 = 每 10 秒内下载字节 / 10（`:19-29`）。下载量按 **压缩字节**累计（`:71`）。

| 事件 | 关键字段 | TS 是否消费 |
|---|---|---|
| `job_start` / `job_end` / `job_error` / `error` / `completed` | `error` | start 用于安装（`program-install-game.ts:28-31`）；end/error 结束流（`src/sophon.ts:129-138`） |
| `download_summary` | `game_version, download_size, download_file_count` | 否 |
| `chunk_progress` | `filename, overall_progress{downloaded_size,total_size,overall_percent,download_speed}` | 是：安装、更新、预下载、修复 |
| `file_download_start/skipped/complete/error` | `filename, reason, file_size` | 否 |
| `repair_summary` | `repair_mode, total_files` | 否 |
| `check_file` | `overall_progress{checked_files,total_files,overall_percent}` | 是（`program-check-integrity.ts:23-34`） |
| `delete_file_summary` / `delete_file` | `overall_progress{deleted_files,total_files,overall_percent}` | `delete_file` 是 |
| `delete_ldiff_file_summary` / `delete_ldiff_file` | 同上 | `delete_ldiff_file` 是 |
| `ldiff_download_summary/start/skipped/complete/error` | `complete` 带 `overall_progress` | `complete` 是 |
| `ldiff_patch_start/complete/error/skipped` | `filename, error` | 否 |

UI 只需要三种状态：下载中（文件名、速度、已下/总量、百分比）、扫描中（已查/总数）、打补丁/删除中（百分比）。Swift 版可以把事件收窄成一个枚举，不必复刻全部类型。

---

## 8. Python 实现里不应照抄的问题

| # | 问题 | 位置 | Swift 版做法 |
|---|---|---|---|
| 1 | CN 更新/预下载未实现 | `sophon_api.py:707-708` | 补上 CN 主机（需先确认，见 §9） |
| 2 | 临时文件按 basename 命名，8 线程并发下不同目录的同名文件会互相覆盖 | `:959,1226` | 用相对路径的哈希或完整相对路径 |
| 3 | chunk 缓存以 `chunk_id` 命名、按文件删除；若两个文件共享同一 chunk 并发下载，会竞争同一文件 | `:974,1013-1014` | 按 `chunk_id` 去重，由一个 actor 管理下载与引用计数 |
| 4 | HTTP 状态码不检查，错误页被写入数据 | `:894-912` | 只接受 200/206，416 视为完成 |
| 5 | 网络错误无本层重试、无退避 | `:900-909` | 指数退避 + 有上限的重试 |
| 6 | 整文件读入内存做 MD5、整块读 chunk | `:1002,1145,1246,1509` | 流式 MD5（CryptoKit `Insecure.MD5` 增量 `update`），流式解压 |
| 7 | `FileInfo.size` / `DiffFileInfo.size` 是 `int32` | `manifest.proto:15`，`manifest_ldiff.proto:15` | 生成代码是 `Int32`，比较前转 `Int64`，并对负值告警（字段类型是社区逆向，若服务端实际按 varint 发大值会被截断，需在实现票确认） |
| 8 | 补丁后 MD5 不符仍把错误文件移入游戏目录 | `:1247-1261` | 不符则丢弃，走 chunk 下载 |
| 9 | 安装开始就写新版本号进 `config.ini` | `tasks.py:51` | 完成并校验后再写 |
| 10 | 更新不支持取消；`file_download_error` 少传参数，取消时会 TypeError | `tasks.py:166`，`sophon_api.py:972` | 结构化并发，`Task.checkCancellation()` |
| 11 | `raise Exception(...)["pkg_version", ""]` 本身会抛 TypeError | `sophon_api.py:1418` | — |
| 12 | 关闭了全局 TLS 校验 | `server.py:14` | URLSession 默认校验，不要关 |
| 13 | ldiff 打补丁前不校验 `original_hash` | `:1139-1141` | 至少在 reliable 模式下校验 |
| 14 | 快速检查（安装后）与「文件已存在」只比大小 | `:940,1050` | 保持（速度考虑），但修复入口要能 reliable |
| 15 | `malloc_zone_pressure_relief` 等内存 hack | `:95-105` | 不需要 |
| 16 | `filename_safety_check` 只拒 `..` 和前导 `/` | `:202-208` | 规范化后确认仍在游戏目录内 |

---

## 9. Swift 实现

### 依赖

| 需求 | 方案 | 依据 |
|---|---|---|
| protobuf | `apple/swift-protobuf`（最新 1.38.1），用 `SwiftProtobufPlugin` 构建插件从 `.proto` 生成代码，或把生成的 `.pb.swift` 入库 | 官方仓库 `Package.swift` 提供 `.plugin(name: "SwiftProtobufPlugin")`；该版本 `swift-tools-version:6.2`，要求 Swift 6.2 工具链（Xcode 26） |
| zstd | `facebook/zstd`（最新 v1.5.7）以 SwiftPM 依赖引入 `libzstd` 产品，自写薄封装（`ZSTD_DCtx` 流式解压） | 官方仓库根目录自带 `Package.swift`，产品 `libzstd`，target 源于 `lib/` |
| ldiff 打补丁 | `sisong/HDiffPatch`（MIT），把 `libHDiffPatch/HPatch` 和需要的解压插件编成 SwiftPM C target，调用 `patch_decompress_with_cache` 等 API；zstd 插件复用上面的 libzstd，lzma 需另带 LZMA SDK 源码 | 官方 README 列出 `patch_decompress()`、`patch_decompress_with_cache()`、`patch_decompress_mem()`；地图已定「C 库可作为 SwiftPM C target 链接」 |
| MD5 | CryptoKit `Insecure.MD5`（系统框架，无依赖） | — |
| xxhash（可选） | `Cyan4973/xxHash`（v0.8.4）单头文件，作为 C target；仅当决定校验 chunk 的 `xxhash` 字段时需要 | — |
| HTTP | `URLSession`（`bytes(for:)` / download task，`Range` 头） | 替代 pycurl |

### 并发设计要点

- 一个 `SophonInstaller`（或按操作拆）actor 持有状态，下载用 `TaskGroup` 并发，并发度有上限（Python 为 8）；校验并发度按核数（Python 为 `max(2, 物理核 - 4)`）。
- chunk 去重与临时文件管理要集中到一个 actor 里，解决 §8 #2/#3。
- 解压、MD5、HDiffPatch 都是阻塞 CPU/IO 的同步 C 调用，放在非主 actor 的 nonisolated 函数里；HDiffPatch 一次 patch 可能几十秒（Python 给了 300 s 超时），需要能在文件边界响应取消（C 调用本身无法中断）。
- 进度用 `AsyncStream`，在生产端节流（≥ 1 s）；速度用滑动窗口。`@Observable` 的 UI 模型在 `@MainActor` 上消费。
- Swift 6 strict concurrency：生成的 protobuf 消息是值类型且 `Sendable`；C 指针（`ZSTD_DCtx*`、HDiffPatch 流结构）不可跨任务，封装成每任务一个。
- 文件写入：用 `FileHandle` 按 offset 写；完成后用原子 `rename`（同卷）移入游戏目录，避免半成品。

### 主要难点

1. **CN 增量更新主机名与参数未知**（最大风险）：没有它就无法实现 CN 的更新/预下载，而这是「与 TS 版功能对等」之外的新能力——TS 版本身也做不到。
2. HDiffPatch 的 C 集成：插件选择、编译宏、内存/缓存参数、尾随数据限制（必须精确切片），以及大文件下的内存占用。
3. 断点续传语义：chunk 级缓存 + 文件级重组 + 原子替换，要在崩溃、断网、磁盘满下都安全。
4. 版本检测要与 TS/Python 一致（`globalgamemanagers` 正则 + `config.ini` 取较小值），否则老用户升级后会被误判。
5. 一致性测试：需要录制的真实 getBuild/getPatchBuild 响应与 manifest 作夹具，不能在测试里打米哈游服务器。

### 新的决策问题（地图上没有）

1. CN 的 getBuild/getPatchBuild 更新主机是什么，Swift 版是否要提供 TS 版没有的 CN 增量更新与预下载？若不提供，CN 用户更新只能整包重装或靠修复补齐。
2. 是否在 Swift 版放弃 3.6.0 音频目录迁移（`program-update-game.ts:92-136`）。
3. 是否校验 chunk 级 `md5`/`xxhash`（影响是否引入 xxHash）。
4. `.tmp`、`ldiff` 是否继续放在游戏目录内（沿用可兼容 TS 版遗留的半成品；换位置更干净）。
