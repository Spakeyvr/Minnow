//
//  ChatViewModel+TextCleaning.swift
//  Minnow
//
//  Created by Nevio on 10/24/25.
//

import Foundation

// MARK: - Cached regexes (compiled once at startup)
private let _answerTagRegex = try? NSRegularExpression(pattern: #"<answer>([\s\S]*?)</answer>"#, options: [.caseInsensitive])
private let _leadingMarkdownRegex = try? NSRegularExpression(pattern: #"(?s)^\s*(\*\*|\*|[-]{2,}|#{1,6})\s*\n+"#, options: [])
/// Typo fixes for prose. Each word must stand alone: a neighbouring `/`, `.`+letter, `:`, `-`,
/// `_` or `@` means a URL, path, domain, file name or code symbol (`platform :ios`, `ios/`,
/// `apple.com/ios`), which must keep its spelling. The `ios` fix is case-sensitive so an
/// all-caps name such as Cisco IOS is left alone.
private let _typoFixRegexes: [(NSRegularExpression, String)] = [
    (#"(?<![/.:@\-_\w])(?:ios|Ios)(?![/:@\-_\w]|\.\w)"#, "iOS"),
    (#"(?i)(?<![/.:@\-_\w])securityreleases(?![/:@\-_\w]|\.\w)"#, "security releases"),
    (#"(?i)(?<![/.:@\-_\w])versionhistory(?![/:@\-_\w]|\.\w)"#, "version history"),
].compactMap { (p, r) in (try? NSRegularExpression(pattern: p, options: [])).map { ($0, r) } }
/// Fenced code blocks (``` or ~~~, closed by the same fence or the end of the text) and
/// inline code spans.
private let _markdownCodeRegex = try? NSRegularExpression(
    pattern: #"(?m)^[ \t]*(`{3,}|~{3,})[^\n]*[\s\S]*?(?:\n[ \t]*\1[ \t]*$|\z)|`[^`\n]+`"#,
    options: []
)

extension ChatViewModel {

    // MARK: - Text Cleaning

    /// Cleans glitched/repetitive text patterns from LLM output
    static func cleanGlitchedText(_ text: String) -> String {
        // IMPORTANT: Don't clean very short responses (like "29." or "Yes.")
        // as the cleaning logic can accidentally mangle them
        guard text.count > 50 else { return text }

        var cleaned = text

        // Strip <answer>...</answer> tags, keeping inner content
        if cleaned.contains("<answer>") || cleaned.contains("<Answer>") || cleaned.contains("<ANSWER>") {
            if let re = _answerTagRegex {
                let ns = cleaned as NSString
                let range = NSRange(location: 0, length: ns.length)
                let stripped = re.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "$1")
                if stripped != cleaned {
                    cleaned = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        // Remove stray leading Markdown-only lines like "**", "*", "---", or "###"
        if let re = _leadingMarkdownRegex {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            let result = re.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
            if result != cleaned {
                cleaned = result
            }
        }

        // Typo fixes and whitespace normalization change characters, so they apply to
        // prose only: code must come out exactly as the model wrote it.
        cleaned = transformingProse(in: cleaned) { prose in
            var fixed = prose
            for (regex, replacement) in _typoFixRegexes {
                let range = NSRange(fixed.startIndex..<fixed.endIndex, in: fixed)
                fixed = regex.stringByReplacingMatches(in: fixed, options: [], range: range, withTemplate: replacement)
            }

            // Strip Unicode whitespace artifacts that can appear in web/tool-injected content
            return fixed
                .replacingOccurrences(of: "\u{00A0}", with: " ")   // NBSP -> space
                .replacingOccurrences(of: "\u{200B}", with: "")    // Zero-width space
                .replacingOccurrences(of: "\u{00AD}", with: "")    // Soft hyphen
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Applies `transform` to the Markdown prose in `text`, leaving fenced code blocks and
    /// inline code spans exactly as they are.
    static func transformingProse(in text: String, _ transform: (String) -> String) -> String {
        guard let codeRegex = _markdownCodeRegex, text.contains(where: { $0 == "`" || $0 == "~" }) else {
            return transform(text)
        }

        let ns = text as NSString
        var result = ""
        var proseStart = 0
        for match in codeRegex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            let code = match.range
            if code.location > proseStart {
                result += transform(ns.substring(with: NSRange(location: proseStart, length: code.location - proseStart)))
            }
            result += ns.substring(with: code)
            proseStart = code.location + code.length
        }
        if proseStart < ns.length {
            result += transform(ns.substring(from: proseStart))
        }
        return result
    }
}
