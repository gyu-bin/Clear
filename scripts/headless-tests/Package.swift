// swift-tools-version: 6.0
// Runs ClearTests against the non-UI layers without launching the app.
// Usage: scripts/run-headless-tests.sh
import PackageDescription

let package = Package(
    name: "ClearHeadless",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Clear", path: "Sources/Clear"),
        .testTarget(name: "ClearTests", dependencies: ["Clear"], path: "Tests/ClearTests"),
    ]
)
