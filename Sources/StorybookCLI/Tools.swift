import Foundation
import StorybookProtocol

/// One toolset method, defined once. Its names on each surface come from
/// `method`, following Storybook 11's toolsets:
/// `stories.render` → CLI `storybook stories render`, MCP `stories-render`.
struct ToolDefinition {
    let method: String
    let summary: String
    /// JSON Schema for the input (MCP `inputSchema`; CLI `--flag` names).
    let properties: [String: JSONValue]
    let required: [String]

    var mcpName: String { method.replacingOccurrences(of: ".", with: "-") }
    var cliWords: [String] { method.split(separator: ".").map(String.init) }

    var inputSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }
}

private func property(_ type: String, _ description: String) -> JSONValue {
    .object(["type": .string(type), "description": .string(description)])
}

private let storyIDProperty = property("string", "Story id, e.g. design-system-pay-button--primary. Defaults to the selected story.")
private let argsProperty = property("object", "Args to merge into the story's current args (JSON merge patch). Keys must be the story's arg names.")
private let globalsProperty = property("object", "Globals to merge: colorScheme (light|dark), dynamicType (xSmall…xxxLarge, accessibility1…5), layoutDirection (leftToRight|rightToLeft), locale. null clears one.")

let tools: [ToolDefinition] = [
    ToolDefinition(method: "stories.list",
                   summary: "List every story with its id, title, name, tags, argTypes and initial args.",
                   properties: ["tag": property("string", "Only stories with this tag.")], required: []),
    ToolDefinition(method: "stories.get",
                   summary: "Describe one story: its argTypes (controls) and current args.",
                   properties: ["storyId": storyIDProperty], required: []),
    ToolDefinition(method: "stories.select",
                   summary: "Show a story in the app's canvas.",
                   properties: ["storyId": storyIDProperty], required: ["storyId"]),
    ToolDefinition(method: "stories.render",
                   summary: "Render a story with optional args and globals and return a PNG of just the component.",
                   properties: ["storyId": storyIDProperty, "args": argsProperty, "globals": globalsProperty,
                                "bleed": property("number", "Points captured around the component so shadows aren't cropped. Default 16; 0 crops to the frame.")],
                   required: ["storyId"]),
    ToolDefinition(method: "args.get",
                   summary: "Get a story's current args.",
                   properties: ["storyId": storyIDProperty], required: []),
    ToolDefinition(method: "args.set",
                   summary: "Merge args into a story's current args; the app re-renders without a rebuild.",
                   properties: ["storyId": storyIDProperty, "args": argsProperty], required: ["args"]),
    ToolDefinition(method: "args.reset",
                   summary: "Reset a story's args to their initial values.",
                   properties: ["storyId": storyIDProperty], required: []),
    ToolDefinition(method: "globals.get",
                   summary: "Get the globals applied to every story.",
                   properties: [:], required: []),
    ToolDefinition(method: "globals.set",
                   summary: "Merge globals (appearance, text size, layout direction, locale) applied to every story.",
                   properties: ["globals": globalsProperty], required: ["globals"]),
    ToolDefinition(method: "actions.list",
                   summary: "List actions (callbacks) the stories have fired, oldest first.",
                   properties: ["storyId": property("string", "Only actions fired while this story was selected.")], required: []),
    ToolDefinition(method: "actions.clear",
                   summary: "Clear the actions log.",
                   properties: [:], required: []),
    ToolDefinition(method: "index.get",
                   summary: "Get the story index in Storybook's index.json v5 format.",
                   properties: [:], required: []),
]
