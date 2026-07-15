// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Doma",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Doma", targets: ["Doma"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    ],
    targets: [
        .executableTarget(
            name: "Doma",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Doma",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
            ]
        ),
        .testTarget(
            name: "DomaTests",
            path: "Tests/DomaTests"
        ),
    ]
)
