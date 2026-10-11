# Project understanding

Yaagl is a native Swift 6 and SwiftUI launcher for Genshin Impact's CN server. It runs the Windows game through modified Wine and DXMT on Apple Silicon, with macOS 26 as the minimum supported platform. The archived TypeScript launcher remains the source of historical parity references.

## Architecture

- `App/` is the SwiftUI composition root. Library behavior is split across the one-way Swift package modules in `Sources/`; `Package.swift` describes those modules, while `project.yml` describes the app and helper targets.
- Wine, the x86_64 helper executables, and the existing `codesign`, `tar`, and `ditto` tools are the only external processes launched by the app.
- The data-directory policy and native module boundaries are recorded in [ADR 0001](docs/adr/0001-native-app-fresh-start.md) and [ADR 0002](docs/adr/0002-native-architecture.md). DXMT's source, bundle, and Wine-install lifecycle are described in [ADR 0003](docs/adr/0003-dxmt-built-from-source-and-bundled.md).
- `CONTEXT.md` defines project vocabulary. [`docs/genshin-macos.md`](docs/genshin-macos.md) describes the game-session lifecycle and runtime integration. [`docs/parity/`](docs/parity/) and [`docs/research/`](docs/research/) preserve links to the archived launcher and evidence behind native behavior.

The session evidence and decisions behind the 1.0.0 project memory are recorded in [the retrospective](docs/agents/retrospective-native-launcher-1.0.0.md).
