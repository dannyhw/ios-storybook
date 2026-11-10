import Foundation
import Storybook
import StorybookProtocol

/// Discovers stories, restores state from launch arguments and starts the
/// agent server. One per app.
///
/// Launch arguments (also usable from `simctl launch`):
/// - `-StorybookStory <id>`: story to open
/// - `-StorybookArgs '<json>'`: args patch for that story
/// - `-StorybookGlobals '<json>'`: globals, e.g. `{"colorScheme":"dark"}`
/// - `-StorybookPort <port>`: agent server port (default 9300)
/// - `-StorybookToken <token>`: required token (devices generate one if unset)
@MainActor
public final class StorybookSession {
    public let store: StoryStore
    public let server: AgentServer
    public private(set) var serverError: String?

    public static let shared = StorybookSession()

    private init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        store = StoryStore()
        // Read raw arguments: UserDefaults would parse `{…}` values as plists.
        func argument(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: "-\(name)"), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        if let id = argument("StorybookStory") {
            try? store.select(id)
            if let patch = Self.json(argument("StorybookArgs")) {
                try? store.updateArgs(id, patch: patch)
            }
        }
        if let globals = Self.json(argument("StorybookGlobals")),
           let decoded = try? globals.decode(StoryGlobals.self) {
            store.updateGlobals(decoded)
        }

        let port = argument("StorybookPort").flatMap(Int.init) ?? 0
        #if targetEnvironment(simulator)
        let loopbackOnly = true
        let token = argument("StorybookToken")
        #else
        let loopbackOnly = false
        let token = argument("StorybookToken") ?? Self.randomToken()
        #endif
        server = AgentServer(store: store, port: port > 0 ? UInt16(port) : defaultAgentPort, token: token)
        do {
            try server.start(loopbackOnly: loopbackOnly)
        } catch {
            serverError = "\(error)"
        }
    }

    /// The address a CLI should connect to, shown in the app on devices.
    public var connectionURL: String {
        #if targetEnvironment(simulator)
        let host = "127.0.0.1"
        #else
        let host = Self.lanAddress() ?? "<device-ip>"
        #endif
        var url = "ws://\(host):\(server.port)"
        if let token = server.token { url += "?token=\(token)" }
        return url
    }

    private static func json(_ string: String?) -> JSONValue? {
        guard let data = string?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func randomToken() -> String {
        String((0..<8).map { _ in "abcdefghjkmnpqrstuvwxyz23456789".randomElement()! })
    }

    /// The device's Wi-Fi IPv4 address (`en0`).
    static func lanAddress() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = interface.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            }
        }
        return nil
    }
}
