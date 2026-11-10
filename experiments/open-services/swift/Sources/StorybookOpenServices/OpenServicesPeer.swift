import Foundation
import StorybookProtocol
import StorybookRuntime

/// Joins a Storybook 11 dev server's channel as an Open Services peer.
///
/// It implements the smallest part of the protocol a native runtime needs:
/// - **Responder** for the peer service (`ios/device` or
///   `remote-renderer/peer`): the server registers it without handlers, so
///   its commands are broadcast as `services:command-invoke` and this peer
///   acks and answers them.
/// - **Caller** of the hub service (`ios/bridge` or `remote-renderer/hub`),
///   whose handlers run on the server.
///
/// It never authors state writes and never answers sync requests, so it needs
/// no Lamport clock, version vector or undo log.
@MainActor
public final class OpenServicesPeer {
    /// Service ids and command names this peer speaks.
    public struct Contract: Sendable {
        public var peerService: String
        public var hubService: String
        /// Input key that addresses one peer, since invokes are broadcast.
        public var idKey: String
        public var connected: String
        public var event: String

        /// The web-preview experiment (`storybook-ios`).
        public static let iosBridge = Contract(peerService: "ios/device", hubService: "ios/bridge", idKey: "deviceId", connected: "deviceConnected", event: "deviceEvent")
        /// The headless, framework-neutral contract (`storybook-remote-renderer`).
        public static let remoteRenderer = Contract(peerService: "remote-renderer/peer", hubService: "remote-renderer/hub", idKey: "peerId", connected: "peerConnected", event: "peerEvent")
    }

    public struct Configuration: Sendable {
        /// `ws://host:port/storybook-server-channel?token=…`
        public var url: URL
        public var deviceID: String
        public var deviceName: String
        public var contract: Contract

        public init(url: URL, deviceID: String, deviceName: String, contract: Contract = .iosBridge) {
            self.url = url
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.contract = contract
        }
    }

    public enum State: Equatable, Sendable {
        case connecting, connected, disconnected(String)
    }

    public private(set) var state: State = .connecting {
        didSet { onStateChange?(state) }
    }
    public var onStateChange: ((State) -> Void)?

    private let store: StoryStore
    private let toolset: AgentToolset
    private let configuration: Configuration
    private var contract: Contract { configuration.contract }
    private let runtimeID = "ios-" + UUID().uuidString.prefix(8).lowercased()
    private var socket: URLSessionWebSocketTask?
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var retryDelay: Duration = .milliseconds(500)
    private var heartbeat: Task<Void, Never>?

    public init(store: StoryStore, configuration: Configuration) {
        self.store = store
        self.toolset = AgentToolset(store: store)
        self.configuration = configuration
        let previous = store.onEvent
        store.onEvent = { [weak self] event in
            previous?(event)
            self?.forward(event)
        }
    }

    public func start() {
        state = .connecting
        let socket = URLSession.shared.webSocketTask(with: configuration.url)
        socket.maximumMessageSize = 64 * 1024 * 1024
        self.socket = socket
        socket.resume()
        receive(on: socket)
        Task { await announce() }
    }

    // MARK: Wire

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, socket === self.socket else { return }
                switch result {
                case .success(.string(let text)):
                    self.handle(frame: text)
                    self.receive(on: socket)
                case .success(.data(let data)):
                    self.handle(frame: String(decoding: data, as: UTF8.self))
                    self.receive(on: socket)
                case .success:
                    self.receive(on: socket)
                case .failure(let error):
                    self.reconnect(after: error)
                }
            }
        }
    }

    private func reconnect(after error: Error) {
        state = .disconnected(error.localizedDescription)
        socket = nil
        heartbeat?.cancel()
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
        pending.removeAll()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, .seconds(5))
        Task {
            try? await Task.sleep(for: delay)
            start()
        }
    }

    /// Storybook channel frames are `{ type, args: [payload], from }`.
    private func emit(_ type: String, _ payload: JSONValue) {
        let frame: JSONValue = .object(["type": .string(type), "args": .array([payload]), "from": .string(runtimeID)])
        guard let data = try? JSONEncoder().encode(frame) else { return }
        socket?.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private func handle(frame text: String) {
        guard let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
              let type = frame["type"]?.stringValue else { return }
        let payload: JSONValue = if case .array(let args) = frame["args"], let first = args.first { first } else { .null }

        switch type {
        case "ping":
            emit("pong", .null)
        case "services:command-invoke":
            invoked(payload)
        case "services:command-result":
            settle(payload, with: .success(payload["result"] ?? .null))
        case "services:command-error":
            let message = payload["error"]?["message"]?.stringValue ?? "Remote command failed"
            settle(payload, with: .failure(RPCError(code: "remote-error", message: message)))
        case "services:command-unhandled":
            settle(payload, with: .failure(RPCError(code: "unhandled", message: "No runtime handled the command.")))
        default:
            break
        }
    }

    // MARK: Responder (peer service)

    private func invoked(_ payload: JSONValue) {
        guard payload["serviceId"]?.stringValue == contract.peerService,
              let callID = payload["callId"]?.stringValue,
              let command = payload["commandName"]?.stringValue else { return }
        let input = payload["input"] ?? .object([:])
        // Invokes are broadcast to every peer; only the addressed device answers.
        if let target = input[contract.idKey]?.stringValue, target != configuration.deviceID { return }

        let reply: JSONValue = .object(["serviceId": .string(contract.peerService), "callId": .string(callID), "runtimeId": .string(runtimeID)])
        // The caller rejects the call if no ack arrives within 300 ms.
        emit("services:command-ack", reply)
        Task {
            do {
                let result = try await perform(command, input)
                emit("services:command-result", reply.merging(patch: .object(["result": result])))
            } catch {
                let serialized: JSONValue = .object([
                    "__openServiceError__": .bool(true),
                    "name": .string("IOSDeviceError"),
                    "message": .string("\(error)"),
                ])
                emit("services:command-error", reply.merging(patch: .object(["error": serialized])))
            }
        }
    }

    /// Maps each peer command onto the app's existing toolset.
    private func perform(_ command: String, _ input: JSONValue) async throws -> JSONValue {
        switch command {
        case "describe": return try describe()
        case "render": return try await toolset.handle(method: "stories.render", params: input)
        case "select": return try await toolset.handle(method: "stories.select", params: input)
        case "getArgs": return try await toolset.handle(method: "args.get", params: input)
        case "setArgs": return try await toolset.handle(method: "args.set", params: input)
        case "resetArgs": return try await toolset.handle(method: "args.reset", params: input)
        case "setGlobals": return try await toolset.handle(method: "globals.set", params: input)
        case "listActions": return try await toolset.handle(method: "actions.list", params: input)
        default: throw RPCError(code: "unknown-command", message: "\(contract.peerService) has no command '\(command)'.")
        }
    }

    private func describe() throws -> JSONValue {
        .object([
            contract.idKey: .string(configuration.deviceID),
            "name": .string(configuration.deviceName),
            "platform": .string("ios"),
            "osVersion": .string(ProcessInfo.processInfo.operatingSystemVersionString),
            "selected": store.selectedID.map(JSONValue.string) ?? .null,
            "globals": try JSONValue.encode(store.globals),
            "stories": try JSONValue.encode(store.stories.map(\.description)),
        ])
    }

    // MARK: Caller (hub service)

    private func call(_ command: String, _ input: JSONValue) async throws -> JSONValue {
        let callID = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pending[callID] = continuation
            emit("services:command-invoke", .object([
                "serviceId": .string(contract.hubService),
                "commandName": .string(command),
                "input": input,
                "callId": .string(callID),
                "runtimeId": .string(runtimeID),
            ]))
            Task {
                try? await Task.sleep(for: .seconds(10))
                settle(.object(["callId": .string(callID)]), with: .failure(RPCError(code: "timeout", message: "\(command) timed out")))
            }
        }
    }

    private func settle(_ payload: JSONValue, with result: Result<JSONValue, Error>) {
        guard let callID = payload["callId"]?.stringValue, let continuation = pending.removeValue(forKey: callID) else { return }
        continuation.resume(with: result)
    }

    /// Registers this device with the server, then keeps the registration
    /// fresh so the server can expire devices that vanish.
    private func announce() async {
        do {
            _ = try await call(contract.connected, describe())
            state = .connected
            retryDelay = .milliseconds(500)
            heartbeat?.cancel()
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard let self else { return }
                    _ = try? await self.call("heartbeat", .object([self.contract.idKey: .string(self.configuration.deviceID)]))
                }
            }
        } catch {
            state = .disconnected("\(error)")
        }
    }

    /// Store changes (actions, args, selection) go to the server, which turns
    /// them into service state and Storybook channel events.
    private func forward(_ event: RPCEvent) {
        guard state == .connected else { return }
        let input: JSONValue = .object([
            contract.idKey: .string(configuration.deviceID),
            "event": .string(event.event),
            "data": event.data,
        ])
        Task { _ = try? await call(contract.event, input) }
    }
}
