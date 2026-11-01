//
//  ChatViewModel+StreamWatchdog.swift
//  Minnow
//

import Foundation

extension ChatViewModel {

    /// Fails a stream that has gone silent for longer than its current timeout. One
    /// long-lived task replaces a timeout race per token: each event only records the
    /// time, and the watchdog re-checks the deadline when it wakes, so a search that
    /// starts mid-wait extends the allowance.
    @MainActor
    final class StreamWatchdog {
        private let timeouts: StreamTimeouts
        private let chunkTimeout: Duration
        private let isSearching: @MainActor () -> Bool
        private var lastEventAt = ContinuousClock.now
        private var task: Task<Void, Never>?
        var hasOutput = false

        /// The prompt is processed before the first token and again after each
        /// tool result, and emits nothing meanwhile, so those waits get extra time.
        private let prefillAllowance: Duration
        var awaitingPrefill = true

        init(
            timeouts: StreamTimeouts,
            chunkTimeout: Duration,
            prefillAllowance: Duration,
            isSearching: @escaping @MainActor () -> Bool
        ) {
            self.timeouts = timeouts
            self.chunkTimeout = chunkTimeout
            self.prefillAllowance = prefillAllowance
            self.isSearching = isSearching
        }

        private var currentTimeout: Duration {
            if isSearching() { return timeouts.webSearch }
            return (hasOutput ? chunkTimeout : timeouts.firstToken)
                + (awaitingPrefill ? prefillAllowance : .zero)
        }

        func recordEvent() {
            lastEventAt = .now
        }

        func start(onExpire: @escaping @MainActor @Sendable (Duration) -> Void) {
            lastEventAt = .now
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let timeout = self.currentTimeout
                    let deadline = self.lastEventAt.advanced(by: timeout)
                    if ContinuousClock.now >= deadline {
                        onExpire(timeout)
                        return
                    }
                    do {
                        try await Task.sleep(until: deadline, clock: .continuous)
                    } catch {
                        return
                    }
                }
            }
        }

        func stop() {
            task?.cancel()
            task = nil
        }
    }
}
