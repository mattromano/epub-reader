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
        .library(name: "Exporting", targets: ["Exporting"]),
        .library(name: "WidgetData", targets: ["WidgetData"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "Persistence",
            dependencies: ["Importing", "Tracking", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "Importing"),
        .target(name: "Tracking"),
        .target(name: "Metrics", dependencies: ["Persistence", "WidgetData", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "WidgetData", dependencies: ["Tracking"]),
        .target(name: "Exporting", dependencies: ["Persistence"]),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence", "Importing", "Tracking", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "ImportingTests",
            dependencies: ["Importing"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "TrackingTests", dependencies: ["Tracking"]),
        .testTarget(
            name: "MetricsTests",
            dependencies: ["Metrics", "Persistence", "Tracking", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "WidgetDataTests", dependencies: ["WidgetData"]),
        .testTarget(
            name: "ExportingTests",
            dependencies: ["Exporting", "Persistence", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
