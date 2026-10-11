# third_party instructions

Vendored dependencies and submodules are tracked here. Preserve upstream licenses/notices and pin/update provenance. Build DXMT with `scripts/build-dxmt` after installing Meson, CMake, Ninja, and MinGW-w64; after the first successful build, delete the generated `Yaagl.app` once so Xcode signs the bundled DXMT on the next build. The `dxmt` submodule has its own instructions and is outside this parent guide's tracked file coverage.
