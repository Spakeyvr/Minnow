//
//  ChatViewModel+Timeout.swift
//  ChatLLM
//
//  Races an async operation against a deadline.
//

import Foundation

/// Every mutable field is read and written under `lock`.
nonisolated private final class TimeoutRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private var continuation: CheckedContinuation<T, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func start(
        duration: Duration,
        operation: @escaping @Sendable () async throws -> T,
        continuation: CheckedContinuation<T, Error>
    ) {
        // withTaskCancellationHandler runs onCancel before the body when the caller is
        // already cancelled, so cancel() can finish the race before a continuation exists.
        // Resume it here; storing it would leave the caller suspended forever.
        let alreadyFinished = lock.withLock { () -> Bool in
            guard !didResume else { return true }
            self.continuation = continuation
            return false
        }
        if alreadyFinished {
            continuation.resume(throwing: CancellationError())
            return
        }

        let operationTask = Task {
            do {
                try Task.checkCancellation()
                let value = try await operation()
                resume(with: .success(value))
            } catch {
                resume(with: .failure(error))
            }
        }

        let timeoutTask = Task {
            do {
                try await Task.sleep(for: duration)
                resume(with: .failure(ChatViewModel.GenerationTimeoutError(timeout: duration)))
            } catch {
                // Cancellation means the operation completed or the caller cancelled.
            }
        }

        let shouldCancelStartedTasks = lock.withLock { () -> Bool in
            guard !didResume else { return true }
            self.operationTask = operationTask
            self.timeoutTask = timeoutTask
            return false
        }
        if shouldCancelStartedTasks {
            operationTask.cancel()
            timeoutTask.cancel()
        }
    }

    func cancel() {
        resume(with: .failure(CancellationError()))
    }

    private func resume(with result: Result<T, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<T, Error>? in
            guard !didResume else { return nil }
            didResume = true
            let continuation = self.continuation
            self.continuation = nil
            operationTask?.cancel()
            timeoutTask?.cancel()
            return continuation
        }
        if let continuation {
            continuation.resume(with: result)
        }
    }
}

extension ChatViewModel {

    func withTimeout<T: Sendable>(_ duration: Duration, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let race = TimeoutRace<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(duration: duration, operation: operation, continuation: continuation)
            }
        } onCancel: {
            race.cancel()
        }
    }
}
