//
//  ChatViewModel+FoundationModelsLock.swift
//  Minnow
//

import Foundation

extension ChatViewModel {

    // MARK: - Foundation Models Session Management

    /// Serializes Foundation Models operations so only one session runs at a time,
    /// preventing "accumulator already completed" errors.
    func withFoundationModelsLock<T: Sendable>(
        timeout: Duration = .seconds(15),
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await Self.fmGate.acquire()
        let gateLease = FoundationModelsGateLease(gate: Self.fmGate)

        let operationTask = Task<T, Error> {
            do {
                let value = try await operation()
                await gateLease.release()
                return value
            } catch {
                await gateLease.release()
                throw error
            }
        }

        do {
            return try await withTimeout(timeout) {
                try await operationTask.value
            }
        } catch {
            // The operation releases its permit when it actually exits. A
            // timeout must not allow a second session to overlap a slow unwind.
            operationTask.cancel()
            throw error
        }
    }
}
