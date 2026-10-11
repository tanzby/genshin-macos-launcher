# 原生启动器 1.0.0 复盘

## 范围与证据

本复盘涵盖 Claude Code 主会话“原生启动器 1.0.0”及其派发的 27 个 session，不含截图中相邻的“云端启动器功能完善”。主会话 desktop ID 为 `local_2a7eaab5-536c-40d5-9108-d65c8427a22c`，CLI transcript ID 为 `0dd47538-8f29-4bb2-afaf-1ae4be52e891`，时间为 `2026-10-08T17:34:22Z` 至 `2026-10-11T16:02:45Z`。本机 transcript 位于 `~/.claude/projects/-Users-zubingtan-Projects-genshin-macos-launcher/`；只记录可核对的 session ID 和事件位置，不复制原始日志。

主会话记录了 27 个唯一派发 session、37 次启动/恢复调用和 3 个 sidechain。通过 Claude session metadata 中 `spawnedFrom.sessionId` 等于主 desktop ID 识别直接派发项，再以各自的 `cliSessionId` 对应 transcript 文件名；本次检查共覆盖 31 份 JSONL（主会话、27 个派发 session、3 个 sidechain），23,550 条记录。21 个派发 session 有完成 turn；最后的 #87、#75、#76、#74、#73、#85 因主 session 达到用量上限而被截断，没有完成 turn。它们的实现结果不在本复盘的结论范围内。

## 发现与决定

1. **合并门槛曾失守。** 早期 PR #16 合并后仍有一条 Codex P1：Sparkle updater 从未启动（主 transcript 第 108、128 行，`885a3662-90e8-4528-8998-e3eebd163133`、`42dbd6f8-30a4-4c61-ad68-2aaaec0af360`）；后续 PR #18 启动条件改为正式构建且公钥存在，第 531、734 行记录本地 gate 通过并合并（`29ffec19-2247-41b3-9b5a-2d08b3441d64`、`dad5f906-22fa-4378-bb29-9a877bbeb639`）。PR #31 合并时还有两条 P2：启动前取消绕过进程 SIGKILL 兜底，以及 Wine shim 先移动再复制有丢失入口的风险（第 800、804 行，`f9d173a0-589e-4336-9648-27c2132fca23`、`a90f7cf3-a249-49c1-afc7-6df8fb126c95`）；后续 PR #32 修复并回复评论，第 940、950 行（`422c3199-4e26-4d95-908b-5bb305d22541`）。但到 2026-10-11，PR #43 又在两条 Codex P2 未处理时合并（第 1840 行，`62981490-a137-480d-a0c4-2a970ceb1b12`），说明门槛需要依赖显式检查。PR #40 和 #60 的会话也再次要求 merge 前实际运行 `/simplify`、`/code-review` 并确认 CI（第 1941、2218 行，`51f7b61f-e006-4566-83bf-310dc5a13b31`、`ba2f6af2-393a-482e-90a9-5bae7d11bfa8`）。当前流程已写入 [`development-workflow.md`](development-workflow.md)。

2. **等待缺少边界。** 2026-10-09，PR #26 的会话被提醒保持活动并每 30 分钟检查 CI/review（第 412、443 行，`e47402f1-e6d6-40a9-8e37-645a3f22b326`、`9b5799b0-9618-4219-b66f-a5040e8eef31`）。2026-10-10，一条命令十几个小时没有进展，维护者中断后才从断点恢复（第 1313 行，`d8765059-a099-4cfc-ba5b-c60b4b125ec4`）。流程现要求等待不超过 30 分钟后重查、长命令保留任务专属临时日志，并在无进展时检查一次后安全恢复或报告阻塞。

3. **review 规则出现版本差异。** 主会话后段及本机 Claude 项目 memory 记录：每次 push 前运行 `/simplify` 和 namespaced code-review skill；Codex bot 自行评论时按真实 bug 处理，但不等待它作为 gate。会话中 #43 的问题是两条 P2 未处理便 merge（第 1840 行；`62981490-a137-480d-a0c4-2a970ceb1b12`），随后维护者更新了审查规则（第 1984–2002 行；`29aadfea-2909-4498-864a-3949735130b0`）。当前仓库随本任务提供的 AGENTS 指令仍要求 `/code-review`、处理 bot 评论并重复 `@codex review`；本次按该明确的仓库指令保留，未改成相反规则。两处来源应由维护者统一。会话后段还把 Sparkle 验证从连续推 RC 调整为先在 PR 中用 `scripts/dev/sparkle-local-check` 验证、稳定后再打 tag（第 2850–2941 行；`937be202-b7b0-4b0d-8740-b7b57160b749`）。[`docs/release.md`](../release.md) 已记录最终做法，无需再复制一份规则。

4. **已有检查应复用。** #87 的派发 session 被用量上限截断，不能据此判断其实现结果。仓库已有 `scripts/dev/macos-check` 对 `Package.resolved` 做前后 hash 比较，并由 CI 与 lefthook pre-push 共用；因此保留该机制和 `Package.swift` 的依赖边界，不另加重复检查。

5. **命令等待需要可移植边界。** 主会话和派发日志中至少有 6 个 transcript 出现 `timeout: command not found`，例如主 transcript 第 1818 行（`2026-10-11T02:59:19Z`，`1d4bc970-28fa-4f1c-b0ca-bd5ac288d833`）和 #12 第 31 行（`2026-10-10T16:12:58Z`，`604d5b7c-2a2a-4da2-86b1-5327e73cc4ac`）。这说明当时 shell 没有 GNU `timeout`，不代表业务命令失败。新增 `scripts/dev/run-with-timeout`，用 Python 标准库给本机命令及其子进程组设截止时间；工作流指向该入口。

6. **根指引需要分层。** 原根 `AGENTS.md` 将项目介绍、分支/PR 流程、构建细节、Swift 约束、测试、UI 和领域导航混在一起。现将流程放到 `docs/agents/development-workflow.md`，把目录专属约束放到最近的 `AGENTS.md`，根文件只保留全局规则和条件导航。

## 本次 harness 改动

- 为每个 Git 跟踪的子目录添加 `AGENTS.md`，并添加单行 `CLAUDE.md`（`@AGENTS.md`），让 Claude Code 在读取该子目录时加载相同的局部规则。DXMT 子模块内容不纳入覆盖范围。
- 新增 `scripts/dev/check-agent-instructions`，并接入 `scripts/dev/macos-check`。它以 `git ls-files` 的目录前缀为范围，要求每个受跟踪子目录有非空 `AGENTS.md` 和直接导入它的 `CLAUDE.md`；现有 CI 与 pre-push 因而自动覆盖此规则。
- 新增 `scripts/dev/test-agent-instructions`，用临时 Git 仓库验证缺少嵌套指南时失败、补齐后通过。
- 完整 gate 首次发现 XcodeGen 会把 `App/` 和 Proton 资源目录内的本地指南当作 app 资源，导致多个资源输出冲突；SwiftPM 也把 Swift target/test target 中的指南报告为未处理文件。`project.yml` 与 `Package.swift` 现分别排除这些指引文件，避免打进 app 或 test fixtures。这是本次修改验证时发现的打包耦合，不是原会话结论。
- 新增 `scripts/dev/run-with-timeout` 和 `scripts/dev/test-run-with-timeout`，在 macOS 没有 GNU `timeout` 时使用 Python 标准库做有界等待，并验证 leader 退出时仍会终止忽略 `SIGTERM` 的 child。
- 没有根据“27 个派发 session”这一数量单独添加并行策略；证据不足以判断派发次数本身导致了延误。六个 quota-cut session 只记为未完成，不推断其代码质量或任务结论。
