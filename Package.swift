// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Strapontin",
    platforms: [.macOS(.v14)],
    dependencies: [
        // mises à jour intégrées : appcast publié avec chaque release, archives signées EdDSA
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        // libmpv installé par Homebrew (brew install mpv)
        .systemLibrary(name: "Cmpv", path: "Sources/Cmpv", pkgConfig: "mpv", providers: [.brew(["mpv"])]),
        .target(name: "StrapontinCore", path: "Sources/StrapontinCore"),
        .executableTarget(
            name: "Strapontin",
            dependencies: ["Cmpv", "StrapontinCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Strapontin",
            linkerSettings: [.linkedFramework("OpenGL"), .linkedFramework("QuartzCore"), .linkedFramework("AppKit"), .linkedFramework("MediaPlayer")]
        ),
        .testTarget(name: "StrapontinCoreTests", dependencies: ["StrapontinCore"], path: "Tests/StrapontinCoreTests"),
    ]
)
