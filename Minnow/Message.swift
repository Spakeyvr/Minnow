//
//  Message.swift
//  Minnow
//
//  Created by Nevio on 10/24/25.
//

import Foundation
import SwiftData
import Synchronization

// Pre-compiled regexes used to clean message text for display (compiled once at app launch)
// swiftlint:disable force_try
nonisolated private let _thinkingTagRegex = try! NSRegularExpression(
    pattern: #"<(?:think|thinking)>[\s\S]*?</(?:think|thinking)>\s*"#, options: [.caseInsensitive])
nonisolated private let _answerTagDisplayRegex = try! NSRegularExpression(
    pattern: #"<answer>([\s\S]*?)</answer>"#, options: [.caseInsensitive])
nonisolated private let _hiddenImageContextRegex = try! NSRegularExpression(
    pattern: #"\[HIDDEN_IMAGE_CONTEXT\].*?\[/HIDDEN_IMAGE_CONTEXT\]"#, options: [.dotMatchesLineSeparators])
nonisolated private let _imageAnalysisBlockRegex = try! NSRegularExpression(
    pattern: #"--- Image Analysis Data ---.*?(?:--- End Image Analysis ---\s*User's question:\s*|--- User Question ---\n?)"#,
    options: [.dotMatchesLineSeparators])
// swiftlint:enable force_try

enum ReasoningStreamPhase: String, Sendable {
    case initialThinking
    case postToolReasoning
    case finalAnswer
}

nonisolated enum MessageRole: String, Codable, CaseIterable, Sendable {
    case system
    case user
    case assistant

    var isAssistant: Bool { self == .assistant }
}

@Model
final class Message {
    @Attribute(.unique) var id: UUID
    var order: Int
    var role: MessageRole
    var isFinal: Bool
    var isReasoningMode: Bool
    var createdAt: Date

    var text: String
    var reasoning: String?
    var finalAnswer: String?
    var promptSnapshot: String?
    var searchQuery: String?  // Stores the user's query when web search was used
    var requiresWebSearch: Bool?
    var rawText: String?
    var generationBackend: String?
    var generationModelName: String?
    var generationStartedAt: Date?
    var generationCompletedAt: Date?
    var reasoningStartedAt: Date?
    var reasoningCompletedAt: Date?
    // Backend-reported token counts and timings. Only MLX reports these; the
    // Developer panel falls back to character-based estimates when nil.
    var generationPromptTokenCount: Int?
    var generationCachedPromptTokenCount: Int?
    var generationPromptTime: Double?
    var generationOutputTokenCount: Int?
    var generationDecodeTime: Double?
    var generationTimeToFirstToken: Double?
    // Persisted so a failed turn still shows its (localized) error callout
    // after relaunch, instead of storing an English sentinel in `text`.
    var generationError: String?
    @Transient var streamingReasoningPhase: ReasoningStreamPhase?
    @Transient var postToolReasoningStartCloseTagCount: Int?

    // All web search invocations stored as JSON for SwiftData compatibility
    var searchInvocationsJSON: String?

    // Retired: structured reasoning steps were parsed and saved here but never
    // shown. The column stays so existing stores open without a migration, and
    // regeneration clears whatever an older build left behind.
    private var reasoningStepsJSON: String?

    // Computed property to access search invocations
    @Transient
    var searchInvocations: [SearchInvocation]? {
        get {
            guard let json = searchInvocationsJSON else { return nil }
            if json == _cachedSearchInvocationsJSON { return _cachedSearchInvocations }
            _cachedSearchInvocationsJSON = json
            _cachedSearchInvocations = try? JSONDecoder().decode([SearchInvocation].self, from: Data(json.utf8))
            return _cachedSearchInvocations
        }
        set {
            if let invocations = newValue, !invocations.isEmpty,
               let data = try? JSONEncoder().encode(invocations),
               let json = String(data: data, encoding: .utf8) {
                searchInvocationsJSON = json
                // Backward compat: set searchQuery to first query
                searchQuery = invocations.first?.query
            } else {
                searchInvocationsJSON = nil
                searchQuery = nil
            }
            _cachedSearchInvocationsJSON = nil
            _cachedSearchInvocations = nil
        }
    }

    @Relationship var conversation: Conversation?
    @Relationship(deleteRule: .cascade, inverse: \MessageAttachment.message)
    var attachments: [MessageAttachment]

    // MARK: - Display text

    // Cleaned display text for the current display source, recomputed only when
    // the source changes. Not persisted.
    @Transient private var _displayTextCache: MessageDisplayTextCache?

    // Cached decoded values for JSON-backed computed properties (not persisted)
    @Transient private var _cachedSearchInvocations: [SearchInvocation]?
    @Transient private var _cachedSearchInvocationsJSON: String?

    var isAssistant: Bool { role.isAssistant }

    /// The stored text the display text is cleaned from: in reasoning mode an
    /// assistant reply shows `finalAnswer` when there is one, even if it only
    /// holds sources, which the UI extracts from it.
    var displaySource: String {
        if isReasoningMode && isAssistant {
            return finalAnswer ?? text
        }
        return text
    }

    /// The reply as shown in the bubble, without reasoning tags or hidden image context.
    var displayText: String {
        displayTextCache().displayText
    }

    /// The display text without `<sources>` blocks, as copied, shared and searched.
    var userVisibleText: String {
        var cache = displayTextCache()
        if let userVisibleText = cache.userVisibleText {
            return userVisibleText
        }
        let userVisibleText = cache.displayText.removingSourcesBlocks()
        cache.userVisibleText = userVisibleText
        _displayTextCache = cache
        return userVisibleText
    }

    /// Returns the cache for the current display source, rebuilding it when the
    /// source changed. Comparing the source by value catches every write to
    /// `text`, `finalAnswer`, `isReasoningMode` and `role`, and is effectively
    /// free while the string storage is unchanged.
    private func displayTextCache() -> MessageDisplayTextCache {
        let source = displaySource
        if let cache = _displayTextCache, cache.source == source {
            return cache
        }
        let cache = MessageDisplayTextCache(
            source: source,
            displayText: MessageDisplayTextCleaner.displayText(from: source)
        )
        _displayTextCache = cache
        return cache
    }

    /// Drops the cached display text so the next read rebuilds it.
    private func invalidateCache() {
        _displayTextCache = nil
    }

    // MARK: - Initializer

    init(
        id: UUID = UUID(),
        role: MessageRole,
        text: String,
        createdAt: Date = Date(),
        order: Int,
        conversation: Conversation? = nil,
        attachments: [MessageAttachment] = [],
        promptSnapshot: String? = nil,
        isFinal: Bool = false,
        reasoning: String? = nil,
        finalAnswer: String? = nil,
        isReasoningMode: Bool = false,
        searchQuery: String? = nil,
        requiresWebSearch: Bool? = nil,
        rawText: String? = nil,
        generationBackend: String? = nil,
        generationModelName: String? = nil,
        generationStartedAt: Date? = nil,
        generationCompletedAt: Date? = nil,
        reasoningStartedAt: Date? = nil,
        reasoningCompletedAt: Date? = nil
    ) {
        self.id = id
        self.order = order
        self.role = role
        self.isFinal = isFinal
        self.isReasoningMode = isReasoningMode
        self.createdAt = createdAt
        self.text = text
        self.reasoning = reasoning
        self.finalAnswer = finalAnswer
        self.promptSnapshot = promptSnapshot
        self.searchQuery = searchQuery
        self.requiresWebSearch = requiresWebSearch
        self.rawText = rawText
        self.generationBackend = generationBackend
        self.generationModelName = generationModelName
        self.generationStartedAt = generationStartedAt
        self.generationCompletedAt = generationCompletedAt
        self.reasoningStartedAt = reasoningStartedAt
        self.reasoningCompletedAt = reasoningCompletedAt
        self.conversation = conversation
        self.attachments = attachments
    }
}

// MARK: - Generation capture and regeneration

extension Message {
    nonisolated static let maximumCapturedRawTextCharacters = 32_768

    var developerRawText: String {
        if let rawText, !rawText.isEmpty {
            return rawText
        }
        if isReasoningMode {
            return finalAnswer ?? text
        }
        return text
    }

    var generationDuration: TimeInterval? {
        guard let generationStartedAt, let generationCompletedAt else { return nil }
        let duration = generationCompletedAt.timeIntervalSince(generationStartedAt)
        return duration > 0 ? duration : nil
    }

    var reasoningDuration: TimeInterval? {
        guard let reasoningStartedAt, let reasoningCompletedAt else { return nil }
        let duration = reasoningCompletedAt.timeIntervalSince(reasoningStartedAt)
        return duration > 0 ? duration : nil
    }

    /// Decode throughput as measured by the backend, excluding prompt
    /// processing, time to first token, and UI work.
    var decodeTokensPerSecond: Double? {
        guard let generationOutputTokenCount,
              let generationDecodeTime,
              generationDecodeTime > 0 else { return nil }
        return Double(generationOutputTokenCount) / generationDecodeTime
    }

    var promptTokensPerSecond: Double? {
        guard let generationPromptTokenCount,
              let generationPromptTime,
              generationPromptTime > 0 else { return nil }
        return Double(generationPromptTokenCount) / generationPromptTime
    }

    func recordGenerationMetrics(_ metrics: GenerationMetrics) {
        generationPromptTokenCount = metrics.promptTokenCount
        generationCachedPromptTokenCount = metrics.cachedPromptTokenCount
        generationPromptTime = metrics.promptTime
        generationOutputTokenCount = metrics.outputTokenCount
        generationDecodeTime = metrics.decodeTime
        generationTimeToFirstToken = metrics.timeToFirstToken
    }

    private func clearGenerationMetrics() {
        setIfChanged(\.generationPromptTokenCount, to: nil)
        setIfChanged(\.generationCachedPromptTokenCount, to: nil)
        setIfChanged(\.generationPromptTime, to: nil)
        setIfChanged(\.generationOutputTokenCount, to: nil)
        setIfChanged(\.generationDecodeTime, to: nil)
        setIfChanged(\.generationTimeToFirstToken, to: nil)
    }

    var estimatedOutputTokenCount: Int? {
        let raw = developerRawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        // A lightweight fallback for developer diagnostics when the backend does not expose true token counts.
        return max(1, Int(ceil(Double(raw.count) / 4.0)))
    }

    var estimatedTokensPerSecond: Double? {
        guard let duration = generationDuration,
              let estimatedOutputTokenCount,
              duration > 0 else { return nil }
        return Double(estimatedOutputTokenCount) / duration
    }

    func beginGenerationCapture(backend: String, modelName: String?, startedAt: Date = Date()) {
        rawText = nil
        generationBackend = backend
        generationModelName = modelName
        generationStartedAt = startedAt
        generationCompletedAt = nil
        clearGenerationMetrics()
        reasoningStartedAt = isReasoningMode ? startedAt : nil
        reasoningCompletedAt = nil
        streamingReasoningPhase = isReasoningMode ? .initialThinking : nil
        postToolReasoningStartCloseTagCount = nil
    }

    func completeReasoningCapture(completedAt: Date = Date()) {
        guard isReasoningMode,
              reasoningStartedAt != nil,
              reasoningCompletedAt == nil else { return }
        reasoningCompletedAt = completedAt
    }

    /// A tool call means the model is still working: a `</think>` before the call
    /// does not end reasoning, so reopen it until text after a later close arrives.
    func reopenReasoningForToolCall(closeTagCount: Int) {
        guard isReasoningMode else { return }
        streamingReasoningPhase = .postToolReasoning
        postToolReasoningStartCloseTagCount = closeTagCount
        reasoningCompletedAt = nil
    }

    func completeGenerationCapture(
        rawText: String,
        captureRawText: Bool,
        completedAt: Date = Date()
    ) {
        self.rawText = captureRawText
            ? String(rawText.prefix(Self.maximumCapturedRawTextCharacters))
            : nil
        generationCompletedAt = completedAt
        if !(reasoning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            completeReasoningCapture(completedAt: completedAt)
        }
    }

    /// Mark as complete and finalize
    func markAsComplete() {
        guard !self.isFinal else { return } // Skip if already final
        self.isFinal = true
        invalidateCache()
    }
    
    /// A finished reply as it was before regenerating it. A regeneration that is
    /// stopped before writing anything puts the whole reply back, so it keeps its
    /// sources and timings rather than only its text.
    struct RegenerationSnapshot {
        fileprivate let text: String
        fileprivate let reasoning: String?
        fileprivate let finalAnswer: String?
        fileprivate let rawText: String?
        fileprivate let generationBackend: String?
        fileprivate let generationModelName: String?
        fileprivate let generationStartedAt: Date?
        fileprivate let generationCompletedAt: Date?
        fileprivate let reasoningStartedAt: Date?
        fileprivate let reasoningCompletedAt: Date?
        fileprivate let generationPromptTokenCount: Int?
        fileprivate let generationCachedPromptTokenCount: Int?
        fileprivate let generationPromptTime: Double?
        fileprivate let generationOutputTokenCount: Int?
        fileprivate let generationDecodeTime: Double?
        fileprivate let generationTimeToFirstToken: Double?
        fileprivate let searchInvocationsJSON: String?
        fileprivate let searchQuery: String?
        fileprivate let requiresWebSearch: Bool?
        fileprivate let generationError: String?
        fileprivate let isReasoningMode: Bool
    }

    func regenerationSnapshot() -> RegenerationSnapshot {
        RegenerationSnapshot(
            text: text,
            reasoning: reasoning,
            finalAnswer: finalAnswer,
            rawText: rawText,
            generationBackend: generationBackend,
            generationModelName: generationModelName,
            generationStartedAt: generationStartedAt,
            generationCompletedAt: generationCompletedAt,
            reasoningStartedAt: reasoningStartedAt,
            reasoningCompletedAt: reasoningCompletedAt,
            generationPromptTokenCount: generationPromptTokenCount,
            generationCachedPromptTokenCount: generationCachedPromptTokenCount,
            generationPromptTime: generationPromptTime,
            generationOutputTokenCount: generationOutputTokenCount,
            generationDecodeTime: generationDecodeTime,
            generationTimeToFirstToken: generationTimeToFirstToken,
            searchInvocationsJSON: searchInvocationsJSON,
            searchQuery: searchQuery,
            requiresWebSearch: requiresWebSearch,
            generationError: generationError,
            isReasoningMode: isReasoningMode
        )
    }

    func restore(_ snapshot: RegenerationSnapshot) {
        invalidateCache()
        text = snapshot.text
        reasoning = snapshot.reasoning
        finalAnswer = snapshot.finalAnswer
        rawText = snapshot.rawText
        generationBackend = snapshot.generationBackend
        generationModelName = snapshot.generationModelName
        generationStartedAt = snapshot.generationStartedAt
        generationCompletedAt = snapshot.generationCompletedAt
        reasoningStartedAt = snapshot.reasoningStartedAt
        reasoningCompletedAt = snapshot.reasoningCompletedAt
        generationPromptTokenCount = snapshot.generationPromptTokenCount
        generationCachedPromptTokenCount = snapshot.generationCachedPromptTokenCount
        generationPromptTime = snapshot.generationPromptTime
        generationOutputTokenCount = snapshot.generationOutputTokenCount
        generationDecodeTime = snapshot.generationDecodeTime
        generationTimeToFirstToken = snapshot.generationTimeToFirstToken
        searchInvocationsJSON = snapshot.searchInvocationsJSON
        searchQuery = snapshot.searchQuery
        requiresWebSearch = snapshot.requiresWebSearch
        generationError = snapshot.generationError
        isReasoningMode = snapshot.isReasoningMode
    }

    /// Reset message state before regeneration so the next run starts clean.
    func resetForRegeneration() {
        let preservedForcedSearchQuery = requiresWebSearch == true ? searchQuery : nil

        // Always reset every field: a partial "is anything set?" check drifted from
        // the fields cleared here. Each write is skipped when the value is already
        // clean, so a new turn's untouched placeholder is not dirtied and saved again.
        invalidateCache()
        setIfChanged(\.text, to: "")
        setIfChanged(\.reasoning, to: nil)
        setIfChanged(\.finalAnswer, to: nil)
        setIfChanged(\.isFinal, to: false)
        setIfChanged(\.generationError, to: nil)
        setIfChanged(\.rawText, to: nil)
        setIfChanged(\.generationBackend, to: nil)
        setIfChanged(\.generationModelName, to: nil)
        setIfChanged(\.generationStartedAt, to: nil)
        setIfChanged(\.generationCompletedAt, to: nil)
        setIfChanged(\.reasoningStartedAt, to: nil)
        setIfChanged(\.reasoningCompletedAt, to: nil)
        clearGenerationMetrics()
        setIfChanged(\.streamingReasoningPhase, to: nil)
        setIfChanged(\.postToolReasoningStartCloseTagCount, to: nil)
        if reasoningStepsJSON != nil { reasoningStepsJSON = nil }
        setIfChanged(\.searchInvocationsJSON, to: nil)
        setIfChanged(\.searchQuery, to: preservedForcedSearchQuery)
    }

    /// Writes `value` only when it differs from the stored one, so SwiftData
    /// does not record a change for an identical value.
    func setIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<Message, Value>, to value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }
}

/// Token counts and timings for one assistant response, summed across tool-call
/// iterations. Times are in seconds.
nonisolated struct GenerationMetrics: Equatable, Sendable {
    /// Prompt tokens processed by the model for this response.
    let promptTokenCount: Int
    /// Prompt tokens restored from the on-disk prompt-prefix cache instead.
    let cachedPromptTokenCount: Int
    let promptTime: TimeInterval
    let outputTokenCount: Int
    let decodeTime: TimeInterval
    let timeToFirstToken: TimeInterval?
}

enum ThoughtDurationFormatter {
    /// Formats at most two units ("1 minute and 8 seconds") in `locale`'s language, so the
    /// "Thought for…" label doesn't mix an English duration into a translated sentence.
    nonisolated static func string(for duration: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        let totalSeconds = max(1, Int(duration.rounded()))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        let parts: [(Int, UnitDuration)]
        if hours > 0 {
            parts = [(hours, .hours), minutes > 0 ? (minutes, .minutes) : (seconds, .seconds)]
        } else if minutes > 0 {
            parts = [(minutes, .minutes), (seconds, .seconds)]
        } else {
            parts = [(seconds, .seconds)]
        }

        return parts
            .filter { $0.0 > 0 }
            .map { unit($0.0, $0.1, locale: locale) }
            .formatted(.list(type: .and).locale(locale))
    }

    nonisolated private static func unit(_ value: Int, _ unit: UnitDuration, locale: Locale) -> String {
        Measurement(value: Double(value), unit: unit).formatted(
            .measurement(width: .wide, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0)))
                .locale(locale)
        )
    }
}

nonisolated enum ReasoningTextSanitizer {
    nonisolated private struct Entry {
        let input: String
        let output: String
    }

    // The reasoning view asks for the same text several times per render, and
    // streaming asks once per frame, so the last result is reused while the
    // input is unchanged.
    private static let lastResult = Mutex<Entry?>(nil)

    static func string(from text: String) -> String {
        if let cached = lastResult.withLock({ $0 }), cached.input == text {
            return cached.output
        }
        let output = sanitize(text)
        lastResult.withLock { $0 = Entry(input: text, output: output) }
        return output
    }

    private static func sanitize(_ text: String) -> String {
        // Tags separate reasoning passes around tool calls, so they become
        // paragraph breaks; dropping them would fuse two steps into one.
        var result = text
        if result.range(of: "think", options: .caseInsensitive) != nil {
            result = SharedRegexes.reasoningTag.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "\n\n"
            )
        }
        result = SharedRegexes.blankLineRun.stringByReplacingMatches(
            in: result,
            options: [],
            range: NSRange(result.startIndex..., in: result),
            withTemplate: "\n\n"
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A message's cleaned display text, keyed by the source it was cleaned from.
private struct MessageDisplayTextCache {
    let source: String
    let displayText: String
    var userVisibleText: String?
}

/// Turns stored message text into what the reader sees. Pure and nonisolated,
/// so exports can clean text away from the main actor.
nonisolated enum MessageDisplayTextCleaner {
    static func displayText(from source: String) -> String {
        var result = source

        // Raw reasoning tags never reach the bubble.
        if result.range(of: "<think>", options: .caseInsensitive) != nil
            || result.range(of: "<thinking>", options: .caseInsensitive) != nil {
            result = replacing(_thinkingTagRegex, in: result, with: "")
            if let prefix = result.range(of: "final answer:", options: [.caseInsensitive, .anchored]) {
                result = String(result[prefix.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Qwen3 sometimes wraps responses in <answer> tags.
        if result.range(of: "<answer>", options: .caseInsensitive) != nil {
            result = replacing(_answerTagDisplayRegex, in: result, with: "$1")
        }

        // Hidden image analysis context is for the model only.
        if result.contains("[HIDDEN_IMAGE_CONTEXT]") {
            result = replacing(_hiddenImageContextRegex, in: result, with: "")
        }

        if result.contains("--- Image Analysis Data ---") {
            result = replacing(_imageAnalysisBlockRegex, in: result, with: "")
            if result.hasSuffix("Please respond based on the image analysis data above.") {
                result = result.replacingOccurrences(of: "\n\nPlease respond based on the image analysis data above.", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return result
    }

    /// The display text without `<sources>` blocks.
    static func userVisibleText(from source: String) -> String {
        displayText(from: source).removingSourcesBlocks()
    }

    private static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Collection helpers for Message

nonisolated extension Array where Element == Message {
    /// Returns messages sorted by `order`, breaking ties with `createdAt`.
    var sortedByOrder: [Message] {
        self.sorted {
            if $0.order == $1.order {
                return $0.createdAt < $1.createdAt
            }
            return $0.order < $1.order
        }
    }
}
