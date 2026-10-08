# Yaagl

Yaagl 是 macOS 上的原神启动器。原生版（本仓库）让用户安装、更新、预下载、修复游戏，并在 Wine 中启动它。

## Language

**Game Directory**:
用户选择的游戏安装目录，位于数据目录之外，可以在外置盘上。
_Avoid_: 安装路径、gamedir

**Data Directory**:
`~/Library/Application Support/Yaagl`，存放 Wine、prefix、DXMT、日志和原生状态文件。
_Avoid_: 应用目录、support 目录

**Native Marker**:
数据目录里 `.yaagl-native` 文件，表示这个目录属于原生版。没有这个文件就触发首启清场。
_Avoid_: 版本文件

**Job**:
一次可暂停、可继续的长任务：游戏的安装、更新、预下载、修复，或 Wine 准备。同一时刻只有一个独占作业。
_Avoid_: 任务、task（task 留给 Swift 并发）

**Pending Job**:
被暂停或被中断、还没完成的游戏作业，记录种类和目标版本，存在游戏目录的 `.yaagl-tmp/job.json`。Wine 准备不记 Pending Job，由 Wine 目录的版本戳推导。重启后主按钮显示「继续」。
_Avoid_: 断点

**ldiff**:
Sophon 的增量更新文件，一个文件里拼接多个 HDiffPatch 补丁，把旧版本文件改成新版本。
_Avoid_: patch、差分包

**Pre-download**:
在正式更新发布前，提前下载新版本所需的 ldiff 和新增文件的 chunk，只写临时目录，不改游戏文件。
_Avoid_: 预更新

**Launch Mutations**:
启动前对游戏文件、Wine 运行时和 prefix 的改动，退出后还原。
_Avoid_: patch、补丁

**Mutations Journal**:
记录 Launch Mutations 所需还原项（文件改名、注册表原值）的小文件，改动前写入，还原后删除；崩溃后据此恢复。
_Avoid_: patched 标记

**Hosts Blocklist**:
`/etc/hosts` 里 `# Added by Yaagl` 到 `# End of section` 的一段，把遥测域名指向 0.0.0.0。缺失或过期时禁止启动游戏。
_Avoid_: 屏蔽网络、block_net

**对等清单**:
`docs/parity/hk4e-cn.md`：旧 TS 版 180 条规则（规则 ID + 基线 commit `f38cda4`）逐条的处置（照搬、改写、作废）、依据、验收层和对应测试。「功能全部对等」的验收依据，也是 1.0.0 发布门槛的一部分。
_Avoid_: 规则卡（`docs/research/hk4e-rules.md` 是只读研究来源）、功能列表

**Game Mode**:
让系统把游戏进程识别为游戏并启用原生全屏（含刘海区域）的机制，由注入 Wine 的 x86_64 shim 与 dylib 实现。
_Avoid_: 原生全屏（只是它的效果之一）
