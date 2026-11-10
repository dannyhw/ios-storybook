import Foundation
import StorybookProtocol

/// A stdio MCP server (newline-delimited JSON-RPC 2.0) that relays tool
/// calls to the running app. Tools come from the same `tools` table as the
/// CLI.
struct MCPServer {
    let client: AgentClient

    func run() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let message = try? JSONDecoder().decode(JSONValue.self, from: data) else { continue }
            let id = message["id"]
            let method = message["method"]?.stringValue ?? ""
            // Notifications (no id) need no reply.
            guard let id, id != .null else { continue }
            do {
                let result = try await handle(method: method, params: message["params"] ?? .object([:]))
                write(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
            } catch {
                write(.object(["jsonrpc": .string("2.0"), "id": id,
                               "error": .object(["code": .number(-32603), "message": .string("\(error)")])]))
            }
        }
    }

    private func handle(method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "initialize":
            return .object([
                "protocolVersion": params["protocolVersion"] ?? .string("2025-06-18"),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("ios-storybook"), "version": .string("0.1.0")]),
                "instructions": .string("""
                    Drives a native iOS storybook running in a simulator or on a device. \
                    Call stories-list first to get story ids and their argTypes, then stories-render \
                    with args to see a component in a given state.
                    """),
            ])
        case "ping":
            return .object([:])
        case "tools/list":
            return .object(["tools": .array(tools.map { tool in
                .object(["name": .string(tool.mcpName), "description": .string(tool.summary), "inputSchema": tool.inputSchema])
            })])
        case "tools/call":
            return await callTool(name: params["name"]?.stringValue ?? "", arguments: params["arguments"] ?? .object([:]))
        default:
            throw RPCError(code: "method-not-found", message: "Unknown MCP method \(method)")
        }
    }

    /// Tool failures are results with `isError`, so the model can read them.
    private func callTool(name: String, arguments: JSONValue) async -> JSONValue {
        guard let tool = tools.first(where: { $0.mcpName == name }) else {
            return errorResult("Unknown tool \(name)")
        }
        do {
            var result = try await client.call(tool.method, arguments)
            if tool.method == "stories.render", case .object(var object) = result, let png = object.removeValue(forKey: "png") {
                result = .object(object)
                return .object([
                    "content": .array([
                        .object(["type": .string("image"), "data": png, "mimeType": .string("image/png")]),
                        .object(["type": .string("text"), "text": .string(Output.json(result))]),
                    ]),
                ])
            }
            return .object([
                "content": .array([.object(["type": .string("text"), "text": .string(Output.json(result))])]),
                "structuredContent": result.objectValue != nil ? result : .object(["result": result]),
            ])
        } catch {
            return errorResult("\(error)")
        }
    }

    private func errorResult(_ message: String) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(message)])]), "isError": .bool(true)])
    }

    private func write(_ message: JSONValue) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
