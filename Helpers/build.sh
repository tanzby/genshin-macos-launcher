#!/bin/sh
# Build the x86_64 (Rosetta) development helpers used by `scripts/diag/genshin-launcher-diag run --autoplay` into
# OUTDIR (default: build/helpers): genshin-launcher-gamehost-dev.dylib and, when llvm-mingw is available
# (LLVM_MINGW=/path or on PATH), turner.exe. The shipped helpers are XcodeGen targets (project.yml).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/../build/helpers}"
mkdir -p "$out"

clang -arch x86_64 -O2 -Wall -fobjc-arc -dynamiclib -undefined dynamic_lookup \
  -framework AppKit -framework Metal -framework QuartzCore -framework ImageIO \
  -o "$out/genshin-launcher-gamehost-dev.dylib" "$here/gamehost-dev.m"
codesign -f -s - "$out/genshin-launcher-gamehost-dev.dylib" 2>/dev/null
mingw="${LLVM_MINGW:+$LLVM_MINGW/bin/}x86_64-w64-mingw32-clang"
if command -v "$mingw" >/dev/null 2>&1; then
  "$mingw" -O2 -o "$out/turner.exe" "$here/turner.c"
fi
