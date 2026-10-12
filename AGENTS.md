# AGENTS.md

A native macOS launcher for Genshin Impact (CN server), written in Swift 6 and SwiftUI. It runs the Windows game through a modified Wine with DXMT. Apple Silicon only, macOS 26+. Repo: `tanzby/genshin-macos-launcher`. It replaces the TS launcher `tanzby/yet-another-anime-game-launcher`, which is now archived and still holds the research tickets.

## Workflow: one worktree per change

- Keep the main checkout on a clean `main`. Make each change in its own worktree under `.claude/worktrees/<name>` (gitignored), branched from `origin/main`.
- `main` is protected: changes land by PR, squash-merged, with the `swift` check green.
- Never use bare `git stash`; the stash stack is shared by all worktrees. Use a WIP commit instead.
- Only one worktree may run the game at a time. All worktrees share the installed app, `~/Library/Application Support/Yaagl` and the game files.

```bash
git fetch origin && git worktree add .claude/worktrees/<name> -b <branch> origin/main
```

## Commands

- `scripts/dev/macos-check` runs the repo checks, `swift test`, then `xcodegen generate` and `xcodebuild`. It is the CI `swift` job and the lefthook pre-push hook (`brew install xcodegen lefthook && lefthook install`).
- `swift test` on its own for the library targets.
- Every third-party package is declared in `Package.swift`, never in `project.yml` (Sparkle comes in through the `Updates` target), so SwiftPM and Xcode resolve the same graph and `Package.resolved` stays put (#87).
- `Helpers/build.sh [--dev]` builds the x86_64 helpers by hand; normally XcodeGen builds them.
- `scripts/build-dxmt` builds DXMT (submodule `third_party/dxmt`) into `build/dxmt`, which XcodeGen puts into the app (ADR 0003). Needs `brew install meson cmake ninja mingw-w64`; the first run builds LLVM (about 2 min locally). CI: `.github/workflows/dxmt.yaml`. Without it the app builds but cannot install Wine. After the first run delete the built `Yaagl.app` once, so Xcode signs it with DXMT inside.

## Architecture

- Module layout and boundaries: `docs/adr/0002-native-architecture.md`. Data-dir policy: `docs/adr/0001-native-app-fresh-start.md`. Glossary: `CONTEXT.md`.
- `Package.swift` holds the library targets (Sophon, Platform, Wine, GenshinCN, Launcher) with one-way dependencies. `project.yml` (XcodeGen) defines the arm64 App and the x86_64 helpers in `Helpers/`. The generated `.xcodeproj` is not committed.
- Only Wine, the x86_64 helpers and the system tools `codesign`, `tar` and `ditto` may run as external processes. Everything else is Swift or a linked C target.
- Research behind these decisions is in `docs/research/`. Its `file:line` references point at the old TS repo.
- Judgement-call rules for Swift, tests and UI strings: `CODING_STANDARDS.md`. The mechanical rule from #48 is enforced by `scripts/dev/check-async-closure-default`, part of `macos-check`.

## Verification

Verify game behaviour with deterministic, time-boxed text output, not screenshots, and always close the game afterwards. The Game Mode and full-screen mechanism is described in `docs/genshin-macos.md`.

## Agent skills

### Issue tracker

Issues live in this repo's GitHub Issues (`gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

The five default labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one root `CONTEXT.md` and `docs/adr/`. See `docs/agents/domain.md`.
