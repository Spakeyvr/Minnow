//
//  ChatLLMTests+ChatOrchestration
//  ChatLLMTests
//
//  Turn lifecycle, stream timeouts, saving and final-text cleanup in ChatViewModel.
//  Part of the single @Suite(.serialized) ChatLLMTests suite.
//

import Testing
import Foundation
import SwiftData
@testable import ChatLLM

extension ChatLLMTests {

    // MARK: - Timeouts

    @Test func withTimeoutCalledFromAnAlreadyCancelledTaskThrowsInsteadOfHanging() async throws {
        let viewModel = try makeViewModel()
        var outcome: String?
        let task = Task { @MainActor in
            do {
                _ = try await viewModel.withTimeout(.seconds(5)) { 42 }
                outcome = "value"
            } catch is CancellationError {
                outcome = "cancelled"
            } catch {
                outcome = "other"
            }
        }
        // The task has not started yet, so it begins already cancelled.
        task.cancel()
        try await waitUntil { outcome != nil }
        #expect(outcome == "cancelled")
    }

    @Test func streamThatGoesSilentAfterPartialOutputFailsWithTheTimeoutAndKeepsTheText() async throws {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        defer { continuation.finish() }
        let viewModel = try makeViewModel(generator: ControlledMarkdownGenerator(stream: stream))
        viewModel.streamTimeouts.firstToken = .milliseconds(400)
        viewModel.streamTimeouts.chunk = .milliseconds(250)
        continuation.yield("Partial answer")

        await viewModel.send(userText: "Hello")

        let reply = try #require(viewModel.conversation.messages.first { $0.role == .assistant })
        #expect(reply.text == "Partial answer")
        #expect(reply.generationError?.contains("timed out") == true)
        #expect(reply.isFinal)
        #expect(!viewModel.isGenerating)
    }

    @Test func steadyTokensKeepAStreamAliveLongerThanTheChunkTimeout() async throws {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let viewModel = try makeViewModel(generator: ControlledMarkdownGenerator(stream: stream))
        viewModel.streamTimeouts.firstToken = .milliseconds(300)
        viewModel.streamTimeouts.chunk = .milliseconds(300)
        let producer = Task {
            for index in 0..<12 {
                continuation.yield("t\(index) ")
                try? await Task.sleep(for: .milliseconds(60))
            }
            continuation.finish()
        }
        defer { producer.cancel() }

        await viewModel.send(userText: "Hello")

        let reply = try #require(viewModel.conversation.messages.first { $0.role == .assistant })
        #expect(reply.generationError == nil)
        #expect(reply.text.hasPrefix("t0 t1"))
        #expect(reply.text.hasSuffix("t11"))
    }

    @Test func replyWaitingOnAModelLoadThatNeverFinishesFailsWithAnError() async throws {
        let bridge = testEnvironment.bridge
        let manager = try #require(bridge.modelManager)
        bridge.selectedBackend = .mlx
        bridge.selectedModelID = manager.availableModels.first?.id
        manager.isLoading = true
        defer { manager.isLoading = false }
        let viewModel = try makeViewModel()
        viewModel.streamTimeouts.modelLoad = .milliseconds(200)

        await viewModel.send(userText: "Hello")

        let reply = try #require(viewModel.conversation.messages.first { $0.role == .assistant })
        #expect(reply.generationError?.contains("isn't ready") == true)
        #expect(!viewModel.isGenerating)
    }

    @Test func replyWaitingOnAModelLoadContinuesAsSoonAsTheLoadEnds() async throws {
        let bridge = testEnvironment.bridge
        let manager = try #require(bridge.modelManager)
        bridge.selectedBackend = .mlx
        bridge.selectedModelID = manager.availableModels.first?.id
        manager.isLoading = true
        defer { manager.isLoading = false }
        let viewModel = try makeViewModel()
        let task = Task { await viewModel.send(userText: "Hello") }
        defer { task.cancel() }
        try await waitUntil { viewModel.isWaitingForModelLoad }

        // No model ends up loaded, so the reply reports that once the load stops.
        manager.isLoading = false
        try await waitUntil { !viewModel.isGenerating }

        let reply = try #require(viewModel.conversation.messages.first { $0.role == .assistant })
        #expect(reply.generationError?.contains("isn't ready") == true)
    }

    // MARK: - Ending a stream

    @Test func errorAfterPartialOutputKeepsTokensThatArrivedAfterTheLastRepaint() async throws {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        continuation.yield("Hello")
        continuation.yield(" world")
        continuation.finish(throwing: NSError(domain: "Test", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "Backend failed"
        ]))
        let viewModel = try makeViewModel(generator: ControlledMarkdownGenerator(stream: stream))

        await viewModel.send(userText: "Hi")

        let reply = try #require(viewModel.conversation.messages.first { $0.role == .assistant })
        #expect(reply.text == "Hello world")
        #expect(reply.generationError == "Backend failed")
        #expect(reply.isFinal)
    }

    @Test func replyThatStopsWhileStillReasoningReportsTheMissingAnswer() async throws {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        continuation.yield("<thinking>\nStill working out the steps")
        continuation.finish()
        let viewModel = try makeViewModel(generator: ControlledMarkdownGenerator(stream: stream))
        let question = Message(role: .user, text: "Solve it", order: 0,
                               conversation: viewModel.conversation, isFinal: true)
        let reply = Message(role: .assistant, text: "", order: 1,
                            conversation: viewModel.conversation, isReasoningMode: true)
        viewModel.conversation.messages = [question, reply]

        let outcome = await viewModel.streamAssistant(into: reply, basedOnHistoryUpTo: reply.order)

        #expect(outcome == .failedAfterPartialOutput)
        #expect(reply.reasoning?.contains("Still working out the steps") == true)
        #expect(reply.generationError != nil)
        #expect(reply.isFinal)
    }

    @Test func outputEndsInsideReasoningOnlyWhenTheLastBlockIsUnclosed() {
        #expect(ChatViewModel.outputEndsInsideReasoning("Thinking without a close", reasoningOpensInPrompt: true))
        #expect(!ChatViewModel.outputEndsInsideReasoning("Thinking</think>Answer", reasoningOpensInPrompt: true))
        #expect(!ChatViewModel.outputEndsInsideReasoning("A plain answer", reasoningOpensInPrompt: false))
        #expect(ChatViewModel.outputEndsInsideReasoning("<thinking>Still going", reasoningOpensInPrompt: false))
        #expect(!ChatViewModel.outputEndsInsideReasoning("<thinking>Done</thinking>", reasoningOpensInPrompt: false))
        #expect(ChatViewModel.outputEndsInsideReasoning("<think>a</think>b<think>c", reasoningOpensInPrompt: false))
    }

    // MARK: - Turn lifecycle

    @Test func sendingWhileARegenerationRunsReportsThatTheMessageWasNotSent() async throws {
        let generator = CapturingFoundationGenerator()
        let viewModel = try makeViewModel(generator: generator)
        viewModel.isRegenerating = true

        #expect(viewModel.isBusy)
        #expect(await viewModel.trySend(userText: "Hello") == false)
        #expect(generator.request == nil)
        #expect(viewModel.conversation.messages.isEmpty)

        viewModel.isRegenerating = false
        #expect(await viewModel.trySend(userText: "Hello"))
        #expect(viewModel.conversation.messages.sortedByOrder.map(\.role) == [.user, .assistant])
    }

    @Test func messageSentDuringADelayedRegenerationCancelsItAndIsKept() async throws {
        let viewModel = try makeViewModel(generator: CapturingFoundationGenerator())
        _ = try #require(viewModel.prepareUserMessageForSend("First question"))
        let reply = viewModel.appendAssistantPlaceholder(isReasoningMode: false)
        reply.text = "Existing answer"
        reply.markAsComplete()

        viewModel.scheduleRegeneration(messageID: reply.id, instruction: nil)
        let scheduled = try #require(viewModel.scheduledRegenerationTask)
        await viewModel.send(userText: "Second question")
        // Sending cancels the delayed regeneration; let it finish before checking nothing changed.
        await scheduled.value

        #expect(viewModel.conversation.messages.sortedByOrder.map(\.text) == [
            "First question", "Existing answer", "Second question", "A plain answer."
        ])
        #expect(viewModel.scheduledRegenerationTask == nil)
    }

    @Test func regenerationRequestedWhileAReplyStreamsLeavesThatReplyRunning() async throws {
        let viewModel = try makeViewModel(generator: BlockingLLMGenerator())
        _ = try #require(viewModel.prepareUserMessageForSend("First"))
        let earlierReply = viewModel.appendAssistantPlaceholder(isReasoningMode: false)
        earlierReply.text = "Earlier answer"
        earlierReply.markAsComplete()
        let sendTask = Task { await viewModel.send(userText: "Second") }
        defer { sendTask.cancel() }
        try await waitUntil { viewModel.streamingMessageID != nil }

        await viewModel.regenerateAfterAssistant(messageID: earlierReply.id)

        #expect(viewModel.isGenerating)
        #expect(viewModel.conversation.messages.count == 4)
        #expect(earlierReply.text == "Earlier answer")
        #expect(await viewModel.cancelGenerationAndWait())
        await sendTask.value
    }

    @Test func titleTimeoutFallsBackInsteadOfRetrying() {
        #expect(!ChatViewModel.shouldRetryTitleGeneration(after: ChatViewModel.GenerationTimeoutError(timeout: .seconds(8))))
        #expect(ChatViewModel.shouldRetryTitleGeneration(after: NSError(domain: "Test", code: 1)))
    }

    @Test func turnFinishesItsLifecycleAndNamesTheChatBeforeSendReturns() async throws {
        let viewModel = try makeViewModel(generator: CapturingFoundationGenerator())
        viewModel.conversation.title = String(localized: "New Chat", bundle: .appLocalized)

        await viewModel.send(userText: "Plan a Vienna weekend trip")

        #expect(!viewModel.isGenerating)
        #expect(viewModel.conversation.hasAutoGeneratedTitle)
        #expect(viewModel.autoNamingTask == nil)
    }

    @Test func streamingStateMirrorsThePublishedStreamingProperties() throws {
        let viewModel = try makeViewModel()
        let messageID = UUID()

        viewModel.isGenerating = true
        viewModel.streamingMessageID = messageID
        viewModel.streamingActivity = .searching

        #expect(viewModel.streamingState.isStreaming(messageID))
        #expect(!viewModel.streamingState.isStreaming(UUID()))
        #expect(viewModel.streamingState.activity == .searching)

        viewModel.isGenerating = false
        #expect(!viewModel.streamingState.isStreaming(messageID))
    }

    // MARK: - Reasoning resolution

    @Test func replyWithoutAPrecedingQuestionReasonsOnlyWhereReasoningIsAvailable() throws {
        let viewModel = try makeChat([])
        viewModel.conversation.reasoningMode = true
        testEnvironment.bridge.selectedBackend = .foundationModels
        #expect(!viewModel.resolvedReasoningMode(for: nil))

        testEnvironment.bridge.selectedBackend = .mlx
        testEnvironment.bridge.selectedModelID = "qwen3.5-0.8b-4bit"
        #expect(viewModel.resolvedReasoningMode(for: nil))

        viewModel.conversation.reasoningMode = false
        viewModel.conversation.smartReasoningMode = true
        // Smart reasoning judges a prompt; with none there is nothing to judge.
        #expect(!viewModel.resolvedReasoningMode(for: nil))
    }

    // MARK: - Saving

    @Test func mutationRightAfterASaveIsPersistedOnceTheDebounceElapses() async throws {
        let viewModel = try makeChat([(.user, "Hello")])
        viewModel.immediateSave()

        viewModel.conversation.messages[0].text = "Edited"
        viewModel.scheduleCoalescedSave()

        #expect(viewModel.context.hasChanges)
        try await waitUntil { !viewModel.context.hasChanges }
    }

    @Test func renumberingAlreadyOrderedMessagesChangesNothing() throws {
        let viewModel = try makeChat([(.user, "a"), (.assistant, "b"), (.user, "c")])
        viewModel.immediateSave()

        viewModel.renumberMessagesByOrder()

        #expect(!viewModel.context.hasChanges)
    }

    // MARK: - Final text cleanup

    @Test func finalCleanupFixesIOSInProseButNotInCodeURLsOrPaths() {
        let input = """
        To target ios 17, add this to your Podfile:

        ```ruby
        platform :ios, '17.0'
        ```

        See https://developer.apple.com/ios/ and the `ios` folder in ios/App. Cisco IOS is different.
        """

        let cleaned = ChatViewModel.cleanGlitchedText(input)

        #expect(cleaned.contains("To target iOS 17"))
        #expect(cleaned.contains("platform :ios, '17.0'"))
        #expect(cleaned.contains("https://developer.apple.com/ios/"))
        #expect(cleaned.contains("`ios` folder in ios/App"))
        #expect(cleaned.contains("Cisco IOS"))
    }

    @Test func finalCleanupLeavesWhitespaceInsideCodeBlocksAlone() {
        let code = "let label = \"a\u{00A0}b\"   // keep the non-breaking space"
        let input = "Here is the snippet you asked for:\u{00A0}\n\n```swift\n\(code)\n```"

        let cleaned = ChatViewModel.cleanGlitchedText(input)

        #expect(cleaned.contains(code))
        #expect(cleaned.hasPrefix("Here is the snippet you asked for: \n"))
    }

    @Test func legacySearchMarkersAreRemovedButSimilarContentIsKept() throws {
        let viewModel = try makeViewModel()
        let input = """
        <search>swift 6 release date</search>
        SEARCH: weather in vienna

        Search: press Cmd+F to find text.

        ```yaml
        search: true


        algolia: enabled
        ```

        <search>
          <form action="/find"><input name="q"></form>
        </search>
        """

        let stripped = viewModel.stripSearchTags(input, preserveBoundaries: false)

        #expect(!stripped.contains("swift 6 release date"))
        #expect(!stripped.contains("SEARCH: weather"))
        #expect(stripped.hasPrefix("Search: press Cmd+F to find text."))
        #expect(stripped.contains("search: true\n\n\nalgolia: enabled"))
        #expect(stripped.contains("<form action=\"/find\">"))
        #expect(stripped.contains("<search>\n  <form"))
    }

    // MARK: - Shimmer timing

    @Test func viewModelShimmerTimingMatchesTheStatusLabel() {
        #expect(ShimmerTiming.period == InlineThinkingView.shimmerPeriod)
        for step in 0..<40 {
            let date = Date(timeIntervalSinceReferenceDate: 1_000 * ShimmerTiming.period + Double(step) * 0.04)
            #expect(ShimmerTiming.offset(at: date) == InlineThinkingView.shimmerOffset(at: date))
            #expect(ShimmerTiming.remainingSweepDuration(at: date) == InlineThinkingView.remainingSweepDuration(at: date))
        }
    }
}
