#if STORYBOOK
import Storybook
import SwiftUI

struct AvatarArgs: StoryArgs {
    var name = "Ada Lovelace"
    var size: AvatarSize = .medium
    var tint: StoryColor = .hex("#5856D6")
    /// Optional: `nil` hides the presence dot.
    var isOnline: Bool? = nil
}

// No title: it's derived from the module and type, "SampleDesignSystem/Avatar".
enum AvatarStories: Stories {
    static let meta = StoryMeta(args: AvatarArgs()) { args in
        Avatar(name: args.name, size: args.size, tint: args.tint.color, isOnline: args.isOnline)
    }
    
    static let basic = meta.story()
     static let online = meta.story { $0.isOnline = true }
    static let large = meta.story { $0.size = .large; $0.name = "Grace Hopper"; $0.tint = .hex("#FF9500") }
    
    static var all: [StoryEntry<AvatarArgs>] {
        [.init("basic", basic), .init("online", online), .init("large", large)]
    }
}
#endif
