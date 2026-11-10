import Foundation

// Exact ports of Storybook's id helpers (`code/core/src/csf/csf-utils.ts`,
// `toStartCaseStr.ts` on `next`), so story ids match across both worlds.
// Tests use Storybook's own test vectors.

public enum StoryID {
    public struct InvalidPart: Error, CustomStringConvertible {
        public let part: String
        public let value: String
        public var description: String { "Invalid \(part) '\(value)', must include alphanumeric characters" }
    }

    /// Removes punctuation and illegal characters so the id is URL-safe.
    public static func sanitize(_ string: String) -> String {
        var result = string.lowercased()
        result = replace(punctuation, in: result, with: "-")
        result = replace("-+", in: result, with: "-")
        result = replace("^-+", in: result, with: "")
        result = replace("-+$", in: result, with: "")
        return result
    }

    /// `toId(kind, name)` → `kind--name`.
    public static func toId(_ kind: String, _ name: String? = nil) throws -> String {
        let kindPart = try sanitizeSafe(kind, part: "kind")
        guard let name, !name.isEmpty else { return kindPart }
        return "\(kindPart)--\(try sanitizeSafe(name, part: "name"))"
    }

    /// `toTestId(parentId, testName)` → `parentId:test-name`.
    public static func toTestId(_ parentId: String, _ testName: String) throws -> String {
        "\(parentId):\(try sanitizeSafe(testName, part: "test"))"
    }

    /// Turns an export (member) name into a display name: `someNAME` → `Some NAME`.
    public static func storyNameFromExport(_ key: String) -> String {
        toStartCase(key)
    }

    public static func toStartCase(_ string: String) -> String {
        var s = string
        s = s.replacingOccurrences(of: "_", with: " ")
        s = s.replacingOccurrences(of: "-", with: " ")
        s = s.replacingOccurrences(of: ".", with: " ")
        s = replace("([^\\n])([A-Z])([a-z])", in: s, with: "$1 $2$3")
        s = replace("([a-z])([A-Z])", in: s, with: "$1 $2")
        s = replace("([a-zA-Z])([0-9])", in: s, with: "$1 $2")
        s = replace("([0-9])([a-zA-Z])", in: s, with: "$1 $2")
        s = uppercaseWordStarts(s)
        s = replace(" +", in: s, with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Combines project / meta / story tags; `!tag` removes `tag`.
    public static func combineTags(_ tags: [String]) -> [String] {
        var result: [String] = []
        for tag in tags {
            if tag.hasPrefix("!") {
                result.removeAll { $0 == String(tag.dropFirst()) }
            } else if !result.contains(tag) {
                result.append(tag)
            }
        }
        return result
    }

    // MARK: - Private

    /// Storybook's class: `[ ’–—―′¿'`~!@#$%^&*()_|+\-=?;:'",.<>\{\}\[\]\\\/]`.
    private static let punctuation: String = {
        let characters = " ’–—―′¿'`~!@#$%^&*()_|+-=?;:'\",.<>{}[]\\/"
        // ICU treats a backslash before any non-alphanumeric character as a literal.
        return "[" + characters.map { "\\" + String($0) }.joined() + "]"
    }()

    private static func sanitizeSafe(_ string: String, part: String) throws -> String {
        let sanitized = sanitize(string)
        if sanitized.isEmpty { throw InvalidPart(part: part, value: string) }
        return sanitized
    }

    private static func replace(_ pattern: String, in string: String, with template: String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(string.startIndex..., in: string)
        return regex.stringByReplacingMatches(in: string, range: range, withTemplate: template)
    }

    /// JS: `.replace(/(\s|^)(\w)/g, (_, a, b) => a + b.toUpperCase())`. JS `\w` is ASCII.
    private static func uppercaseWordStarts(_ string: String) -> String {
        let regex = try! NSRegularExpression(pattern: "(\\s|^)([A-Za-z0-9_])")
        let ns = string as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: string, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            result += ns.substring(with: match.range(at: 1))
            result += ns.substring(with: match.range(at: 2)).uppercased()
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
