// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DisplayDials",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "DisplayDials", targets: ["DisplayDials"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(name: "UsageTelemetry"),
        .testTarget(name: "UsageTelemetryTests", dependencies: ["UsageTelemetry"]),
        .target(name: "NightShiftBridge", publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        .executableTarget(name: "DisplayDials", dependencies: [
            "NightShiftBridge", "UsageTelemetry", .product(name: "Sparkle", package: "Sparkle")
        ], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])])
    ]
)
