// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EasyDisplay",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "EasyDisplay", targets: ["EasyDisplay"])],
    targets: [
        .executableTarget(
            name: "EasyDisplay",
            resources: [.process("Resources")],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .testTarget(name: "EasyDisplayTests", dependencies: ["EasyDisplay"]),
    ]
)
