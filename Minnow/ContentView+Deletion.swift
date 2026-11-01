//
//  ContentView+Deletion.swift
//  Minnow
//
//  Deleting chats (one, all, all but the open one, and auto-delete by age),
//  and removing the image files they leave behind.
//

import SwiftUI
import SwiftData
import OSLog

extension ContentView {

    // MARK: - Attachment Files

    private func attachmentURLs(in conversations: [Conversation]) -> [URL] {
        conversations
            .flatMap(\.messages)
            .flatMap(\.attachments)
            .map(\.actualFileURL)
    }

    private func deleteAttachmentFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            for url in urls {
                try? await ImageStore.shared.delete(url: url)
                await ImageStore.shared.deleteInferenceVariant(for: url)
            }
        }
    }

    func scheduleAttachmentStorageCleanup(excludingConversationIDs excludedConversationIDs: Set<UUID> = []) {
        attachmentCleanupTask?.cancel()
        attachmentCleanupTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }

            // A failed fetch must skip cleanup: an empty set would delete every image.
            guard let referencedURLs = try? MessageAttachment.referencedFileURLs(
                in: modelContext,
                excludingConversationIDs: excludedConversationIDs
            ) else { return }
            try? await ImageStore.shared.cleanupOrphanedFiles(referencedURLs: referencedURLs)
        }
    }

    // MARK: - Single Deletion

    func delete(_ conversation: Conversation) {
        Task {
            await deleteAfterStoppingGeneration(conversation)
        }
    }

    private func deleteAfterStoppingGeneration(_ conversation: Conversation) async {
        let conversationID = conversation.id
        // A second confirmation for the same chat, or a chat already gone.
        guard conversations.contains(where: { $0.id == conversationID }) else { return }

        AppHaptics.impact(.medium)

        // Like the bulk deletions: the reply must stop before its chat goes away, or the
        // stream keeps writing to a deleted conversation.
        guard await stopGenerationBeforeDeleting(conversationIDs: [conversationID]),
              conversations.contains(where: { $0.id == conversationID }) else {
            return
        }

        let previousSelection = selection
        let attachmentURLsToDelete = attachmentURLs(in: [conversation])

        // Deleting the open chat replaces it with a blank one behind the sidebar,
        // so the user never lands on an empty placeholder.
        if selection?.id == conversationID {
            openDraftChat()
        }

        withAnimation {
            modelContext.delete(conversation)
        }

        do {
            try modelContext.save()
            deleteAttachmentFiles(attachmentURLsToDelete)
            scheduleAttachmentStorageCleanup(excludingConversationIDs: [conversationID])
            AppHaptics.notification(.success)
        } catch {
            contentLogger.error("Failed to save after deleting conversation: \((error as NSError).localizedDescription, privacy: .public)")
            rollBackFailedDeletion(restoringSelection: previousSelection)
            AppHaptics.notification(.error)
            errorMessage = String(localized: "Failed to delete conversation. Please try again.", bundle: .appLocalized)
        }
    }

    /// Undoes a deletion whose save failed: the chats stay listed instead of waiting,
    /// marked deleted, for a later save to remove them anyway, and their files are kept.
    private func rollBackFailedDeletion(restoringSelection previousSelection: Conversation?) {
        modelContext.rollback()
        if let previousSelection, selection?.id != previousSelection.id {
            // Reopens the chat and retires the blank draft that stood in for it.
            selection = previousSelection
        }
    }

    // MARK: - Bulk Deletion

    func deleteAllChats() {
        Task {
            await deleteAllChatsAfterStoppingGeneration()
        }
    }

    private func deleteAllChatsAfterStoppingGeneration() async {
        AppHaptics.impact(.heavy)

        let conversationsToDelete = Array(conversations)
        let conversationIDsToDelete = Set(conversationsToDelete.map(\.id))
        guard await stopGenerationBeforeDeleting(conversationIDs: conversationIDsToDelete) else {
            return
        }

        let previousSelection = selection
        // stopGenerationBeforeDeleting retired the open chat's view model if it
        // is being deleted. An open draft is unaffected and stays as it is;
        // otherwise replace the deleted chat with a blank one, as a single
        // delete does. Clearing the view model under a draft would strand the
        // UI: New Chat only reveals an existing draft.
        if draftConversation == nil {
            openDraftChat()
        }

        let excludedConversationIDs = conversationIDsToDelete
        let attachmentURLsToDelete = attachmentURLs(in: conversationsToDelete)

        // Delete everything
        for convo in conversationsToDelete {
            modelContext.delete(convo)
        }

        do {
            try modelContext.save()
            deleteAttachmentFiles(attachmentURLsToDelete)
            scheduleAttachmentStorageCleanup(excludingConversationIDs: excludedConversationIDs)
            AppHaptics.notification(.success)
        } catch {
            contentLogger.error("Failed to save after deleting all conversations: \((error as NSError).localizedDescription, privacy: .public)")
            rollBackFailedDeletion(restoringSelection: previousSelection)
            AppHaptics.notification(.error)
            errorMessage = String(localized: "Failed to delete all conversations. Please try again.", bundle: .appLocalized)
        }
    }

    func deleteAllExceptCurrent() {
        Task {
            await deleteAllExceptCurrentAfterStoppingGeneration()
        }
    }

    private func deleteAllExceptCurrentAfterStoppingGeneration() async {
        AppHaptics.impact(.heavy)

        // The open chat stays, or the most recent one when none is open. An open
        // draft stays open too, so the user is not moved to another chat.
        let plan = ChatNavigationRules.deleteAllExceptCurrentPlan(
            conversationIDs: conversations.map(\.id),
            selectionID: selection?.id,
            draftID: draftConversation?.id
        )
        let deletedIDs = Set(plan.deletedIDs)
        let conversationsToDelete = conversations.filter { deletedIDs.contains($0.id) }
        guard !conversationsToDelete.isEmpty else { return }
        let keptConversation = plan.keptID.flatMap { keptID in conversations.first { $0.id == keptID } }
        let attachmentURLsToDelete = attachmentURLs(in: conversationsToDelete)

        guard await stopGenerationBeforeDeleting(conversationIDs: deletedIDs) else {
            return
        }

        for convo in conversationsToDelete {
            modelContext.delete(convo)
        }

        do {
            try modelContext.save()
            deleteAttachmentFiles(attachmentURLsToDelete)
            scheduleAttachmentStorageCleanup(excludingConversationIDs: deletedIDs)
            AppHaptics.notification(.success)
            // Open the kept chat when nothing was open; a draft stays where it is.
            if plan.opensKeptChat, let keptConversation, selection?.id != keptConversation.id {
                selection = keptConversation
            }
        } catch {
            contentLogger.error("Failed to save after deleting conversations except current: \((error as NSError).localizedDescription, privacy: .public)")
            rollBackFailedDeletion(restoringSelection: nil)
            AppHaptics.notification(.error)
            errorMessage = String(localized: "Failed to delete conversations. Please try again.", bundle: .appLocalized)
        }
    }

    // MARK: - Auto Delete

    func performAutoDeleteIfNeeded() {
        Task {
            await performAutoDeleteAfterStoppingGenerationIfNeeded()
        }
    }

    /// Chats past the retention period. The open chat is kept until the user leaves it,
    /// so coming back to the app never pulls a conversation out from under them.
    static func conversationsToAutoDelete(
        _ conversations: [Conversation],
        olderThan cutoffDate: Date,
        keeping openConversationID: UUID?
    ) -> [Conversation] {
        conversations.filter { $0.lastUpdated < cutoffDate && $0.id != openConversationID }
    }

    private func performAutoDeleteAfterStoppingGenerationIfNeeded() async {
        guard autoDeleteOldChats, !isPerformingAutoDelete else { return }
        isPerformingAutoDelete = true
        defer { isPerformingAutoDelete = false }

        let cutoffDate = Calendar.current.date(byAdding: .day, value: -autoDeleteDays, to: Date()) ?? Date()
        let conversationsToDelete = Self.conversationsToAutoDelete(
            conversations,
            olderThan: cutoffDate,
            keeping: selection?.id
        )

        guard !conversationsToDelete.isEmpty else { return }
        let excludedConversationIDs = Set(conversationsToDelete.map(\.id))
        let attachmentURLsToDelete = attachmentURLs(in: conversationsToDelete)

        guard await stopGenerationBeforeDeleting(conversationIDs: excludedConversationIDs) else {
            return
        }

        // Delete old conversations
        for convo in conversationsToDelete {
            modelContext.delete(convo)
        }

        do {
            try modelContext.save()
            deleteAttachmentFiles(attachmentURLsToDelete)
            scheduleAttachmentStorageCleanup(excludingConversationIDs: excludedConversationIDs)
            contentLogger.notice("Auto-deleted \(conversationsToDelete.count, privacy: .public) conversations older than \(autoDeleteDays, privacy: .public) days")
        } catch {
            contentLogger.error("Failed to auto-delete old conversations: \((error as NSError).localizedDescription, privacy: .public)")
            rollBackFailedDeletion(restoringSelection: nil)
        }
    }

    private func stopGenerationBeforeDeleting(conversationIDs: Set<UUID>) async -> Bool {
        while let viewModel = currentViewModel,
              conversationIDs.contains(viewModel.conversation.id) {
            guard await ChatNavigationRules.stopReply(of: viewModel, beforeDeleting: conversationIDs) else {
                errorMessage = String(localized: "Couldn't stop the active response. Please try deleting again.", bundle: .appLocalized)
                return false
            }
            if currentViewModel === viewModel {
                currentViewModel = nil
            }
        }
        return true
    }
}
