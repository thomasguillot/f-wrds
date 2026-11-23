// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WrdsKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "WrdsKit", targets: ["WrdsKit"]),
    ],
    dependencies: [
        // Espanso YAML is an import/export border, not the live schema.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .target(name: "WrdsKit", dependencies: [.product(name: "Yams", package: "Yams")]),
        .testTarget(name: "WrdsKitTests", dependencies: ["WrdsKit"],
                    // Real Espanso YAML, copied verbatim rather than processed: the importer's job
                    // is to read what Espanso writes, so the fixtures have to reach the bundle
                    // byte-for-byte.
                    resources: [.copy("Fixtures")]),
    ]
)
