// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "nocnoc",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "nocnoc", targets: ["nocnoc"]),
        .executable(name: "nocnoc-mcp", targets: ["nocnoc-mcp"]),
    ],
    targets: [
        // Everything testable without a UI: socket server, HTTP parsing,
        // turning agent hook payloads into events, routing.
        .target(
            name: "NocnocCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The menu-bar app: state, notifications, menu UI.
        .executableTarget(
            name: "nocnoc",
            dependencies: ["NocnocCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // stdio MCP server exposing ask_user; agents launch it (Phase 5).
        .executableTarget(
            name: "nocnoc-mcp",
            dependencies: ["NocnocCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NocnocCoreTests",
            dependencies: ["NocnocCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
