// swift-tools-version: 6.2
import PackageDescription

// Dependency direction (ADR 0002), each arrow points at a dependency:
//   GenshinCN -> Launcher, Sophon, Wine, Platform
//   Launcher  -> Platform, Wine
//   Wine      -> Platform
//   Sophon    -> swift-protobuf only
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
    .target(
      name: "Sophon",
      dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]
    ),
    .target(name: "Platform"),
    .target(name: "Wine", dependencies: ["Platform"]),
    .target(name: "Launcher", dependencies: ["Platform", "Wine"]),
    .target(name: "GenshinCN", dependencies: ["Launcher", "Sophon", "Wine", "Platform"]),

    .testTarget(
      name: "SophonTests",
      dependencies: ["Sophon", .product(name: "SwiftProtobuf", package: "swift-protobuf")]
    ),
    .testTarget(name: "PlatformTests", dependencies: ["Platform"]),
    .testTarget(name: "WineTests", dependencies: ["Wine"]),
    .testTarget(name: "LauncherTests", dependencies: ["Launcher"]),
    .testTarget(name: "GenshinCNTests", dependencies: ["GenshinCN", "Launcher"]),
  ],
  swiftLanguageModes: [.v6]
)
