// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "SayItKeyboardCLI", platforms: [.macOS(.v13)],
  products: [.executable(name: "say-it", targets: ["SayItCLI"])],
  dependencies: [
    .package(path: "../../packages/KeyboardCore"),
    .package(url: "https://github.com/MacPaw/OpenAI.git", exact: "0.5.1")
  ],
  targets: [
    .executableTarget(name: "SayItCLI", dependencies: [.product(name: "KeyboardCore", package: "KeyboardCore")]),
    .testTarget(name: "KeyboardCoreTests", dependencies: [.product(name: "KeyboardCore", package: "KeyboardCore"), "SayItCLI", .product(name: "OpenAI", package: "OpenAI")], resources: [.copy("Fixtures")])
  ])
