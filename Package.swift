// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Voci",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(name: "whisper", path: "Vendor/build-apple/whisper.xcframework"),
        .executableTarget(
            name: "Voci",
            dependencies: ["whisper"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
