// swift-tools-version: 6.0
import PackageDescription

// The C core comes prebuilt from the repository root (make xcframework):
// one binary per platform, the same headers.
let package = Package(
  name: "Fosforo",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .executable(name: "fosforo", targets: ["fosforo"])
  ],
  targets: [
    .binaryTarget(name: "CFosforo", path: "Frameworks/CFosforo.xcframework"),
    .target(
      name: "FosforoCore",
      dependencies: ["CFosforo"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .target(
      name: "FosforoRender",
      dependencies: ["FosforoCore", "CFosforo"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .target(
      name: "FosforoSSH",
      dependencies: ["FosforoCore"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .target(
      name: "FosforoMosh",
      dependencies: ["FosforoCore", "FosforoSSH", "CFosforo"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .executableTarget(
      name: "fosforo",
      dependencies: ["FosforoCore", "FosforoRender", "FosforoMosh"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .executableTarget(
      name: "fosforo-ios",
      dependencies: ["FosforoCore", "FosforoRender", "FosforoSSH", "FosforoMosh"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "FosforoCoreTests",
      dependencies: ["FosforoCore"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "FosforoSSHTests",
      dependencies: ["FosforoSSH", "FosforoCore"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "FosforoMoshTests",
      dependencies: ["FosforoMosh", "FosforoSSH", "FosforoCore"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "FosforoRenderTests",
      dependencies: ["FosforoRender", "FosforoCore"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
