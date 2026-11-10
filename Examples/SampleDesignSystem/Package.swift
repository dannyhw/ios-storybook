// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SampleDesignSystem",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "SampleDesignSystem", targets: ["SampleDesignSystem"]),
    ],
    dependencies: [
        .package(name: "Storybook", path: "../.."),
    ],
    targets: [
        .target(
            name: "SampleDesignSystem",
            dependencies: [.product(name: "Storybook", package: "Storybook")],
            // Stories compile in Debug only; Release builds strip them.
            swiftSettings: [.define("STORYBOOK", .when(configuration: .debug))]
        ),
    ]
)
