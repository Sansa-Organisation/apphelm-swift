// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "Apphelm",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [
    .library(name: "Apphelm", targets: ["Apphelm"]),
  ],
  targets: [
    .target(name: "Apphelm", path: "Sources/Apphelm"),
    .testTarget(name: "ApphelmTests", dependencies: ["Apphelm"], path: "Tests/ApphelmTests"),
  ]
)
