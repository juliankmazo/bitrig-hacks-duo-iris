// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "SayItKeyboardCLI", platforms: [.macOS(.v13)],
  products: [.executable(name: "say-it", targets: ["SayItCLI"])],
  dependencies: [.package(url: "https://github.com/MacPaw/OpenAI.git", exact: "0.5.1")],
  targets: [.target(name: "KeyboardCore", dependencies: [.product(name: "OpenAI", package: "OpenAI")]), .executableTarget(name: "SayItCLI", dependencies: ["KeyboardCore"]),
            .testTarget(name: "KeyboardCoreTests", dependencies: ["KeyboardCore", "SayItCLI", .product(name: "OpenAI", package: "OpenAI")], resources: [.copy("Fixtures")])])
