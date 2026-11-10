import Foundation
import Storybook

/// Collects stories from the conformance scan plus manual registrations.
@MainActor
public enum StoryRegistry {
    private static var manual: [any Stories.Type] = []

    /// Escape hatch when discovery can't see a type (e.g. it was stripped).
    public static func register(_ types: any Stories.Type...) {
        manual += types
    }

    public struct Discovery: Sendable {
        public var stories: [ResolvedStory]
        /// Types that failed to resolve, e.g. a title with no alphanumerics.
        public var errors: [String]
    }

    public static func discover() -> Discovery {
        var seen = Set<ObjectIdentifier>()
        var stories: [ResolvedStory] = []
        var errors: [String] = []
        let types = ConformanceScanner.storiesTypes() + manual
        for type in types where seen.insert(ObjectIdentifier(type)).inserted {
            do {
                stories += try type.resolve()
            } catch {
                errors.append("\(type): \(error)")
            }
        }
        // Duplicate ids would make stories unreachable; keep the first and report.
        var ids = Set<String>()
        stories = stories.filter { story in
            if ids.insert(story.id).inserted { return true }
            errors.append("Duplicate story id '\(story.id)' in \(story.description.entry.xIOS.storiesType)")
            return false
        }
        stories.sort { ($0.title, $0.description.entry.xIOS.line) < ($1.title, $1.description.entry.xIOS.line) }
        return Discovery(stories: stories, errors: errors)
    }
}
