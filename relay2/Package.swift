// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Relay2",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "RelayKit",
            dependencies: []
        ),
        .executableTarget(
            name: "RelayApp",
            dependencies: [
                "RelayKit"
            ]
        ),
        .testTarget(
            name: "RelayKitTests",
            dependencies: ["RelayKit"]
        )
    ]
)
