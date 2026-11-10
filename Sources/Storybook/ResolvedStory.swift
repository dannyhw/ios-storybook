import SwiftUI
import StorybookProtocol

/// A story with its generics erased, ready to list, describe and render.
public struct ResolvedStory: Sendable, Identifiable {
    public let description: StoryDescription
    public let layout: StoryLayout
    let makeView: @MainActor @Sendable (JSONValue) throws -> AnyView

    public var id: String { description.entry.id }
    public var title: String { description.entry.title }
    public var name: String { description.entry.name }

    /// Renders the story with `args` (a full args object), applying story
    /// then meta decorators.
    @MainActor
    public func view(args: JSONValue) throws -> AnyView {
        try makeView(args)
    }
}

/// Project-wide tags, applied before meta and story tags (Storybook's defaults).
public let defaultProjectTags = ["dev", "test"]

extension Stories {
    /// Resolves every story in `all` into ids, names, tags and argTypes,
    /// using Storybook's rules.
    public static func resolve(projectTags: [String] = defaultProjectTags) throws -> [ResolvedStory] {
        let meta = self.meta
        let title = meta.title ?? defaultTitle(fileID: meta.fileID)
        let inference = ArgTypeInference.argTypes(for: Args.self)
        let storiesType = String(describing: Self.self)

        return try all.map { entry in
            let story = entry.story
            let name = story.name ?? StoryID.storyNameFromExport(entry.exportName)
            // As in CSF: the id comes from the export name, not the display name.
            let id = try StoryID.toId(meta.id ?? title, StoryID.storyNameFromExport(entry.exportName))
            let indexEntry = IndexEntry(
                id: id, title: title, name: name,
                importPath: meta.fileID, exportName: entry.exportName,
                tags: StoryID.combineTags(projectTags + meta.tags + story.tags),
                xIOS: NativeInfo(storiesType: storiesType, line: story.line))
            let description = StoryDescription(
                entry: indexEntry, argTypes: inference.argTypes, argOrder: inference.order,
                initialArgs: try JSONValue.encode(story.args))
            let decorators = story.decorators + meta.decorators
            return ResolvedStory(
                description: description,
                layout: story.layout ?? meta.layout,
                makeView: { json in
                    let args = try json.decode(Args.self)
                    return decorators.reduce(meta.render(args)) { view, decorator in decorator.apply(view) }
                })
        }
    }

    /// `Module/PayButtonStories` → `Module/Pay Button` when no title is given.
    static func defaultTitle(fileID: String) -> String {
        let module = fileID.split(separator: "/").first.map(String.init) ?? "Stories"
        var typeName = String(describing: Self.self)
        if typeName.hasSuffix("Stories"), typeName.count > "Stories".count {
            typeName.removeLast("Stories".count)
        }
        return "\(module)/\(StoryID.toStartCase(typeName))"
    }
}
