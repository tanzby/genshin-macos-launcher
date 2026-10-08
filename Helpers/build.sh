#!/bin/sh
# Build the x86_64 (Rosetta) game-host helpers into OUTDIR (default:
# build/helpers): the wine loader shim and yaagl-gamehost.dylib.
# With --dev, build only the development pieces used by
# `yaagl-diag watch --autoplay` instead: yaagl-gamehost-dev.dylib and, when
# llvm-mingw is available (LLVM_MINGW=/path or on PATH), turner.exe.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
dev=0
if [ "${1:-}" = "--dev" ]; then dev=1; shift; fi
out="${1:-$here/../build/helpers}"
mkdir -p "$out"

if [ "$dev" = 0 ]; then
  clang -arch x86_64 -O2 -Wall -Wextra -o "$out/yaagl-wine-shim" "$here/wine-shim.c"
  clang -arch x86_64 -O2 -Wall -Wextra -dynamiclib -o "$out/yaagl-gamehost.dylib" "$here/gamehost.c"
  codesign -f -s - "$out/yaagl-wine-shim" "$out/yaagl-gamehost.dylib" 2>/dev/null
  exit 0
fi

clang -arch x86_64 -O2 -Wall -fobjc-arc -dynamiclib -undefined dynamic_lookup \
  -framework AppKit -framework Metal -framework QuartzCore -framework ImageIO \
  -o "$out/yaagl-gamehost-dev.dylib" "$here/gamehost-dev.m"
codesign -f -s - "$out/yaagl-gamehost-dev.dylib" 2>/dev/null
mingw="${LLVM_MINGW:+$LLVM_MINGW/bin/}x86_64-w64-mingw32-clang"
if command -v "$mingw" >/dev/null 2>&1; then
  "$mingw" -O2 -o "$out/turner.exe" "$here/turner.c"
fi
