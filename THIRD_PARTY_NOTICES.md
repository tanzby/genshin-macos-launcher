# Third-party notices

This project builds on, bundles or links the following. Notices are added as each dependency lands.

| Component | Use | License |
|---|---|---|
| [Yet Another Anime Game Launcher](https://github.com/yaagl/yet-another-anime-game-launcher) (3Shain) | Origin of `Helpers/` C sources and of the launcher behaviour this app reimplements | MIT |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | Self-update | MIT |
| [swift-protobuf](https://github.com/apple/swift-protobuf) | Sophon manifest parsing | Apache-2.0 |
| protonextras (`Resources/protonextras/`) | Four Windows files copied into the Wine prefix for the Steam patch; see below | Proton: BSD-3-Clause; Wine-derived parts: LGPL-2.1-or-later |
| Wine (CrossOver 11.0-1 build, yaagl/anime-game-wine) | Downloaded at install time into the data directory, not bundled | LGPL-2.1-or-later (CrossOver sources: see upstream) |
| [DXMT](https://github.com/3Shain/dxmt) (build 654f547 from yaagl/anime-game-wine) | Downloaded at install time and copied into the Wine runtime, not bundled | See upstream repository |

## protonextras

`Resources/protonextras/` holds four files, taken unchanged from the TS launcher's `sidecar/protonextras/`
(the files originate from Dawn Winery's dwproton, a Proton fork; mirror: <https://dawn.wine/dawn-winery/dwproton>,
<https://github.com/dawn-winery/dwproton-mirror>):

| File | Role | SHA-256 |
|---|---|---|
| `steam32.exe` | Proton `steam_helper` (32-bit) | `d3b17fda25217165f5f5198ac179bb0645d4fcc61381bfeb0ba3c73ea029a433` |
| `steam64.exe` | Proton `steam_helper` (64-bit) | `0424339444c54bf1f9fdbadf12e4e2c90ceef41d987fe573b93f5f2ebfd8a657` |
| `lsteamclient32.dll` | Proton `lsteamclient` (32-bit) | `608eece6672369db539211fd04eb95b9fb5ddd077e76aa87c28c04c25c1e2fe2` |
| `lsteamclient64.dll` | Proton `lsteamclient` (64-bit) | `af50ed0d952ef98d99d4d3ff67b4836b545c9403894430fca31969f9f630637b` |

They are Windows PE binaries that only run inside Wine; the launcher copies them into the prefix and never executes them itself.

Licensing: Proton's top-level licence is the BSD 3-clause "LICENSE.proton" (Copyright (c) Valve Corporation); the
binaries also contain code derived from Wine (LGPL-2.1-or-later), whose corresponding source is available from the
upstream projects above. The exact dwproton release these binaries were built from is not recorded in the old
repository, so the version and the per-component licence texts still need to be confirmed against it before 1.0.0
(tracked as a follow-up on the map).
