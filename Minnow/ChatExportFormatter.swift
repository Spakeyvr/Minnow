import Foundation

/// Plain-text export of saved chats, written in the app's interface language so the
/// file reads like the rest of the app. Message content is exported as written.
///
/// Exporting a large history is slow, so it runs in two steps: `snapshots(of:)`
/// copies the stored values on the main actor, and `text(for:language:exportedAt:)`
/// or `writeExportFile(for:language:exportedAt:in:)` does the cleanup, formatting
/// and file writing away from it.
nonisolated enum ChatExportFormatter {
    /// The stored values of one chat that the export needs.
    nonisolated struct ConversationSnapshot: Sendable {
        let title: String
        let lastUpdated: Date
        let reasoningMode: Bool
        /// Non-system messages in display order.
        let messages: [MessageSnapshot]
    }

    /// The stored values of one message that the export needs.
    nonisolated struct MessageSnapshot: Sendable {
        let role: MessageRole
        /// The stored text the visible text is cleaned from, so the cleanup can
        /// run off the main actor.
        let displaySource: String
        let generationError: String?
        let imageFileNames: [String]
    }

    /// Copies what the export needs out of the SwiftData models.
    @MainActor
    static func snapshots(of conversations: [Conversation]) -> [ConversationSnapshot] {
        conversations.map { conversation in
            ConversationSnapshot(
                title: conversation.title,
                lastUpdated: conversation.lastUpdated,
                reasoningMode: conversation.reasoningMode,
                messages: conversation.messages
                    .filter { $0.role != .system }
                    .sortedByOrder
                    .map { message in
                        MessageSnapshot(
                            role: message.role,
                            displaySource: message.displaySource,
                            generationError: message.generationError,
                            imageFileNames: message.attachments
                                .filter { $0.type == .image }
                                .map(\.fileName)
                        )
                    }
            )
        }
    }

    /// Formats saved chats on the calling actor. Prefer the snapshot overload for
    /// large histories.
    @MainActor
    static func text(
        for conversations: [Conversation],
        language: AppLanguage = .current,
        exportedAt: Date = Date()
    ) -> String {
        text(for: snapshots(of: conversations), language: language, exportedAt: exportedAt)
    }

    static func text(
        for conversations: [ConversationSnapshot],
        language: AppLanguage = .current,
        exportedAt: Date = Date()
    ) -> String {
        let bundle = language.bundle
        let locale = language.locale
        func formatted(_ date: Date) -> String {
            date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
        }

        let separator = String(repeating: "=", count: 60)
        let chatSeparator = String(repeating: "-", count: 60)
        let exportedDate = formatted(exportedAt)
        let count = conversations.count
        var text = "# \(String(localized: "Chat Export", bundle: bundle, locale: locale))\n"
        text += String(localized: "Exported: \(exportedDate)", bundle: bundle, locale: locale) + "\n"
        text += String(localized: "Conversations: \(count)", bundle: bundle, locale: locale) + "\n\n"
        text += separator + "\n\n"

        for conversation in conversations.sorted(by: { $0.lastUpdated > $1.lastUpdated }) {
            let lastUpdated = formatted(conversation.lastUpdated)
            text += "## \(conversation.title)\n"
            text += String(localized: "Last updated: \(lastUpdated)", bundle: bundle, locale: locale) + "\n"
            if conversation.reasoningMode {
                text += String(localized: "Reasoning mode", bundle: bundle, locale: locale) + "\n"
            }
            text += "\n"

            for message in conversation.messages where message.role != .system {
                let role = message.role == .user
                    ? String(localized: "User", bundle: bundle, locale: locale)
                    : String(localized: "Assistant", bundle: bundle, locale: locale)
                text += "**\(role):**\n"
                let visibleText = MessageDisplayTextCleaner.userVisibleText(from: message.displaySource)
                if !visibleText.isEmpty {
                    text += visibleText + "\n"
                }
                if let generationError = message.generationError {
                    text += "[\(String(localized: "Error: \(generationError)", bundle: bundle, locale: locale))]\n"
                }
                for fileName in message.imageFileNames {
                    text += "[\(String(localized: "Image: \(fileName)", bundle: bundle, locale: locale))]\n"
                }
                text += "\n"
            }

            text += chatSeparator + "\n\n"
        }
        return text
    }

    /// Formats and writes the export file off the main actor, returning its URL.
    @concurrent
    static func writeExportFile(
        for conversations: [ConversationSnapshot],
        language: AppLanguage,
        exportedAt: Date = Date(),
        in directory: URL = FileManager.default.temporaryDirectory
    ) async throws -> URL {
        let exportText = text(for: conversations, language: language, exportedAt: exportedAt)
        let url = directory.appendingPathComponent(fileName(exportedAt: exportedAt))
        try Data(exportText.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// A readable, sortable name for Files and AirDrop instead of a raw timestamp.
    static func fileName(exportedAt: Date = Date(), timeZone: TimeZone = .current) -> String {
        let style = Date.VerbatimFormatStyle(
            format: "\(year: .padded(4))-\(month: .twoDigits)-\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: timeZone,
            calendar: Calendar(identifier: .gregorian)
        )
        return "Minnow-Export-\(exportedAt.formatted(style)).txt"
    }
}
