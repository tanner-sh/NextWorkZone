// swift-tools-version:6.2
// macOS 原生界面。用 ./build.sh 构建：先编译 Rust 应用层并生成 Swift 绑定，再编译本包并打成 .app。
import Foundation
import PackageDescription

let rustLib = ProcessInfo.processInfo.environment["NWZ_RUST_LIB_DIR"] ?? "../target/debug"

let package = Package(
    name: "NextWorkZone",
    platforms: [.macOS(.v26)],
    targets: [
        // UniFFI 生成的 C 头文件（由 build.sh 放入 include/）
        .target(name: "CoreFFI", path: "Sources/CoreFFI"),
        .executableTarget(
            name: "NextWorkZone",
            dependencies: ["CoreFFI"],
            path: "Sources/NextWorkZone",
            swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("BareSlashRegexLiterals")],
            linkerSettings: [
                // 明确链接静态库：同一目录下还有动态库（生成绑定时用），只写库名时链接器会选动态库，
                // 应用就会依赖仓库里的 target 目录
                .unsafeFlags(["\(rustLib)/libnextworkzone_ffi.a"]),
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Carbon"),
                .linkedLibrary("sqlite3"),
                .linkedLibrary("iconv"),
            ]
        ),
    ]
)
