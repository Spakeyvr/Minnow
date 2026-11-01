//
//  ChatViewModel+Regeneration.swift
//  ChatLLM
//
//  Created by Nevio on 10/24/25.
//

import Foundation
import SwiftData
import os

struct UserMessageEditRewindResult: Equatable {
    let messageID: UUID
    let restoredText: String
    let requiresTitleRegeneration: Bool
}

extension ChatViewModel {

    // MARK: - Scheduled Regeneration (Menu-Safe)

    /// A menu may disappear before this starts; the view model owns the delay
    /// so stopping or leaving the chat still cancels the pending action.
    func scheduleRegeneration(messageID: UUID, instruction: String?) {
        guard isActive else { return }
        scheduledRegenerationTask?.cancel()
        scheduledRegenerationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            guard let self, self.isActive, !Task.isCancelled else { return }
            if let instruction {
                await self.regenerateReplacingAssistant(messageID: messageID, instruction: instruction)
            } else {
                await self.regenerateAfterAssistant(messageID: messageID)
            }
        }
    }

    func regenerateAfterAssistant(messageID: UUID) async {
        guard canStartRegeneration(logContext: "Regenerate") else { return }
        isRegenerating = true
        defer { isRegenerating = false }

        // A send that resumed first during the wait owns the chat now.
        guard isActive, !Task.isCancelled, await waitForStreamToFinish(),
              isActive, !Task.isCancelled, !isGenerating else { return }

        guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else {
            logger.warning("Regenerate failed: message not found")
            return
        }
        // Force SwiftData fault resolution before async boundaries
        let messageRole = conversation.messages[index].role
        let messageOrder = conversation.messages[index].order

        guard messageRole == .assistant else {
            logger.warning("Regenerate failed: message is not an assistant message")
            return
        }

        logger.debug("Starting regeneration for message order \(messageOrder, privacy: .public)")

        deleteMessages(after: messageOrder)
        renumberMessagesByOrder()

        guard let updatedIndex = conversation.messages.firstIndex(where: { $0.id == messageID }) else {
            logger.error("Target message disappeared after renumbering")
            return
        }
        let updatedOrder = conversation.messages[updatedIndex].order

        conversation.lastUpdated = Date()
        immediateSave()

        // CRITICAL FIX (Bug 2): Use updatedOrder (post-renumber) instead of stale messageOrder
        let precedingUserMessage = conversation.messages
            .filter { $0.role == .user && $0.order < updatedOrder }
            .sortedByOrder
            .last

        let shouldUseReasoning = resolvedReasoningMode(for: precedingUserMessage)

        guard isActive, !Task.isCancelled else {
            logger.warning("Regenerate cancelled after reasoning evaluation")
            return
        }

        // CRITICAL FIX: Look up by ID, not index; SwiftData can reorder the array between lookups.
        guard let targetMessage = conversation.messages.first(where: { $0.id == messageID }) else {
            logger.error("Target message disappeared before applying reasoning mode")
            return
        }

        targetMessage.promptSnapshot = nil
        conversation.lastUpdated = Date()
        immediateSave()
        invalidateMLXConversationSession(reason: "regenerate_after_assistant")

        // basedOnHistoryUpTo is exclusive, so the prompt excludes this assistant
        // message itself while including all preceding user messages.
        await streamAssistant(
            into: targetMessage,
            basedOnHistoryUpTo: targetMessage.order,
            disableWebSearch: answersImageMessage(targetMessage),
            reasoningMode: shouldUseReasoning
        )
        logger.debug("Regeneration completed for message order \(messageOrder, privacy: .public)")
    }

    private func deleteMessages(after order: Int) {
        let messagesToDelete = conversation.messages.filter { $0.order > order }
        let idsToDelete = Set(messagesToDelete.map(\.id))
        conversation.messages.removeAll { idsToDelete.contains($0.id) }
        for message in messagesToDelete {
            context.delete(message)
        }
    }

    func regenerateReplacingAssistant(messageID: UUID, instruction: String) async {
        guard canStartRegeneration(logContext: "Regenerate with instruction") else { return }
        isRegenerating = true
        defer { isRegenerating = false }

        // A send that resumed first during the wait owns the chat now.
        guard isActive, !Task.isCancelled, await waitForStreamToFinish(),
              isActive, !Task.isCancelled, !isGenerating else { return }

        guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else {
            logger.warning("Regenerate with instruction failed: message not found")
            return
        }
        // Force SwiftData fault resolution before async boundaries
        let messageRole = conversation.messages[index].role

        guard messageRole == .assistant else {
            logger.warning("Regenerate with instruction failed: message is not an assistant message")
            return
        }

        logger.debug("Starting regeneration with custom instruction")

        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let shouldUseReasoning = resolvedReasoningMode(for: trimmed)

        guard isActive, !Task.isCancelled else {
            logger.warning("Regenerate with instruction cancelled after reasoning evaluation")
            return
        }

        guard let targetMessage = conversation.messages.first(where: { $0.id == messageID }) else {
            logger.error("Target message disappeared after reasoning evaluation")
            return
        }
        targetMessage.promptSnapshot = nil
        conversation.lastUpdated = Date()
        immediateSave()
        invalidateMLXConversationSession(reason: "regenerate_with_instruction")

        // Do NOT insert a new user message; the instruction is passed transiently only.
        await streamAssistant(
            into: targetMessage,
            basedOnHistoryUpTo: targetMessage.order,
            additionalUserInstruction: trimmed,
            disableWebSearch: answersImageMessage(targetMessage),
            reasoningMode: shouldUseReasoning
        )
    }

    /// Image turns are answered without web search (see `sendWithImage`), so a
    /// regenerated reply to one must not search either.
    private func answersImageMessage(_ reply: Message) -> Bool {
        let question = conversation.messages
            .filter { $0.role == .user && $0.order < reply.order }
            .max { $0.order < $1.order }
        return question?.attachments.isEmpty == false
    }

    @discardableResult
    func rewindForEditingUserMessage(
        messageID: UUID,
        replacementText: String? = nil
    ) -> UserMessageEditRewindResult? {
        guard !isGenerating, !isRegenerating else {
            logger.warning("Edit failed: generation is in progress")
            return nil
        }

        guard let message = conversation.messages.first(where: { $0.id == messageID }) else {
            logger.warning("Edit failed: message not found")
            return nil
        }

        guard message.role == .user else {
            logger.warning("Edit failed: message is not a user message")
            return nil
        }

        let restoredText = message.text
        let isFirstUserMessage = !conversation.messages.contains {
            $0.role == .user && $0.order < message.order
        }
        let requiresTitleRegeneration = isFirstUserMessage && conversation.hasAutoGeneratedTitle
        cancelAutoNaming()
        deleteMessages(after: message.order)
        if let replacementText {
            message.text = replacementText
        }

        renumberMessagesByOrder()
        if requiresTitleRegeneration {
            conversation.title = String(localized: "New Chat", bundle: .appLocalized)
            conversation.hasAutoGeneratedTitle = false
        }
        conversation.lastUpdated = Date()
        immediateSave()
        invalidateMLXConversationSession(reason: "rewind_for_user_message_edit")

        return UserMessageEditRewindResult(
            messageID: message.id,
            restoredText: restoredText,
            requiresTitleRegeneration: requiresTitleRegeneration
        )
    }

    /// Deletes one message, stopping its reply first if it is still streaming.
    func deleteMessage(_ message: Message) async {
        if isGenerating, let streamingID = streamingMessageID, streamingID == message.id {
            cancelGeneration()
            guard isActive, !Task.isCancelled, await waitForStreamToFinish(),
              isActive, !Task.isCancelled else { return }
        }

        cancelAutoNaming()
        context.delete(message)
        conversation.messages.removeAll { $0.id == message.id }
        renumberMessagesByOrder()
        conversation.lastUpdated = Date()
        immediateSave()
        invalidateMLXConversationSession(reason: "message_deleted")
    }

    // MARK: - Private Helpers

    /// A regeneration replaces the reply it targets and deletes what follows, so it must
    /// not wait on (and then force-cancel) a turn it doesn't own. Stopping a reply clears
    /// `isGenerating` at once, so a regeneration right after Stop still proceeds and
    /// waits for that reply to unwind.
    private func canStartRegeneration(logContext: String) -> Bool {
        guard !isRegenerating else {
            logger.warning("\(logContext, privacy: .public) failed: already regenerating (double-tap protection)")
            return false
        }
        guard !isGenerating else {
            logger.warning("\(logContext, privacy: .public) failed: another reply is generating")
            return false
        }
        return true
    }
}
