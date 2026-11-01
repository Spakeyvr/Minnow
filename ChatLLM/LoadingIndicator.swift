//
//  LoadingIndicator.swift
//  ChatLLM
//
//  Reusable loading views: an animated label whose trailing dots cycle
//  1 → 2 → 3 → 1 to signal liveness, plus a convenience wrapper that
//  pairs it with a spinner.
//

import SwiftUI

/// Just the animated text label — pair with your own spinner when you
/// already render one (e.g. inside a toolbar capsule).
struct LoadingDotsLabel: View {
    var label: LocalizedStringKey = "Loading"
    var font: Font = .subheadline
    var color: Color = .secondary

    static let dotInterval: TimeInterval = 0.4

    /// The dot count is read off the clock rather than kept in state, so a parent
    /// that re-renders often (a progress update, say) cannot reset or stall it.
    /// Rounding, not truncation, keeps a timeline entry that lands a hair before
    /// its interval from repeating the previous count.
    static func dotCount(at date: Date) -> Int {
        let step = Int((date.timeIntervalSinceReferenceDate / dotInterval).rounded())
        return ((step % 3) + 3) % 3 + 1
    }

    var body: some View {
        TimelineView(.periodic(from: .distantPast, by: Self.dotInterval)) { context in
            Text("\(Text(label))\(String(repeating: ".", count: Self.dotCount(at: context.date)))")
                .font(font)
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .accessibilityLabel(Text(label))
    }
}

/// Spinner + animated label. Use for full-screen / empty-state loading.
struct LoadingIndicator: View {
    var label: LocalizedStringKey = "Loading"

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
            LoadingDotsLabel(label: label)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(label))
    }
}
