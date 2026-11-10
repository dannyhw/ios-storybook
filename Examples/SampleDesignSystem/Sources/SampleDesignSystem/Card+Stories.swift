#if STORYBOOK
import Storybook
import SwiftUI

struct CardArgs: StoryArgs {
    var symbol = "creditcard.fill"
    var title = "Payment received"
    @Arg(.text(multiline: true))
    var message = "£42.00 from Ada arrived in your account."
}

enum CardStories: Stories {
    static let meta = StoryMeta(title: "Design System/Card", args: CardArgs(), layout: .padded) { args in
        Card(symbol: args.symbol, title: args.title, message: args.message)
    }

    static let basic = meta.story()
    static let longMessage = meta.story {
        $0.symbol = "exclamationmark.triangle.fill"
        $0.title = "Card expiring soon"
        $0.message = "Your card ending in 4242 expires next month. Add a new card to keep your subscriptions running without interruption."
    }

    static var all: [StoryEntry<CardArgs>] {
        [.init("basic", basic), .init("longMessage", longMessage)]
    }
}
#endif
