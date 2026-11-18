// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MockUsage",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MockUsage", targets: ["MockUsage"])],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(name: "MockUsage", dependencies: ["UsageCore"],
                          resources: [.copy("Resources/collector.py")]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
        .testTarget(name: "MockUsageIntegrationTests", dependencies: ["MockUsage", "UsageCore"],
                    resources: [.copy("Fixtures/simulated-docker.py")])
    ],
    swiftLanguageModes: [.v5]
)
