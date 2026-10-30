// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SignType",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SignType",
            path: "Sources/SignType",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
