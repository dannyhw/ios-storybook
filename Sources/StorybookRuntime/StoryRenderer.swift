#if canImport(UIKit)
import Observation
import SwiftUI
import UIKit
import Storybook
import StorybookProtocol

/// Hosts the selected story in a `UIHostingController`, sizes it per its
/// layout, applies globals as trait overrides (so they reach UIKit and
/// SwiftUI content alike) and captures PNGs.
@MainActor
public final class StoryHostViewController: UIViewController {
    /// The canvas currently on screen; agent renders capture from it.
    public private(set) static weak var current: StoryHostViewController?

    private let store: StoryStore
    private let hosting = UIHostingController(rootView: AnyView(EmptyView()))
    private var layout: StoryLayout = .centered
    private static let padding: CGFloat = 16

    /// Parts of the canvas covered by browser chrome (status bar, bottom bar,
    /// the addons sheet). Stories lay out in the rest; the background still
    /// fills the whole canvas.
    public var contentInsets: UIEdgeInsets = .zero {
        didSet { if oldValue != contentInsets { view.setNeedsLayout() } }
    }

    public init(store: StoryStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        // The canvas takes the story's appearance; the story itself is transparent.
        view.backgroundColor = .systemBackground
        view.clipsToBounds = true
        hosting.view.backgroundColor = .clear
        // The canvas already lays stories out clear of the chrome.
        hosting.safeAreaRegions = []
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        observeStore()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Self.current = self
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let area = view.bounds.inset(by: contentInsets)
        guard area.width > 0, area.height > 0 else { return }
        switch layout {
        case .fullscreen:
            hosting.view.frame = area
        case .centered:
            let fit = hosting.sizeThatFits(in: area.size)
            let size = CGSize(width: min(fit.width, area.width), height: min(fit.height, area.height))
            hosting.view.frame = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                                        width: size.width, height: size.height).integral
        case .padded:
            let inner = area.insetBy(dx: Self.padding, dy: Self.padding)
            let fit = hosting.sizeThatFits(in: inner.size)
            hosting.view.frame = CGRect(x: inner.minX, y: inner.minY, width: inner.width,
                                        height: min(fit.height, inner.height)).integral
        }
    }

    // MARK: Rendering

    /// Re-renders whenever anything the render reads changes in the store.
    private func observeStore() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStore() }
        }
    }

    private func render() {
        let globals = store.globals
        let token = store.renderToken
        guard let story = store.selected else {
            hosting.rootView = AnyView(Text("No stories found").foregroundStyle(.secondary))
            return
        }
        layout = story.layout
        let content: AnyView
        do {
            content = try story.view(args: store.args(for: story.id))
        } catch {
            content = AnyView(Text(verbatim: "Can't render \(story.id):\n\(error)").foregroundStyle(.red).padding())
        }
        var root = content
        if let locale = globals.locale {
            root = AnyView(root.environment(\.locale, Locale(identifier: locale)))
        }
        hosting.rootView = AnyView(root.id("\(story.id)#\(token)"))
        applyTraits(globals)
        view.setNeedsLayout()
    }

    private func applyTraits(_ globals: StoryGlobals) {
        // SwiftUI owns this controller's own overrides (it's a representable),
        // so apply the style to the hosting child and paint the canvas to match.
        switch globals.colorScheme {
        case "dark": hosting.overrideUserInterfaceStyle = .dark
        case "light": hosting.overrideUserInterfaceStyle = .light
        default: hosting.overrideUserInterfaceStyle = .unspecified
        }
        let style = hosting.overrideUserInterfaceStyle == .unspecified
            ? traitCollection.userInterfaceStyle : hosting.overrideUserInterfaceStyle
        view.backgroundColor = UIColor.systemBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        if let size = globals.dynamicType.flatMap(Self.contentSizeCategory) {
            hosting.traitOverrides.preferredContentSizeCategory = size
        } else if hosting.traitOverrides.contains(UITraitPreferredContentSizeCategory.self) {
            hosting.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
        }
        switch globals.layoutDirection {
        case "rightToLeft": hosting.traitOverrides.layoutDirection = .rightToLeft
        case "leftToRight": hosting.traitOverrides.layoutDirection = .leftToRight
        default:
            if hosting.traitOverrides.contains(UITraitLayoutDirection.self) {
                hosting.traitOverrides.remove(UITraitLayoutDirection.self)
            }
        }
    }

    static func contentSizeCategory(_ name: String) -> UIContentSizeCategory? {
        [
            "xSmall": .extraSmall, "small": .small, "medium": .medium, "large": .large,
            "xLarge": .extraLarge, "xxLarge": .extraExtraLarge, "xxxLarge": .extraExtraExtraLarge,
            "accessibility1": .accessibilityMedium, "accessibility2": .accessibilityLarge,
            "accessibility3": .accessibilityExtraLarge, "accessibility4": .accessibilityExtraExtraLarge,
            "accessibility5": .accessibilityExtraExtraExtraLarge,
        ][name]
    }

    // MARK: Capture

    public struct Snapshot: Sendable {
        public var png: Data
        public var width: Double
        public var height: Double
        public var scale: Double
    }

    /// Points captured around the story's frame by default, so shadows and
    /// focus rings that draw outside it aren't cut off.
    public static let defaultBleed: CGFloat = 16

    /// Waits for layout to settle, then captures the story's frame plus
    /// `bleed` points on each side (clamped to the canvas).
    public func snapshot(bleed: CGFloat? = nil) async throws -> Snapshot {
        guard let window = view.window else {
            throw RPCError(code: "canvas-hidden", message: "The story canvas isn't on screen, so it can't be captured.")
        }
        await settle()
        let frame = hosting.view.frame
        guard frame.width > 0, frame.height > 0 else {
            throw RPCError(code: "empty-render", message: "The story rendered with zero size.")
        }
        let margin = layout == .fullscreen ? 0 : max(0, bleed ?? Self.defaultBleed)
        let rect = frame.insetBy(dx: -margin, dy: -margin).intersection(view.bounds).integral
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        let background = view.backgroundColor ?? .systemBackground
        let canvas = view!
        let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            background.setFill()
            context.fill(CGRect(origin: .zero, size: rect.size))
            _ = canvas.drawHierarchy(in: CGRect(origin: CGPoint(x: -rect.minX, y: -rect.minY), size: canvas.bounds.size),
                                     afterScreenUpdates: true)
        }
        guard let png = image.pngData() else {
            throw RPCError(code: "encode-failed", message: "Couldn't encode the capture as PNG.")
        }
        return Snapshot(png: png, width: rect.width, height: rect.height, scale: format.scale)
    }

    /// "Rendered" means layout has settled, not just mounted: lay out on each
    /// display frame until the story's frame is unchanged for two frames in a
    /// row (or a frame budget runs out, for stories that animate forever).
    private func settle() async {
        var previous: CGRect?
        var stableFrames = 0
        for _ in 0..<30 {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            CATransaction.flush()
            await DisplayFrame.next()
            let frame = hosting.view.frame
            stableFrames = frame == previous ? stableFrames + 1 : 0
            if stableFrames >= 2 { return }
            previous = frame
        }
    }
}

/// Awaits the next display refresh.
@MainActor
private final class DisplayFrame: NSObject {
    private var continuation: CheckedContinuation<Void, Never>?
    private var link: CADisplayLink?

    static func next() async {
        let waiter = DisplayFrame()
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            let link = CADisplayLink(target: waiter, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            waiter.link = link
        }
    }

    @objc private func tick() {
        link?.invalidate()
        link = nil
        continuation?.resume()
        continuation = nil
    }
}

/// The story canvas as a SwiftUI view, for the in-app browser. The canvas
/// fills its frame; `contentInsets` keeps stories clear of overlapping chrome.
public struct StoryCanvas: UIViewControllerRepresentable {
    let store: StoryStore
    let contentInsets: EdgeInsets

    public init(store: StoryStore, contentInsets: EdgeInsets = EdgeInsets()) {
        self.store = store
        self.contentInsets = contentInsets
    }

    public func makeUIViewController(context: Context) -> StoryHostViewController {
        StoryHostViewController(store: store)
    }

    public func updateUIViewController(_ controller: StoryHostViewController, context: Context) {
        let insets = UIEdgeInsets(top: contentInsets.top, left: contentInsets.leading,
                                  bottom: contentInsets.bottom, right: contentInsets.trailing)
        guard controller.contentInsets != insets else { return }
        context.animate {
            controller.contentInsets = insets
            controller.view.layoutIfNeeded()
        }
    }
}
#endif
