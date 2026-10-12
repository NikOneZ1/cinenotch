// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CineNotch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CineNotch", targets: ["CineNotch"]),
        // Loaded into /usr/bin/perl to reach macOS's Now Playing (see NowPlaying.swift).
        .library(name: "NowPlayingBridge", type: .dynamic, targets: ["NowPlayingBridge"]),
    ],
    dependencies: [
        // In-app updates from the appcast on cinenotch.cam.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "CineNotch",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/CineNotch"
        ),
        .target(
            name: "NowPlayingBridge",
            path: "Sources/NowPlayingBridge",
            linkerSettings: [.linkedFramework("Foundation")]
        ),
    ]
)
