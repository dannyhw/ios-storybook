// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Storybook",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Storybook", targets: ["Storybook"]),
        .library(name: "StorybookRuntime", targets: ["StorybookRuntime"]),
        .library(name: "StorybookUI", targets: ["StorybookUI"]),
        .library(name: "StorybookProtocol", targets: ["StorybookProtocol"]),
        .executable(name: "storybook", targets: ["StorybookCLI"]),
    ],
    targets: [
        // Wire types shared by the app runtime and the Mac CLI. Foundation only.
        .target(name: "StorybookProtocol"),
        // The story format: Stories, StoryMeta, Story, args, decorators, ids.
        .target(name: "Storybook", dependencies: ["StorybookProtocol"]),
        // Discovery, store, renderer and agent server (iOS app process).
        .target(name: "StorybookRuntime", dependencies: ["Storybook", "StorybookProtocol"]),
        // In-app browser: sidebar, canvas, Controls and Actions panels.
        .target(name: "StorybookUI", dependencies: ["Storybook", "StorybookRuntime"]),
        // Mac CLI and stdio MCP server that drive a running app.
        .executableTarget(name: "StorybookCLI", dependencies: ["StorybookProtocol"]),
        .testTarget(name: "StorybookTests", dependencies: ["Storybook", "StorybookRuntime", "StorybookProtocol"]),
    ]
)
