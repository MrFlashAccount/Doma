// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Doma",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Doma", targets: ["Doma"]),
    ],
    targets: [
        .executableTarget(
            name: "Doma",
            path: "Sources/Doma",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
            ]
        ),
    ]
)
