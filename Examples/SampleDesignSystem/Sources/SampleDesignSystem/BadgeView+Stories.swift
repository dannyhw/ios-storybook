#if STORYBOOK
import Storybook
import UIKit

struct BadgeArgs: StoryArgs {
    var text = "New"
    var color: StoryColor = .hex("#34C759")
    @Arg(.range(0...99), description: "Shown after the text; unset hides it")
    var count: Int? = nil
}

enum BadgeViewStories: Stories {
    static let meta = StoryMeta.uiView(title: "Design System/Badge (UIKit)", args: BadgeArgs()) { args in
        let c = args.color.rgba
        return BadgeView(text: args.text, color: UIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha),
                         count: args.count)
    }

    static let new = meta.story()
    static let withCount = meta.story { $0.text = "Inbox"; $0.color = .hex("#FF3B30"); $0.count = 12 }

    static var all: [StoryEntry<BadgeArgs>] {
        [.init("new", new), .init("withCount", withCount)]
    }
}
#endif
