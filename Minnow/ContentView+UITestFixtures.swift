//
//  ContentView+UITestFixtures.swift
//  Minnow
//

import SwiftUI
import SwiftData
import UIKit

// MARK: - UI Test Fixtures

#if DEBUG
/// Chats seeded by UI-test launch arguments. Debug only: the shipping app never carries
/// fixture data. The scheme's Test action builds Debug, so UI tests still reach it.
extension ContentView {
    func seedWebSearchDemoIfNeeded() -> Conversation? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-test-web-search-demo") else { return nil }
        if let existing = conversations.first(where: { $0.title == "Web Search Preview" }) {
            return existing
        }

        let includesReasoning = !arguments.contains("-ui-test-web-search-without-reasoning")
        let usesLongReasoning = arguments.contains("-ui-test-long-reasoning-demo")
        let demoReasoning = usesLongReasoning
            ? """
            I need current platform information, so I should check primary sources.
            The first search gives the broad release context. A second, narrower query can confirm the exact SwiftUI API.
            I should compare the terminology used by both sources before drawing a conclusion.
            This newly exposed reasoning must appear immediately when the sheet expands.
            I should also verify that the terminology is consistent across the documentation.
            That comparison rules out a naming mismatch between the two sources.
            The implementation details now line up with the platform overview.
            No additional search is needed before forming the final response.
            Finally, I can summarize the verified platform change concisely.
            """
            : "I need current platform information, so I should check primary sources.\n\n</think>\n\nThe first search gives the broad release context. A second, narrower query can confirm the exact SwiftUI API.\n\n</think>"

        let conversation = Conversation(title: "Web Search Preview", reasoningMode: true)
        // Earlier exchanges that make the conversation taller than the screen.
        let fillerMessages: [Message] = arguments.contains("-ui-test-long-chat")
            ? (0..<24).map { index in
                Message(
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    text: "Earlier message \(index + 1)",
                    order: index,
                    conversation: conversation,
                    isFinal: true
                )
            }
            : []
        let userMessage = Message(
            role: .user,
            text: "What changed in SwiftUI web views this year?",
            order: fillerMessages.count,
            conversation: conversation,
            isFinal: true
        )
        let assistantMessage = Message(
            role: .assistant,
            text: "",
            order: fillerMessages.count + 1,
            conversation: conversation,
            isFinal: true,
            reasoning: includesReasoning
                ? demoReasoning
                : " \n ",
            finalAnswer: "SwiftUI now has a native `WebView` and an observable `WebPage` model.\n\n**The key change is native SwiftUI integration.**\n\nApps can embed and control web content without wrapping `WKWebView` themselves, while Apple’s documentation and release coverage agree on the core API shape.",
            isReasoningMode: true,
            generationBackend: "Preview",
            generationModelName: "UI Fixture"
        )

        let firstResponse = WebSearchResponse(
            query: "SwiftUI WebView iOS 26 changes",
            sources: [
                WebSearchSource(
                    title: "WebKit for SwiftUI",
                    url: "https://developer.apple.com/documentation/webkit/webkit-for-swiftui",
                    snippet: "Apple documents the SwiftUI-native WebView and WebPage APIs for displaying and controlling web content.",
                    score: 0.97,
                    publishedDate: "June 2026"
                ),
                WebSearchSource(
                    title: "What’s new in WebKit and Safari",
                    url: "https://webkit.org/blog/",
                    snippet: "WebKit release notes cover new platform capabilities and behavior across Safari and embedded web views.",
                    score: 0.89
                ),
                WebSearchSource(
                    title: "SwiftUI updates",
                    url: "https://developer.apple.com/swiftui/whats-new/",
                    snippet: "Apple’s SwiftUI overview highlights the newest framework APIs and platform integrations.",
                    score: 0.84
                )
            ],
            responseTimeSeconds: 0.42
        )
        let secondResponse = WebSearchResponse(
            query: "Apple WebPage WebView SwiftUI documentation",
            sources: [
                WebSearchSource(
                    title: "WebView",
                    url: "https://developer.apple.com/documentation/webkit/webview-swift.struct",
                    snippet: "A SwiftUI view that displays web content managed by a WebPage instance.",
                    score: 0.99
                ),
                WebSearchSource(
                    title: "WebPage",
                    url: "https://developer.apple.com/documentation/webkit/webpage",
                    snippet: "An observable object that manages navigation, page state, and interactions for web content.",
                    score: 0.98
                )
            ],
            responseTimeSeconds: 0.31
        )
        let now = Date()
        if includesReasoning {
            assistantMessage.reasoningStartedAt = now.addingTimeInterval(-68)
            assistantMessage.reasoningCompletedAt = now
        }
        assistantMessage.searchInvocations = [
            SearchInvocation(
                query: firstResponse.query,
                results: firstResponse.modelFacingText(),
                response: firstResponse,
                status: .completed,
                anchorStepNumber: 1,
                timestamp: now.addingTimeInterval(-1.1),
                completedAt: now.addingTimeInterval(-0.68)
            ),
            SearchInvocation(
                query: secondResponse.query,
                results: secondResponse.modelFacingText(),
                response: secondResponse,
                status: .completed,
                anchorStepNumber: 2,
                timestamp: now.addingTimeInterval(-0.55),
                completedAt: now.addingTimeInterval(-0.24)
            )
        ]
        conversation.messages = fillerMessages + [userMessage, assistantMessage]
        modelContext.insert(conversation)
        if arguments.contains("-ui-test-image-message") {
            attachFixtureImage(to: userMessage)
        }
        if arguments.contains("-ui-test-second-chat") {
            seedSecondChatFixture()
        }
        try? modelContext.save()
        return conversation
    }

    func attachFixtureImage(to message: Message) {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        }
        Task { @MainActor in
            guard let url = try? await ImageStore.shared.save(image: image) else { return }
            let attachment = MessageAttachment(type: .image, fileURL: url, fileName: url.lastPathComponent)
            message.attachments.append(attachment)
            attachment.message = message
            try? modelContext.save()
        }
    }

    /// Puts an image in the demo chat's composer, as if the user had just picked one,
    /// so UI tests don't depend on the simulator's photo library.
    func seedComposerImageIfNeeded(into viewModel: ChatViewModel) {
        guard ProcessInfo.processInfo.arguments.contains("-ui-test-composer-image"),
              viewModel.conversation.title == "Web Search Preview" else { return }
        viewModel.composerDraft.image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        }
    }

    func seedSecondChatFixture() {
        let conversation = Conversation(title: "Second Chat")
        conversation.messages = [
            Message(role: .user, text: "Hello there", order: 0, conversation: conversation, isFinal: true),
            Message(
                role: .assistant,
                text: "Second chat reply.",
                order: 1,
                conversation: conversation,
                isFinal: true,
                generationBackend: "Preview",
                generationModelName: "UI Fixture"
            )
        ]
        if ProcessInfo.processInfo.arguments.contains("-ui-test-stale-second-chat") {
            conversation.lastUpdated = Calendar.current.date(byAdding: .day, value: -60, to: Date()) ?? Date()
        }
        modelContext.insert(conversation)
    }
}
#endif
