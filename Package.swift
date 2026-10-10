// swift-tools-version: 6.2
import PackageDescription

// Dependency direction (ADR 0002), each arrow points at a dependency:
//   GenshinCN -> Launcher, Sophon, Wine, Platform
//   Launcher  -> Platform, Wine
//   Wine      -> Platform
//   Sophon    -> swift-protobuf, CZstd (vendored facebook/zstd, decompression only),
//                CHDiffPatch (vendored sisong/HDiffPatch v4.5.2, patching only)
// The SwiftUI app (project.yml) sits on top of Launcher and GenshinCN.
let package = Package(
  name: "YaaglKit",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "Sophon", targets: ["Sophon"]),
    .library(name: "Platform", targets: ["Platform"]),
    .library(name: "Wine", targets: ["Wine"]),
    .library(name: "GenshinCN", targets: ["GenshinCN"]),
    .library(name: "Launcher", targets: ["Launcher"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1")
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

    .testTarget(
      name: "SophonTests",
      dependencies: ["Sophon", .product(name: "SwiftProtobuf", package: "swift-protobuf")],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(name: "PlatformTests", dependencies: ["Platform"]),
    .testTarget(name: "WineTests", dependencies: ["Wine"]),
    .testTarget(name: "LauncherTests", dependencies: ["Launcher"]),
    .testTarget(name: "GenshinCNTests", dependencies: ["GenshinCN", "Launcher", "Wine"]),
  ],
  swiftLanguageModes: [.v6]
)
