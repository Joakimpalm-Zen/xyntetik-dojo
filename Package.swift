// swift-tools-version:6.0
import Foundation
import PackageDescription

// With the Command Line Tools, a rebuild of the test target sometimes runs without the
// swift-testing macro plugin path ("plugin for module 'TestingMacros' not found").
// Passing the path explicitly makes every test build find it.
let cltTestingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: cltTestingPlugins)
    ? [.unsafeFlags(["-plugin-path", cltTestingPlugins])]
    : []

let package = Package(
    name: "XyntetikHarnessSupervisor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "XyntetikHarnessSupervisor", targets: ["XHSApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.1"),
    ],
    targets: [
        .target(name: "XHSCore"),
        .executableTarget(
            name: "XHSApp",
            dependencies: ["XHSCore", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .testTarget(name: "XHSCoreTests", dependencies: ["XHSCore"], swiftSettings: testSettings),
    ],
    swiftLanguageModes: [.v5]
)
