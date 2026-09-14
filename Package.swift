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
    targets: [
        .executableTarget(
            name: "LosslessSystemAudioRecorder",
            path: "Sources/LosslessSystemAudioRecorder"
        ),
        .testTarget(
            name: "LosslessSystemAudioRecorderTests",
            dependencies: ["LosslessSystemAudioRecorder"],
            path: "Tests/LosslessSystemAudioRecorderTests"
        )
    ]
)
