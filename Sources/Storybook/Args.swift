import Foundation
import Synchronization
import SwiftUI
import StorybookProtocol

/// A story's inputs. `Codable` gives the wire format for `args.set`;
/// `init()` gives the defaults the Controls panel starts from.
public protocol StoryArgs: Codable, Sendable, Equatable {
    init()
}

/// Overrides the control derived from a property's type.
public enum ArgControl: Sendable, Equatable {
    case text(multiline: Bool = false)
    case range(ClosedRange<Double>, step: Double = 1)
    case select
    case color
    case object
    case hidden
}

/// Attaches control metadata to an args property:
/// `@Arg(.range(0...5, step: 0.5)) var rating = 3.0`.
///
/// Encodes as its wrapped value, so the wire format is unchanged.
@propertyWrapper
public struct Arg<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var wrappedValue: Value
    public let control: ArgControl?
    public let description: String?

    public init(wrappedValue: Value, _ control: ArgControl? = nil, description: String? = nil) {
        self.wrappedValue = wrappedValue
        self.control = control
        self.description = description
    }

    public init(from decoder: Decoder) throws {
        wrappedValue = try decoder.singleValueContainer().decode(Value.self)
        control = nil
        description = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.wrappedValue == rhs.wrappedValue }
}

/// Lets `ArgTypeInference` read `@Arg` metadata through `Mirror`.
protocol ArgMetadataProviding {
    var argControl: ArgControl? { get }
    var argDescription: String? { get }
    static var valueType: Any.Type { get }
}

extension Arg: ArgMetadataProviding {
    var argControl: ArgControl? { control }
    var argDescription: String? { description }
    static var valueType: Any.Type { Value.self }
}

/// A color arg. Encodes as `#RRGGBB` or `#RRGGBBAA`.
public struct StoryColor: Codable, Sendable, Equatable, Hashable {
    public var hex: String

    public init(hex: String) { self.hex = hex }
    public static func hex(_ hex: String) -> StoryColor { StoryColor(hex: hex) }

    public init(from decoder: Decoder) throws {
        hex = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    public var rgba: (red: Double, green: Double, blue: Double, alpha: Double) {
        var digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if digits.count == 6 { digits += "FF" }
        let value = UInt64(digits, radix: 16) ?? 0xFF
        return (Double((value >> 24) & 0xFF) / 255, Double((value >> 16) & 0xFF) / 255,
                Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    public var color: Color {
        let c = rgba
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }
}

/// A callback arg. Calls are logged to the Actions panel and streamed to
/// clients. Encodes as its name.
public struct StoryAction: Codable, Sendable, Equatable, Hashable {
    public let name: String

    public init(_ name: String) { self.name = name }

    public init(from decoder: Decoder) throws {
        name = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }

    public func callAsFunction(_ payload: Any...) {
        let description = payload.map { String(describing: $0) }.joined(separator: ", ")
        StoryActionSink.emit(name: name, payload: description)
    }

    /// A closure that logs this action, for components that take `() -> Void`.
    public var handler: @Sendable () -> Void {
        let name = self.name
        return { StoryActionSink.emit(name: name, payload: "") }
    }
}

/// Where `StoryAction` calls go. The runtime installs a handler.
public enum StoryActionSink {
    public typealias Handler = @Sendable (_ name: String, _ payload: String) -> Void
    private static let handler = Mutex<Handler?>(nil)

    public static func install(_ newHandler: Handler?) {
        handler.withLock { $0 = newHandler }
    }

    static func emit(name: String, payload: String) {
        let current = handler.withLock { $0 }
        current?(name, payload)
    }
}
