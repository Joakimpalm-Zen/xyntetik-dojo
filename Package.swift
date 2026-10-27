// swift-tools-version:6.0
import PackageDescription

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
        .testTarget(name: "XHSCoreTests", dependencies: ["XHSCore"]),
    ],
    swiftLanguageModes: [.v5]
)
