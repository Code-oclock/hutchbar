// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "hutchbar",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "HutchbarCore", targets: ["HutchbarCore"]),
    .executable(name: "hutchbar", targets: ["hutchbar"]),
  ],
  targets: [
    .target(name: "HutchbarCore"),
    .executableTarget(name: "hutchbar", dependencies: ["HutchbarCore"]),
    .testTarget(name: "HutchbarCoreTests", dependencies: ["HutchbarCore"]),
  ],
  swiftLanguageModes: [.v6]
)
