// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZenRayDictate",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ZenRayDictate",
            path: "Sources/ZenRayDictate",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech")
            ]
        )
    ]
)
