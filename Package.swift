// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "nocnoc",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything testable without a UI: socket server, HTTP parsing,
        // turning agent hook payloads into events, routing.
        .target(
            name: "NocnocCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NocnocCoreTests",
            dependencies: ["NocnocCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
