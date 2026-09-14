// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "LosslessSystemAudioRecorder",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(
            name: "LosslessSystemAudioRecorder",
            targets: ["LosslessSystemAudioRecorder"]
        )
    ],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")],
    targets: [
        .executableTarget(
            name: "LosslessSystemAudioRecorder",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/LosslessSystemAudioRecorder",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "LosslessSystemAudioRecorderTests",
            dependencies: ["LosslessSystemAudioRecorder"],
            path: "Tests/LosslessSystemAudioRecorderTests"
        )
    ]
)
