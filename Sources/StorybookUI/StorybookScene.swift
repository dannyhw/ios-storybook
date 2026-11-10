#if canImport(UIKit)
import SwiftUI
import Storybook
import StorybookRuntime

/// The whole storybook app as a scene:
///
/// ```swift
/// @main struct AppStorybook: App {
///     var body: some Scene { StorybookScene() }
/// }
/// ```
public struct StorybookScene: Scene {
    public init() {}

    public var body: some Scene {
        WindowGroup {
            StorybookRootView(session: .shared)
        }
    }
}

enum BrowserSheet: String, Identifiable {
    case stories, addons
    var id: String { rawValue }
}

/// The browser, laid out like React Native Storybook: the story fills the
/// screen, a bottom bar names it, and the story list and addons open as
/// sheets. The addons sheet doesn't block the canvas, so you can tap the
/// story while tweaking its controls; the canvas re-centres the story in
/// whatever space the sheet leaves.
public struct StorybookRootView: View {
    let session: StorybookSession
    @State private var sheet: BrowserSheet?
    @State private var addonsTab = AddonsTab.controls
    @State private var addonsDetent = AddonsSheet.defaultDetent
    /// Heights of the bottom chrome, measured from the bottom of the screen.
    @State private var barHeight: CGFloat = 0
    @State private var addonsHeight: CGFloat = 0

    public init(session: StorybookSession) {
        self.session = session
    }

    private var store: StoryStore { session.store }

    public var body: some View {
        GeometryReader { proxy in
            StoryCanvas(store: store, contentInsets: canvasInsets(proxy))
                .ignoresSafeArea()
        }
        .overlay(alignment: .bottom) {
            BrowserBar(store: store, onStories: { sheet = .stories }, onAddons: { sheet = .addons })
                // Sheets cover the bar; hide it so it doesn't show through their glass.
                .opacity(sheet == nil ? 1 : 0)
                .allowsHitTesting(sheet == nil)
                .animation(.easeInOut(duration: 0.2), value: sheet)
                .background {
                    Color.clear
                        .ignoresSafeArea(edges: .bottom)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
                }
        }
        .sheet(item: $sheet) { kind in
            switch kind {
            case .stories:
                StoriesSheet(session: session, onDone: { sheet = nil })
            case .addons:
                AddonsSheet(store: store, tab: $addonsTab, detent: $addonsDetent,
                            onStories: { sheet = .stories }, onClose: { sheet = nil })
                    .background {
                        Color.clear
                            .ignoresSafeArea()
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { addonsHeight = $0 }
                    }
                    .onDisappear { addonsHeight = 0 }
            }
        }
        // Picking a story (in the list or from an agent) shows it.
        .onChange(of: store.selectedID) {
            if sheet == .stories { sheet = nil }
        }
    }

    private func canvasInsets(_ proxy: GeometryProxy) -> EdgeInsets {
        let safe = proxy.safeAreaInsets
        let screenHeight = proxy.size.height + safe.top + safe.bottom
        // Keep some canvas visible even when the sheet is fully expanded.
        let bottom = min(max(barHeight, addonsHeight, safe.bottom), screenHeight - safe.top - 120)
        return EdgeInsets(top: safe.top, leading: safe.leading, bottom: bottom, trailing: safe.trailing)
    }
}

/// The floating bar under the canvas: the current story (tap for the list),
/// globals and the addons toggle.
struct BrowserBar: View {
    let store: StoryStore
    let onStories: () -> Void
    let onAddons: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onStories) {
                HStack(spacing: 12) {
                    Image(systemName: "sidebar.left")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.selected.map { $0.title.replacingOccurrences(of: "/", with: " / ") } ?? "Storybook")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(store.selected?.name ?? "No story selected")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 18)
                .frame(maxWidth: .infinity, minHeight: 56)
                .contentShape(.rect)
            }
            .accessibilityLabel("Stories")
            .accessibilityValue(store.selected?.name ?? "")

            GlobalsMenu(store: store)
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 48, height: 56)
            Button(action: onAddons) {
                Label("Addons", systemImage: "slider.horizontal.below.rectangle")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 48, height: 56)
                    .contentShape(.rect)
            }
            .padding(.trailing, 6)
        }
        .buttonStyle(.plain)
        .browserBarBackground()
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}

private extension View {
    @ViewBuilder func browserBarBackground() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .capsule)
        } else {
            background(.regularMaterial, in: .capsule)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
    }
}
#endif
