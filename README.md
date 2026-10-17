# Genshin macOS Launcher

A native macOS (SwiftUI) launcher for Genshin Impact (CN server) on Apple Silicon. It installs, updates, pre-downloads and repairs the game, then runs it through Wine with DXMT.

> **Unofficial.** This project is not affiliated with, endorsed by, or connected to miHoYo / HoYoverse / COGNOSPHERE. "Genshin Impact" is their trademark.

Planning happens in this repo's GitHub issues; decisions are in `docs/adr/` and `docs/research/`.

## Requirements

- Apple Silicon Mac, macOS 26 or later

## 下载安装

从 [Releases](https://github.com/tanzby/genshin-macos-launcher/releases/latest) 下载 `GenshinLauncher-<版本>.dmg`。App 没有 Apple 开发者签名和公证，第一次打开会被 macOS 拦下，需要放行一次，步骤见 [安装说明](scripts/release/dmg-install.txt)（DMG 里的「安装说明.txt」和每个 release 的说明是同一份）。

## Build

See `CONTRIBUTING.md` for setup, building and testing.

## History

This app replaces the TypeScript/NeutralinoJS fork [tanzby/yet-another-anime-game-launcher](https://github.com/tanzby/yet-another-anime-game-launcher) of Yet Another Anime Game Launcher by 3Shain (credits in `THIRD_PARTY_NOTICES.md`). It does not read that launcher's data (ADR 0001).

## License

MIT. See `LICENSE` and `THIRD_PARTY_NOTICES.md`.
