# Genshin macOS Launcher

A native macOS (SwiftUI) launcher for Genshin Impact (CN server) on Apple Silicon. It installs, updates, pre-downloads and repairs the game, then runs it through Wine with DXMT.

> **Unofficial.** This project is not affiliated with, endorsed by, or connected to miHoYo / HoYoverse / COGNOSPHERE. "Genshin Impact" is their trademark.

Status: early development. Planning and decisions are tracked on the wayfinder map in this repo's issues; see `docs/adr/` and `docs/research/`.

## Requirements

- macOS 26 or later, Apple Silicon
- Xcode 26+, `brew install xcodegen`

## Build

```bash
scripts/dev/macos-check
```

This runs `swift test`, generates `Yaagl.xcodeproj` with XcodeGen and builds the app with `xcodebuild`.

## History

This app replaces the TypeScript/NeutralinoJS fork [tanzby/yet-another-anime-game-launcher](https://github.com/tanzby/yet-another-anime-game-launcher) of [Yet Another Anime Game Launcher](https://github.com/yaagl/yet-another-anime-game-launcher) by 3Shain. It does not read that launcher's data (ADR 0001).

## License

MIT. See `LICENSE` and `THIRD_PARTY_NOTICES.md`.
