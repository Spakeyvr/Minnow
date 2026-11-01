//
//  MessageContextMenuView.swift
//  ChatLLM
//

import SwiftUI

// MARK: - Message context menu

/// The long-press menu of a message.
///
/// Share and Edit present UI, so they must wait for the menu to finish
/// dismissing. `onShare` and `onEdit` already do that themselves (ChatView runs
/// them through its `menuSafe`), so the menu calls them directly rather than
/// waiting a second time. Only Copy, whose callback runs immediately, is
/// deferred here.
struct MessageContextMenuView: View {
    /// How long Copy waits for the menu to dismiss.
    static let dismissalDelay: Duration = .milliseconds(150)

    let message: Message
    let onEdit: (Message) -> Void
    let onShare: (String) -> Void
    let onCopy: (String) -> Void

    var body: some View {
        Button {
            afterMenuDismisses { onCopy(message.userVisibleText) }
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }

        Button {
            onShare(message.userVisibleText)
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }

        if message.role == .user {
            Button {
                onEdit(message)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
        }
    }

    private func afterMenuDismisses(_ action: @escaping () -> Void) {
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: Self.dismissalDelay)
            action()
        }
    }
}
