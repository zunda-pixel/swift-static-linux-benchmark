// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "swift-static-linux-benchmark",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .executable(name: "BenchmarkServer", targets: ["BenchmarkServer"])
  ],
  dependencies: [
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0")
  ],
  targets: [
    .executableTarget(
      name: "BenchmarkServer",
      dependencies: [
        .product(name: "Hummingbird", package: "hummingbird")
      ]
    )
  ]
)
