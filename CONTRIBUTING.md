# Contributing

## Requirements

- Apple Silicon Mac, macOS 26 or later
- Xcode 26 or later
- Homebrew

## Setup

```bash
git clone --recurse-submodules https://github.com/tanzby/genshin-macos-launcher.git
brew install xcodegen lefthook meson cmake ninja mingw-w64
lefthook install
scripts/build-dxmt
```

- `lefthook install` runs `scripts/dev/macos-check` before every push, the same check as CI.
- `scripts/build-dxmt` builds DXMT into `build/dxmt`. The first run also builds LLVM (a few minutes). Without DXMT the app builds but cannot set up Wine. After the first DXMT build, delete the built `Yaagl.app` once so Xcode signs it with DXMT inside.

## Build and test

```bash
scripts/dev/macos-check
```

It runs the repo checks and `swift test`, generates `Yaagl.xcodeproj` with XcodeGen and builds the app into `build/DerivedData`. For the library targets alone, `swift test` is enough. Open the generated `Yaagl.xcodeproj` in Xcode to run the app.

Code rules: `CODING_STANDARDS.md`. Architecture: `docs/adr/`. Glossary: `CONTEXT.md`.

## Pull requests

- One change per PR, branched from `main`. PRs are squash-merged once the `swift` check is green.
- Workflow, YAML and `project.yml` changes are reviewed like code.
- Releases: `docs/release.md`.

## Optional agent tooling

The repo works with any coding agent: `AGENTS.md` is the entry point (`CLAUDE.md` imports it).

- **Claude Code**: `.claude/settings.json` registers the [mattpocock/skills](https://github.com/mattpocock/skills) marketplace and enables its `mattpocock-skills` plugin. `docs/agents/` is that plugin's configuration for this repo (issue tracker, labels, domain docs).
- **Apple's SwiftUI guidance**: Xcode ships it for its own coding assistant. `scripts/dev/install-xcode-skills [dir]` copies it from your Xcode into a local skill (default `~/.claude/skills/swiftui-specialist`). It is Apple's text, so it is never committed.
