//
//  MinnowTests+DataModels
//  MinnowTests
//
//  Message display caching, chat search, attachment storage, export, interface
//  language and settings defaults. Part of the single @Suite(.serialized)
//  MinnowTests suite.
//

import Testing
import Foundation
import SwiftData
import UIKit
@testable import Minnow

extension MinnowTests {
    // MARK: - Message display text

    @Test func resettingAnUntouchedPlaceholderLeavesNothingToSave() throws {
        let context = try makeContext()
        let placeholder = Minnow.Message(role: .assistant, text: "", order: 0, isFinal: false)
        context.insert(placeholder)
        try context.save()

        placeholder.resetForRegeneration()
        #expect(!context.hasChanges)

        placeholder.text = "Earlier reply"
        placeholder.isFinal = true
        try context.save()
        placeholder.resetForRegeneration()
        #expect(context.hasChanges)
        #expect(placeholder.text.isEmpty && !placeholder.isFinal)
    }

    @Test func displayTextFollowsReasoningModeChanges() {
        let message = Minnow.Message(
            role: .assistant,
            text: "Draft text",
            order: 0,
            finalAnswer: "Final answer"
        )
        #expect(message.displayText == "Draft text")

        message.isReasoningMode = true
        #expect(message.displayText == "Final answer")

        message.isReasoningMode = false
        #expect(message.displayText == "Draft text")
    }

    @Test func userVisibleTextFollowsFinalAnswerChanges() {
        let message = Minnow.Message(
            role: .assistant,
            text: "",
            order: 0,
            finalAnswer: "First.\n<sources>[]</sources>",
            isReasoningMode: true
        )
        #expect(message.userVisibleText == "First.")

        message.finalAnswer = "Second.\n<SOURCES>[]</SOURCES>"
        #expect(message.userVisibleText == "Second.")
        #expect(message.displayText.contains("<SOURCES>"))
    }

    @Test func displayTextStripsMixedCaseTagsAndTheFinalAnswerLabel() {
        let message = Minnow.Message(
            role: .assistant,
            text: "<Think>weighing options</Think>Final Answer: <Answer>Paris.</Answer>",
            order: 0
        )

        #expect(message.displayText == "Paris.")
    }

    @Test func regenerationResetClearsMetricsWhenNothingElseIsSet() {
        let message = Minnow.Message(role: .assistant, text: "", order: 0)
        message.generationPromptTokenCount = 120
        message.generationPromptTime = 0.4
        message.generationTimeToFirstToken = 0.2

        message.resetForRegeneration()

        #expect(message.generationPromptTokenCount == nil)
        #expect(message.generationPromptTime == nil)
        #expect(message.generationTimeToFirstToken == nil)
    }

    @Test func regenerationResetKeepsAForcedSearchQuery() {
        let message = Minnow.Message(
            role: .assistant,
            text: "Old answer",
            order: 0,
            isFinal: true,
            searchQuery: "weather vienna",
            requiresWebSearch: true
        )

        message.resetForRegeneration()

        #expect(message.text.isEmpty)
        #expect(!message.isFinal)
        #expect(message.requiresWebSearch == true)
        #expect(message.searchQuery == "weather vienna")
    }

    // MARK: - Reasoning sanitizer

    @Test func reasoningSanitizerTurnsTagsOfAnyCaseIntoParagraphBreaks() {
        let sanitized = ReasoningTextSanitizer.string(from: "<THINK>One.</Think>\n\n\n\n<thinking>Two.</THINKING>")

        #expect(sanitized == "One.\n\nTwo.")
    }

    @Test func reasoningSanitizerReturnsTheRightTextWhenInputsAlternate() {
        let first = "Alpha.</think>"
        let second = "Beta.\n\n\n\nGamma."

        #expect(ReasoningTextSanitizer.string(from: first) == "Alpha.")
        #expect(ReasoningTextSanitizer.string(from: first) == "Alpha.")
        #expect(ReasoningTextSanitizer.string(from: second) == "Beta.\n\nGamma.")
        #expect(ReasoningTextSanitizer.string(from: first) == "Alpha.")
    }

    // MARK: - Whole-phrase matching

    @Test func wholePhraseListMatchesOnlyWholeWords() {
        let phrases = ["latest", "breaking news"]

        #expect(SharedRegexes.containsAnyWholePhrase(phrases, in: "what is the latest on this?"))
        #expect(SharedRegexes.containsAnyWholePhrase(phrases, in: "Any BREAKING NEWS today"))
        #expect(!SharedRegexes.containsAnyWholePhrase(phrases, in: "the latestversion of breaking newsletters"))
        #expect(!SharedRegexes.containsAnyWholePhrase([], in: "latest"))
        #expect(SharedRegexes.containsWholePhrase("ai", in: "ask the ai"))
        #expect(!SharedRegexes.containsWholePhrase("ai", in: "she said so"))
    }

    // MARK: - Chat search

    @Test func chatSearchFindsTermsSpreadOverSeparateMessages() {
        let conversation = Conversation(title: "Plans")
        conversation.messages = [
            Minnow.Message(role: .system, text: "hidden instructions", order: 0, conversation: conversation, isFinal: true),
            Minnow.Message(role: .assistant, text: "Visit the museum.", order: 2, conversation: conversation, isFinal: true),
            Minnow.Message(role: .user, text: "Where in Vienna?", order: 1, conversation: conversation, isFinal: true)
        ]

        #expect(conversation.matchesSearch(["vienna", "museum"]))
        #expect(conversation.matchesSearch(["plans", "museum"]))
        #expect(!conversation.matchesSearch(["vienna", "zoo"]))
        #expect(!conversation.matchesSearch(["instructions"]))
    }

    @Test func chatSearchIgnoresSourcesBlocks() {
        let conversation = Conversation(title: "Weather")
        conversation.messages = [
            Minnow.Message(
                role: .assistant,
                text: "Sunny.\n<sources>[{\"title\":\"forecast site\"}]</sources>",
                order: 0,
                conversation: conversation,
                isFinal: true
            )
        ]

        #expect(conversation.matchesSearch(["sunny"]))
        #expect(!conversation.matchesSearch(["forecast"]))
    }

    // MARK: - Attachments

    @Test func referencedFilesSkipAttachmentsWithoutASavedChat() throws {
        let context = try makeContext()
        let conversation = Conversation(title: "Saved")
        context.insert(conversation)
        let message = Minnow.Message(role: .user, text: "Look", order: 0, conversation: conversation, isFinal: true)
        conversation.messages = [message]
        let saved = MessageAttachment(type: .image, fileURL: URL(fileURLWithPath: "/old/container/saved.jpg"), fileName: "saved.jpg")
        message.attachments = [saved]
        saved.message = message
        let detachedMessage = Minnow.Message(role: .user, text: "Draft", order: 0, isFinal: true)
        context.insert(detachedMessage)
        let unsaved = MessageAttachment(type: .image, fileURL: URL(fileURLWithPath: "/tmp/unsaved.jpg"), fileName: "unsaved.jpg")
        detachedMessage.attachments = [unsaved]
        unsaved.message = detachedMessage
        try context.save()

        let referenced = try MessageAttachment.referencedFileURLs(in: context)

        #expect(referenced == [MessageAttachment.attachmentsDirectory.appending(path: "saved.jpg")])
    }

    @Test func attachmentsDirectoryLivesInDocuments() {
        #expect(MessageAttachment.attachmentsDirectory.lastPathComponent == "Attachments")
        #expect(MessageAttachment.attachmentsDirectory.deletingLastPathComponent().standardizedFileURL
            == URL.documentsDirectory.standardizedFileURL)
    }

    @Test func deletingAnInferenceVariantRemovesTheSavedVariant() async throws {
        let store = makeImageStore()
        let source = try await store.save(image: makeTestImage(width: 800, height: 600), maxDimension: 800)

        let variant = try await store.saveInferenceVariant(from: source)
        #expect(FileManager.default.fileExists(atPath: variant.path))

        await store.deleteInferenceVariant(for: source)

        #expect(!FileManager.default.fileExists(atPath: variant.path))
    }

    @Test func diskImageLoaderReturnsNilForMissingFilesAndDecodesSavedOnes() async throws {
        let missing = MessageAttachment.attachmentsDirectory.appending(path: "\(UUID().uuidString).jpg")
        #expect(await DiskBackedImageLoader.loadThumbnail(at: missing, maxPixelSize: 128) == nil)
        #expect(await DiskBackedImageLoader.loadImage(at: missing) == nil)

        let store = makeImageStore()
        let url = try await store.save(image: makeTestImage(width: 300, height: 200), maxDimension: 300)

        let thumbnail = try #require(await DiskBackedImageLoader.loadThumbnail(at: url, maxPixelSize: 100))
        #expect(max(thumbnail.size.width, thumbnail.size.height) <= 100)
        // A second request is served from the cache with the same image.
        let cached = await DiskBackedImageLoader.loadThumbnail(at: url, maxPixelSize: 100)
        #expect(cached === thumbnail)

        let image = try #require(await DiskBackedImageLoader.loadImage(at: url))
        #expect(image.size.width * image.scale == 300)
    }

    // MARK: - Export

    @Test func chatExportOrdersMessagesWithEqualOrderByCreationDate() throws {
        let conversation = Conversation(title: "Ties")
        let base = Date(timeIntervalSince1970: 1_000)
        conversation.messages = [
            Minnow.Message(role: .assistant, text: "Second", createdAt: base.addingTimeInterval(5), order: 1, conversation: conversation, isFinal: true),
            Minnow.Message(role: .user, text: "First", createdAt: base, order: 1, conversation: conversation, isFinal: true)
        ]

        let snapshot = try #require(ChatExportFormatter.snapshots(of: [conversation]).first)

        #expect(snapshot.messages.map(\.displaySource) == ["First", "Second"])
    }

    @Test func chatExportFileIsWrittenAwayFromTheMainActor() async throws {
        let conversation = Conversation(title: "Trip")
        conversation.lastUpdated = Date(timeIntervalSince1970: 1_790_000_000)
        let assistant = Minnow.Message(
            role: .assistant,
            text: "",
            order: 1,
            conversation: conversation,
            isFinal: true,
            finalAnswer: "<think>plan</think>Take the train.\n<sources>[]</sources>",
            isReasoningMode: true
        )
        conversation.messages = [
            Minnow.Message(role: .user, text: "How do I get there?", order: 0, conversation: conversation, isFinal: true),
            assistant
        ]
        let snapshots = ChatExportFormatter.snapshots(of: [conversation])
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try await ChatExportFormatter.writeExportFile(
            for: snapshots,
            language: .english,
            exportedAt: conversation.lastUpdated,
            in: directory
        )

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written == ChatExportFormatter.text(for: [conversation], language: .english, exportedAt: conversation.lastUpdated))
        #expect(written.contains("**Assistant:**\nTake the train.\n"))
        #expect(!written.contains("<sources>"))
        #expect(!written.contains("plan"))
    }

    @Test func chatExportFileNameIsSortableLocalTime() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 1_790_000_000)

        #expect(ChatExportFormatter.fileName(exportedAt: date, timeZone: utc) == "Minnow-Export-2026-09-21-141320.txt")
    }

    // MARK: - Interface language

    @Test func systemDefaultLanguageIsTheFirstSupportedPreferredLanguage() {
        #expect(AppLanguage.preferred(from: ["fr-FR", "de-AT", "en-US"]) == .german)
        #expect(AppLanguage.preferred(from: ["es-419"]) == .spanish)
        #expect(AppLanguage.preferred(from: ["en-GB", "de-DE"]) == .english)
        #expect(AppLanguage.preferred(from: ["fr-FR", "ja-JP"]) == .english)
        #expect(AppLanguage.preferred(from: []) == .english)
    }

    @Test func currentLanguageFollowsEveryWriteToTheSetting() throws {
        // A selection over a scratch domain, so the host app's standard defaults stay untouched.
        let defaults = try makeScratchDefaults(#function)
        let selection = AppLanguageSelection(defaults: defaults)

        defaults.set("de", forKey: AppSettingsKeys.appLanguage)
        #expect(selection.current == .german)

        defaults.set("es", forKey: AppSettingsKeys.appLanguage)
        #expect(selection.current == .spanish)

        defaults.removeObject(forKey: AppSettingsKeys.appLanguage)
        #expect(selection.current == AppLanguage.systemDefault)

        defaults.set("unsupported", forKey: AppSettingsKeys.appLanguage)
        #expect(selection.current == .english)
    }

    @Test func localizedBundleFollowsTheCurrentLanguage() {
        AppLanguage.overrideCurrent(with: .german)
        #expect(AppLanguage.current == .german)
        #expect(Bundle.appLocalized == AppLanguage.german.bundle)
        AppLanguage.overrideCurrent(with: .english)
        #expect(Bundle.appLocalized == AppLanguage.english.bundle)
    }

    // MARK: - Settings defaults

    @Test func freshSettingsLoadMatchesTheResetDefaults() throws {
        let defaults = try makeScratchDefaults(#function)

        var loaded = AppSettingsDraft.load(from: defaults)
        // The API key comes from the Keychain, which a scratch suite doesn't isolate.
        loaded.tavilyApiKey = ""

        #expect(loaded == AppSettingsDraft.defaults())
        #expect(loaded.appLanguage == AppLanguage.systemDefault.rawValue)
    }

    @Test func settingsLoadKeepsSavedValuesOverDefaults() throws {
        let defaults = try makeScratchDefaults(#function)
        defaults.set("dark", forKey: AppSettingsKeys.appAppearance)
        defaults.set("es", forKey: AppSettingsKeys.appLanguage)
        defaults.set(false, forKey: AppSettingsKeys.enableHaptics)
        defaults.set(12, forKey: AppSettingsKeys.autoDeleteDays)
        defaults.set(2.0, forKey: AppSettingsKeys.mlxRepetitionPenalty)

        let loaded = AppSettingsDraft.load(from: defaults)

        #expect(loaded.appAppearance == "dark")
        #expect(loaded.appLanguage == "es")
        #expect(!loaded.enableHaptics)
        #expect(loaded.autoDeleteDays == 12)
        // Out-of-range saved values are still clamped by the typed accessor.
        #expect(loaded.mlxRepetitionPenalty == 1.5)
    }

    // MARK: - Privacy manifest

    @Test func privacyManifestDeclaresSearchQueriesSentToTavily() throws {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try #require(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        )
        let collected = try #require(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let searchHistory = try #require(collected.first {
            $0["NSPrivacyCollectedDataType"] as? String == "NSPrivacyCollectedDataTypeSearchHistory"
        })

        #expect(searchHistory["NSPrivacyCollectedDataTypeLinked"] as? Bool == false)
        #expect(searchHistory["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
        #expect(searchHistory["NSPrivacyCollectedDataTypePurposes"] as? [String] == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"])
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
    }
}
