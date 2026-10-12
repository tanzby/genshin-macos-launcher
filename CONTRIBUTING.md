# Contributing

Commands, architecture and conventions, including how PRs land, are in `AGENTS.md`. It is written for people and coding agents alike.

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
scripts/dev/macos-check
```

- `lefthook install` runs `scripts/dev/macos-check` before every push, the same check as CI.
- The first `scripts/build-dxmt` also builds LLVM (a few minutes). After it, delete the built `Yaagl.app` once so Xcode signs it with DXMT inside.
- `scripts/dev/macos-check` runs the tests, generates `Yaagl.xcodeproj` and builds the app. Open the project in Xcode to run it.

## Pull requests

- One change per PR, branched from `main`.
- Workflow, YAML and `project.yml` changes are reviewed like code.
- Releases: `docs/release.md`.

## Agent tooling

- **Claude Code**: `.claude/settings.json` registers the [mattpocock/skills](https://github.com/mattpocock/skills) marketplace and enables its `mattpocock-skills` plugin. `docs/agents/` is that plugin's configuration for this repo.
- **Apple's SwiftUI guidance**: Xcode ships it for its own coding assistant. `scripts/dev/install-xcode-skills [dir]` copies it from your Xcode into a local skill (default `~/.claude/skills/swiftui-specialist`).
