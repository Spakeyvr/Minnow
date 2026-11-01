//
//  ChatViewModel+WebSearch.swift
//  ChatLLM
//
//  Created by Nevio on 10/24/25.
//

import Foundation
import os

extension ChatViewModel {

    // MARK: - Web Search Helpers

    internal static func timeSensitiveYearTokens(referenceDate: Date = Date()) -> [String] {
        let currentYear = Calendar.current.component(.year, from: referenceDate)
        return [
            String(currentYear - 1),
            String(currentYear),
            String(currentYear + 1)
        ]
    }

    // Combined regex for stripping the search markers older prompts asked the model to
    // emit (single-pass). Only those exact forms match: a marker holds a one-line query,
    // so HTML's `<search>` element (which wraps markup) and ordinary "Search: …" prose or
    // `search: true` config lines are not markers. The tag forms ignore case; the line
    // form is the uppercase `SEARCH:` the old prompt used.
    // swiftlint:disable:next force_try
    static let combinedSearchPattern: NSRegularExpression = try! NSRegularExpression(
        pattern: [
            #"(?i:<search>[^<>\n]*</search>)"#,
            #"(?i:<search\s+query\s*=\s*"[^"\n]*"\s*/>)"#,
            #"(?i:\[search\][^\[\]\n]*\[/search\])"#,
            #"(?m:^[ \t]*SEARCH:[^\n]*$)"#,
            #"(?i:<tool:search>[^<>\n]*</tool:search>)"#
        ].joined(separator: "|"),
        options: []
    )

    // Extract the first <sources>...</sources> block content (without the tags)
    func extractSources(from text: String) -> String? {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = SharedRegexes.sourcesBlock.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2 else { return nil }
        let inner = match.range(at: 1)
        guard inner.location != NSNotFound else { return nil }
        return ns.substring(with: inner).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Strip legacy <search> markers (backward compat, single-pass). Code is left as written,
    // and blank lines are collapsed only where a marker was removed.
    func stripSearchTags(_ text: String, preserveBoundaries: Bool = true) -> String {
        let stripped = Self.transformingProse(in: text) { prose in
            let ns = prose as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard Self.combinedSearchPattern.firstMatch(in: prose, options: [], range: range) != nil else {
                return prose
            }
            // A removed marker line leaves its neighbours' blank lines behind.
            return Self.combinedSearchPattern
                .stringByReplacingMatches(in: prose, options: [], range: range, withTemplate: "")
                .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        }
        return preserveBoundaries ? stripped : stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
