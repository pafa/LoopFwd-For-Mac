// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LoopFwd",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LoopFwd", targets: ["LoopFwd"])
    ],
    targets: [
        .executableTarget(
            name: "LoopFwd",
            path: "Sources/LoopFwd",
            resources: [
                .copy("Resources/agents"),
                .copy("Resources/brand"),
                .process("Resources/Localizable.xcstrings"),
            ]
        ),
        .testTarget(
            name: "LoopFwdTests",
            dependencies: ["LoopFwd"],
            path: "Tests/LoopFwdTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
