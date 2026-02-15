// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Paneless",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Paneless",
            path: "Sources/Paneless",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreVideo"),
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])
            ]
        )
    ]
)
