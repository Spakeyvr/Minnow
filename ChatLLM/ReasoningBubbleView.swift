//
//  ReasoningBubbleView.swift
//  ChatLLM
//
//  Created by Nevio on 10/24/25.
//

import SwiftUI

// MARK: - Inline thinking indicator shown during streaming

struct InlineThinkingView: View {
    var text: String = Strings.thinking
    let onTap: (() -> Void)?
    /// Whether the shimmer plays. Stays on while reasoning streams, even once the label becomes tappable.
    var isAnimating: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Forwards to `ShimmerTiming`, which the view model also uses to time label changes.
    static var shimmerPeriod: TimeInterval { ShimmerTiming.period }
    /// Half the width of the glow band, in unit-point space.
    private static var shimmerBandHalfWidth: CGFloat { ShimmerTiming.bandHalfWidth }

    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) {
                    thinkingLabel(animatesGlow: isAnimating)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("message.thought")
            } else {
                // Same frame as the tappable branch so the label doesn't jump
                // when the first reasoning token makes it tappable.
                thinkingLabel(animatesGlow: isAnimating)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("message.thought")
            }
        }
    }

    /// Sweeps from -0.4 to 1.4 once per period, phase-locked to the clock.
    static func shimmerOffset(at date: Date) -> CGFloat {
        ShimmerTiming.offset(at: date)
    }

    /// Time until the glow band currently crossing the label has left it, or 0 when no band
    /// is over the label. Swapping the text then never cuts a sweep off mid-word.
    static func remainingSweepDuration(at date: Date) -> TimeInterval {
        ShimmerTiming.remainingSweepDuration(at: date)
    }

    @ViewBuilder
    private func thinkingLabel(animatesGlow: Bool) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: text)
            .overlay {
                if animatesGlow && !reduceMotion {
                    // Derive the sweep from wall-clock time rather than view state, so the
                    // shimmer continues seamlessly when the label is rebuilt mid-stream
                    // (placeholder → reasoning bubble, plain → tappable).
                    // Capped at 30 fps: the sweep stays smooth without re-rendering on every
                    // ProMotion frame while the main actor is busy streaming tokens.
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let shimmerOffset = Self.shimmerOffset(at: context.date)
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .white.opacity(0.85), location: 0.5),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: UnitPoint(x: shimmerOffset - Self.shimmerBandHalfWidth, y: 0.5),
                            endPoint: UnitPoint(x: shimmerOffset + Self.shimmerBandHalfWidth, y: 0.5)
                        )
                    }
                    .mask {
                        Text(text)
                            .font(.subheadline)
                    }
                    .blendMode(.plusLighter)
                    .accessibilityHidden(true)
                }
            }
    }
}

// MARK: - Reasoning steps

/// Splits sanitized reasoning into the steps the reasoning sheet shows.
///
/// Steps are separated by blank lines, but a blank line inside a fenced code
/// block or a display formula does not end a step: splitting there would render
/// half a fence or half a formula in each step. Search anchors count the
/// blank-line pieces (see `ChatViewModel.reasoningPieceCount(for:)`), so each segment
/// records which pieces it covers.
nonisolated enum ReasoningStepSegmenter {
    nonisolated struct Segment: Equatable, Sendable {
        let text: String
        /// The zero-based blank-line pieces this segment joins.
        let pieces: ClosedRange<Int>
    }

    static func segments(from text: String) -> [Segment] {
        let pieces = text
            .components(separatedBy: "\n\n")
            .filter { $0.contains(where: { !$0.isWhitespace }) }
        var segments: [Segment] = []
        var current: [String] = []
        var firstPiece = 0
        var openBlock = OpenBlockTracker()

        for (index, piece) in pieces.enumerated() {
            if !current.isEmpty, !openBlock.isOpen, !continuesPreviousPiece(piece) {
                segments.append(Segment(text: joined(current), pieces: firstPiece...(index - 1)))
                current.removeAll()
                firstPiece = index
            }
            current.append(piece)
            openBlock.consume(piece)
        }
        if !current.isEmpty {
            segments.append(Segment(text: joined(current), pieces: firstPiece...(pieces.count - 1)))
        }
        return segments
    }

    /// An indented piece continues the list item above it.
    private static func continuesPreviousPiece(_ piece: String) -> Bool {
        piece.hasPrefix("  ") || piece.hasPrefix("\t")
    }

    private static func joined(_ pieces: [String]) -> String {
        pieces.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Follows fences and display math across lines, with the parser's fence rules.
    private struct OpenBlockTracker {
        private var fence: MarkdownBlockParser.Fence?
        private var mathCloser: String?

        var isOpen: Bool { fence != nil || mathCloser != nil }

        mutating func consume(_ piece: String) {
            for line in piece.components(separatedBy: "\n") {
                if let openFence = fence {
                    if MarkdownBlockParser.isFenceClosing(line, fence: openFence) { fence = nil }
                    continue
                }
                if let closer = mathCloser {
                    if line.contains(closer) { mathCloser = nil }
                    continue
                }
                if let opening = MarkdownBlockParser.fenceOpening(line) {
                    fence = opening
                    continue
                }
                mathCloser = Self.unclosedDisplayMath(startingLine: line)
            }
        }

        /// The delimiter still owed by display math that starts this line, if any.
        /// Mirrors the math document's block rule: only a display delimiter at
        /// the start of a line may span blank lines.
        private static func unclosedDisplayMath(startingLine line: String) -> String? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("$$") {
                return trimmed.dropFirst(2).contains("$$") ? nil : "$$"
            }
            if trimmed.hasPrefix("\\[") {
                return trimmed.dropFirst(2).contains("\\]") ? nil : "\\]"
            }
            let begin = "\\begin{"
            if trimmed.hasPrefix(begin), let close = trimmed.firstIndex(of: "}") {
                let environment = trimmed[trimmed.index(trimmed.startIndex, offsetBy: begin.count)..<close]
                let closer = "\\end{\(environment)}"
                return trimmed.contains(closer) ? nil : closer
            }
            return nil
        }
    }
}

// MARK: - Step-by-Step Reasoning Sheet

struct StepByStepReasoningSheet: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    let reasoning: String
    let searchInvocations: [SearchInvocation]?
    /// Built once: sanitizing, splitting and ordering the searches are full passes
    /// over the reasoning, and the rows are rendered from this list.
    private let timelineItems: [TimelineItem]
    @State private var selectedInvocation: SearchInvocation?
    @State private var selectedDetent: PresentationDetent = .medium

    enum TimelineItem: Identifiable {
        case reasoningChunk(Int, String)
        case search(SearchInvocation)

        var id: String {
            switch self {
            case .reasoningChunk(let index, _):
                return "reasoning-\(index)"
            case .search(let invocation):
                return "search-\(invocation.id.uuidString)"
            }
        }
    }

    init(reasoning: String, searchInvocations: [SearchInvocation]?) {
        self.reasoning = reasoning
        self.searchInvocations = searchInvocations
        self.timelineItems = Self.makeTimeline(reasoning: reasoning, searchInvocations: searchInvocations)
    }

    /// Reasoning steps interleaved with the searches anchored after them.
    static func makeTimeline(reasoning: String, searchInvocations: [SearchInvocation]?) -> [TimelineItem] {
        let segments = ReasoningStepSegmenter.segments(from: ReasoningTextSanitizer.string(from: reasoning))
        let searches = (searchInvocations ?? []).sorted { lhs, rhs in
            if lhs.anchorStepNumber == rhs.anchorStepNumber {
                return lhs.timestamp < rhs.timestamp
            }
            return (lhs.anchorStepNumber ?? 0) < (rhs.anchorStepNumber ?? 0)
        }

        guard let pieceCount = segments.last.map({ $0.pieces.upperBound + 1 }) else {
            return searches.map(TimelineItem.search)
        }

        var items: [TimelineItem] = []

        let leadingSearches = searches.filter { ($0.anchorStepNumber ?? 0) <= 0 }
        items.append(contentsOf: leadingSearches.map(TimelineItem.search))

        for segment in segments {
            items.append(.reasoningChunk(segment.pieces.lowerBound, segment.text))
            // A search anchored after piece N follows the segment holding piece N.
            let anchoredSearches = searches.filter {
                guard let anchor = $0.anchorStepNumber else { return false }
                return segment.pieces.contains(anchor - 1)
            }
            items.append(contentsOf: anchoredSearches.map(TimelineItem.search))
        }

        let trailingSearches = searches.filter { ($0.anchorStepNumber ?? 0) > pieceCount }
        items.append(contentsOf: trailingSearches.map(TimelineItem.search))

        return items
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !timelineItems.isEmpty {
                        let lastIndex = timelineItems.count - 1
                        // Lazy: a long trace builds only the steps on screen, and so
                        // only those holding math take a web view.
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(timelineItems.enumerated()), id: \.element.id) { index, item in
                                switch item {
                                case .reasoningChunk(_, let text):
                                    RawReasoningChunkView(
                                        text: text,
                                        isLast: index == lastIndex
                                    )
                                case .search(let invocation):
                                    SearchStepCard(invocation: invocation) {
                                        if !invocation.displaySources.isEmpty {
                                            selectedInvocation = invocation
                                        }
                                    }
                                    .padding(.bottom, index == lastIndex ? 0 : 20)
                                }
                            }
                        }
                    } else {
                        Text("No reasoning content available.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    }
                }
                .padding()
            }
            .navigationTitle("Reasoning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("sheet.close")
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .sheet(item: $selectedInvocation) { invocation in
            SourcesSheetView(
                invocations: [invocation],
                title: String(localized: "Search Results", bundle: .appLocalized, locale: locale)
            )
        }
    }
}

struct RawReasoningChunkView: View {
    let text: String
    let isLast: Bool
    @AppStorage(AppSettingsKeys.messageFontSize) private var messageFontSize: Double = 16.0

    var body: some View {
        RichMarkdownView(
            text: text,
            fontSize: messageFontSize
        )
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, isLast ? 0 : 20)
    }
}

// MARK: - Search step card for reasoning flow (display only — parent owns the sheet)

struct SearchStepCard: View {
    @Environment(\.locale) private var locale
    let invocation: SearchInvocation
    let onTap: () -> Void

    private var statusTitle: String {
        switch invocation.status {
        case .searching: String(localized: "Searching the web", bundle: .appLocalized, locale: locale)
        case .completed: String(localized: "Searched the web", bundle: .appLocalized, locale: locale)
        case .failed: String(localized: "Web search failed", bundle: .appLocalized, locale: locale)
        }
    }

    private var statusDetail: String {
        switch invocation.status {
        case .searching:
            return String(localized: "Waiting for results…", bundle: .appLocalized, locale: locale)
        case .completed:
            let count = invocation.sourceCount
            let sources = String(localized: "\(count) sources", bundle: .appLocalized, locale: locale)
            guard let duration = invocation.durationMilliseconds else { return sources }
            return String(localized: "\(sources) · \(duration) ms", bundle: .appLocalized, locale: locale)
        case .failed:
            return invocation.errorDescription ?? String(localized: "Search could not be completed.", bundle: .appLocalized, locale: locale)
        }
    }

    private var statusIcon: String {
        switch invocation.status {
        case .searching: "magnifyingglass"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch invocation.status {
        case .searching: .secondary
        case .completed: .green
        case .failed: .red
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: statusIcon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(statusColor)
                    .frame(width: 18, height: 18)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(statusTitle)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 0)

                        if !invocation.displaySources.isEmpty {
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Text(invocation.query)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous)
                    .fill(.thinMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(invocation.displaySources.isEmpty)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous))
        .contentShape(Rectangle())
    }
}
