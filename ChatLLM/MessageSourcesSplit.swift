//
//  MessageSourcesSplit.swift
//  ChatLLM
//

import Foundation

/// Memoised `extractSourcesBlocks()` for view bodies, which run it for every
/// visible message on each re-render.
enum MessageSourcesSplit {
    struct Value: Equatable, Sendable {
        let visible: String
        let sources: String?
    }

    private static let cache = BoundedCache<String, Value>(limit: 64)

    /// - Parameter caching: false while the text is streaming. Each token is a new
    ///   key that would never be read again and would push finished messages out.
    static func split(_ text: String, caching: Bool = true) -> Value {
        func compute() -> Value {
            let split = text.extractSourcesBlocks()
            return Value(visible: split.visible, sources: split.sources)
        }
        guard caching else { return compute() }
        return cache.value(for: text, orInsert: compute)
    }

    /// The text without its sources blocks, the same as `Message.userVisibleText`.
    static func visibleText(_ text: String, caching: Bool = true) -> String {
        // A sources block is inserted whole by the view model, never streamed, so
        // a reply without one only needs trimming and never enters the cache.
        guard text.range(of: "<sources>", options: .caseInsensitive) != nil else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return split(text, caching: caching).visible
    }
}
