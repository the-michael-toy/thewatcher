// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TheWatcher",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "TheWatcher", targets: ["TheWatcher"])
    ],
    targets: [
        .target(
            name: "CNetStat",
            cSettings: [.headerSearchPath("xnu")]
        ),
        .target(
            name: "WatcherCore",
            dependencies: ["CNetStat"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "TheWatcher",
            dependencies: ["WatcherCore"]
        ),
        .testTarget(
            name: "WatcherCoreTests",
            dependencies: ["WatcherCore"]
        ),
    ]
)
