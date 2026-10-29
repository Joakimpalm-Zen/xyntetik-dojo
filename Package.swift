// swift-tools-version:6.0
import Foundation
import PackageDescription

// With the Command Line Tools, a rebuild of the test target sometimes runs without the
// swift-testing macro plugin path ("plugin for module 'TestingMacros' not found").
// Passing the path explicitly makes every test build find it.
// The path belongs to the Command Line Tools only: with an Xcode on the machine (a CI runner, say) the
// active toolchain is Xcode's, whose plugin server cannot load the Command Line Tools' plugin.
let cltTestingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? ""
let xcodeInstalled = ((try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? [])
    .contains { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
let usingCLT = developerDir.contains("CommandLineTools") || (developerDir.isEmpty && !xcodeInstalled)
let testSettings: [SwiftSetting] = usingCLT && FileManager.default.fileExists(atPath: cltTestingPlugins)
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
