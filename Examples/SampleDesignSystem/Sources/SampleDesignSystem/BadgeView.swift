import UIKit

/// A UIKit pill badge, to show UIKit components work as stories too.
public final class BadgeView: UIView {
    private let label = UILabel()

    public init(text: String, color: UIColor, count: Int?) {
        super.init(frame: .zero)
        backgroundColor = color
        layer.cornerCurve = .continuous
        layer.cornerRadius = 12
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.text = count.map { "\(text) · \($0)" } ?? text
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
