// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Readpaw",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Readpaw", targets: ["Readpaw"])
    ],
    targets: [
        .executableTarget(
            name: "Readpaw",
            path: "Sources/Readpaw"
        )
    ]
)
