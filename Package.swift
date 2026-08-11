// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZenRayDictate",
    platforms: [.macOS(.v14)],
    targets: [
        // bridge.js is copied into the .app bundle by build.sh, so the target
        // stays free of SPM resource plumbing and Bundle.module.
        .executableTarget(
            name: "ZenRayDictate",
            path: "Sources/ZenRayDictate",
            exclude: ["Resources"]
        )
    ]
)
