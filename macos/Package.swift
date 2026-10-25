// swift-tools-version:6.2
// NextWorkZone（macOS）。用 ./build.sh 构建并打成 .app，用 ./test.sh 运行测试。
import Foundation
import PackageDescription

let sdk = ProcessInfo.processInfo.environment["SDKROOT"] ?? "/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"

let package = Package(
    name: "NextWorkZone",
    platforms: [.macOS(.v26)],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .systemLibrary(name: "CLibXML2"),
        .target(name: "NWZCore", dependencies: ["CSQLite"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "NWZRich", dependencies: ["NWZCore", "CLibXML2"], swiftSettings: [.swiftLanguageMode(.v6), .unsafeFlags(["-I\(sdk)/usr/include/libxml2"])]),
        .target(name: "NWZWorkspace", dependencies: ["NWZCore", "NWZRich"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "NWZJira", dependencies: ["NWZCore", "NWZRich"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "NWZWiki", dependencies: ["NWZCore", "NWZRich"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "NWZGitLab", dependencies: ["NWZCore", "NWZRich"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "NWZPreview", dependencies: ["NWZCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "NWZClipboard", dependencies: ["NWZCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "NWZServices", dependencies: ["NWZCore", "NWZWorkspace", "NWZRich", "NWZPreview", "NWZJira", "NWZWiki", "NWZGitLab", "NWZClipboard"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "NWZTool", dependencies: ["NWZServices", "NWZCore", "NWZJira", "NWZWiki", "NWZGitLab"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "NWZTests", dependencies: ["NWZCore", "NWZServices", "NWZRich", "NWZWorkspace", "NWZPreview", "NWZJira", "NWZWiki", "NWZGitLab", "NWZClipboard", "CLibXML2"], resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v6), .unsafeFlags(["-I\(sdk)/usr/include/libxml2"])]),
        .executableTarget(
            name: "NextWorkZone",
            dependencies: ["NWZCore", "NWZServices", "NWZRich", "NWZWorkspace", "NWZPreview", "NWZJira", "NWZWiki", "NWZGitLab", "NWZClipboard"],
            path: "Sources/NextWorkZone",
            swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("BareSlashRegexLiterals")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
