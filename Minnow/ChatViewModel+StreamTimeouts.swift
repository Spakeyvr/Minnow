//
//  ChatViewModel+StreamTimeouts.swift
//  Minnow
//

import Foundation

extension ChatViewModel {

    // MARK: - Timeouts

    /// How long a reply may go without producing an event before it fails.
    struct StreamTimeouts {
        /// The first event also covers model warm-up and prompt prefill.
        var firstToken: Duration = .seconds(30)
        var chunk: Duration = .seconds(20)
        var reasoningChunk: Duration = .seconds(30)
        /// Covers a Tavily search including its retry (see TavilySearchService:
        /// two 15 s requests plus a bounded Retry-After wait).
        var webSearch: Duration = .seconds(60)
        /// How long a reply waits for an MLX model that is still loading.
        var modelLoad: Duration = .seconds(120)
    }

    /// Slowest prompt processing a wait for the next token allows for.
    /// LFM2.5 2.6B processed a 9K-token prompt at about 160 tokens/s on an
    /// iPhone 16 Pro; larger models and older phones are slower.
    nonisolated static let slowestPrefillTokensPerSecond = 40.0

    /// Extra time for prompt processing, which emits nothing until it ends, so
    /// a long prompt no longer trips the fixed first-token timeout.
    nonisolated static func prefillAllowance(forPromptTokens tokens: Int) -> Duration {
        .seconds(Double(max(tokens, 0)) / slowestPrefillTokensPerSecond)
    }
}
