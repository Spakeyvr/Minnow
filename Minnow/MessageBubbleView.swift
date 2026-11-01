//
//  MessageBubbleView.swift
//  Minnow
//
//  Created by Nevio on 10/24/25.
//

import SwiftUI
import SwiftData
import UIKit

// MARK: - Localized status strings
enum Strings {
    static var thinking: String { String(localized: "Thinking…", bundle: .appLocalized) }
}

// MARK: - Shared error callout

private struct ErrorCalloutView: View {
    let text: String
    var topPadding: CGFloat = 0

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .padding(10)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.small))
            .padding(.top, topPadding)
    }
}

// MARK: - Basic message bubble with reasoning mode support

struct MessageBubble: View {
    let message: Message
    var isStreaming: Bool = false
    var streamingActivity: StreamingActivity = .loading

    var isAssistant: Bool { message.role == .assistant }

    var body: some View {
        // Show reasoning bubble if message is flagged as reasoning mode OR if it contains thinking tags
        if isAssistant && (message.isReasoningMode || message.containsReasoningTags) {
            ReasoningMessageBubble(message: message, isStreaming: isStreaming, streamingActivity: streamingActivity)
        } else {
            StandardMessageBubble(message: message, isStreaming: isStreaming)
        }
    }
}

// MARK: - Standard message bubble

struct StandardMessageBubble: View {
    let message: Message
    var isStreaming: Bool = false
    @AppStorage(AppSettingsKeys.messageFontSize) private var messageFontSize: Double = 16.0

    var isUser: Bool { message.role == .user }
    var isSystem: Bool { message.role == .system }

    var body: some View {
        // displayText strips hidden image context; a sources block (inserted whole
        // by the view model) is removed while streaming too, so it never flashes.
        let visibleText = MessageSourcesSplit.visibleText(message.displayText, caching: !isStreaming)

        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                // Show image attachments for user messages
                if isUser && !message.attachments.isEmpty {
                    ForEach(message.attachments, id: \.id) { attachment in
                        if attachment.type == .image {
                            MessageImageAttachmentView(attachment: attachment)
                        }
                    }
                }

                // Use the same whitespace-preserving renderer during and after streaming.
                if !visibleText.isEmpty {
                    RichMarkdownView(
                        text: visibleText,
                        fontSize: messageFontSize,
                        textTone: isSystem ? .secondary : .primary,
                        isStreaming: isStreaming
                    )
                        .textSelection(.enabled)
                }

                // Error callout — shown below partial content (if any) or alone
                if let errorText = message.generationError {
                    ErrorCalloutView(text: errorText, topPadding: visibleText.isEmpty ? 0 : 6)
                }

            }
            .modifier(ChatBubbleStyle(role: message.role))

        }
    }

}

// MARK: - Reasoning mode message bubble with modern design

struct ReasoningMessageBubble: View {
    @Environment(\.locale) private var locale
    let message: Message
    var isStreaming: Bool = false
    var streamingActivity: StreamingActivity = .loading
    @AppStorage(AppSettingsKeys.messageFontSize) private var messageFontSize: Double = 16.0

    @State private var showReasoningSheet = false

    // Parse reasoning content on-demand if not already parsed.
    // Callers should bind this once per body pass — it rescans the full message text,
    // which runs on every streamed frame otherwise.
    private var parsedContent: (reasoning: String?, finalAnswer: String?) {
        // If already parsed, return stored values. Only a non-whitespace check
        // here; the reasoning is trimmed when the sheet shows it.
        if let reasoning = message.reasoning, reasoning.contains(where: { !$0.isWhitespace }) {
            return (reasoning, message.finalAnswer)
        }
        // Not parsed by the view model, but tagged: parse on demand. An unclosed
        // tag is still-streaming reasoning, so it never shows as the answer.
        if let parsed = ReasoningTagParser.parse(message.text, caching: !isStreaming) {
            return (parsed.reasoning, parsed.finalAnswer)
        }
        return (nil, nil)
    }

    /// Reasoning is complete once the model has moved on to (or finished) the answer.
    static func hasCompletedReasoning(_ message: Message, hasReasoningContent: Bool) -> Bool {
        hasReasoningContent && (
            message.isFinal ||
            message.reasoningCompletedAt != nil ||
            message.streamingReasoningPhase == .finalAnswer
        )
    }

    /// The thinking shimmer plays only while reasoning is still streaming.
    static func thinkingIndicatorAnimates(for message: Message, hasReasoningContent: Bool) -> Bool {
        !hasCompletedReasoning(message, hasReasoningContent: hasReasoningContent)
    }

    /// The live status to show in place of "Thought for…": the reply's current activity
    /// while reasoning streams, and a search even after reasoning has wrapped up.
    static func liveActivity(
        isStreaming: Bool,
        hasCompletedReasoning: Bool,
        activity: StreamingActivity
    ) -> StreamingActivity? {
        guard isStreaming else { return nil }
        if activity == .searching || !hasCompletedReasoning { return activity }
        return nil
    }

    var body: some View {
        // Parse once per body pass; every access rescans the full message text.
        let parsed = parsedContent
        let reasoningText = parsed.reasoning
        let hasReasoningContent = !(reasoningText?.isEmpty ?? true)
        let hasCompletedReasoning = Self.hasCompletedReasoning(message, hasReasoningContent: hasReasoningContent)
        let liveActivity = Self.liveActivity(
            isStreaming: isStreaming,
            hasCompletedReasoning: hasCompletedReasoning,
            activity: streamingActivity
        )
        let reasoningStatusText: String? = {
            if let liveActivity {
                return liveActivity.label(locale: locale)
            }
            if hasCompletedReasoning {
                if let duration = message.reasoningDuration ?? message.generationDuration {
                    return String(localized: "Thought for \(ThoughtDurationFormatter.string(for: duration, locale: locale))", bundle: .appLocalized, locale: locale)
                }
                return String(localized: "Thought", bundle: .appLocalized, locale: locale)
            }
            return nil
        }()

        VStack(alignment: .leading, spacing: 8) {
            let rawFinal = parsed.finalAnswer ?? message.finalAnswer ?? message.displayText
            // The regex only runs when a sources block is present, so this stays
            // cheap on every streamed token.
            let hasSourcesBlock = rawFinal.range(of: "<sources>", options: .caseInsensitive) != nil
            let split = hasSourcesBlock
                ? MessageSourcesSplit.split(rawFinal, caching: !isStreaming)
                : MessageSourcesSplit.Value(visible: rawFinal.trimmingCharacters(in: .whitespacesAndNewlines), sources: nil)
            let finalText = split.visible
            let inlineSourcesText = split.sources

            if let reasoningStatusText {
                InlineThinkingView(
                    text: reasoningStatusText,
                    onTap: hasReasoningContent ? { showReasoningSheet = true } : nil,
                    isAnimating: liveActivity != nil ||
                        Self.thinkingIndicatorAnimates(for: message, hasReasoningContent: hasReasoningContent)
                )
            }

            // Final answer section — only shown when there is content to display
            let hasFinalSection = !finalText.isEmpty || message.generationError != nil ||
                (message.searchInvocations?.isEmpty == false && message.isFinal) ||
                (message.isFinal && inlineSourcesText != nil)
            if hasFinalSection {
                VStack(alignment: .leading, spacing: 8) {
                    if !finalText.isEmpty {
                        RichMarkdownView(text: finalText, fontSize: messageFontSize, isStreaming: isStreaming)
                            .textSelection(.enabled)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Error callout for reasoning messages
                    if let errorText = message.generationError {
                        ErrorCalloutView(text: errorText, topPadding: finalText.isEmpty ? 0 : 6)
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showReasoningSheet) {
            StepByStepReasoningSheet(
                reasoning: reasoningText ?? "",
                searchInvocations: message.searchInvocations
            )
        }
    }
}

// MARK: - Bubble chrome

/// Shared bubble chrome, so the Appearance preview stays in sync with the chat.
struct ChatBubbleStyle: ViewModifier {
    let role: MessageRole
    var fill = Color(uiColor: .secondarySystemBackground)

    func body(content: Content) -> some View {
        if role.isAssistant {
            // Assistant replies render as plain text on the chat background, without a bubble.
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let isUser = role == .user
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(
                    fill,
                    in: .rect(
                        cornerRadius: isUser ? DesignTokens.CornerRadius.bubble : DesignTokens.CornerRadius.medium,
                        style: .continuous
                    )
                )
                // Keep a gutter on the leading side so user bubbles never span the full width.
                .padding(.leading, isUser ? 32 : 0)
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        }
    }
}
