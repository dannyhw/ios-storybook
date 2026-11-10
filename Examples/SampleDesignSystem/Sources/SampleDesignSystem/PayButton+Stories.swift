#if STORYBOOK
import Storybook
import SwiftUI

struct PayButtonArgs: StoryArgs {
    var title = "Pay"
    var style: PayButtonStyle = .primary
    var isEnabled = true
    var isLoading = false
    var tint: StoryColor = .hex("#0A84FF")
    var onTap = StoryAction("onTap")
}

enum PayButtonStories: Stories {
    static let meta = StoryMeta(title: "Design System/Pay Button", args: PayButtonArgs(), tags: ["autodocs"]) { args in
        PayButton(args.title, style: args.style, isEnabled: args.isEnabled, isLoading: args.isLoading,
                  tint: args.tint.color, action: args.onTap.handler)
    }

    static let primary = meta.story()
    static let secondary = meta.story { $0.style = .secondary }
    static let destructive = meta.story { $0.style = .destructive; $0.title = "Cancel payment" }
    static let disabled = primary.extend(name: "Disabled state") { $0.isEnabled = false }
    static let loading = primary.extend { $0.isLoading = true; $0.title = "Paying…" }
    static let longTitle = meta.story { $0.title = "Pay £1,234.56 with Apple Pay" }

    static var all: [StoryEntry<PayButtonArgs>] {
        [.init("primary", primary), .init("secondary", secondary), .init("destructive", destructive),
         .init("disabled", disabled), .init("loading", loading), .init("longTitle", longTitle)]
    }
}
#endif
