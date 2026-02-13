// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LanraragiKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LanraragiKit", targets: ["LanraragiKit"])
    ],
    targets: [
        .target(
            name: "LanraragiKit",
            dependencies: [],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "LanraragiKitTests",
            dependencies: ["LanraragiKit"]
        )
    ]
)
