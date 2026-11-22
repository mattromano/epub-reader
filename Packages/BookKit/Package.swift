// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BookKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "Importing", targets: ["Importing"]),
        .library(name: "Tracking", targets: ["Tracking"]),
        .library(name: "Metrics", targets: ["Metrics"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "Persistence",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "Importing"),
        .target(name: "Tracking"),
        .target(name: "Metrics"),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "ImportingTests", dependencies: ["Importing"]),
        .testTarget(name: "TrackingTests", dependencies: ["Tracking"]),
        .testTarget(name: "MetricsTests", dependencies: ["Metrics"]),
    ],
    swiftLanguageModes: [.v6]
)
