// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CcinnClickHouse",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClickHouseWire", targets: ["ClickHouseWire"]),
        .library(name: "ClickHouseKit", targets: ["ClickHouseKit"]),
        .library(name: "CcinnClickHouseKit", targets: ["CcinnClickHouseKit"]),
        .executable(name: "CcinnClickHouse", targets: ["CcinnClickHouse"]),
    ],
    targets: [
        // ClickHouse HTTP protocol pieces: type grammar, TSV result parsing, headers, exceptions, quoting, gzip. No I/O.
        .target(name: "ClickHouseWire", swiftSettings: settings),
        // Transport (URLSession), client, sessions, cancellation, SSH tunnels and ClickHouse-aware metadata/operations.
        .target(name: "ClickHouseKit", dependencies: ["ClickHouseWire"], swiftSettings: settings),
        // UI-independent app logic: profiles, SQL lexer/completion/guard, charts, export, history, MCP.
        .target(name: "CcinnClickHouseKit", dependencies: ["ClickHouseWire", "ClickHouseKit"], swiftSettings: settings),
        // SwiftUI application (and the `mcp` subcommand).
        .executableTarget(name: "CcinnClickHouse", dependencies: ["ClickHouseWire", "ClickHouseKit", "CcinnClickHouseKit"],
                          swiftSettings: settings),

        .testTarget(name: "ClickHouseWireTests", dependencies: ["ClickHouseWire"], swiftSettings: settings),
        .testTarget(name: "ClickHouseKitTests", dependencies: ["ClickHouseWire", "ClickHouseKit"], swiftSettings: settings),
        .testTarget(name: "CcinnClickHouseKitTests", dependencies: ["ClickHouseWire", "ClickHouseKit", "CcinnClickHouseKit"],
                    swiftSettings: settings),
        .testTarget(name: "IntegrationTests", dependencies: ["ClickHouseWire", "ClickHouseKit", "CcinnClickHouseKit"],
                    swiftSettings: settings),
    ],
    swiftLanguageModes: [.v6]
)
