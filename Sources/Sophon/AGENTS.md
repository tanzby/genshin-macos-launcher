# Sophon module

This module owns Sophon manifests, chunk downloads, Zstandard decoding, and ldiff patching. It consumes the vendored decoder and patcher through their narrow interfaces; protocol behavior is represented in `Tests/SophonTests/Fixtures/`.
