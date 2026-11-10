import Testing
@testable import Storybook

// Test vectors copied from Storybook `next`: code/core/src/csf/index.test.ts
// and toStartCaseStr.test.ts.

@Suite struct IdTests {
    @Test(arguments: [
        ("kind", "story", "kind--story"),
        ("kind", nil, "kind"),
        ("a b$c?d😀e", "1-2:3", "a-b-c-d😀e--1-2-3"),
        ("a?&*b", "story", "a-b--story"),
        ("?ab-", "story", "ab--story"),
        ("KIND", "STORY", "kind--story"),
        ("Кнопки", "нормальный", "кнопки--нормальный"),
        ("kind", "바보 (babo)", "kind--바보-babo"),
        ("kind", "unicorns,’–—―′¿`\"<>()!.!!!{}[]%^&$*#&", "kind--unicorns"),
    ] as [(String, String?, String)])
    func toId(kind: String, story: String?, expected: String) throws {
        #expect(try StoryID.toId(kind, story) == expected)
    }

    @Test func toIdRejectsEmptyParts() {
        #expect(throws: StoryID.InvalidPart.self) { try StoryID.toId("?", "asdf") }
        #expect(throws: StoryID.InvalidPart.self) { try StoryID.toId("", "asdf") }
        #expect(throws: StoryID.InvalidPart.self) { try StoryID.toId("kind", "?") }
        #expect(throws: Never.self) { try StoryID.toId("kind", "") }
    }

    @Test(arguments: [
        ("name", "Name"),
        ("someName", "Some Name"),
        ("someNAME", "Some NAME"),
        ("some_custom_NAME", "Some Custom NAME"),
        ("someName1234", "Some Name 1234"),
        ("someName1_2_3_4", "Some Name 1 2 3 4"),
    ])
    func storyNameFromExport(key: String, expected: String) {
        #expect(StoryID.storyNameFromExport(key) == expected)
    }

    @Test(arguments: [
        ("snake_case", "Snake Case"),
        ("AAAaaaAAAaaa", "AA Aaaa AA Aaaa"),
        ("kebab-case", "Kebab Case"),
        ("camelCase", "Camel Case"),
        ("camelCase1", "Camel Case 1"),
        ("camelCase1a", "Camel Case 1 A"),
        ("camelCase1A", "Camel Case 1 A"),
        ("camelCase1A2", "Camel Case 1 A 2"),
        ("camelCase1A2b", "Camel Case 1 A 2 B"),
        ("camelCase1A2B", "Camel Case 1 A 2 B"),
        ("camelCase1A2B3", "Camel Case 1 A 2 B 3"),
        ("__FOOBAR__", "FOOBAR"),
        ("__FOO_BAR__", "FOO BAR"),
        ("__FOO__BAR__", "FOO BAR"),
        (" FOO BAR", "FOO BAR"),
        ("1. Fooo", "1 Fooo"),
        ("ZIndex", "Z Index"),
    ])
    func toStartCase(input: String, expected: String) {
        #expect(StoryID.toStartCase(input) == expected)
    }

    @Test(arguments: [
        ([], []),
        (["a", "b"], ["a", "b"]),
        (["a", "b", "b"], ["a", "b"]),
        (["a", "b", "!b"], ["a"]),
        (["b", "!b", "b"], ["b"]),
    ] as [([String], [String])])
    func combineTags(tags: [String], expected: [String]) {
        #expect(StoryID.combineTags(tags) == expected)
    }
}
