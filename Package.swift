// swift-tools-version:6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

#if swift(<6)
let swiftSettings: [SwiftSetting] = [
    .enableExperimentalFeature("ExistentialAny"),
    .enableExperimentalFeature("StrictConcurrency")
]
#else
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny")
]
#endif

let package = Package(
    name: "HaishinKit",
    platforms: [
        .iOS(.v15),
        .tvOS(.v15),
        .macCatalyst(.v15),
        .macOS(.v12),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "HaishinKit", targets: ["HaishinKit"]),
        .library(name: "RTMPHaishinKit", targets: ["RTMPHaishinKit"]),
        .library(name: "SRTHaishinKit", targets: ["SRTHaishinKit"]),
        .library(name: "MoQTHaishinKit", targets: ["MoQTHaishinKit"]),
        .library(name: "RTCHaishinKit", targets: ["RTCHaishinKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.5"),
        .package(url: "https://github.com/shogo4405/Logboard.git", "2.6.0"..<"2.7.0")
    ],
    targets: [
        .binaryTarget(
            name: "libsrt",
            path: "libsrt.xcframework"
        ),
        .binaryTarget(
            name: "libdatachannel",
            path: "libdatachannel.xcframework"
        ),
        .target(
            name: "HaishinKit",
            dependencies: ["Logboard"],
            path: "HaishinKit/Sources",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "RTMPHaishinKit",
            dependencies: ["HaishinKit"],
            path: "RTMPHaishinKit/Sources",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "SRTHaishinKit",
            dependencies: ["libsrt", "HaishinKit"],
            path: "SRTHaishinKit/Sources",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "MoQTHaishinKit",
            dependencies: ["HaishinKit"],
            path: "MoQTHaishinKit/Sources",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "RTCHaishinKit",
            dependencies: ["libdatachannel", "HaishinKit"],
            path: "RTCHaishinKit/Sources",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "HaishinKitTests",
            dependencies: ["HaishinKit"],
            path: "HaishinKit/Tests",
            resources: [
                .process("Asset")
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "RTMPHaishinKitTests",
            dependencies: ["RTMPHaishinKit"],
            path: "RTMPHaishinKit/Tests",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SRTHaishinKitTests",
            dependencies: ["SRTHaishinKit"],
            path: "SRTHaishinKit/Tests",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "RTCHaishinKitTests",
            dependencies: ["RTCHaishinKit"],
            path: "RTCHaishinKit/Tests",
            swiftSettings: swiftSettings
        )
    ],
    swiftLanguageModes: [.v6, .v5]
)
