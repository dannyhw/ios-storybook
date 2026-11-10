#if canImport(UIKit)
import SwiftUI
import StorybookProtocol
import StorybookRuntime

enum AddonsTab: String, CaseIterable {
    case controls = "Controls"
    case actions = "Actions"
}

/// Controls and Actions in a sheet that leaves the canvas live: taps reach
/// the story, and the sheet only closes from its close button. Dragging
/// down parks it at a small detent instead of dismissing it.
struct AddonsSheet: View {
    let store: StoryStore
    @Binding var tab: AddonsTab
    @Binding var detent: PresentationDetent
    let onStories: () -> Void
    let onClose: () -> Void

    static let collapsedDetent = PresentationDetent.height(76)
    static let defaultDetent = PresentationDetent.fraction(0.45)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Picker("Addon", selection: $tab) {
                    ForEach(AddonsTab.allCases, id: \.self) { tab in
                        Text(tab == .actions && !store.actions.isEmpty ? "Actions (\(store.actions.count))" : tab.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                Spacer(minLength: 8)
                Button(action: onStories) {
                    Label("Stories", systemImage: "sidebar.left").frame(width: 40, height: 40)
                }
                Button(action: onClose) {
                    Label("Close addons", systemImage: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.title2)
                        .frame(width: 40, height: 40)
                }
                .tint(.secondary)
            }
            .labelStyle(.iconOnly)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 6)

            switch tab {
            case .controls: ControlsPanel(store: store)
            case .actions: ActionsPanel(store: store)
            }
        }
        .presentationDetents([Self.collapsedDetent, Self.defaultDetent, .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled)
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
    }
}

/// Toolbar state applied to every story.
struct GlobalsMenu: View {
    let store: StoryStore

    private static let dynamicTypes = ["xSmall", "small", "medium", "large", "xLarge", "xxLarge", "xxxLarge",
                                       "accessibility1", "accessibility2", "accessibility3", "accessibility4", "accessibility5"]
    private static let locales = ["en", "de", "ar", "ja"]

    private func update(_ change: (inout StoryGlobals) -> Void) {
        var globals = store.globals
        change(&globals)
        store.updateGlobals(globals)
    }

    var body: some View {
        Menu {
            Picker("Appearance", selection: Binding(get: { store.globals.colorScheme }, set: { v in update { $0.colorScheme = v } })) {
                Text("System").tag(String?.none)
                Text("Light").tag(String?.some("light"))
                Text("Dark").tag(String?.some("dark"))
            }
            Picker("Text size", selection: Binding(get: { store.globals.dynamicType }, set: { v in update { $0.dynamicType = v } })) {
                Text("System").tag(String?.none)
                ForEach(Self.dynamicTypes, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .pickerStyle(.menu)
            Picker("Locale", selection: Binding(get: { store.globals.locale }, set: { v in update { $0.locale = v } })) {
                Text("System").tag(String?.none)
                ForEach(Self.locales, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .pickerStyle(.menu)
            Toggle("Right to left", isOn: Binding(get: { store.globals.layoutDirection == "rightToLeft" },
                                                  set: { on in update { $0.layoutDirection = on ? "rightToLeft" : nil } }))
        } label: {
            Label("Globals", systemImage: "circle.lefthalf.filled")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
        }
    }
}

struct ActionsPanel: View {
    let store: StoryStore

    var body: some View {
        List {
            ForEach(store.actions.reversed()) { action in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(action.name).font(.body.monospaced().bold())
                        Spacer()
                        Text(action.timestamp, format: .dateTime.hour().minute().second())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !action.payload.isEmpty {
                        Text(action.payload).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if store.actions.isEmpty {
                Text("Actions fired by the story appear here.").foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !store.actions.isEmpty {
                Button("Clear actions", role: .destructive) { store.clearActions() }
                    .buttonStyle(.bordered)
                    .padding(.bottom, 8)
            }
        }
    }
}

/// Shows how to connect the CLI, with a QR code on devices.
struct ConnectionButton: View {
    let session: StorybookSession
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: { Label("Connect", systemImage: "antenna.radiowaves.left.and.right") }
            .sheet(isPresented: $showing) {
                VStack(spacing: 16) {
                    Text("Connect the CLI").font(.headline)
                    if let qr = QRCode.image(for: session.connectionURL) {
                        Image(uiImage: qr).interpolation(.none).resizable().frame(width: 200, height: 200)
                    }
                    Text("storybook --url '\(session.connectionURL)' list")
                        .font(.caption.monospaced()).textSelection(.enabled).multilineTextAlignment(.center)
                    Text("Server: \(session.serverError ?? session.server.state)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
                .presentationDetents([.medium])
            }
    }
}
#endif
