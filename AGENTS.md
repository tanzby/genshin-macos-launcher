# AGENTS.md

A native macOS launcher for Genshin Impact (CN server), written in Swift 6 and SwiftUI. It runs the Windows game through a modified Wine with DXMT. It replaces the TS launcher `tanzby/yet-another-anime-game-launcher`, which is now archived and still holds the research tickets.

Setup and requirements: `CONTRIBUTING.md`.

## Commands

- `scripts/dev/macos-check` runs the repo checks, `swift test`, then `xcodegen generate` and `xcodebuild`. It is the CI `swift` job and the pre-push hook.
- `swift test` on its own for the library targets.
- `scripts/build-dxmt` builds DXMT (submodule `third_party/dxmt`) into `build/dxmt`, which XcodeGen puts into the app (ADR 0003). Without it the app builds but cannot install Wine.
- `Helpers/build.sh [--dev]` builds the x86_64 helpers by hand; normally XcodeGen builds them.

## Architecture

- Module layout and boundaries: `docs/adr/0002-native-architecture.md`. Data-dir policy: `docs/adr/0001-native-app-fresh-start.md`. Glossary: `CONTEXT.md`.
- `Package.swift` holds the library targets (Sophon, Platform, Wine, GenshinCN, Launcher) with one-way dependencies. `project.yml` (XcodeGen) defines the arm64 App and the x86_64 helpers in `Helpers/`. The generated `.xcodeproj` is not committed.
- Every third-party package is declared in `Package.swift`, never in `project.yml` (Sparkle comes in through the `Updates` target), so SwiftPM and Xcode resolve the same graph and `Package.resolved` stays put (#87).
- Only Wine, the x86_64 helpers and the system tools `codesign`, `tar` and `ditto` may run as external processes. Everything else is Swift or a linked C target.
- Research behind these decisions is in `docs/research/`. Its `file:line` references point at the old TS repo.

## Conventions

- Judgement-call rules for Swift, tests and UI strings: `CODING_STANDARDS.md`. The mechanical rule from #48 is enforced by `scripts/dev/check-async-closure-default`, part of `macos-check`.
- `main` is protected: changes land by PR, squash-merged, with the `swift` check green.
- Issues live in GitHub Issues (`gh`). Label meanings: `docs/agents/triage-labels.md`.
- Never use bare `git stash`: the stash is shared by all worktrees. Use a WIP commit.
- Only one checkout may run the game at a time. All share the installed app, `~/Library/Application Support/Yaagl` and the game files.

## Verification

Verify game behaviour with deterministic, time-boxed text output, not screenshots, and always close the game afterwards. Diagnostics tool, Game Mode and full-screen: `docs/genshin-macos.md`.
