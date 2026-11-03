// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Voci",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Voci"),
    ],
    swiftLanguageModes: [.v5]
)
