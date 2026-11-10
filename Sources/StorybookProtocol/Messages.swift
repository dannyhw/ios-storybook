import Foundation

/// Default port the in-app agent server listens on.
public let defaultAgentPort: UInt16 = 9300

/// Client → app. `method` is a dotted toolset method such as `stories.render`.
public struct RPCRequest: Codable, Sendable {
    public var id: Int
    public var method: String
    public var params: JSONValue
    public var token: String?

    public init(id: Int, method: String, params: JSONValue = .object([:]), token: String? = nil) {
        self.id = id
        self.method = method
        self.params = params
        self.token = token
    }
}

/// App → client, one per request.
public struct RPCResponse: Codable, Sendable {
    public var id: Int
    public var result: JSONValue?
    public var error: RPCError?

    public init(id: Int, result: JSONValue) {
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: Int, error: RPCError) {
        self.id = id
        self.result = nil
        self.error = error
    }
}

public struct RPCError: Codable, Sendable, Error, CustomStringConvertible {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code): \(message)" }

    public static func unknownStory(_ id: String) -> RPCError {
        RPCError(code: "unknown-story", message: "No story with id '\(id)'. Call stories.list to see available ids.")
    }
}

/// App → client, unsolicited (`storyRendered`, `actionFired`, `argsChanged`).
public struct RPCEvent: Codable, Sendable {
    public var event: String
    public var data: JSONValue

    public init(event: String, data: JSONValue) {
        self.event = event
        self.data = data
    }
}

/// One logged call of a `StoryAction`.
public struct ActionEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var storyId: String?
    public var name: String
    public var payload: String
    public var timestamp: Date

    public init(id: Int, storyId: String?, name: String, payload: String, timestamp: Date) {
        self.id = id
        self.storyId = storyId
        self.name = name
        self.payload = payload
        self.timestamp = timestamp
    }
}

/// Toolbar state applied to every story (Storybook "globals").
public struct StoryGlobals: Codable, Sendable, Equatable {
    /// `light` or `dark`; nil follows the system.
    public var colorScheme: String?
    /// A `DynamicTypeSize` case name, e.g. `large`, `accessibility3`.
    public var dynamicType: String?
    /// `leftToRight` or `rightToLeft`.
    public var layoutDirection: String?
    /// A locale identifier, e.g. `ar`, `en_GB`.
    public var locale: String?

    public init(colorScheme: String? = nil, dynamicType: String? = nil, layoutDirection: String? = nil, locale: String? = nil) {
        self.colorScheme = colorScheme
        self.dynamicType = dynamicType
        self.layoutDirection = layoutDirection
        self.locale = locale
    }
}
