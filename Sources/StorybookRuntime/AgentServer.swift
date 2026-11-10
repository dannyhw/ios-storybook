import Foundation
import Network
import Storybook
import StorybookProtocol

/// A WebSocket server inside the app. The Mac CLI connects to it rather
/// than the app connecting out, so devices need no local-network prompt.
///
/// - Simulator: listens on loopback only, no token needed.
/// - Device: listens on all interfaces and every request must carry the
///   token shown in the app.
@MainActor
public final class AgentServer {
    public let port: UInt16
    public let token: String?
    public private(set) var state: String = "stopped"

    private let toolset: AgentToolset
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "storybook.agent-server")

    public init(store: StoryStore, port: UInt16, token: String?) {
        self.port = port
        self.token = token
        self.toolset = AgentToolset(store: store)
        store.onEvent = { [weak self] event in self?.broadcast(event) }
    }

    public func start(loopbackOnly: Bool) throws {
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 64 * 1024 * 1024
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        if loopbackOnly {
            parameters.requiredInterfaceType = .loopback
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RPCError(code: "invalid-port", message: "Invalid port \(port)")
        }
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in self?.state = "\(newState)" }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .failed, .cancelled:
                Task { @MainActor in self?.connections[key] = nil }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if error != nil {
                connection.cancel()
                return
            }
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty { await self.handle(data, from: connection) }
                self.receive(on: connection)
            }
        }
    }

    private func handle(_ data: Data, from connection: NWConnection) async {
        let request: RPCRequest
        do {
            request = try JSONDecoder().decode(RPCRequest.self, from: data)
        } catch {
            send(RPCResponse(id: -1, error: RPCError(code: "bad-request", message: "\(error)")), to: connection)
            return
        }
        if let token, request.token != token {
            send(RPCResponse(id: request.id, error: RPCError(code: "unauthorized", message: "Missing or wrong token.")), to: connection)
            return
        }
        do {
            let result = try await toolset.handle(method: request.method, params: request.params)
            send(RPCResponse(id: request.id, result: result), to: connection)
        } catch let error as RPCError {
            send(RPCResponse(id: request.id, error: error), to: connection)
        } catch {
            send(RPCResponse(id: request.id, error: RPCError(code: "failed", message: "\(error)")), to: connection)
        }
    }

    private func broadcast(_ event: RPCEvent) {
        for connection in connections.values {
            send(event, to: connection)
        }
    }

    private func send<T: Encodable>(_ message: T, to connection: NWConnection) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}
