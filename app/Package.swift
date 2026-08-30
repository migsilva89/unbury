// swift-tools-version: 6.0
import PackageDescription

// UnburyCore is the engine: the local mirror, the search, the sync with the Pi.
// It has no UI in it, so `unburyctl` can prove it works before the app exists.
let package = Package(
    name: "Unbury",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UnburyCore", targets: ["UnburyCore"]),
        .executable(name: "unburyctl", targets: ["unburyctl"]),
        .executable(name: "Unbury", targets: ["Unbury"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        // Pinned because this framework installs executable code. Updating it
        // is a deliberate review, not something a release build decides.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .target(
            name: "UnburyCore",
            dependencies: [.product(name: "PostgresNIO", package: "postgres-nio")],
            path: "Sources/UnburyCore"
        ),
        .executableTarget(
            name: "Unbury",
            // Sparkle belongs to the app alone. `unburyctl` is a command someone
            // ran on purpose; it has no business replacing itself while it runs.
            dependencies: [
                "UnburyCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Unbury",
            // The executable sits in Contents/MacOS; Sparkle is embedded in the
            // standard sibling Frameworks directory when the bundle is assembled.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks",
            ])]
        ),
        .executableTarget(
            name: "unburyctl",
            dependencies: ["UnburyCore"],
            path: "Sources/unburyctl"
        ),
    ]
)
