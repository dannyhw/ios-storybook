import Foundation
import Storybook
import StorybookProtocol

/// App-side implementation of the toolset methods. The Mac CLI and MCP
/// server send these over the agent socket; method names match the CLI
/// (`stories render`) and MCP (`stories-render`) names.
@MainActor
public struct AgentToolset {
    let store: StoryStore

    public init(store: StoryStore) { self.store = store }

    public func handle(method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "stories.list":
            let tag = params["tag"]?.stringValue
            let stories = store.stories.filter { tag == nil || $0.description.entry.tags.contains(tag!) }
            return .object([
                "stories": try JSONValue.encode(stories.map(\.description)),
                "selected": store.selectedID.map(JSONValue.string) ?? .null,
                "discoveryErrors": try JSONValue.encode(store.discoveryErrors),
            ])

        case "stories.get":
            let id = try storyID(params)
            guard let story = store.story(id) else { throw RPCError.unknownStory(id) }
            return .object(["story": try JSONValue.encode(story.description), "args": try store.args(for: id)])

        case "stories.select":
            let id = try storyID(params)
            try store.select(id)
            return .object(["selected": .string(id)])

        case "stories.render":
            return try await render(params)

        case "index.get":
            return try JSONValue.encode(store.index())

        case "args.get":
            let id = try storyID(params)
            return .object(["storyId": .string(id), "args": try store.args(for: id)])

        case "args.set":
            let id = try storyID(params)
            guard let patch = params["args"], patch.objectValue != nil else {
                throw RPCError(code: "invalid-params", message: "args.set needs an 'args' object (a JSON merge patch).")
            }
            try store.updateArgs(id, patch: patch)
            return .object(["storyId": .string(id), "args": try store.args(for: id)])

        case "args.reset":
            let id = try storyID(params)
            try store.resetArgs(id)
            return .object(["storyId": .string(id), "args": try store.args(for: id)])

        case "globals.get":
            return try JSONValue.encode(store.globals)

        case "globals.set":
            try applyGlobals(params["globals"] ?? params)
            return try JSONValue.encode(store.globals)

        case "actions.list":
            let id = params["storyId"]?.stringValue
            return .object(["actions": try JSONValue.encode(store.actions.filter { id == nil || $0.storyId == id })])

        case "actions.clear":
            store.clearActions()
            return .object(["cleared": .bool(true)])

        default:
            throw RPCError(code: "unknown-method", message: "Unknown method '\(method)'.")
        }
    }

    /// Selects the story, applies optional args/globals, waits for layout to
    /// settle and returns a PNG of the story's frame.
    private func render(_ params: JSONValue) async throws -> JSONValue {
        let id = try storyID(params)
        try store.select(id)
        if let patch = params["args"], patch.objectValue != nil {
            try store.updateArgs(id, patch: patch)
        }
        if let globals = params["globals"], globals.objectValue != nil {
            try applyGlobals(globals)
        }
        #if canImport(UIKit)
        let start = Date()
        guard let canvas = StoryHostViewController.current else {
            throw RPCError(code: "canvas-hidden", message: "No story canvas is on screen yet.")
        }
        let snapshot = try await canvas.snapshot(bleed: params["bleed"]?.numberValue.map { CGFloat($0) })
        return .object([
            "storyId": .string(id),
            "png": .string(snapshot.png.base64EncodedString()),
            "width": .number(snapshot.width),
            "height": .number(snapshot.height),
            "scale": .number(snapshot.scale),
            "renderMs": .number((Date().timeIntervalSince(start) * 1000).rounded()),
            "args": try store.args(for: id),
            "globals": try JSONValue.encode(store.globals),
        ])
        #else
        throw RPCError(code: "unsupported", message: "Rendering needs UIKit.")
        #endif
    }

    /// Globals are merged: omitted keys keep their value, `null` clears one.
    private func applyGlobals(_ patch: JSONValue) throws {
        let merged = try JSONValue.encode(store.globals).merging(patch: patch)
        store.updateGlobals(try merged.decode(StoryGlobals.self))
    }

    private func storyID(_ params: JSONValue) throws -> String {
        if let id = params["storyId"]?.stringValue { return id }
        if let id = store.selectedID { return id }
        throw RPCError(code: "invalid-params", message: "Missing 'storyId'.")
    }
}
