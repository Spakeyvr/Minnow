//
//  WrappedXMLToolCallStreamFilter.swift
//  Minnow
//
//  Filters wrapped XML tool-call markup out of streamed MLX output so the UI
//  only sees user-visible assistant text while tool invocations are dispatched
//  separately.
//

import Foundation

/// A value type owned by the one stream it filters, so each chunk is handled
/// synchronously instead of hopping to another actor.
nonisolated struct WrappedXMLToolCallStreamFilter: Sendable {
    /// Matched without regard to case, like the closing wrapper.
    private static let toolMarkupMarkers = [
        "<tool_call>",
        "<function=",
        "<parameter=",
        "</parameter>",
        "</function>",
        "</tool_call>"
    ]
    private static let longestMarkerUTF8Count = toolMarkupMarkers.map(\.utf8.count).max() ?? 0

    /// A disabled filter passes every chunk through unchanged.
    private let isEnabled: Bool
    private var pendingText = ""
    private var suppressingToolMarkup = false
    private var suppressedMarkup = ""

    init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    mutating func consume(_ chunk: String) -> String? {
        guard !chunk.isEmpty else { return nil }
        guard isEnabled else { return chunk }

        if suppressingToolMarkup {
            suppressedMarkup += chunk
            return resumeAfterClosedToolCallIfPossible()
        }

        pendingText += chunk

        if let markerRange = Self.firstMarkerRange(in: pendingText) {
            let visiblePrefix = String(pendingText[..<markerRange.lowerBound])
            suppressedMarkup = String(pendingText[markerRange.lowerBound...])
            pendingText = ""
            suppressingToolMarkup = true
            let resumedText = resumeAfterClosedToolCallIfPossible() ?? ""
            let visibleText = visiblePrefix + resumedText
            return visibleText.isEmpty ? nil : visibleText
        }

        let safeEnd = Self.safePrefixEnd(in: pendingText)
        guard safeEnd > pendingText.startIndex else {
            return nil
        }

        let safeChunk = String(pendingText[..<safeEnd])
        pendingText = String(pendingText[safeEnd...])
        return safeChunk.isEmpty ? nil : safeChunk
    }

    mutating func didDispatchToolCall() {
        pendingText = ""
        suppressedMarkup = ""
        suppressingToolMarkup = false
    }

    mutating func finish() -> String? {
        defer {
            pendingText = ""
            suppressedMarkup = ""
            suppressingToolMarkup = false
        }

        if suppressingToolMarkup {
            if let recovered = resumeAfterClosedToolCallIfPossible(), !recovered.isEmpty {
                return recovered
            }

            // Some tokenizer templates omit the outer </tool_call> wrapper.
            // Once </function> has closed, content after it is no longer part
            // of the arguments and is safe to return instead of swallowing the
            // remainder of the assistant response.
            if let functionEnd = suppressedMarkup.range(
                of: "</function>",
                options: [.caseInsensitive, .backwards]
            ) {
                var trailing = String(suppressedMarkup[functionEnd.upperBound...])
                if let wrapperEnd = trailing.range(
                    of: "</tool_call>",
                    options: [.caseInsensitive, .anchored]
                ) {
                    trailing.removeSubrange(wrapperEnd)
                }
                return trailing.isEmpty ? nil : trailing
            }

            return nil
        }

        return pendingText.isEmpty ? nil : pendingText
    }

    /// Ends suppression as soon as a complete wrapper is observed, even when
    /// the model framework fails to emit a corresponding `.toolCall` event.
    /// Any following assistant text is fed back through the normal marker
    /// boundary logic so partial markers remain buffered safely.
    private mutating func resumeAfterClosedToolCallIfPossible() -> String? {
        guard let closingRange = suppressedMarkup.range(
            of: "</tool_call>",
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let trailing = String(suppressedMarkup[closingRange.upperBound...])
        suppressedMarkup = ""
        suppressingToolMarkup = false
        guard !trailing.isEmpty else { return nil }
        return consume(trailing)
    }

    private static func firstMarkerRange(in text: String) -> Range<String.Index>? {
        toolMarkupMarkers
            .compactMap { marker in text.range(of: marker, options: [.caseInsensitive]) }
            .min { $0.lowerBound < $1.lowerBound }
    }

    /// End of the text that cannot be the start of a marker split across
    /// chunks. Only the tail after the last `<` can be one, so the search
    /// stays within the longest marker's length instead of the whole buffer.
    private static func safePrefixEnd(in text: String) -> String.Index {
        guard let lastOpen = text.utf8.lastIndex(of: UInt8(ascii: "<")) else {
            return text.endIndex
        }
        let tail = text.utf8[lastOpen...]
        guard tail.count <= longestMarkerUTF8Count else { return text.endIndex }
        let tailText = String(decoding: tail, as: UTF8.self).lowercased()
        return toolMarkupMarkers.contains(where: { $0.hasPrefix(tailText) }) ? lastOpen : text.endIndex
    }
}
