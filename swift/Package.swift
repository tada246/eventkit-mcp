// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "eventkit-cli",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "eventkit-cli",
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
        )
    ]
)
