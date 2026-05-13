// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Readpaw",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Readpaw", targets: ["Readpaw"])
    ],
    targets: [
        .executableTarget(
            name: "Readpaw",
            path: "Sources/Readpaw",
            resources: [
                .copy("Resources/Color_orb.usdz")
            ],
            swiftSettings: [
                // Keep Swift 5 semantics — Swift 6 strict-concurrency surfaces
                // a bunch of pre-existing actor/Sendable issues that would
                // sprawl this change beyond its scope. The toolchain stays at
                // 6.0 only so we can declare the macOS 15 platform.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
