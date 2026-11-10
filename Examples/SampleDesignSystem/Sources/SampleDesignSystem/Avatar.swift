import SwiftUI

public enum AvatarSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large

    var points: CGFloat {
        switch self {
        case .small: 32
        case .medium: 48
        case .large: 72
        }
    }
}

/// A circular avatar with initials and an optional presence dot.
public struct Avatar: View {
    let name: String
    let size: AvatarSize
    let tint: Color
    let isOnline: Bool?

    public init(name: String, size: AvatarSize = .medium, tint: Color = .indigo, isOnline: Bool? = nil) {
        self.name = name
        self.size = size
        self.tint = tint
        self.isOnline = isOnline
    }

    public var body: some View {
        Text(initials)
            .font(.system(size: size.points * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size.points, height: size.points)
            .background(tint.gradient, in: .circle)
            .overlay(alignment: .bottomTrailing) {
                if let isOnline {
                    Circle()
                        .fill(isOnline ? .green : .gray)
                        .frame(width: size.points * 0.28, height: size.points * 0.28)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                }
            }
            .accessibilityLabel(name)
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}
