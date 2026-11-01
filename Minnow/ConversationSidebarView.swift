//
//  ConversationSidebarView.swift
//  Minnow
//
//  Created by Nevio on 10/24/25.
//

import SwiftUI
import SwiftData
import UIKit

// Pre-compiled regexes for stripForPreview (compiled once at app launch)
// swiftlint:disable force_try
private let _previewThinkingBlockRegex = try! NSRegularExpression(pattern: #"<(?:think|thinking)>.*?</(?:think|thinking)>"#, options: [.dotMatchesLineSeparators, .caseInsensitive])
private let _previewSourcesTagRegex   = try! NSRegularExpression(pattern: #"</?sources>"#,              options: [.caseInsensitive])
private let _previewThinkingTagRegex  = try! NSRegularExpression(pattern: #"</?(?:think|thinking)>"#,   options: [.caseInsensitive])
// Line-start Markdown (headings, quotes, list markers, code fences, rules) that would
// show as literal symbols on a one-line preview, which renders inline Markdown only.
private let _previewBlockMarkerRegex  = try! NSRegularExpression(pattern: #"^[ \t]*(?:#{1,6}[ \t]+|>[ \t]?|[-*+][ \t]+|\d+[.)][ \t]+|```.*$|(?:[-*_][ \t]*){3,}$)"#, options: [.anchorsMatchLines])
// swiftlint:enable force_try

// MARK: - Conversation Row

struct ConversationRow: View {
    @Environment(\.locale) private var locale
    let conversation: Conversation

    /// Marks chats that reason. Apple Intelligence and MLX models without a thinking
    /// mode never do, even when the chat was started with reasoning turned on.
    static func showsReasoningBadge(for conversation: Conversation) -> Bool {
        let backend = conversation.preferredBackendRawValue.flatMap(ModelBackendBridge.Backend.init(rawValue:))
        if backend == .foundationModels { return false }
        if backend == .mlx,
           let modelID = conversation.preferredModelID,
           let model = MLXModelManager.modelDefinitions.first(where: { $0.id == modelID }) {
            return model.requiresReasoning || (conversation.reasoningMode && model.supportsReasoning)
        }
        return conversation.reasoningMode
    }

    private var messagePreview: MessagePreview {
        if let latestText = Self.previewText(for: conversation) {
            return .message(latestText)
        } else if conversation.messages.isEmpty {
            return .empty
        } else {
            return .none
        }
    }

    /// How much of a message the preview reads. The row shows one line, and the open
    /// chat's row re-renders as its reply streams, so the cost must not grow with the reply.
    static let previewSourceLimit = 1_000
    /// Longest preview handed to the Markdown parser; far more than one line can show.
    static let previewLengthLimit = 300

    /// The newest visible message text. Walks back from the latest message because
    /// displayText hashes the whole message, so computing it for every message on each
    /// sidebar render adds up. A reply that failed before writing anything has no text,
    /// so the preview falls back to the message before it.
    static func previewText(for conversation: Conversation) -> String? {
        let visible = conversation.messages.filter { $0.role != .system }
        // Common case: the latest message has text, so skip sorting the whole chat.
        if let latest = visible.max(by: { $0.order < $1.order }) {
            let text = previewSnippet(from: latest.displayText)
            if !text.isEmpty { return text }
        }
        return visible
            .sorted { $0.order > $1.order }
            .dropFirst()
            .lazy
            .map { previewSnippet(from: $0.displayText) }
            .first { !$0.isEmpty }
    }

    /// The preview of one message, built from its beginning only. Falls back to the whole
    /// text when hidden blocks fill the part that was read.
    static func previewSnippet(from text: String) -> String {
        guard let cutoff = text.index(text.startIndex, offsetBy: previewSourceLimit, limitedBy: text.endIndex),
              cutoff < text.endIndex else {
            return String(stripForPreview(text).prefix(previewLengthLimit))
        }
        let snippet = stripForPreview(String(text[..<cutoff]), isTruncated: true)
        if !snippet.isEmpty {
            return String(snippet.prefix(previewLengthLimit))
        }
        return String(stripForPreview(text).prefix(previewLengthLimit))
    }

    // Removes <sources>…</sources>, stray <sources> tags, and <thinking>…</thinking> from preview text.
    // A truncated text may end inside a hidden block, so it is cut where that block opens.
    private static func stripForPreview(_ text: String, isTruncated: Bool = false) -> String {
        var output = text

        func applying(_ regex: NSRegularExpression) {
            let ns = output as NSString
            let range = NSRange(location: 0, length: ns.length)
            output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: "")
        }

        // Remove full blocks first
        applying(SharedRegexes.sourcesBlock)
        applying(_previewThinkingBlockRegex)
        if isTruncated,
           let unclosedBlock = output.range(of: #"<(?:sources|think|thinking)>"#, options: [.regularExpression, .caseInsensitive]) {
            output = String(output[..<unclosedBlock.lowerBound])
        }
        // Remove any stray opening/closing tags that may remain
        applying(_previewSourcesTagRegex)
        applying(_previewThinkingTagRegex)
        applying(_previewBlockMarkerRegex)
        // Collapse excessive whitespace/newlines
        var ns = output as NSString
        output = SharedRegexes.multipleBlankLines.stringByReplacingMatches(
            in: output, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: "\n")
        ns = output as NSString
        output = SharedRegexes.excessiveWhitespace.stringByReplacingMatches(
            in: output, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)

        return output
    }

    private enum MessagePreview {
        case message(String)
        case empty
        case none
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(conversation.title.isEmpty ? String(localized: "Untitled", bundle: .appLocalized, locale: locale) : conversation.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                if Self.showsReasoningBadge(for: conversation) {
                    Image(systemName: "brain.head.profile")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .accessibilityLabel("Reasoning mode")
                }

                Spacer(minLength: 0)
            }

            switch messagePreview {
            case .message(let text):
                // Renders inline formatting like **bold**. Not a LocalizedStringKey: the
                // message is shown as written, never looked up in the string catalog.
                Text(NativeMarkdownParser.attributedString(from: text) ?? AttributedString(text))
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            case .empty:
                Text("No messages yet")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .italic()
            case .none:
                EmptyView()
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Skipping Unchanged Renders

extension ConversationSidebar: Equatable {
    /// The parent re-renders whenever SwiftData processes a change, several times a second
    /// while a reply streams. Rows observe their own chats, so only the list's shape and
    /// the open chat decide whether the body runs again. The selection binding alone is
    /// not enough: List keeps its rows' highlight until the parent passes new values.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hasConversations == rhs.hasConversations
            && lhs.selectedID == rhs.selectedID
            && lhs.sections.map(\.id) == rhs.sections.map(\.id)
            && lhs.sections.map { $0.conversations.map(\.id) } == rhs.sections.map { $0.conversations.map(\.id) }
    }
}

// MARK: - Cached Sections

/// The sidebar's filtered, recency-grouped chats, recomputed only when the list, a chat's
/// title or activity date, the search, or the day changes. ContentView renders several
/// times a second while a reply streams, and searching reads every message of every chat.
final class SidebarSectionsCache {
    private struct Entry: Equatable {
        let id: UUID
        let title: String
        let lastUpdated: Date
    }

    private struct Key: Equatable {
        let entries: [Entry]
        let searchTerms: [String]
        let day: Date
    }

    private var key: Key?
    private var cachedSections: [ConversationRecencySection] = []
    private(set) var computeCount = 0

    func sections(
        for conversations: [Conversation],
        searchTerms: [String],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ConversationRecencySection] {
        // A new message updates lastUpdated, so the key also notices message text that
        // a search could now match.
        let key = Key(
            entries: conversations.map { Entry(id: $0.id, title: $0.title, lastUpdated: $0.lastUpdated) },
            searchTerms: searchTerms,
            day: calendar.startOfDay(for: now)
        )
        if key == self.key { return cachedSections }

        let matching = searchTerms.isEmpty
            ? conversations
            : conversations.filter { $0.matchesSearch(searchTerms) }
        cachedSections = ConversationRecencySection.grouping(matching, now: now, calendar: calendar)
        self.key = key
        computeCount += 1
        return cachedSections
    }
}

// MARK: - Recency Sections

struct ConversationRecencySection: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let conversations: [Conversation]

    /// Buckets conversations (already sorted newest first) into Today / Yesterday /
    /// Last 7 Days / Last 30 Days / Older, dropping empty buckets.
    static func grouping(
        _ conversations: [Conversation],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ConversationRecencySection] {
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now)
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now)

        func bucketID(for date: Date) -> String {
            if calendar.isDate(date, inSameDayAs: now) { return "today" }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
               calendar.isDate(date, inSameDayAs: yesterday) {
                return "yesterday"
            }
            if let sevenDaysAgo, date >= sevenDaysAgo { return "last7Days" }
            if let thirtyDaysAgo, date >= thirtyDaysAgo { return "last30Days" }
            return "older"
        }

        let grouped = Dictionary(grouping: conversations) { bucketID(for: $0.lastUpdated) }
        let buckets: [(id: String, title: LocalizedStringKey)] = [
            ("today", "Today"),
            ("yesterday", "Yesterday"),
            ("last7Days", "Last 7 Days"),
            ("last30Days", "Last 30 Days"),
            ("older", "Older")
        ]

        return buckets.compactMap { bucket in
            guard let conversations = grouped[bucket.id], !conversations.isEmpty else { return nil }
            return ConversationRecencySection(id: bucket.id, title: bucket.title, conversations: conversations)
        }
    }
}

// MARK: - Sidebar

/// Chat history column: inline large title with a glass settings button, recency-grouped
/// conversations, and a Liquid Glass bottom toolbar holding a minimized search field and
/// the New Chat button.
struct ConversationSidebar: View {
    let sections: [ConversationRecencySection]
    let hasConversations: Bool
    /// The open chat, passed by value so a new selection fails the Equatable check
    /// and the rows redraw their highlight.
    let selectedID: UUID?
    @Binding var selection: Conversation?
    @Binding var searchText: String
    @Binding var isSearchPresented: Bool
    let onSubmitSearch: () -> Void
    let onSelect: () -> Void
    let onNewChat: () -> Void
    let onShowSettings: () -> Void
    let onRename: (Conversation) -> Void
    /// Deletes a chat the user has confirmed deleting.
    let onDelete: (Conversation) -> Void

    /// The chat whose Delete is waiting for confirmation. Deleting removes the chat and
    /// its attachment files for good, so neither a stray swipe nor the menu does it alone.
    @State private var conversationPendingDeletion: Conversation?

    private var isDeleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { conversationPendingDeletion != nil },
            set: { if !$0 { conversationPendingDeletion = nil } }
        )
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(sections) { section in
                Section {
                    ForEach(Array(section.conversations.enumerated()), id: \.element.id) { index, convo in
                        let next = section.conversations.indices.contains(index + 1)
                            ? section.conversations[index + 1] : nil
                        row(for: convo)
                            // Separators would cut through the open chat's highlight.
                            .listRowSeparator(
                                isSelected(convo) || next.map(isSelected) == true ? .hidden : .automatic,
                                edges: .bottom
                            )
                    }
                } header: {
                    Text(section.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            emptyState
        }
        .navigationTitle(Text(verbatim: "Minnow"))
        .toolbarTitleDisplayMode(.inlineLarge)
        .searchable(
            text: $searchText,
            isPresented: $isSearchPresented,
            prompt: Text("Search chats")
        )
        .searchToolbarBehavior(.minimize)
        .onSubmit(of: .search, onSubmitSearch)
        .alert(
            "Delete Chat?",
            isPresented: isDeleteConfirmationPresented,
            presenting: conversationPendingDeletion
        ) { convo in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                onDelete(convo)
            }
        } message: { _ in
            Text("This chat and its attachments will be permanently deleted. This cannot be undone.")
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onShowSettings) {
                    Label("Settings", systemImage: "gearshape.fill")
                }
            }

            DefaultToolbarItem(kind: .search, placement: .bottomBar)

            ToolbarSpacer(.flexible, placement: .bottomBar)

            ToolbarItem(placement: .bottomBar) {
                Button {
                    isSearchPresented = false
                    onNewChat()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("New Chat")
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.glassProminent)
                .tint(Color(uiColor: .label))
                .accessibilityLabel("New Chat")
            }
        }
    }

    private func row(for convo: Conversation) -> some View {
        ConversationRow(conversation: convo)
            .contentShape(Rectangle())
            .onTapGesture {
                AppHaptics.selectionChanged()
                selection = convo
                onSelect()
            }
            // A clear row background hides List's own selection highlight, so mark
            // the open chat explicitly.
            .listRowBackground(
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous)
                    .fill(isSelected(convo) ? Color(uiColor: .tertiarySystemFill) : .clear)
                    .padding(.horizontal, 8)
            )
            .contextMenu {
                Button {
                    onRename(convo)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    conversationPendingDeletion = convo
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            // No full swipe and no destructive role: either would slide the row away
            // before the user has confirmed.
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    conversationPendingDeletion = convo
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
    }

    private func isSelected(_ convo: Conversation) -> Bool {
        selectedID == convo.id
    }

    @ViewBuilder
    private var emptyState: some View {
        if sections.isEmpty {
            if !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else if !hasConversations {
                ContentUnavailableView {
                    Label("No Chats Yet", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Start a new chat to see it here.")
                }
            }
        }
    }
}
