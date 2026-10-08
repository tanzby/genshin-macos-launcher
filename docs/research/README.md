# 迁移研究

这些文档是从旧 TS 版启动器（[tanzby/yet-another-anime-game-launcher](https://github.com/tanzby/yet-another-anime-game-launcher)，提交 `f38cda4` 前后）迁到原生版之前做的研究，是原生版设计与验收的依据。

- 文中的 `file:line` 引用、`src/…`、`sophon_server/…`、`native/gamehost/…` 都指**旧仓库**。
- 文中的 `#NN` 票号指旧仓库的 wayfinder 地图 [#13](https://github.com/tanzby/yet-another-anime-game-launcher/issues/13)。
- 研究中的“待定”和“建议”已经由后续决定收口，以本仓库地图的 Decisions so far 和 `docs/adr/` 为准，例如 bundle id 已改为 `io.github.tanzby.yaagl`，数据不再兼容旧版。

| 文档 | 内容 |
|---|---|
| [hk4e-inventory.md](hk4e-inventory.md) | 原神 CN 路径的模块、调用图、外部进程盘点 |
| [hk4e-rules.md](hk4e-rules.md) | 180 条 Given/When/Then 业务规则 |
| [sophon-spec.md](sophon-spec.md) | Sophon 协议规格与 Swift 实现依赖 |
| [sidecar-replacement.md](sidecar-replacement.md) | sidecar 工具逐个替换方案 |
| [data-contract.md](data-contract.md) | 数据目录与设置存储 |
| [sparkle.md](sparkle.md) | Sparkle 2 在未签名 App 上的集成 |
| [wine-launch-contract.md](wine-launch-contract.md) | Wine/DXMT 启动契约 |
