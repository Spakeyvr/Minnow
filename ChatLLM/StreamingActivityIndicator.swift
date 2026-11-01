//
//  StreamingActivityIndicator.swift
//  ChatLLM
//

import SwiftUI

// MARK: - Streaming activity indicator

/// The shimmering "Thinking…" / "Searching…" row under a reply that is streaming.
/// For full-screen loading states use `LoadingIndicator`.
struct StreamingActivityIndicator: View {
    @Environment(\.locale) private var locale
    var activity: StreamingActivity = .loading

    var body: some View {
        InlineThinkingView(text: activity.label(locale: locale), onTap: nil)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
