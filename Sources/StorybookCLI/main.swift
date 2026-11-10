import Foundation
import StorybookProtocol

// storybook — drive a running native iOS storybook from the terminal or an agent.
//
//   storybook list                                   # alias for `stories list`
//   storybook stories render <storyId> --args '{"title":"Hi"}' --out pay.png
//   storybook args set <storyId> --args '{"isEnabled":false}'
//   storybook globals set --globals '{"colorScheme":"dark"}'
//   storybook mcp                                    # stdio MCP server
//
// Options: --url ws://host:port[?token=…] (default ws://127.0.0.1:9300)

enum Output {
    static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "\(value)"
    }
}

struct Invocation {
    var url = URL(string: "ws://127.0.0.1:\(defaultAgentPort)")!
    var words: [String] = []
    var flags: [String: String] = [:]

    init(_ arguments: [String]) throws {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                guard let value = iterator.next() else { throw CLIError.usage("Missing value for \(argument)") }
                if name == "url" {
                    guard let parsed = URL(string: value) else { throw CLIError.usage("Invalid --url \(value)") }
                    url = parsed
                } else {
                    flags[name] = value
                }
            } else {
                words.append(argument)
            }
        }
    }
}

let usage = """
    usage: storybook [--url ws://host:port] <toolset> <method> [storyId] [--flag value …]
           storybook list | mcp | help

    \(tools.map { "  \($0.cliWords.joined(separator: " "))".padding(toLength: 22, withPad: " ", startingAt: 0) + $0.summary }.joined(separator: "\n"))

    Flags are the tool's input properties (--storyId, --args, --globals, --tag); JSON values are parsed.
    stories render also takes --out <file.png>.
    """

func run() async throws {
    var invocation = try Invocation(Array(CommandLine.arguments.dropFirst()))
    if invocation.words.first == "list" { invocation.words = ["stories", "list"] }
    guard let first = invocation.words.first, first != "help" else {
        print(usage)
        return
    }

    let client = AgentClient(url: invocation.url)
    defer { client.close() }

    if first == "mcp" {
        await MCPServer(client: client).run()
        return
    }

    guard invocation.words.count >= 2,
          let tool = tools.first(where: { $0.cliWords == Array(invocation.words.prefix(2)) }) else {
        throw CLIError.usage("Unknown command '\(invocation.words.joined(separator: " "))'.\n\n\(usage)")
    }

    // Build params from flags, plus an optional positional story id.
    var params: [String: JSONValue] = [:]
    if invocation.words.count > 2 { params["storyId"] = .string(invocation.words[2]) }
    let output = invocation.flags.removeValue(forKey: "out")
    for (name, raw) in invocation.flags {
        guard tool.properties[name] != nil else {
            throw CLIError.usage("\(tool.cliWords.joined(separator: " ")) has no --\(name). Flags: \(tool.properties.keys.sorted().map { "--\($0)" }.joined(separator: ", "))")
        }
        params[name] = (try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))) ?? .string(raw)
    }

    var result = try await client.call(tool.method, .object(params))

    if tool.method == "stories.render", case .object(var object) = result, let png = object.removeValue(forKey: "png")?.stringValue {
        let path = output ?? "\(params["storyId"]?.stringValue ?? "story").png"
        guard let data = Data(base64Encoded: png) else { throw CLIError.usage("The app returned an invalid PNG.") }
        try data.write(to: URL(fileURLWithPath: path))
        object["file"] = .string(path)
        result = .object(object)
    }
    print(Output.json(result))
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
