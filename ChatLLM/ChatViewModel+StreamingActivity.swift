//
//  ChatViewModel+StreamingActivity.swift
//  ChatLLM
//
//  The shimmering status label shown while a reply streams: "Loading…" until the
//  first token, "Thinking…" afterwards, and "Searching…" while a web search runs.
//

import Foundation
import Observation
import UIKit

/// The streaming status of one chat. Unlike `ChatViewModel`'s `objectWillChange`, which
/// invalidates every view holding the view model, each property here is tracked on its
/// own: a message cell that calls `isStreaming(_:)` re-renders only when generation
/// starts or stops or the streaming message changes, and only the views that read
/// `activity` re-render when the status label changes.
@MainActor
@Observable
final class ChatStreamingState {
    var isGenerating = false
    var streamingMessageID: UUID?
    var activity: StreamingActivity = .loading

    func isStreaming(_ messageID: UUID) -> Bool {
        isGenerating && streamingMessageID == messageID
    }
}

/// Timing of the glow that sweeps across the streaming status label. The label draws the
/// sweep, and the view model waits for it before changing the label's text.
nonisolated enum ShimmerTiming {
    static let period: TimeInterval = 1.6
    /// Half the glow band's width, as a fraction of the label's width.
    static let bandHalfWidth: CGFloat = 0.25

    /// The band's centre: sweeps from -0.4 to 1.4 once per period, phase-locked to the clock.
    static func offset(at date: Date) -> CGFloat {
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period
        return -0.4 + 1.8 * CGFloat(phase)
    }

    /// Time until the glow band currently crossing the label has left it, or 0 when no band
    /// is over the label. Swapping the text then never cuts a sweep off mid-word.
    static func remainingSweepDuration(at date: Date) -> TimeInterval {
        let centre = offset(at: date)
        let bandIsOverLabel = centre + bandHalfWidth > 0 && centre - bandHalfWidth < 1
        guard bandIsOverLabel else { return 0 }
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period
        let phaseWhenBandLeaves = (1 + bandHalfWidth + 0.4) / 1.8
        return (Double(phaseWhenBandLeaves) - phase) * period
    }
}

enum StreamingActivity: Equatable {
    case loading
    case thinking
    case searching

    /// What the reply is doing right now, from the stream's progress.
    static func current(hasReceivedOutput: Bool, isSearching: Bool) -> StreamingActivity {
        if isSearching { return .searching }
        return hasReceivedOutput ? .thinking : .loading
    }

    func label(locale: Locale = .current) -> String {
        switch self {
        case .loading: String(localized: "Loading…", bundle: .appLocalized, locale: locale)
        case .thinking: String(localized: "Thinking…", bundle: .appLocalized, locale: locale)
        case .searching: String(localized: "Searching…", bundle: .appLocalized, locale: locale)
        }
    }
}

extension ChatViewModel {

    /// Switches the status label to `activity` once the glow currently sweeping across it
    /// has finished, so the text never changes mid-sweep. While a switch is waiting, only
    /// the most recent request is applied.
    func requestStreamingActivity(_ activity: StreamingActivity, now: Date = Date()) {
        guard activity != streamingActivity else {
            cancelPendingStreamingActivity()
            return
        }
        pendingStreamingActivity = activity
        // A switch is already waiting for the sweep to end; it will pick up the new target.
        guard streamingActivityTask == nil else { return }

        let delay = UIAccessibility.isReduceMotionEnabled
            ? 0
            : ShimmerTiming.remainingSweepDuration(at: now)
        guard delay > 0 else {
            applyPendingStreamingActivity()
            return
        }
        streamingActivityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.streamingActivityTask = nil
            self.applyPendingStreamingActivity()
        }
    }

    /// Starts a new reply at "Loading…" without waiting for a sweep.
    func resetStreamingActivity() {
        cancelPendingStreamingActivity()
        streamingActivity = .loading
    }

    private func applyPendingStreamingActivity() {
        guard let pending = pendingStreamingActivity else { return }
        pendingStreamingActivity = nil
        streamingActivity = pending
    }

    private func cancelPendingStreamingActivity() {
        streamingActivityTask?.cancel()
        streamingActivityTask = nil
        pendingStreamingActivity = nil
    }
}
