// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DisplayDials",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "DisplayDials", targets: ["DisplayDials"])],
    targets: [
        .target(name: "DisplayCore"),
        .target(name: "NightShiftBridge", publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        .executableTarget(name: "DisplayDials", dependencies: ["DisplayCore", "NightShiftBridge"]),
        .testTarget(name: "DisplayCoreTests", dependencies: ["DisplayCore"])
    ]
)
