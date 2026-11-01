//
//  MessageCellView.swift
//  ChatLLM
//

import SwiftUI

// MARK: - Performance-optimized message cell view

/// One transcript row. It does not observe the chat view model as a whole: its body
/// reads only `viewModel.streamingState`, whose properties are tracked one by one, and
/// reduces that to the few values a row depends on. `MessageCellContent` gets plain
/// values and an identity-stable actions box, so SwiftUI skips every row whose values
/// did not change, such as on each composer keystroke or a change in the streaming
/// row's activity.
struct MessageCellView: View {
    let message: Message
    let viewModel: ChatViewModel
    /// Called from the long-press menu. The caller defers its UI work until the
    /// menu has dismissed, so the menu does not add a delay of its own.
    let onEdit: (Message) -> Void
    /// Called from the long-press menu, deferred by the caller like `onEdit`.
    let onShare: (String) -> Void
    @State private var actions = MessageCellActions()

    var body: some View {
        let streamingState = viewModel.streamingState
        let isStreaming = streamingState.isStreaming(message.id)
        let _ = actions.update(viewModel: viewModel, onEdit: onEdit, onShare: onShare)
        MessageCellContent(
            message: message,
            isStreaming: isStreaming,
            // Only the streaming row reads the activity, so the others ignore its changes.
            streamingActivity: isStreaming ? streamingState.activity : .loading,
            isGenerating: streamingState.isGenerating,
            actions: actions
        )
    }

    static func showsSearchingBelowText(message: Message, isStreaming: Bool, activity: StreamingActivity) -> Bool {
        message.role == .assistant && isStreaming && activity == .searching &&
            !message.isReasoningMode && !message.containsReasoningTags
    }
}

/// Holds a row's latest callbacks. Its identity never changes, so passing it
/// down does not make SwiftUI treat the row as changed the way fresh closures do.
private final class MessageCellActions {
    private(set) var onEdit: (Message) -> Void = { _ in }
    private(set) var onShare: (String) -> Void = { _ in }
    private weak var viewModel: ChatViewModel?

    func update(viewModel: ChatViewModel, onEdit: @escaping (Message) -> Void, onShare: @escaping (String) -> Void) {
        self.viewModel = viewModel
        self.onEdit = onEdit
        self.onShare = onShare
    }

    func regenerate(_ message: Message, instruction: String?) {
        viewModel?.scheduleRegeneration(messageID: message.id, instruction: instruction)
    }
}

private struct MessageCellContent: View {
    @Environment(\.locale) private var locale
    let message: Message
    let isStreaming: Bool
    let streamingActivity: StreamingActivity
    let isGenerating: Bool
    let actions: MessageCellActions
    @AppStorage(AppSettingsKeys.developerModeEnabled) private var developerModeEnabled: Bool = false
    @State private var showDeveloperSheet = false

    private var hasContent: Bool {
        !message.text.isEmpty ||
        !(message.finalAnswer?.isEmpty ?? true) ||
        !(message.reasoning?.isEmpty ?? true) ||
        message.generationError != nil
    }

    private var canAct: Bool {
        !isGenerating && !isStreaming && hasContent && message.isFinal
    }

    private var showsActionsBar: Bool {
        message.role == .assistant && hasContent && message.isFinal && !isStreaming
    }

    private var sourceInvocations: [SearchInvocation] {
        let stored = (message.searchInvocations ?? []).filter { !$0.displaySources.isEmpty }
        if !stored.isEmpty { return stored }

        guard let legacyText = extractSourcesFromMessage(), !legacyText.isEmpty else { return [] }
        return [SearchInvocation(
            query: message.searchQuery?.isEmpty == false ? message.searchQuery! : String(localized: "Saved web search", bundle: .appLocalized, locale: locale),
            results: legacyText
        )]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Bubble or loading placeholder
            if message.role == .assistant, isStreaming, !hasContent {
                StreamingActivityIndicator(activity: streamingActivity)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    MessageBubble(message: message, isStreaming: isStreaming, streamingActivity: streamingActivity)
                        .contextMenu {
                            MessageContextMenuView(
                                message: message,
                                onEdit: actions.onEdit,
                                onShare: actions.onShare,
                                onCopy: { text in
                                    UIPasteboard.general.string = text
                                }
                            )
                        }
                        .accessibilityActions {
                            if message.role == .user {
                                Button("Edit") {
                                    actions.onEdit(message)
                                }
                            }
                        }

                    // Reasoning bubbles show the search in their own status label; plain
                    // replies get one below the text written so far.
                    if MessageCellView.showsSearchingBelowText(
                        message: message,
                        isStreaming: isStreaming,
                        activity: streamingActivity
                    ) {
                        StreamingActivityIndicator(activity: .searching)
                    }
                }
            }

            // Actions for a finished assistant reply. The transition carries its
            // own animation, so the bar fades in when a reply finishes without
            // animating the rest of the row, and a row the lazy transcript
            // recreates shows it straight away instead of fading in again.
            if showsActionsBar {
                AssistantActionsBar(
                    copyText: MessageSourcesSplit.visibleText(message.displayText),
                    canAct: canAct,
                    sourceInvocations: sourceInvocations,
                    onTryAgain: {
                        actions.regenerate(message, instruction: nil)
                    },
                    onConcise: {
                        actions.regenerate(message, instruction: "Please answer again, but be more concise.")
                    },
                    onFormal: {
                        actions.regenerate(message, instruction: "Please answer again using a formal tone.")
                    },
                    developerModeEnabled: developerModeEnabled && message.role == .assistant,
                    onDeveloper: {
                        showDeveloperSheet = true
                    }
                )
                .transition(
                    .opacity.combined(with: .move(edge: .bottom))
                        .animation(.easeInOut(duration: 0.25))
                )
            }
        }
        .sheet(isPresented: $showDeveloperSheet) {
            DeveloperMessageSheet(message: message)
        }
    }

    private func extractSourcesFromMessage() -> String? {
        let candidateText = message.isReasoningMode
            ? (message.finalAnswer ?? message.displayText)
            : message.displayText
        guard candidateText.range(of: "<sources>", options: .caseInsensitive) != nil else { return nil }
        let extracted = MessageSourcesSplit.split(candidateText).sources.map {
            SearchInvocation.userVisibleResults(from: $0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (extracted?.isEmpty == false) ? extracted : nil
    }
}
