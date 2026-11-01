//
//  ChatViewModel+Lifecycle.swift
//  Minnow
//
//  Owns a generation's lifecycle: starting and refusing turns, cancelling,
//  waiting for a reply to unwind, and the chat title task that follows.
//

import Foundation
import os

extension ChatViewModel {

    // MARK: - Public controls

    func cancelGeneration() {
        cancelGeneration(at: Date())
    }

    /// Retire a view model before changing chats. Delayed menu actions must not
    /// restart generation after the UI has selected another conversation.
    func deactivate() {
        isActive = false
        cancelGeneration()
        flushPendingSaveForTeardown()
    }

    internal func cancelGeneration(at cancelledAt: Date) {
        scheduledRegenerationTask?.cancel()
        scheduledRegenerationTask = nil
        autoNamingTask?.cancel()
        if let streamingMessageID,
           let streamingMessage = conversation.messages.first(where: { $0.id == streamingMessageID }),
           streamingMessage.reasoningStartedAt != nil,
           streamingMessage.reasoningCompletedAt == nil {
            streamingMessage.completeReasoningCapture(completedAt: cancelledAt)
            conversation.lastUpdated = cancelledAt
            immediateSave()
        }

        activeGenerationID = nil
        isGenerating = false
        streamingMessageID = nil
        resetStreamingActivity()
        currentStreamTask?.cancel()
        currentGenerationTask?.cancel()
    }

    @discardableResult
    func cancelGenerationAndWait() async -> Bool {
        cancelGeneration()
        return await waitForStreamToFinish()
    }

    // MARK: - Turn Lifecycle

    /// Own the full turn, including image preparation, so cancellation and deletion
    /// wait for every stage that can write messages. A title requested by the turn runs
    /// after the lifecycle ends and is awaited here.
    internal func runGeneration(_ operation: @escaping @MainActor (UUID) async -> Void) async {
        _ = await runTurn(operation)
    }

    /// `runGeneration`, returning false when the turn was refused.
    internal func runTurn(_ operation: @escaping @MainActor (UUID) async -> Void) async -> Bool {
        // A new turn must never preempt a running one: waitForStreamToFinish()
        // force-cancels a task that outlives its timeout. Callers that intend to
        // replace a turn call cancelGeneration() first, which clears this flag.
        guard !isGenerating else {
            logger.notice("Turn refused: another reply is still generating")
            return false
        }
        guard await waitForStreamToFinish(), !isGenerating, !Task.isCancelled,
              let id = beginGenerationLifecycle() else {
            logger.warning("Turn refused: the chat is closed or the previous reply did not finish unwinding")
            return false
        }
        let task = Task { @MainActor in
            defer {
                if self.generationTaskID == id {
                    self.currentGenerationTask = nil
                    self.generationTaskID = nil
                }
                self.endGenerationLifecycle(id)
            }
            guard self.isGenerationActive(id) else { return }
            await operation(id)
        }
        generationTaskID = id
        currentGenerationTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        if let naming = autoNamingTask {
            await withTaskCancellationHandler {
                await naming.value
            } onCancel: {
                naming.cancel()
            }
        }
        return true
    }

    // MARK: - Internals

    internal func waitForStreamToFinish() async -> Bool {
        await cancelAutoNamingAndWait()
        guard let task = currentGenerationTask ?? currentStreamTask else { return activeGenerationID == nil }

        do {
            try await withTimeout(.seconds(4)) {
                await task.value
            }
            return true
        } catch is GenerationTimeoutError {
            logger.warning("waitForStreamToFinish timed out; cancelling task")
            task.cancel()
            // Give cancellation a brief window to propagate before we force-reset.
            if (try? await withTimeout(.seconds(1)) {
                await task.value
            }) != nil {
                return true
            }
            return false
        } catch {
            logger.warning("waitForStreamToFinish saw unexpected error: \((error as NSError).localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    internal func beginGenerationLifecycle() -> UUID? {
        guard isActive, activeGenerationID == nil, currentStreamTask == nil, currentGenerationTask == nil else { return nil }
        let id = UUID()
        activeGenerationID = id
        isGenerating = true
        return id
    }

    internal func isGenerationActive(_ id: UUID) -> Bool {
        activeGenerationID == id && !Task.isCancelled
    }

    internal func endGenerationLifecycle(_ id: UUID) {
        guard activeGenerationID == id else { return }
        activeGenerationID = nil
        isGenerating = false
        streamingMessageID = nil
    }

    // MARK: - Auto Naming

    /// Starts naming the chat once the reply is complete. The title runs in its own task,
    /// after the turn's lifecycle ends, so a slow Apple Intelligence title doesn't keep
    /// the composer showing Stop; `runGeneration` still waits for it before returning.
    internal func scheduleAutoNamingIfNeeded(_ needsAutoNaming: Bool) {
        guard needsAutoNaming, isActive, !Task.isCancelled else { return }
        autoNamingTask?.cancel()
        let taskID = UUID()
        autoNamingTaskID = taskID
        autoNamingTask = Task { @MainActor [weak self] in
            await self?.generateChatTitle()
            guard let self, self.autoNamingTaskID == taskID else { return }
            self.autoNamingTask = nil
            self.autoNamingTaskID = nil
        }
    }

    /// Names the chat now if `needsAutoNaming`, and waits for the title.
    internal func finishAutoNamingIfNeeded(_ needsAutoNaming: Bool) async {
        scheduleAutoNamingIfNeeded(needsAutoNaming)
        await autoNamingTask?.value
    }

    /// Drops a title still being generated from messages that are about to change,
    /// so it can't be applied afterwards; the next reply names the chat again.
    internal func cancelAutoNaming() {
        autoNamingTask?.cancel()
        autoNamingTask = nil
        autoNamingTaskID = nil
    }

    /// A title still being generated yields to anything about to change the chat;
    /// the next reply names it again.
    private func cancelAutoNamingAndWait() async {
        guard let task = autoNamingTask else { return }
        task.cancel()
        await task.value
    }
}
