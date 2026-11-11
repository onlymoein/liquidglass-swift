// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "LiquidGlass",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .library(name: "LiquidGlass", targets: ["LiquidGlass"]),
  ],
  targets: [
    .target(name: "LiquidGlass"),
    .executableTarget(name: "LiquidGlassDemo", dependencies: ["LiquidGlass"]),
    .testTarget(name: "LiquidGlassTests", dependencies: ["LiquidGlass"]),
  ]
)
