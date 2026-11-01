//
//  ReasoningTagParser.swift
//  ChatLLM
//

import Foundation

// MARK: - Reasoning tags

/// Reads `<think>`/`<thinking>` reasoning out of raw model text. Routing,
/// parsing and the search indicator all use these rules, so a reply that uses
/// either tag, in any case, is treated the same way everywhere.
nonisolated enum ReasoningTagParser {
    nonisolated struct Result: Equatable, Sendable {
        /// The reasoning so far, or nil when there is none yet.
        let reasoning: String?
        /// The answer after the reasoning; empty while reasoning is still streaming.
        let finalAnswer: String
    }

    // swiftlint:disable:next force_try
    private static let closedBlock = try! NSRegularExpression(
        pattern: #"<(thinking|think)>([\s\S]*?)</\1>"#, options: [.caseInsensitive])

    private static let cache = BoundedCache<String, Result>(limit: 32)

    /// Whether the text opens with a reasoning tag. Models emit the tag before
    /// anything else, so a tag later in the text is prose or code that only
    /// mentions it (for example "Qwen wraps reasoning in `<think>` tags").
    static func containsOpeningTag(_ text: String) -> Bool {
        guard let start = text.firstIndex(where: { !$0.isWhitespace }) else { return false }
        let leading = text[start...]
        return ["<think>", "<thinking>"].contains { tag in
            leading.range(of: tag, options: [.caseInsensitive, .anchored]) != nil
        }
    }

    /// Splits tagged text into reasoning and answer, or returns nil when it does
    /// not open with a reasoning tag. An unclosed tag is reasoning still being streamed, so
    /// everything after it is reasoning and there is no answer yet.
    static func parse(_ text: String, caching: Bool = true) -> Result? {
        guard containsOpeningTag(text) else { return nil }
        guard caching else { return makeResult(text) }
        return cache.value(for: text) { makeResult(text) }
    }

    private static func makeResult(_ text: String) -> Result {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmedText.startIndex..<trimmedText.endIndex, in: trimmedText)
        guard let match = closedBlock.firstMatch(in: trimmedText, options: [], range: range),
              match.numberOfRanges >= 3,
              let reasoningRange = Range(match.range(at: 2), in: trimmedText),
              let fullMatchRange = Range(match.range(at: 0), in: trimmedText) else {
            return Result(reasoning: openReasoning(in: trimmedText), finalAnswer: "")
        }

        let reasoningContent = String(trimmedText[reasoningRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let afterThinking = String(trimmedText[fullMatchRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let finalAnswer = afterThinking
            .replacingOccurrences(
                of: "^Final answer:\\s*",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(reasoning: reasoningContent.isEmpty ? nil : reasoningContent, finalAnswer: finalAnswer)
    }

    /// The text after the leading opening tag of an unclosed reasoning block.
    private static func openReasoning(in text: String) -> String? {
        let openings = ["<thinking>", "<think>"].compactMap { text.range(of: $0, options: [.caseInsensitive, .anchored]) }
        guard let opening = openings.first else { return nil }
        let reasoning = text[opening.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return reasoning.isEmpty ? nil : reasoning
    }
}

extension Message {
    /// Whether the raw text opens with `<think>` or `<thinking>` reasoning, in any case.
    var containsReasoningTags: Bool {
        ReasoningTagParser.containsOpeningTag(text)
    }
}
