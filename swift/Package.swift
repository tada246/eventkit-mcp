// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "eventkit-cli",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "EventKitCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "eventkit-cli",
            dependencies: ["EventKitCore"],
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Sources/eventkit-cli/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "EventKitCoreTests",
            dependencies: ["EventKitCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
