// swift-tools-version:5.9
// Builds the Dusk executable; build.sh wraps it into Dusk.app.

import PackageDescription

let package = Package(
    name: "Dusk",
    platforms: [.macOS(.v13)],
    dependencies: [
        // In-app updates.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Dusk",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework ships inside the app, in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
