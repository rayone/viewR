// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "viewR",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .executableTarget(
            name: "viewR",
            path: "Sources/viewR",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
