> **说明**：本文描述的是旧 TS 版（[tanzby/yet-another-anime-game-launcher](https://github.com/tanzby/yet-another-anime-game-launcher)）中 Game Mode 与全屏的设计和实现。文中的 `src/…`、`yaagl-diag` 指旧仓库；`Helpers/` 下的 C 源码已迁入本仓库。原生版沿用相同的机制。

# Genshin on macOS: Game Mode and process cleanup

## Game Mode

macOS enables Game Mode only when **both** hold for the front process, as decided by `gamepolicyd`:

- `isIdentifiedGame`: LaunchServices maps the process to a **registered app bundle** with `LSApplicationCategoryType = public.app-category.games`. An unbundled binary's embedded `__info_plist` is not enough: it was tested and reported `isIdentifiedGame=0`.
- `isGameFullscreen`: the window is in a **native full-screen Space**. Wine's mac driver offers native full screen only for resizable windows; the game's window is not resizable, so before this change it never got one.

Implementation (setting "Native full screen + Game Mode", on by default, `config_game_mode`):

- `src/wine/game-host.ts` installs `Helpers/wine-shim.c` as `<wine>/lib/wine/x86_64-unix/wine` and keeps the original host as `wine-host`. Wine execs that path for every new Windows process. When `argv[1]` contains the game executable, the shim execs `YaaglGame.app/Contents/MacOS/wine` instead. That file is a copy of `wine-host` in a bundle registered with `lsregister`. All other processes run `wine-host` unchanged.
- The bundle copy is re-signed with `-i com.3shain.yaagl.game`. If the code-signing identifier differs from the bundle identifier, every `getaddrinfo` in the process stalls for about 35 s.
- `Helpers/gamehost.c` is injected into the game process only. The shim sets `DYLD_INSERT_LIBRARIES` from `YAAGL_GAME_HOST_DYLIB` when it execs the game and clears it for the game's child processes. It links only libSystem and attaches once `winemac.so` is loaded. It does five things:
  - moves the game window (at least half the screen) into a native full-screen Space;
  - makes that window cover the whole screen, notch area included. On a Mac with a notch, a native full-screen Space showed a black strip along the top (33 pt on a 14" MacBook Pro), for two reasons:
    - AppKit lays out the window below the camera housing (1512×949 of 1512×982 pt) while the game renders at the full display size. `setFrame:` cannot get past this, because AppKit clamps the frame again. gamehost overrides four private `NSWindow` getters for the game window, `_frameForFullScreenMode` and the three full-screen tile frames, to return the screen frame. With only the first one, the window falls back below the notch when it is ordered front again, for example after the app is hidden.
    - The menu bar window (Window Server, level 24) stays on screen over the top of the Space and is drawn black, even with `NSApplicationPresentationHideMenuBar`. gamehost hooks winemac's `minimumLevelForActive:` so that the game window sits at level 25 while the app is active and the window is in full screen on a screen with a top safe-area inset. It asks winemac to recompute the levels (`adjustWindowLevels`) when that changes, so windows the game orders in front stay above it. When another app becomes active (for example a dialog of another Wine program), the game window drops back to its normal level and the strip shows the menu bar again until the game is clicked. The menu bar then no longer drops down over the game on hover; Ctrl-Cmd-F and Cmd-Tab still work. The camera covers about 185×32 pt at the top center of the picture. Game Mode still reports `isGameFullscreen=1`;
  - keeps winemac from dropping the full-screen behavior;
  - logs `gamepolicyd`'s verdict through `GPProcessMonitor` in the private GamePolicy framework;
  - answers lookups of the Mac's own `<host>.local` name from the interface address. That lookup is mDNS, which counts as Local Network access, and the bundled game is silently held about 35 s on it. Other names use the system resolver.
- The process exits if it is still running 15 s after its window closed. The launcher cannot time this out itself: its wait on `steam.exe` only returns once the game process is gone.

## Process cleanup

`Wine.shutdown()` runs `wineserver -k`, then kills every process of the prefix. A process belongs to the prefix if it maps files from `/tmp/.wine-<uid>/server-<dev>-<inode of prefix>`, or if its working directory is inside the prefix. The second rule catches orphans whose wineserver died, such as `winedevice.exe`. Shutdown runs before each launch. After the game exits, the launcher waits at most 15 s for Wine to exit on its own before forcing shutdown.

## Verification

`scripts/dev/yaagl-diag` prints text only. With `--launch`, it starts Yaagl using `YAAGL_AUTOLAUNCH=1` (no clicks). Yaagl then quits after the game exits and its patches are reverted. The tool always cleans up the prefix when it finishes.

```bash
scripts/dev/yaagl-diag watch --launch --timeout 60 --until gamemode
scripts/dev/yaagl-diag watch --launch --timeout 150 --until exit --close-after 40
scripts/dev/yaagl-diag ps
scripts/dev/yaagl-diag kill --orphans
```

`--autoplay` loads `Helpers/gamehost-dev.m` into the game (`YAAGL_GAMEHOST_DEV`). It clicks into the world, then logs frame-interval statistics for an idle phase and a camera-turn phase (`frames: … p50/p99/max, hitches50`) and saves a PNG of each from the game's own drawable. The turn is driven by `turner.exe` (`SendInput` inside the prefix). Synthetic AppKit events do not turn the camera. These dev pieces are not shipped in the app: `--autoplay` builds them with `Helpers/build.sh --dev` into the data dir's sidecar. `turner.exe` needs llvm-mingw (`LLVM_MINGW=/path`).

```bash
scripts/dev/yaagl-diag watch --launch --autoplay --timeout 200
```

`--screen-check` checks what is actually on screen. It enters the game, then runs these steps: idle in the world, hide and unhide the app, walk, attack, a control with the window held below the menu bar, and restore. After each step the dev companion saves the game's drawable and logs the screen's top safe-area inset and display number. yaagl-diag then captures that display at once (`screencapture -D`, which needs Screen Recording for the calling terminal). `screen-compare.swift` compares per-row luma profiles (scaling a non-Retina drawable to the screen) and prints `verdict=ok`, `covered` (black over the top strip while the game drew there), `shifted` (best match at a vertical offset), `mismatch` or `size-mismatch`. On a Mac with a notch the control step must report `covered`, which shows the check can fail. The last step, `other-window`, opens Notepad in the prefix: it passes when Notepad's window is on screen and the game is inactive at level 24 or lower. It runs last because a background app may not activate itself, and the check has no Accessibility access to click the game. The PNGs stay in `~/Library/Caches/yaagl-diag/shots/<time>/`.

```bash
scripts/dev/yaagl-diag watch --launch --screen-check --timeout 200
```

Result on 2026-10-07 (14" MacBook Pro, macOS 27.0.1): every step `ok` (top strip luma within 1 between screen and game, body diff ≤ 5.7, offset 0), the control `covered` (top luma 0 on screen vs 105 in the game), and `other-window` ok (Notepad on screen, game inactive at level 0). A run where another app took the screen during a step reports that step as `mismatch`.

Measured on 2026-10-04 (M5 Pro, DXMT, native full screen, fast continuous turn):

| Retina | Phase | fps | p99 | Max | Hitches > 50 ms |
| --- | --- | --- | --- | --- | --- |
| On (3024×1898) | Idle | 51.8 | 20.5 ms | 32.7 ms | 0 |
| On (3024×1898) | Turn | 54.0 | 25.4 ms | 42.6 ms | 0 |
| Off (1512×949) | Idle | 59.8 | 17.2 ms | 36.2 ms | 0 |
| Off (1512×949) | Turn | 59.8 | 19.1 ms | 25.1 ms | 0 |

GPTK 4 Beta 2 (`--runtime wine-gptk4`; the runtime dir is selected through `YAAGL_WINE_RUNTIME`, dev only), same spot, Retina on:

| Run | Phase | fps | p99 | Max | Hitches > 50 ms |
| --- | --- | --- | --- | --- | --- |
| First (cold D3DMetal cache) | Idle | 59.4 | 47.6 ms | 71.1 ms | 5 |
| First (cold D3DMetal cache) | Turn | 51.8 | 100.9 ms | 143.3 ms | 24 |
| Second (warm cache) | Idle | 57.9 | 51.3 ms | 142.6 ms | 7 |
| Second (warm cache) | Turn | 59.4 | 28.3 ms | 135.7 ms | 2 |

Cold-cache turn phase (shader caches moved aside for the run, then restored; `$TMPDIR/../C/d3dm/YuanShen.exe` for GPTK, `$TMPDIR/../C/dxmt/YuanShen.exe` for DXMT):

| Backend | Option | Hitches > 50 ms | p99 |
| --- | --- | --- | --- |
| DXMT | — | 19 | 113.8 ms |
| GPTK | `D3DM_MTL4=1` | 16, 9 | 104.5, 52.3 ms |
| GPTK | `D3DM_MTL4=0` | 8, 12 | 54.3, 73.2 ms |

Turn stutter is first-use shader compilation on both backends. The cache is filled per area and the next pass is smooth (warm: 0–2 hitches on both). The user's GPTK stutter came from a young cache: 59 MB for GPTK vs 272 MB for DXMT. D3DMetal has no async or cache option among its `D3DM_*` variables, and `D3DM_MTL4` / `D3DM_MAX_FPS` made no consistent difference.

Volumetric fog was checked with the scene's own setting, using `--grade 9=1` (fog off) at the spawn point. Background luma was 160.6 for DXMT with fog on, 125.5 for DXMT with fog off, and 159.9 for GPTK with fog on. The fog is rendered, and GPTK renders it like DXMT. DXMT stays the default.

### MetalFX upscaling

DXMT has a MetalFX spatial-upscaling swap chain (`d3d11_swapchain.cpp` at `654f547`). It is turned on with `DXMT_METALFX_SPATIAL_SWAPCHAIN=1`, and `d3d11.metalSpatialUpscaleFactor` sets the factor (default 2). The game renders at the window size Wine reports, and MetalFX scales that by the factor into the layer's drawable. With Retina off (1512×949), the game renders at the non-Retina size and the output is the full 3024×1898. With Retina on, it would upscale 3024 to 6048, so the setting forces `RetinaMode=n`. There is no render-scale config key. The temporal paths don't apply: DXMT's `nvngx` (DLSS to MetalFX temporal) and GPTK's `D3DM_ENABLE_METALFX` both need the game to use DLSS, and Genshin ships no `nvngx`/DLSS DLLs.

The setting is "MetalFX upscaling" (`config_metalfx_upscale`, off by default, DXMT only). It sets the variable and starts Wine with Retina off whatever the Retina setting is. It is ignored when a custom resolution is set, because DXMT would then upscale the custom size instead of the non-Retina screen size.

Measured on 2026-10-05, same tool and spot. Each row is one run. Sharpness is the Laplacian variance of the luma of the drawable PNG at 3024×1898. Retina-off shots are upscaled 2× with `sips`, as the compositor does.

| Config | Idle fps / p99 | Turn fps / p99 | Sharpness idle / turn |
| --- | --- | --- | --- |
| Retina on | 60.0 / 18.2 ms | 60.0 / 17.5 ms | 353 / 251 |
| Retina on | 60.0 / 18.6 ms | 60.0 / 17.4 ms | 331 / 240 |
| Retina off | 60.0 / 18.3 ms | 60.0 / 18.0 ms | 165 / 150 |
| Retina off | 60.0 / 17.8 ms | 60.0 / 17.2 ms | 131 / 125 |
| MetalFX | 60.0 / 17.2 ms | 60.1 / 18.6 ms | 255 / 194 |
| MetalFX | 60.0 / 18.0 ms | 60.0 / 17.3 ms | 300 / 244 |
| MetalFX (via the setting, built app) | 60.0 / 17.2 ms | 60.0 / 17.4 ms | — |
| Retina on, render grade `2=9` | 60.0 / 17.4 ms | 60.0 / 17.3 ms | 244 / 223 |
| Retina on, render grade `2=9` | 60.0 / 18.6 ms | 60.0 / 17.2 ms | 241 / 227 |
| MetalFX, render grade `2=9` | 60.0 / 17.3 ms | 60.0 / 17.4 ms | 230 / 199 |
| MetalFX, render grade `2=9` | 60.0 / 18.2 ms | 60.0 / 18.5 ms | 243 / 230 |

No run had a hitch over 50 ms.

- **Sharpness**: MetalFX is far sharper than Retina off and close to native. On crops, edges look as crisp as native, and fine stone texture is slightly smoothed.
- **Frame rate**: these runs don't show a gain, because the spawn scene that day held 60 fps in every mode. That includes Retina on, which gave 52–54 fps on 2026-10-04, and Retina on at render grade 9 (1.5×). Grade 9 does take effect: it smooths the native image.
- **GPU load**: `ioreg` utilization is measured at the current GPU clock. The GPU downclocks to just meet 60, so all modes read 73–91% and the readings can't show headroom. Measuring headroom needs `powermetrics` (sudo) or a scene that is GPU-bound at Retina size.
- **Conclusion**: MetalFX does 1/4 of the 3D and UI pixel work of Retina for close-to-native sharpness, with no frame-pacing cost. Whether it lifts the GPU-bound 52–54 fps case is unproven until that scene is measured again.
- **Verdict (2026-10-06, viewed in game)**: the MetalFX image looked only average. Native Retina resolution with lower in-game effects is the better trade-off when the frame rate is short. The setting stays available but off by default and is not recommended.

`gamemode=on` means `gamepolicyd` reported both `isIdentifiedGame=1` and `isGameFullscreen=1` (logged in `logs/gamehost.log`). `isGameFullscreen` is reported only when it changes, for example when the game's Space is left and entered again. On macOS 27 the first verdict after entering full screen often doesn't arrive, so `--until gamemode` can time out while Game Mode is on. Game progress can be checked in `wineprefix/drive_c/users/crossover/AppData/LocalLow/miHoYo/原神/output_log.txt` (`Genshin Start Log:` lines).
