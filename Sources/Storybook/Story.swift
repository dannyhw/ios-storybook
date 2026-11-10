import SwiftUI
import StorybookProtocol

/// How the canvas sizes a story (Storybook's `parameters.layout`).
public enum StoryLayout: String, Codable, Sendable {
    /// Centered at its ideal size.
    case centered
    /// Full width with padding, top-aligned.
    case padded
    /// Fills the canvas.
    case fullscreen
}

/// Wraps a rendered story. Story decorators sit innermost, then meta
/// decorators, as in CSF.
public struct StoryDecorator: Sendable {
    let apply: @MainActor @Sendable (AnyView) -> AnyView

    public init<V: View>(_ apply: @escaping @MainActor @Sendable (AnyView) -> V) {
        self.apply = { AnyView(apply($0)) }
    }

    public static func padding(_ length: CGFloat = 16) -> StoryDecorator {
        StoryDecorator { $0.padding(length) }
    }

    public static func background(_ color: Color) -> StoryDecorator {
        StoryDecorator { $0.background(color) }
    }

    public static func frame(width: CGFloat? = nil, height: CGFloat? = nil) -> StoryDecorator {
        StoryDecorator { $0.frame(width: width, height: height) }
    }

    public static func colorScheme(_ scheme: ColorScheme) -> StoryDecorator {
        StoryDecorator { $0.environment(\.colorScheme, scheme) }
    }
}

/// File-level defaults for a set of stories (CSF's default export / `meta`).
public struct StoryMeta<Args: StoryArgs>: Sendable {
    public let title: String?
    public let id: String?
    public let args: Args
    public let decorators: [StoryDecorator]
    public let layout: StoryLayout
    public let tags: [String]
    public let fileID: String
    public let line: Int
    let render: @MainActor @Sendable (Args) -> AnyView

    public init<V: View>(
        title: String? = nil,
        id: String? = nil,
        args: Args = Args(),
        decorators: [StoryDecorator] = [],
        layout: StoryLayout = .centered,
        tags: [String] = [],
        fileID: String = #fileID,
        line: Int = #line,
        @ViewBuilder render: @escaping @MainActor @Sendable (Args) -> V
    ) {
        self.title = title
        self.id = id
        self.args = args
        self.decorators = decorators
        self.layout = layout
        self.tags = tags
        self.fileID = fileID
        self.line = line
        self.render = { AnyView(render($0)) }
    }

    /// A story: the meta's args, modified by `args`.
    public func story(
        name: String? = nil,
        args modify: (inout Args) -> Void = { _ in },
        decorators: [StoryDecorator] = [],
        layout: StoryLayout? = nil,
        tags: [String] = [],
        line: Int = #line
    ) -> Story<Args> {
        var storyArgs = args
        modify(&storyArgs)
        return Story(meta: self, name: name, args: storyArgs, decorators: decorators, layout: layout, tags: tags, line: line)
    }
}

/// One named state of a component (a CSF story).
public struct Story<Args: StoryArgs>: Sendable {
    public let meta: StoryMeta<Args>
    public let name: String?
    public let args: Args
    public let decorators: [StoryDecorator]
    public let layout: StoryLayout?
    public let tags: [String]
    public let line: Int

    /// A new story based on this one (CSF Next's `.extend`). Args are
    /// modified in place; decorators and tags are appended.
    public func extend(
        name: String? = nil,
        decorators: [StoryDecorator] = [],
        layout: StoryLayout? = nil,
        tags: [String] = [],
        line: Int = #line,
        _ modify: (inout Args) -> Void = { _ in }
    ) -> Story<Args> {
        var newArgs = args
        modify(&newArgs)
        return Story(meta: meta, name: name, args: newArgs, decorators: self.decorators + decorators,
                     layout: layout ?? self.layout, tags: self.tags + tags, line: line)
    }
}

/// A story plus the member name it's declared as. The member name is the
/// CSF export name, so it determines the story id.
public struct StoryEntry<Args: StoryArgs>: Sendable {
    public let exportName: String
    public let story: Story<Args>

    public init(_ exportName: String, _ story: Story<Args>) {
        self.exportName = exportName
        self.story = story
    }
}

/// A type that declares stories, usually a caseless `enum`:
///
/// ```swift
/// enum PayButtonStories: Stories {
///     static let meta = StoryMeta(args: PayButtonArgs()) { PayButton($0) }
///     static let primary = meta.story()
///     static var all: [StoryEntry<PayButtonArgs>] { [.init("primary", primary)] }
/// }
/// ```
///
/// Conforming types are discovered at runtime; no registration is needed.
public protocol Stories {
    associatedtype Args: StoryArgs
    static var meta: StoryMeta<Args> { get }
    /// Every story, keyed by member name. A future `@Stories` macro generates this.
    static var all: [StoryEntry<Args>] { get }
}
