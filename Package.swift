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
    targets: [
        .executableTarget(
            name: "CineNotch",
            path: "Sources/CineNotch"
        ),
        .target(
            name: "NowPlayingBridge",
            path: "Sources/NowPlayingBridge",
            linkerSettings: [.linkedFramework("Foundation")]
        ),
    ]
)
