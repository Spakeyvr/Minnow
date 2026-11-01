//
//  ChatViewModel+Persistence.swift
//  ChatLLM
//

import Foundation
import SwiftData
import os

extension ChatViewModel {

    // MARK: - Coalesced Save

    internal func scheduleCoalescedSave() {
        // Every mutation either joins the pending save or schedules one, so a
        // crash loses at most `saveInterval` of changes. The count of mutations
        // since the last save additionally forces a save during a burst of
        // updates that arrive faster than the debounce interval.
        saveCount += 1

        if saveCount >= forceSaveThreshold {
            immediateSave()
            return
        }

        if let existing = pendingSaveTask, !existing.isCancelled {
            return // Task already scheduled; it saves this mutation too
        }

        pendingSaveTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            try? await Task.sleep(for: self.saveInterval)
            // After this guard the body runs synchronously on the main actor,
            // so it cannot interleave with immediateSave() or a newer task; the
            // unconditional nil-out below can only clear this task.
            guard !Task.isCancelled else { return }
            do {
                try self.context.save()
                self.saveCount = 0
            } catch {
                self.logger.error("Failed to save context: \((error as NSError).localizedDescription, privacy: .public)")
                // Retry once more immediately on failure; log a second failure
                // instead of discarding it, so persistent save breakage (disk
                // full, store corruption mid-session) is visible in Console.
                do {
                    try self.context.save()
                } catch {
                    self.logger.error("Coalesced save retry failed: \((error as NSError).localizedDescription, privacy: .public)")
                }
            }
            self.pendingSaveTask = nil
        }
    }

    /// Inserts the conversation into the model context if it hasn't been persisted yet.
    /// Called before every save so draft conversations are transparently promoted on first message send.
    private func insertIntoContextIfNeeded() {
        guard canPromoteDraft, !didPromoteDraft, conversation.modelContext == nil else { return }
        context.insert(conversation)
        didPromoteDraft = true
    }

    internal func immediateSave() {
        insertIntoContextIfNeeded()
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        saveCount = 0
        do {
            try context.save()
        } catch {
            logger.error("Failed to immediately save context: \((error as NSError).localizedDescription, privacy: .public)")
        }
    }

    /// Flushes coalesced changes before the view model is discarded (deinit
    /// cannot flush: it is nonisolated). Skips unsent drafts so discarding one
    /// does not promote it into the store.
    func flushPendingSaveForTeardown() {
        guard conversation.modelContext != nil else { return }
        immediateSave()
    }

    func renumberMessagesByOrder() {
        let sorted = conversation.messages.sorted {
            if $0.order == $1.order {
                return $0.createdAt < $1.createdAt
            }
            return $0.order < $1.order
        }
        // Assigning an unchanged order still marks the row dirty, so the next
        // save would rewrite every message.
        for (i, msg) in sorted.enumerated() where msg.order != i {
            msg.order = i
        }
    }
}
