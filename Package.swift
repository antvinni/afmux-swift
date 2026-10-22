// swift-tools-version: 6.0
import Foundation
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

// With only the Command Line Tools installed, the build system sometimes omits the
// Swift Testing macro plugin from test compiles ("plugin for module 'TestingMacros'
// not found"). Naming the plugin directory makes those builds deterministic.
let testingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSettings: [SwiftSetting] = v5
    + (FileManager.default.fileExists(atPath: testingPlugins) ? [.unsafeFlags(["-plugin-path", testingPlugins])] : [])

let package = Package(
    name: "afmux-swift",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "afm", targets: ["afm"])],
    targets: [
        .target(name: "AFMuxCore", swiftSettings: v5),
        .executableTarget(name: "afm", dependencies: ["AFMuxCore"], swiftSettings: v5),
        .testTarget(name: "AFMuxCoreTests", dependencies: ["AFMuxCore"], swiftSettings: testSettings),
        .testTarget(name: "CLITests", dependencies: ["afm"], swiftSettings: testSettings),
        .testTarget(name: "IntegrationTests", dependencies: ["afm"], swiftSettings: testSettings),
    ]
)
