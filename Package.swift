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
            dependencies: [.product(name: "Sparkle", package: "Sparkle"), "CineNotchLicense"],
            path: "Sources/CineNotch"
        ),
        // License keys: token check, Keychain storage, the client for cinenotch.cam's licensing proxy. Off unless
        // `LicensingEnabled` is set in Info.plist (see docs/LICENSING.md). No UI, so it can be tested on its own.
        .target(
            name: "CineNotchLicense",
            path: "Sources/CineNotchLicense"
        ),
        .testTarget(
            name: "CineNotchLicenseTests",
            dependencies: ["CineNotchLicense"],
            path: "Tests/CineNotchLicenseTests"
        ),
        .target(
            name: "NowPlayingBridge",
            path: "Sources/NowPlayingBridge",
            linkerSettings: [.linkedFramework("Foundation")]
        ),
    ]
)
