// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Spacey",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Spacey",
            path: "Sources/Spacey",
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
