// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AppleFMBench",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "AppleFMBench", path: "Sources/AppleFMBench")
    ]
)
