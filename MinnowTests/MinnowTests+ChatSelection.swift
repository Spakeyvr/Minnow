//
//  MinnowTests+ChatSelection
//  MinnowTests
//
//  Part of the single @Suite(.serialized) MinnowTests suite. Covers the app shell's chat
//  selection, draft and deletion rules, and the screens' small pure helpers.
//

import Testing
import Foundation
import SwiftData
import UIKit
@testable import Minnow

// MARK: - Selection and Drafts

extension MinnowTests {
    @Test func savingADraftsFirstMessageOpensItAsASavedChat() {
        let draft = UUID()
        let other = UUID()

        let change = ChatNavigationRules.listChange(
            from: [other],
            to: [draft, other],
            selectionID: nil,
            draftID: draft,
            isRegularWidth: false
        )

        #expect(change == .promoteDraft)
    }

    @Test func deletingTheOpenChatReplacesItWithADraft() {
        let open = UUID()
        let other = UUID()

        #expect(ChatNavigationRules.listChange(
            from: [open, other], to: [other], selectionID: open, draftID: nil, isRegularWidth: true
        ) == .replaceDeletedSelection)
        // Another chat going away leaves the open chat alone.
        #expect(ChatNavigationRules.listChange(
            from: [open, other], to: [open], selectionID: open, draftID: nil, isRegularWidth: true
        ) == .none)
    }

    @Test func onlyRegularWidthOpensTheNewestChatWhenNothingIsOpen() {
        let newest = UUID()
        let older = UUID()

        #expect(ChatNavigationRules.listChange(
            from: [], to: [newest, older], selectionID: nil, draftID: nil, isRegularWidth: true
        ) == .select(newest))
        #expect(ChatNavigationRules.listChange(
            from: [], to: [newest, older], selectionID: nil, draftID: nil, isRegularWidth: false
        ) == .none)
        // An open draft is the current chat, even on regular width.
        #expect(ChatNavigationRules.listChange(
            from: [older], to: [newest, older], selectionID: nil, draftID: UUID(), isRegularWidth: true
        ) == .none)
    }

    @Test func newChatOnlyCreatesADraftWhenNoneIsOpen() {
        #expect(ChatNavigationRules.newChatCreatesDraft(draftID: nil))
        #expect(!ChatNavigationRules.newChatCreatesDraft(draftID: UUID()))
    }
}

// MARK: - Deletion

extension MinnowTests {
    @Test func deleteAllExceptCurrentFromADraftKeepsTheDraftOpen() {
        let saved = [UUID(), UUID()]

        let plan = ChatNavigationRules.deleteAllExceptCurrentPlan(
            conversationIDs: saved,
            selectionID: nil,
            draftID: UUID()
        )

        // As the confirmation promises, the most recent chat is kept when none is
        // selected, but it is not opened, so the draft stays in front.
        #expect(plan.deletedIDs == [saved[1]])
        #expect(plan.keptID == saved[0])
        #expect(!plan.opensKeptChat)
        #expect(!ChatNavigationRules.canDeleteAllExceptCurrent(
            conversationIDs: [saved[0]], selectionID: nil, draftID: UUID()
        ))
    }

    @Test func deleteAllExceptCurrentKeepsTheOpenChatOrTheNewestOne() {
        let newest = UUID()
        let open = UUID()
        let older = UUID()
        let ids = [newest, open, older]

        let keepingOpen = ChatNavigationRules.deleteAllExceptCurrentPlan(
            conversationIDs: ids, selectionID: open, draftID: nil
        )
        #expect(keepingOpen.deletedIDs == [newest, older])
        #expect(keepingOpen.keptID == open)

        let nothingOpen = ChatNavigationRules.deleteAllExceptCurrentPlan(
            conversationIDs: ids, selectionID: nil, draftID: nil
        )
        #expect(nothingOpen.deletedIDs == [open, older])
        #expect(nothingOpen.keptID == newest)
        #expect(nothingOpen.opensKeptChat)
        #expect(!keepingOpen.opensKeptChat)

        #expect(!ChatNavigationRules.canDeleteAllExceptCurrent(
            conversationIDs: [open], selectionID: open, draftID: nil
        ))
        #expect(!ChatNavigationRules.canDeleteAllExceptCurrent(
            conversationIDs: [], selectionID: nil, draftID: nil
        ))
    }

    @Test func deletingAChatStopsItsReplyFirst() async throws {
        let context = try makeContext()
        let conversation = Conversation(title: "Streaming")
        let viewModel = makeIsolatedChatViewModel(
            generator: BlockingLLMGenerator(),
            context: context,
            conversation: conversation
        )
        let sendTask = Task { await viewModel.send(userText: "Hello") }
        try await waitUntil { viewModel.streamingMessageID != nil }

        // Deleting a different chat leaves this reply running.
        #expect(await ChatNavigationRules.stopReply(of: viewModel, beforeDeleting: [UUID()]))
        #expect(viewModel.isGenerating)

        // Deleting this chat waits until the reply has stopped.
        #expect(await ChatNavigationRules.stopReply(of: viewModel, beforeDeleting: [conversation.id]))
        #expect(!viewModel.isGenerating)
        #expect(viewModel.streamingMessageID == nil)
        await sendTask.value
    }
}

// MARK: - Sidebar

extension MinnowTests {
    @Test func sidebarSectionsAreReusedUntilTheListOrSearchChanges() {
        let now = Date()
        let first = Conversation(title: "Swift notes", lastUpdated: now)
        let second = Conversation(title: "Groceries", lastUpdated: now.addingTimeInterval(-60))
        let cache = SidebarSectionsCache()

        let initial = cache.sections(for: [first, second], searchTerms: [], now: now)
        _ = cache.sections(for: [first, second], searchTerms: [], now: now)
        #expect(cache.computeCount == 1)
        #expect(initial.flatMap(\.conversations).map(\.id) == [first.id, second.id])

        let searched = cache.sections(for: [first, second], searchTerms: ["swift"], now: now)
        #expect(cache.computeCount == 2)
        #expect(searched.flatMap(\.conversations).map(\.id) == [first.id])

        // A rename can change what a search matches.
        second.title = "Swift groceries"
        let afterRename = cache.sections(for: [first, second], searchTerms: ["swift"], now: now)
        #expect(cache.computeCount == 3)
        #expect(afterRename.flatMap(\.conversations).map(\.id) == [first.id, second.id])
    }

    @Test func sidebarPreviewReadsOnlyTheStartOfALongReply() {
        let answer = "Short answer."
        let hiddenSources = "<sources>" + String(repeating: "source text ", count: 400) + "</sources>"
        // The read stops inside the sources block; its content must not leak into the preview.
        #expect(ConversationRow.previewSnippet(from: answer + hiddenSources) == answer)

        let longReply = String(repeating: "word ", count: 5_000)
        let preview = ConversationRow.previewSnippet(from: longReply)
        #expect(preview.count <= ConversationRow.previewLengthLimit)
        #expect(preview.hasPrefix("word word"))
    }

    @Test func sidebarPreviewFallsBackToTheWholeTextWhenItStartsHidden() {
        let hiddenSources = "<sources>" + String(repeating: "source text ", count: 400) + "</sources>"
        #expect(ConversationRow.previewSnippet(from: hiddenSources + "Visible after sources") == "Visible after sources")
    }

    @Test func drawerSwipeLeavesAScrolledCodeBlockToScrollBack() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let codeBlock = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        codeBlock.contentSize = CGSize(width: 900, height: 100)
        let codeText = UIView(frame: CGRect(x: 0, y: 0, width: 900, height: 100))
        codeBlock.addSubview(codeText)
        container.addSubview(codeBlock)

        // At its leading edge the code block can't scroll back, so the drawer may open.
        #expect(!DirectionalPanGestureRecognizer.touchedViewCanScrollTowardLeadingEdge(codeText, within: container))

        codeBlock.contentOffset = CGPoint(x: 200, y: 0)
        #expect(DirectionalPanGestureRecognizer.touchedViewCanScrollTowardLeadingEdge(codeText, within: container))

        // A vertical-only scroll view never blocks the drawer.
        let messageList = UIScrollView(frame: container.bounds)
        messageList.contentSize = CGSize(width: 400, height: 4_000)
        messageList.contentOffset = CGPoint(x: 0, y: 500)
        let message = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        messageList.addSubview(message)
        container.addSubview(messageList)
        #expect(!DirectionalPanGestureRecognizer.touchedViewCanScrollTowardLeadingEdge(message, within: container))
    }
}

// MARK: - Screens

extension MinnowTests {
    @Test func onboardingOffersADownloadAgainAfterItFailed() {
        #expect(OnboardingView.downloadStatus(
            hasActiveDownload: false,
            isInstalled: false,
            availabilityIssue: nil,
            downloadError: "The network connection was lost."
        ) == .download(previousError: "The network connection was lost."))
        #expect(OnboardingView.downloadStatus(
            hasActiveDownload: false, isInstalled: false, availabilityIssue: nil, downloadError: nil
        ) == .download(previousError: nil))
        #expect(OnboardingView.downloadStatus(
            hasActiveDownload: true, isInstalled: false, availabilityIssue: nil, downloadError: "Old error"
        ) == .downloading)
        #expect(OnboardingView.downloadStatus(
            hasActiveDownload: false, isInstalled: false, availabilityIssue: "Needs more memory", downloadError: nil
        ) == .unavailable("Needs more memory"))
    }

    @Test func retentionPickerKeepsAStoredPeriodThatIsNotAPreset() {
        #expect(PrivacySettingsView.retentionDayOptions(including: 30) == [7, 14, 30, 60, 90])
        #expect(PrivacySettingsView.retentionDayOptions(including: 45) == [7, 14, 30, 45, 60, 90])
        #expect(PrivacySettingsView.retentionDayOptions(including: 0) == [7, 14, 30, 60, 90])
    }

    @Test func attachedPhotosAreDecodedWithinThePixelBudget() async throws {
        // Points; the renderer's screen scale makes this at least 2,000 pixels wide.
        let photo = makeTestImage(width: 1_000, height: 700)
        let data = try #require(photo.jpegData(compressionQuality: 0.8))

        let attachment = try #require(await AttachmentImageDecoder.thumbnail(from: data))

        let longestSide = max(attachment.size.width * attachment.scale, attachment.size.height * attachment.scale)
        #expect(longestSide <= CGFloat(AttachmentImageDecoder.pixelBudget))
        #expect(await AttachmentImageDecoder.thumbnail(from: Data("not an image".utf8)) == nil)
    }
}
