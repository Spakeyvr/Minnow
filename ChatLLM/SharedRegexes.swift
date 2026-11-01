//
//  SharedRegexes.swift
//  ChatLLM
//

import Foundation
import Synchronization

// swiftlint:disable force_try
nonisolated enum SharedRegexes {
    /// Matches `<sources>...</sources>` blocks (case-insensitive, multiline).
    static let sourcesBlock = try! NSRegularExpression(
        pattern: #"<sources>(.*?)</sources>"#,
        options: [.dotMatchesLineSeparators, .caseInsensitive])

    /// Collapses multiple blank lines into a single newline.
    static let multipleBlankLines = try! NSRegularExpression(
        pattern: #"[ \t]*\n[ \t]*\n+"#, options: [])

    /// Collapses runs of 2+ whitespace characters into a single space.
    static let excessiveWhitespace = try! NSRegularExpression(
        pattern: #"\s{2,}"#, options: [])

    /// An opening or closing `<think>` / `<thinking>` tag, in any case.
    static let reasoningTag = try! NSRegularExpression(
        pattern: #"</?think(?:ing)?>"#, options: [.caseInsensitive])

    /// Two or more blank lines (lines holding only spaces or tabs count as blank).
    static let blankLineRun = try! NSRegularExpression(
        pattern: #"\n[ \t]*\n(?:[ \t]*\n)+"#, options: [])

    /// `![alt](url)` — reduced to its alt text so no remote URL ever reaches the
    /// renderer. Capture 1 is the alt text.
    static let markdownInlineImage = try! NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\([^)]*\)"#, options: [])

    /// `![alt][ref]` — the reference form of the same thing.
    static let markdownReferenceImage = try! NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\[[^\]]*\]"#, options: [])

    /// A link reference definition line, e.g. `[remote]: https://example.com`.
    /// The inline-only parser has no concept of these, so they are dropped
    /// rather than shown to the reader as literal text.
    static let markdownLinkReferenceDefinition = try! NSRegularExpression(
        pattern: #"^[ \t]{0,3}\[[^\]]+\]:[ \t]*\S+[ \t]*$"#, options: [])

    /// Phrase patterns are drawn from fixed keyword lists and reused constantly,
    /// so the compiled regexes are cached instead of rebuilt on every call. A
    /// list of phrases compiles to one alternation, so checking a whole keyword
    /// list is a single scan of the text.
    private static let wholePhraseCache = Mutex<[[String]: NSRegularExpression]>([:])

    private static func wholePhraseRegex(for phrases: [String]) -> NSRegularExpression? {
        if let cached = wholePhraseCache.withLock({ $0[phrases] }) {
            return cached
        }
        // Backtracking tries every alternative at each position, so a short phrase
        // that fails the trailing boundary never hides a longer one.
        let alternatives = phrases
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        let pattern = #"(?<![\p{L}\p{N}])(?:\#(alternatives))(?![\p{L}\p{N}])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        wholePhraseCache.withLock { $0[phrases] = regex }
        return regex
    }

    /// Whether `phrase` appears in `text` as a whole word or words, ignoring case.
    static func containsWholePhrase(_ phrase: String, in text: String) -> Bool {
        containsAnyWholePhrase([phrase], in: text)
    }

    /// Whether any of `phrases` appears in `text` as a whole word or words,
    /// ignoring case, checked with one scan of `text`.
    static func containsAnyWholePhrase(_ phrases: [String], in text: String) -> Bool {
        let phrases = phrases.filter { !$0.isEmpty }
        guard !phrases.isEmpty, let regex = wholePhraseRegex(for: phrases) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
// swiftlint:enable force_try

extension String {
    /// Removes every `<sources>…</sources>` block and trims surrounding whitespace.
    nonisolated func removingSourcesBlocks() -> String {
        // Most text has no sources block, so skip the regex scan entirely.
        guard range(of: "<sources>", options: .caseInsensitive) != nil else {
            return trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let range = NSRange(location: 0, length: (self as NSString).length)
        return SharedRegexes.sourcesBlock
            .stringByReplacingMatches(in: self, options: [], range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Returns the visible text with all <sources>…</sources> blocks removed,
    // and a single combined sources string (if any) for UI presentation.
    nonisolated func extractSourcesBlocks() -> (visible: String, sources: String?) {
        // Almost no reply carries a sources block; skip the regex for those.
        guard range(of: "<sources>", options: .caseInsensitive) != nil else {
            return (trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        let regex = SharedRegexes.sourcesBlock
        let ns = self as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        var sourcesParts: [String] = []

        // Find all matches; collect content forward then remove tags backward
        let matches = regex.matches(in: self, options: [], range: fullRange)
        for match in matches where match.numberOfRanges >= 2 {
            let content = ns.substring(with: match.range(at: 1))
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sourcesParts.append(content)
            }
        }
        var mutable = self
        for match in matches.reversed() {
            if let swiftRange = Range(match.range(at: 0), in: mutable) {
                mutable.removeSubrange(swiftRange)
            }
        }

        let combinedSources = sourcesParts.isEmpty ? nil : sourcesParts.joined(separator: "\n\n")
        return (mutable.trimmingCharacters(in: .whitespacesAndNewlines), combinedSources)
    }
}
