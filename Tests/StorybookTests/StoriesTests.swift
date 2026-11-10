import SwiftUI
import Testing
@testable import Storybook
@testable import StorybookRuntime
import StorybookProtocol

enum FixtureStyle: String, Codable, CaseIterable, Sendable { case primary, secondary, destructive }

struct FixtureArgs: StoryArgs {
    var title = "Pay"
    var style: FixtureStyle = .primary
    var isEnabled = true
    @Arg(.range(0...5, step: 0.5), description: "Stars") var rating = 3.0
    var tint: StoryColor = .hex("#0A84FF")
    var badge: Int? = nil
    var onTap = StoryAction("onTap")
    @Arg(.hidden) var internalID = "x"
    @Arg(.range(0...9)) var count: Int? = 1
}

enum FixtureButtonStories: Stories {
    static let meta = StoryMeta(title: "Design System/Fixture Button", args: FixtureArgs(), tags: ["autodocs"]) { args in
        Text(args.title)
    }
    static let primary = meta.story()
    static let disabled = primary.extend(name: "Disabled state", tags: ["!test"]) { $0.isEnabled = false }
    static let longTitle = meta.story { $0.title = "Pay £1,234.56" }

    static var all: [StoryEntry<FixtureArgs>] {
        [.init("primary", primary), .init("disabled", disabled), .init("longTitle", longTitle)]
    }
}

/// No explicit title: derived from the module and type name.
enum UntitledWidgetStories: Stories {
    static let meta = StoryMeta(args: FixtureArgs()) { Text($0.title) }
    static let basic = meta.story()
    static var all: [StoryEntry<FixtureArgs>] { [.init("basic", basic)] }
}

@Suite struct StoriesTests {
    @Test func resolvesIdsNamesAndTagsLikeCSF() throws {
        let stories = try FixtureButtonStories.resolve()
        #expect(stories.map(\.id) == [
            "design-system-fixture-button--primary",
            "design-system-fixture-button--disabled",
            "design-system-fixture-button--long-title",
        ])
        // Display name override doesn't change the id; the export name does.
        #expect(stories[1].name == "Disabled state")
        #expect(stories[2].name == "Long Title")
        #expect(stories[0].description.entry.tags == ["dev", "test", "autodocs"])
        #expect(stories[1].description.entry.tags == ["dev", "autodocs"])
        #expect(stories[0].description.entry.importPath == "StorybookTests/StoriesTests.swift")
    }

    @Test func defaultTitleComesFromModuleAndType() throws {
        let story = try #require(try UntitledWidgetStories.resolve().first)
        #expect(story.title == "StorybookTests/Untitled Widget")
        #expect(story.id == "storybooktests-untitled-widget--basic")
    }

    @Test func infersControlsFromArgTypes() {
        let result = ArgTypeInference.argTypes(for: FixtureArgs.self)
        #expect(result.order == ["title", "style", "isEnabled", "rating", "tint", "badge", "onTap", "count"])
        let types = result.argTypes
        #expect(types["title"]?.control?.type == "text")
        #expect(types["style"]?.control?.type == "select")
        #expect(types["style"]?.options == ["primary", "secondary", "destructive"])
        #expect(types["isEnabled"]?.control?.type == "boolean")
        #expect(types["rating"]?.control == ControlSpec(type: "range", min: 0, max: 5, step: 0.5))
        #expect(types["rating"]?.description == "Stars")
        #expect(types["tint"]?.control?.type == "color")
        #expect(types["badge"]?.control?.type == "number")
        #expect(types["badge"]?.type.required == false)
        #expect(types["onTap"]?.action == "onTap")
        #expect(types["internalID"] == nil)
    }

    @Test func argsRoundTripThroughJSON() throws {
        let story = try #require(try FixtureButtonStories.resolve().first)
        let args = story.description.initialArgs
        #expect(args["rating"] == .number(3))
        #expect(args["tint"] == .string("#0A84FF"))
        #expect(args["onTap"] == .string("onTap"))
        let patched = args.merging(patch: .object(["title": .string("Hi"), "badge": .number(2)]))
        let decoded = try patched.decode(FixtureArgs.self)
        #expect(decoded.title == "Hi")
        #expect(decoded.badge == 2)
    }

    @Test func conformanceScanFindsStoriesTypes() {
        let names = ConformanceScanner.storiesTypes().map { String(describing: $0) }
        #expect(names.contains("FixtureButtonStories"))
        #expect(names.contains("UntitledWidgetStories"))
    }

    @MainActor
    @Test func storeRejectsUnknownAndInvalidArgs() throws {
        let store = StoryStore(discovery: .init(stories: try FixtureButtonStories.resolve(), errors: []))
        let id = "design-system-fixture-button--primary"
        try store.updateArgs(id, patch: .object(["title": .string("Hello")]))
        #expect(try store.args(for: id)["title"] == .string("Hello"))
        #expect(throws: RPCError.self) { try store.updateArgs(id, patch: .object(["nope": .bool(true)])) }
        #expect(throws: RPCError.self) { try store.updateArgs(id, patch: .object(["isEnabled": .string("yes")])) }
        // Optionals can be set and cleared, including `@Arg` optionals.
        try store.updateArgs(id, patch: .object(["badge": .number(3), "count": .number(4)]))
        try store.updateArgs(id, patch: .object(["badge": .null, "count": .null]))
        #expect(try store.args(for: id)["count"] == .null)
        try store.resetArgs(id)
        #expect(try store.args(for: id)["title"] == .string("Pay"))
    }
}
