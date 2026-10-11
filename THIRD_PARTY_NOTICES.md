# Third-party notices

This project builds on, bundles or links the following. Notices are added as each dependency lands.

| Component | Use | License |
|---|---|---|
| [Yet Another Anime Game Launcher](https://github.com/yaagl/yet-another-anime-game-launcher) (3Shain) | Origin of `Helpers/` C sources and of the launcher behaviour this app reimplements | MIT |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | Self-update | MIT |
| [swift-protobuf](https://github.com/apple/swift-protobuf) | Sophon manifest parsing | Apache-2.0 |
| [zstd](https://github.com/facebook/zstd) v1.5.7 (`Sources/CZstd`, decompressor only) | Decompressing Sophon manifests and chunks | BSD-3-Clause (dual BSD/GPLv2; used under BSD) |
| [HDiffPatch](https://github.com/sisong/HDiffPatch) v4.5.2 (`Sources/CHDiffPatch/hpatch`, patcher only, commit f62556a) | Applying Sophon ldiff patches | MIT |
| protonextras (`Resources/protonextras/`) | Four Windows files copied into the Wine prefix for the Steam patch; see below | steam_helper: BSD-3-Clause (Valve); lsteamclient: Steamworks SDK licence, redistribution open; Wine-derived parts: LGPL-2.1-or-later |
| Wine (CrossOver 11.0-1 build, yaagl/anime-game-wine) | Downloaded at install time into the data directory, not bundled | LGPL-2.1-or-later (CrossOver sources: see upstream) |
| [DXMT](https://github.com/3Shain/dxmt) (submodule `third_party/dxmt`, commit `e94c312f5c054263acf261cfa109edf13e757587`) | Built from source in CI (`scripts/build-dxmt`), shipped in `Yaagl.app/Contents/Resources/dxmt` and copied into the Wine runtime; see below | LGPL-2.1-or-later |
| [LLVM](https://github.com/llvm/llvm-project) 15.0.7 | Statically linked into DXMT's `winemetal.so` (shader converter) | Apache-2.0 WITH LLVM-exception |
| App icon artwork (`App/Assets.xcassets/AppIcon.appiconset`, Paimon from the Genshin Impact HoYoLAB icon) | App icon, masked by `scripts/dev/make-app-icon` | © HoYoverse; not licensed to this project, used as fan art |

## protonextras

`Resources/protonextras/` holds four Windows PE files that the launcher copies into the Wine prefix for the Steam
patch (`steam.exe` and `lsteamclient.dll`, 64-bit into `system32`, 32-bit into `syswow64`). It never executes them
itself. Licence texts sit next to them (`LICENSE.proton`, `LICENSE.lsteamclient`) and ship inside the app bundle.

**Origin.** The unsigned binaries are byte-identical to the ones in
[GE-Proton10-10](https://github.com/GloriousEggroll/proton-ge-custom/releases/tag/GE-Proton10-10) (GloriousEggroll's
build of Valve's Proton, released 2025-07-19; archive `GE-Proton10-10.tar.gz`, SHA-512
`afc056dc569e4ddca0eaf46e20f6af4f5a573f50ca723fc667f55ce963801b5962e355c1a0edeebfe6b5ee7288a14aae59fac9aef15b2efdccae1af4e2301fa6`;
files under `files/lib/wine/{i386,x86_64}-windows/`). They reached the TS launcher in 2025-08 via yaagl/yet-another-anime-game-launcher
(commit 61814bf7), and in 2026-01 (commit 347fbd2c, "make steam stub files signed") they were replaced by the same
files carrying an Authenticode signature from "Dawn Winery Code Signing Certificate" (Dawn Winery CA1). The signature
adds an 11360-byte certificate table and changes seven bytes in the PE header (apparently the checksum and the certificate directory entry);
nothing else differs. The files here are those signed ones, so no dwproton release contains them (the first dwproton
release, 10.0-1, is from 2025-10-18, and its `steam.exe`/`lsteamclient.dll` differ). Hashes below are for the files in this repo;
the unsigned originals are listed for matching against GE-Proton10-10.

| File | Role | SHA-256 (shipped, signed) | SHA-256 (unsigned, = GE-Proton10-10) |
|---|---|---|---|
| `steam32.exe` | Proton `steam_helper` (32-bit) | `d3b17fda25217165f5f5198ac179bb0645d4fcc61381bfeb0ba3c73ea029a433` | `e3aae0996c4f7162486ccdb37710a58ac0f41f907e25dd84859d9165e1d5b965` |
| `steam64.exe` | Proton `steam_helper` (64-bit) | `0424339444c54bf1f9fdbadf12e4e2c90ceef41d987fe573b93f5f2ebfd8a657` | `4f92982f0f9afc67baed01ef0e1662e9e7204a3f74715557dc096ab7a07042fa` |
| `lsteamclient32.dll` | Proton `lsteamclient` (32-bit) | `608eece6672369db539211fd04eb95b9fb5ddd077e76aa87c28c04c25c1e2fe2` | `8801c0bbc4ff490881b5f89dd39238eac8a059590429cc2e379a638eb9ca2e2d` |
| `lsteamclient64.dll` | Proton `lsteamclient` (64-bit) | `af50ed0d952ef98d99d4d3ff67b4836b545c9403894430fca31969f9f630637b` | `94309157fb6d9a80988e1e9fa3ced1aa3e390090bc80592cb736d3f574fb0ec0` |

**Licences** (verified against the GE-Proton10-10 source tree, <https://github.com/GloriousEggroll/proton-ge-custom/tree/GE-Proton10-10>):

- `steam_helper/` (`steam.exe`): the BSD 3-clause licence of Valve's Proton, Copyright (c) 2015-2022 Valve Corporation
  (the top-level `LICENSE.proton`, copied to `Resources/protonextras/LICENSE.proton`). The source directory also holds
  a bundled `jsoncpp.cpp` (MIT / public domain); whether it ends up in the 64/32-bit binaries was not checked.
- `lsteamclient/` (`lsteamclient.dll`): the directory's own `LICENSE` is the **Steamworks SDK licence** (Valve, "SDK
  LICENSE"), copied to `Resources/protonextras/LICENSE.lsteamclient`. The code is built against Wine headers
  (LGPL-2.1-or-later, "Wine builtin DLL") and the Steamworks interface headers. That licence grants redistribution only
  of the SDK's `redistributable_bin` folder, so whether these DLLs may be shipped in this app is **not settled**; see the
  open question on #28. Both "BSD-3-Clause" for lsteamclient in the previous version of this file and in
  `App/Credits.swift` were therefore too generous.
- Corresponding source for the Wine-derived parts: the GE-Proton10-10 tree linked above (Wine and Proton submodules).

## DXMT

DXMT (Direct3D 10/11 on Metal, by Feifan He for CodeWeavers and contributors) is built from the pinned
`third_party/dxmt` submodule, <https://github.com/3Shain/dxmt/tree/e94c312f5c054263acf261cfa109edf13e757587>,
which is also its complete corresponding source. The build recipe is `scripts/build-dxmt`; the exact toolchain
(LLVM 15.0.7, Wine v8.16-3shain headers, mingw-w64, meson 1.10.0, Xcode 16.1) is in
`.github/workflows/dxmt.yaml`. The binaries are `d3d10core.dll`, `d3d11.dll`, `dxgi.dll`, `winemetal.dll` and
`winemetal.so`.

- DXMT is licensed under the GNU Lesser General Public License version 2.1 or (at your option) any later version.
  The text ships next to the binaries as `Resources/dxmt/COPYING.LIB`. The launcher copies the DLLs into the Wine
  runtime; replacing them with a build of your own from the linked source is possible by building
  `third_party/dxmt` and putting the result in `Contents/Resources/dxmt`.
- `winemetal.so` statically links LLVM 15.0.7 (Apache License 2.0 with LLVM Exceptions). The text ships as
  `Resources/dxmt/LICENSE.LLVM`.
