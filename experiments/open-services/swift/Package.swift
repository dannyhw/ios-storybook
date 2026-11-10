// swift-tools-version: 6.0
import PackageDescription

// The device half of the Open Services experiment: joins a Storybook 11 dev
// server as an Open Services peer and serves the `ios/device` commands.
let package = Package(
    name: "StorybookOpenServices",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "StorybookOpenServices", targets: ["StorybookOpenServices"]),
    ],
    dependencies: [
        .package(name: "Storybook", path: "../../.."),
    ],
    targets: [
        .target(name: "StorybookOpenServices", dependencies: [
            .product(name: "StorybookRuntime", package: "Storybook"),
            .product(name: "StorybookUI", package: "Storybook"),
        ]),
    ]
)
