// swift-tools-version: 6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "afmux-swift",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "afm", targets: ["afm"])],
    targets: [
        .target(name: "AFMuxCore", swiftSettings: v5),
        .executableTarget(name: "afm", dependencies: ["AFMuxCore"], swiftSettings: v5),
        .testTarget(name: "AFMuxCoreTests", dependencies: ["AFMuxCore"], swiftSettings: v5),
    ]
)
