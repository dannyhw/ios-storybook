import CoreGraphics
import Foundation
import StorybookProtocol

/// Derives Storybook-shaped `argTypes` from an args struct's stored
/// properties, using `Mirror` over a default instance.
public enum ArgTypeInference {
    public struct Result: Sendable {
        public var argTypes: [String: ArgType]
        public var order: [String]
    }

    public static func argTypes<Args: StoryArgs>(for type: Args.Type) -> Result {
        var argTypes: [String: ArgType] = [:]
        var order: [String] = []
        for child in Mirror(reflecting: Args()).children {
            guard var name = child.label else { continue }
            var valueType: Any.Type = Swift.type(of: child.value)
            var override: ArgControl?
            var description: String?
            if let metadata = child.value as? ArgMetadataProviding {
                // Property wrappers appear as `_name` in the mirror.
                if name.hasPrefix("_") { name.removeFirst() }
                override = metadata.argControl
                description = metadata.argDescription
                valueType = Swift.type(of: metadata).valueType
            }
            if override == .hidden { continue }
            order.append(name)
            argTypes[name] = argType(name: name, valueType: valueType, override: override, description: description)
        }
        return Result(argTypes: argTypes, order: order)
    }

    static func argType(name: String, valueType: Any.Type, override: ArgControl?, description: String?) -> ArgType {
        var required = true
        var type = valueType
        if let optional = type as? any OptionalProtocol.Type {
            required = false
            type = optional.wrappedType
        }

        var argType = ArgType(name: name, description: description, type: ArgValueType(name: "other", required: required))
        switch type {
        case is String.Type:
            argType.type.name = "string"
            argType.control = ControlSpec(type: "text")
        case is Bool.Type:
            argType.type.name = "boolean"
            argType.control = ControlSpec(type: "boolean")
        case is Int.Type, is Double.Type, is Float.Type, is CGFloat.Type:
            argType.type.name = "number"
            argType.control = ControlSpec(type: "number", step: type is Int.Type ? 1 : nil)
        case is StoryColor.Type:
            argType.control = ControlSpec(type: "color")
        case is StoryAction.Type:
            argType.action = name
        default:
            if let enumType = type as? any (CaseIterable & Encodable).Type {
                argType.type.name = "enum"
                argType.options = caseNames(enumType)
                argType.control = ControlSpec(type: "select")
            } else {
                argType.control = ControlSpec(type: "object")
            }
        }

        switch override {
        case .text(let multiline)?:
            argType.control = ControlSpec(type: "text", multiline: multiline ? true : nil)
        case .range(let range, let step)?:
            argType.control = ControlSpec(type: "range", min: range.lowerBound, max: range.upperBound, step: step)
        case .select?:
            argType.control = ControlSpec(type: "select")
        case .color?:
            argType.control = ControlSpec(type: "color")
        case .object?:
            argType.control = ControlSpec(type: "object")
        case .hidden?, nil:
            break
        }
        return argType
    }

    private static func caseNames<T: CaseIterable & Encodable>(_ type: T.Type) -> [String] {
        type.allCases.compactMap { value in
            guard let json = try? JSONValue.encode(value) else { return nil }
            switch json {
            case .string(let string): return string
            case .number(let number): return String(number)
            default: return nil
            }
        }
    }
}

/// Exposes `Optional`'s wrapped type to runtime inference.
protocol OptionalProtocol {
    static var wrappedType: Any.Type { get }
}

extension Optional: OptionalProtocol {
    static var wrappedType: Any.Type { Wrapped.self }
}
