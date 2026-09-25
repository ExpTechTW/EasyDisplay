// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EazyDisplay",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "EazyDisplay", targets: ["EazyDisplay"])],
    targets: [
        .executableTarget(
            name: "EazyDisplay",
            resources: [.process("Resources")],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .testTarget(name: "EazyDisplayTests", dependencies: ["EazyDisplay"]),
    ]
)
