//
//  ChatNavigationRules.swift
//  Minnow
//

import Foundation

// MARK: - Selection, Draft and Deletion Rules

/// The decisions behind ContentView's chat selection, draft and deletion handling, kept
/// apart from the view so they can be unit tested. Chats are identified by ID.
enum ChatNavigationRules {
    /// What the chat list changing means for the open chat.
    enum ListChange: Equatable {
        /// The open draft was saved for the first time; open it as a saved chat.
        case promoteDraft
        /// The open chat no longer exists; a blank draft takes its place.
        case replaceDeletedSelection
        /// Nothing is open on a regular-width layout; open this chat.
        case select(UUID)
        case none
    }

    static func listChange(
        from oldIDs: [UUID],
        to newIDs: [UUID],
        selectionID: UUID?,
        draftID: UUID?,
        isRegularWidth: Bool
    ) -> ListChange {
        if let draftID, newIDs.contains(draftID), !oldIDs.contains(draftID) {
            return .promoteDraft
        }
        if let selectionID {
            return newIDs.contains(selectionID) ? .none : .replaceDeletedSelection
        }
        // Compact width opens into a draft instead; the sidebar slides out on demand.
        if draftID == nil, isRegularWidth, let first = newIDs.first {
            return .select(first)
        }
        return .none
    }

    /// New Chat creates a draft only when none is open; otherwise it reveals that one.
    static func newChatCreatesDraft(draftID: UUID?) -> Bool {
        draftID == nil
    }

    struct KeepCurrentPlan: Equatable {
        let deletedIDs: [UUID]
        /// The saved chat that stays.
        let keptID: UUID?
        /// Whether to open the kept chat afterwards. An open draft stays open instead.
        let opensKeptChat: Bool
    }

    /// "Delete All Except Current". The open chat stays, or the most recent chat when
    /// none is open, as the confirmation says. An open draft also stays open: the most
    /// recent chat is kept but not opened, so the user stays where they were.
    static func deleteAllExceptCurrentPlan(
        conversationIDs: [UUID],
        selectionID: UUID?,
        draftID: UUID?
    ) -> KeepCurrentPlan {
        guard let keptID = selectionID ?? conversationIDs.first else {
            return KeepCurrentPlan(deletedIDs: [], keptID: nil, opensKeptChat: false)
        }
        return KeepCurrentPlan(
            deletedIDs: conversationIDs.filter { $0 != keptID },
            keptID: keptID,
            opensKeptChat: selectionID == nil && draftID == nil
        )
    }

    static func canDeleteAllExceptCurrent(conversationIDs: [UUID], selectionID: UUID?, draftID: UUID?) -> Bool {
        !deleteAllExceptCurrentPlan(conversationIDs: conversationIDs, selectionID: selectionID, draftID: draftID)
            .deletedIDs.isEmpty
    }

    /// Stops and retires the view model's reply when its chat is about to be deleted, and
    /// waits for the stream to end so nothing writes to the deleted chat afterwards.
    /// False when the reply didn't stop, in which case the chat must not be deleted.
    static func stopReply(of viewModel: ChatViewModel, beforeDeleting conversationIDs: Set<UUID>) async -> Bool {
        guard conversationIDs.contains(viewModel.conversation.id) else { return true }
        guard await viewModel.cancelGenerationAndWait() else { return false }
        viewModel.deactivate()
        return true
    }
}
