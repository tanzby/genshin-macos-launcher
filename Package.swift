// swift-tools-version: 6.2
import PackageDescription

let agentGuideFiles = ["AGENTS.md", "CLAUDE.md"]

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
      exclude: ["LICENSE"] + agentGuideFiles + [
        "common/AGENTS.md", "common/CLAUDE.md", "decompress/AGENTS.md", "decompress/CLAUDE.md",
        "include/AGENTS.md", "include/CLAUDE.md",
      ],
      cSettings: [.define("ZSTD_DISABLE_ASM", to: "1"), .headerSearchPath("common")]
    ),
    // sisong/HDiffPatch v4.5.2 (MIT), the patcher only (no diffing, no compression plugins), plus a small
    // file-descriptor front end. The CN ldiff files are uncompressed single-stream diffs.
    .target(
      name: "CHDiffPatch",
      exclude: ["LICENSE"] + agentGuideFiles + [
        "hpatch/AGENTS.md", "hpatch/CLAUDE.md", "include/AGENTS.md", "include/CLAUDE.md",
      ]),
    .target(
      name: "Sophon",
      dependencies: ["CZstd", "CHDiffPatch", .product(name: "SwiftProtobuf", package: "swift-protobuf")],
      exclude: agentGuideFiles + [
        "Proto/manifest.proto", "Proto/manifest_ldiff.proto", "Proto/AGENTS.md", "Proto/CLAUDE.md",
      ]
    ),
    .target(name: "Platform", exclude: agentGuideFiles),
    .target(name: "Wine", dependencies: ["Platform"], exclude: agentGuideFiles),
    .target(name: "Launcher", dependencies: ["Platform", "Wine"], exclude: agentGuideFiles),
    .target(name: "GenshinCN", dependencies: ["Launcher", "Sophon", "Wine", "Platform"], exclude: agentGuideFiles),
    .target(name: "Updates", dependencies: [.product(name: "Sparkle", package: "Sparkle")], exclude: agentGuideFiles),
    .target(name: "Diagnostics", dependencies: ["Launcher", "Platform"], exclude: agentGuideFiles),

    // Shared by the test targets only: temporary directories and waiting helpers.
    .target(name: "TestSupport", path: "Tests/TestSupport", exclude: agentGuideFiles),
    .testTarget(
      name: "SophonTests",
      dependencies: ["Sophon", "TestSupport", .product(name: "SwiftProtobuf", package: "swift-protobuf")],
      exclude: agentGuideFiles + [
        "Fixtures/AGENTS.md", "Fixtures/CLAUDE.md", "Fixtures/ldiff/AGENTS.md", "Fixtures/ldiff/CLAUDE.md",
      ],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(name: "PlatformTests", dependencies: ["Platform", "TestSupport"], exclude: agentGuideFiles),
    .testTarget(name: "WineTests", dependencies: ["Wine", "TestSupport"], exclude: agentGuideFiles),
    .testTarget(name: "LauncherTests", dependencies: ["Launcher", "Diagnostics", "TestSupport"], exclude: agentGuideFiles),
    .testTarget(
      name: "GenshinCNTests",
      dependencies: [
        "GenshinCN", "Launcher", "Wine", "Sophon", "Platform", "TestSupport",
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
      ],
      exclude: agentGuideFiles),
  ],
  swiftLanguageModes: [.v6]
)
