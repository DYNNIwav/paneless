// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Paneless",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "Paneless",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Paneless",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreVideo"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])
            ]
        ),
        .testTarget(
            name: "PanelessTests",
            dependencies: ["Paneless"],
            path: "Tests/PanelessTests"
        )
    ]
)
