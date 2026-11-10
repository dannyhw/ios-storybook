#if canImport(UIKit)
import SwiftUI
import UIKit

/// Hosts a UIKit view in a story. A new view is made for every render, so
/// args changes always reach it.
struct StoryUIViewRepresentable: UIViewRepresentable {
    let make: @MainActor () -> UIView

    func makeUIView(context: Context) -> UIView { make() }
    func updateUIView(_ uiView: UIView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        // Ideal (compressed) size first; only wrap to the proposed width if
        // the ideal width doesn't fit.
        let ideal = uiView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        guard let width = proposal.width, ideal.width > width else { return ideal }
        return uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
    }
}

extension StoryMeta {
    /// Stories for a UIKit component:
    /// `StoryMeta.uiView(args: BadgeArgs()) { BadgeView(args: $0) }`.
    public static func uiView(
        title: String? = nil,
        id: String? = nil,
        args: Args = Args(),
        decorators: [StoryDecorator] = [],
        layout: StoryLayout = .centered,
        tags: [String] = [],
        fileID: String = #fileID,
        line: Int = #line,
        render: @escaping @MainActor @Sendable (Args) -> UIView
    ) -> StoryMeta<Args> {
        StoryMeta(title: title, id: id, args: args, decorators: decorators, layout: layout,
                  tags: tags + ["uikit"], fileID: fileID, line: line) { args in
            StoryUIViewRepresentable { render(args) }.id(UUID())
        }
    }
}
#endif
