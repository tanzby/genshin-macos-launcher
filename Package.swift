// swift-tools-version: 6.2
import PackageDescription

// Dependency direction (ADR 0002), each arrow points at a dependency:
//   GenshinCN -> Launcher, Sophon, Wine, Platform
//   Launcher  -> Platform, Wine
//   Wine      -> Platform
//   Sophon    -> swift-protobuf, CZstd (vendored facebook/zstd, decompression only),
//                CHDiffPatch (vendored sisong/HDiffPatch v4.5.2, patching only)
//   Updates   -> Sparkle (re-exported for the app, so Package.resolved pins it, #87)
//   Diagnostics -> Launcher, Platform (the --autolaunch entry and launcher.log for yaagl-diag, #76)
// The SwiftUI app (project.yml) sits on top of Launcher, GenshinCN, Updates and Diagnostics.
let package = Package(
  name: "YaaglKit",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "Sophon", targets: ["Sophon"]),
    .library(name: "Platform", targets: ["Platform"]),
    .library(name: "Wine", targets: ["Wine"]),
    .library(name: "GenshinCN", targets: ["GenshinCN"]),
    .library(name: "Launcher", targets: ["Launcher"]),
    .library(name: "Updates", targets: ["Updates"]),
    .library(name: "Diagnostics", targets: ["Diagnostics"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
    // Exact: release.yaml (SPARKLE_VERSION) and scripts/dev/sparkle-local-check use the same version's tools.
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
  ],
  targets: [
    // facebook/zstd v1.5.7, decompressor only. Assembly is disabled so the target builds without .S files.
    .target(
      name: "CZstd",
      exclude: ["LICENSE"],
      cSettings: [.define("ZSTD_DISABLE_ASM", to: "1"), .headerSearchPath("common")]
    ),
    // sisong/HDiffPatch v4.5.2 (MIT), the patcher only (no diffing, no compression plugins), plus a small
    // file-descriptor front end. The CN ldiff files are uncompressed single-stream diffs.
    .target(name: "CHDiffPatch", exclude: ["LICENSE"]),
    .target(
      name: "Sophon",
      dependencies: ["CZstd", "CHDiffPatch", .product(name: "SwiftProtobuf", package: "swift-protobuf")],
      exclude: ["Proto/manifest.proto", "Proto/manifest_ldiff.proto"]
    ),
    .target(name: "Platform"),
    .target(name: "Wine", dependencies: ["Platform"]),
    .target(name: "Launcher", dependencies: ["Platform", "Wine"]),
    .target(name: "GenshinCN", dependencies: ["Launcher", "Sophon", "Wine", "Platform"]),
    .target(name: "Updates", dependencies: [.product(name: "Sparkle", package: "Sparkle")]),
    .target(name: "Diagnostics", dependencies: ["Launcher", "Platform"]),

    // Shared by the test targets only: temporary directories and waiting helpers.
    .target(name: "TestSupport", path: "Tests/TestSupport"),
    .testTarget(
      name: "SophonTests",
      dependencies: ["Sophon", "TestSupport", .product(name: "SwiftProtobuf", package: "swift-protobuf")],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(name: "PlatformTests", dependencies: ["Platform", "TestSupport"]),
    .testTarget(name: "WineTests", dependencies: ["Wine", "TestSupport"]),
    .testTarget(name: "LauncherTests", dependencies: ["Launcher", "Diagnostics", "TestSupport"]),
    .testTarget(
      name: "GenshinCNTests",
      dependencies: [
        "GenshinCN", "Launcher", "Wine", "Sophon", "Platform", "TestSupport",
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
      ]),
  ],
  swiftLanguageModes: [.v6]
)
