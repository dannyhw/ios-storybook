import Foundation
import Observation
import Storybook
import StorybookProtocol

/// The single source of truth for selection, args, globals and actions.
/// The in-app UI and the agent server both read and write it, so a change
/// from either side shows up in the other immediately.
@MainActor
@Observable
public final class StoryStore {
    public private(set) var stories: [ResolvedStory]
    public private(set) var discoveryErrors: [String]
    public private(set) var selectedID: String?
    public private(set) var globals = StoryGlobals()
    public private(set) var actions: [ActionEvent] = []
    /// Changes on every story switch or args reset, so the canvas remounts
    /// the story and `@State` doesn't leak between stories.
    public private(set) var renderToken = 0
    private var argsByID: [String: JSONValue] = [:]
    private var nextActionID = 1

    /// Notified on every store change that clients should hear about.
    @ObservationIgnored public var onEvent: (@MainActor (RPCEvent) -> Void)?

    public init(discovery: StoryRegistry.Discovery = StoryRegistry.discover()) {
        stories = discovery.stories
        discoveryErrors = discovery.errors
        selectedID = discovery.stories.first?.id
        let sink: StoryActionSink.Handler = { [weak self] name, payload in
            Task { @MainActor in self?.recordAction(name: name, payload: payload) }
        }
        StoryActionSink.install(sink)
    }

    public var selected: ResolvedStory? {
        selectedID.flatMap(story)
    }

    public func story(_ id: String) -> ResolvedStory? {
        stories.first { $0.id == id }
    }

    public func index() -> StoryIndex {
        StoryIndex(entries: Dictionary(uniqueKeysWithValues: stories.map { ($0.id, $0.description.entry) }))
    }

    // MARK: Selection

    public func select(_ id: String) throws {
        guard story(id) != nil else { throw RPCError.unknownStory(id) }
        guard id != selectedID else { return }
        selectedID = id
        renderToken += 1
        onEvent?(RPCEvent(event: "storySelected", data: .object(["storyId": .string(id)])))
    }

    // MARK: Args

    public func args(for id: String) throws -> JSONValue {
        guard let story = story(id) else { throw RPCError.unknownStory(id) }
        return argsByID[id] ?? story.description.initialArgs
    }

    /// Applies a JSON merge patch to the story's current args. The result
    /// must still decode as the story's args type.
    public func updateArgs(_ id: String, patch: JSONValue) throws {
        guard let story = story(id) else { throw RPCError.unknownStory(id) }
        // Top-level keys are kept with an explicit `null` rather than removed
        // (as plain merge patch would), so `@Arg` optionals still decode.
        var merged = try args(for: id).objectValue ?? [:]
        for (key, value) in patch.objectValue ?? [:] {
            merged[key] = (merged[key] ?? .null).merging(patch: value)
        }
        let mergedArgs = JSONValue.object(merged)
        let allowed = Set(story.description.argOrder)
        if let unknown = patch.objectValue?.keys.first(where: { !allowed.contains($0) }) {
            throw RPCError(code: "unknown-arg", message: "Story '\(id)' has no arg '\(unknown)'. Args: \(story.description.argOrder.joined(separator: ", "))")
        }
        do {
            _ = try story.view(args: mergedArgs)
        } catch {
            throw RPCError(code: "invalid-args", message: "Args don't match the story's types: \(error)")
        }
        argsByID[id] = mergedArgs
        onEvent?(RPCEvent(event: "argsChanged", data: .object(["storyId": .string(id), "args": mergedArgs])))
    }

    public func resetArgs(_ id: String) throws {
        guard story(id) != nil else { throw RPCError.unknownStory(id) }
        argsByID[id] = nil
        renderToken += 1
        onEvent?(RPCEvent(event: "argsChanged", data: .object(["storyId": .string(id), "args": try args(for: id)])))
    }

    // MARK: Globals

    public func updateGlobals(_ newGlobals: StoryGlobals) {
        globals = newGlobals
        onEvent?(RPCEvent(event: "globalsChanged", data: (try? JSONValue.encode(newGlobals)) ?? .null))
    }

    // MARK: Actions

    func recordAction(name: String, payload: String) {
        let event = ActionEvent(id: nextActionID, storyId: selectedID, name: name, payload: payload, timestamp: Date())
        nextActionID += 1
        actions.append(event)
        if actions.count > 500 { actions.removeFirst(actions.count - 500) }
        onEvent?(RPCEvent(event: "actionFired", data: (try? JSONValue.encode(event)) ?? .null))
    }

    public func clearActions() {
        actions.removeAll()
    }
}
