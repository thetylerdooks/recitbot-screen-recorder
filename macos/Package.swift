// swift-tools-version:5.9
import PackageDescription

// RecitbotCore: pure logic (Foundation + CryptoKit only). Recitbot: the agent executable (AppKit, capture, UI, CLI).
let package = Package(
    name: "Recitbot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Recitbot", targets: ["Recitbot"]),
        .library(name: "RecitbotCore", targets: ["RecitbotCore"]),
    ],
    targets: [
        .target(
            name: "RecitbotCore",
            path: "Sources/RecitbotCore",
            linkerSettings: [
                .linkedFramework("CryptoKit"),
            ]
        ),
        .executableTarget(
            name: "Recitbot",
            dependencies: ["RecitbotCore"],
            path: "Sources/Recitbot",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
    ]
)
