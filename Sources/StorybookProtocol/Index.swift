import Foundation

/// Storybook `index.json` v5. Entries use Storybook's field names so
/// Storybook-aware tools and agents can read the manifest unchanged.
public struct StoryIndex: Codable, Sendable, Equatable {
    public var v: Int
    public var entries: [String: IndexEntry]

    public init(entries: [String: IndexEntry]) {
        self.v = 5
        self.entries = entries
    }
}

public struct IndexEntry: Codable, Sendable, Equatable {
    public var type: String
    public var subtype: String
    public var id: String
    public var title: String
    public var name: String
    public var importPath: String
    public var exportName: String
    public var tags: [String]
    /// Native-only fields, namespaced so they never collide with Storybook's.
    public var xIOS: NativeInfo

    public init(id: String, title: String, name: String, importPath: String, exportName: String, tags: [String], xIOS: NativeInfo) {
        self.type = "story"
        self.subtype = "story"
        self.id = id
        self.title = title
        self.name = name
        self.importPath = importPath
        self.exportName = exportName
        self.tags = tags
        self.xIOS = xIOS
    }

    enum CodingKeys: String, CodingKey {
        case type, subtype, id, title, name, importPath, exportName, tags
        case xIOS = "x-ios"
    }
}

public struct NativeInfo: Codable, Sendable, Equatable {
    /// The Swift type that declares the stories, e.g. `PayButtonStories`.
    public var storiesType: String
    public var line: Int

    public init(storiesType: String, line: Int) {
        self.storiesType = storiesType
        self.line = line
    }
}

/// Per-arg metadata in Storybook's `argTypes` shape.
public struct ArgType: Codable, Sendable, Equatable {
    public var name: String
    public var description: String?
    public var control: ControlSpec?
    public var options: [String]?
    /// Set for `StoryAction` args; the value is the action name.
    public var action: String?
    public var type: ArgValueType

    public init(name: String, description: String? = nil, control: ControlSpec? = nil, options: [String]? = nil, action: String? = nil, type: ArgValueType) {
        self.name = name
        self.description = description
        self.control = control
        self.options = options
        self.action = action
        self.type = type
    }
}

public struct ControlSpec: Codable, Sendable, Equatable {
    /// One of Storybook's control types: `text`, `boolean`, `number`, `range`,
    /// `select`, `color`, `object`.
    public var type: String
    public var min: Double?
    public var max: Double?
    public var step: Double?
    public var multiline: Bool?

    public init(type: String, min: Double? = nil, max: Double? = nil, step: Double? = nil, multiline: Bool? = nil) {
        self.type = type
        self.min = min
        self.max = max
        self.step = step
        self.multiline = multiline
    }
}

public struct ArgValueType: Codable, Sendable, Equatable {
    /// `string`, `boolean`, `number`, `enum`, `other`.
    public var name: String
    public var required: Bool

    public init(name: String, required: Bool) {
        self.name = name
        self.required = required
    }
}

/// Everything a client needs to show and drive one story.
public struct StoryDescription: Codable, Sendable, Equatable {
    public var entry: IndexEntry
    public var argTypes: [String: ArgType]
    /// Arg names in declaration order (JSON objects are unordered).
    public var argOrder: [String]
    public var initialArgs: JSONValue

    public init(entry: IndexEntry, argTypes: [String: ArgType], argOrder: [String], initialArgs: JSONValue) {
        self.entry = entry
        self.argTypes = argTypes
        self.argOrder = argOrder
        self.initialArgs = initialArgs
    }
}
