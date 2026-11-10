import SwiftUI

public enum PayButtonStyle: String, Codable, CaseIterable, Sendable {
    case primary, secondary, destructive
}

/// The primary call to action for payments.
public struct PayButton: View {
    let title: String
    let style: PayButtonStyle
    let isEnabled: Bool
    let isLoading: Bool
    let tint: Color
    let action: () -> Void

    public init(_ title: String, style: PayButtonStyle = .primary, isEnabled: Bool = true,
                isLoading: Bool = false, tint: Color = .blue, action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.isEnabled = isEnabled
        self.isLoading = isLoading
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading { ProgressView().tint(foreground) }
                Text(title).font(.headline)
            }
            .frame(minWidth: 160)
            .padding(.vertical, 14)
            .padding(.horizontal, 24)
            .foregroundStyle(foreground)
            .background(background, in: .capsule)
            .overlay {
                if style == .secondary { Capsule().strokeBorder(tint, lineWidth: 2) }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityIdentifier("pay-button")
    }

    private var foreground: Color {
        style == .secondary ? tint : .white
    }

    private var background: Color {
        switch style {
        case .primary: tint
        case .secondary: .clear
        case .destructive: .red
        }
    }
}
