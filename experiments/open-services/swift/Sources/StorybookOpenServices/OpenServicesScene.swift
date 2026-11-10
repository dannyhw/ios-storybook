import SwiftUI
import StorybookRuntime
import StorybookUI

/// `StorybookScene` plus an Open Services connection to a Storybook dev
/// server. The server URL comes from `-StorybookServer ws://…?token=…`, which
/// the `storybook-ios` preset prints and passes when it launches the app.
public struct OpenServicesScene: Scene {
    public init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-StorybookServer"), index + 1 < arguments.count,
           let url = URL(string: arguments[index + 1]) {
            let peer = OpenServicesPeer(
                store: StorybookSession.shared.store,
                configuration: .init(
                    url: url, deviceID: Self.deviceID, deviceName: Self.deviceName,
                    contract: Self.argument("-StorybookContract") == "remote-renderer" ? .remoteRenderer : .iosBridge
                )
            )
            peer.start()
            Self.peer = peer
        }
    }

    @MainActor private static var peer: OpenServicesPeer?

    private static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    public var body: some Scene {
        StorybookScene()
    }

    private static var deviceID: String {
        ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? UIDevice.current.identifierForVendor?.uuidString ?? "ios-device"
    }

    private static var deviceName: String {
        ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? UIDevice.current.name
    }
}
