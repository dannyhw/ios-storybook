import Foundation
import StorybookProtocol

/// Connects to a running storybook app's agent server.
final class AgentClient: @unchecked Sendable {
    let url: URL
    private let token: String?
    private let task: URLSessionWebSocketTask
    private var nextID = 1

    /// `url` may carry `?token=…`, as shown in the app's Connect sheet.
    init(url: URL) {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        token = components?.queryItems?.first { $0.name == "token" }?.value
        components?.queryItems = nil
        self.url = components?.url ?? url
        task = URLSession.shared.webSocketTask(with: self.url)
        task.maximumMessageSize = 64 * 1024 * 1024
        task.resume()
    }

    func call(_ method: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let request = RPCRequest(id: id, method: method, params: params, token: token)
        let data = try JSONEncoder().encode(request)
        do {
            try await task.send(.string(String(decoding: data, as: UTF8.self)))
        } catch {
            throw CLIError.notConnected(url, error)
        }
        // Skip events until our response arrives.
        while true {
            let message = try await task.receive()
            let payload: Data
            switch message {
            case .string(let text): payload = Data(text.utf8)
            case .data(let data): payload = data
            @unknown default: continue
            }
            guard let response = try? JSONDecoder().decode(RPCResponse.self, from: payload), response.id == id else { continue }
            if let error = response.error { throw error }
            return response.result ?? .null
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

enum CLIError: Error, CustomStringConvertible {
    case notConnected(URL, Error)
    case usage(String)

    var description: String {
        switch self {
        case .notConnected(let url, let error):
            """
            Couldn't reach a storybook app at \(url) (\(error.localizedDescription)).
            Is the app running? On the simulator: xcrun simctl launch booted <bundle-id>.
            On a device, pass the address from the app's Connect sheet with --url.
            """
        case .usage(let message):
            message
        }
    }
}
