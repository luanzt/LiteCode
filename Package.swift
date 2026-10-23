// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiteCode",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LiteCode", targets: ["LiteCode"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        // Auto-update from the GitHub Releases appcast (same setup and version as mTerm).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    ],
    targets: [
        // Pure logic (diff alignment, git status parsing) kept AppKit-free so it is unit-testable.
        .target(name: "LiteCodeCore"),
        .executableTarget(
            name: "LiteCode",
            dependencies: [
                "LiteCodeCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            // Material Icon Theme 5.39.0 (MIT), copied from the VS Code extension.
            resources: [.copy("Resources/MaterialIcons")]),
        .testTarget(name: "LiteCodeCoreTests", dependencies: ["LiteCodeCore"]),
    ],
    swiftLanguageModes: [.v5]
)
