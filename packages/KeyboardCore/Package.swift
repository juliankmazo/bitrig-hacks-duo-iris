// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "KeyboardCore", platforms: [.macOS(.v13), .iOS(.v16)],
  products: [.library(name: "KeyboardCore", targets: ["KeyboardCore"])],
  dependencies: [.package(url: "https://github.com/MacPaw/OpenAI.git", exact: "0.5.1")],
  targets: [
    .target(name: "KeyboardCore", dependencies: [.product(name: "OpenAI", package: "OpenAI")]),
    .testTarget(name: "KeyboardCoreTests", dependencies: ["KeyboardCore"])
  ])
