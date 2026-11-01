//
//  MinnowTests+SessionReuse
//  MinnowTests
//
//  Persistent MLX session reuse across turns, stale-session release, and
//  stream cancellation; part of the single @Suite(.serialized) MinnowTests
//  suite. The worker's reuse decision is a pure function of what it stored,
//  so these tests drive it with prompts from the real prompt builder and
//  need no model.
//

import Testing
import Foundation
import MLXLMCommon
import SwiftData
@testable import Minnow

extension MinnowTests {

    // MARK: - Helpers

    private static let sessionReuseConversationID = UUID()

    private func sessionKey(
        conversationID: UUID = MinnowTests.sessionReuseConversationID,
        modelID: String = "qwen3.5-4b",
        enableThinking: Bool = false,
        toolsEnabled: Bool = false,
        includesMedia: Bool = false,
        instructions: String = "System"
    ) -> MLXSessionKey {
        MLXSessionKey(
            conversationID: conversationID,
            modelID: modelID,
            enableThinking: enableThinking,
            toolsEnabled: toolsEnabled,
            includesMedia: includesMedia,
            instructionFingerprint: instructions.hashValue
        )
    }

    private var unboundedCacheConfiguration: MLXSessionCacheConfiguration {
        MLXSessionCacheConfiguration(parameters: GenerateParameters())
    }

    /// What the worker stores after answering `prompt` with `reply`.
    private func storedSession(
        afterAnswering prompt: ChatViewModel.MLXPromptMessages,
        with reply: String,
        key: MLXSessionKey? = nil
    ) throws -> MLXSessionDescriptor {
        let latest = try #require(prompt.messages.last)
        return MLXSessionDescriptor(
            key: key ?? sessionKey(),
            cacheConfiguration: unboundedCacheConfiguration,
            transcript: MLXSessionTranscript(
                history: Array(prompt.messages.dropLast()),
                prompt: latest,
                reply: reply
            )
        )
    }

    private func reuseDecision(
        for prompt: ChatViewModel.MLXPromptMessages,
        stored: MLXSessionDescriptor?,
        key: MLXSessionKey? = nil
    ) -> MLXSessionReuseDecision {
        MLXInferenceWorker.sessionReuseDecision(
            stored: stored,
            requestKey: key ?? sessionKey(),
            requestCacheConfiguration: unboundedCacheConfiguration,
            history: Array(prompt.messages.dropLast())
        )
    }

    private func appendMessage(
        to viewModel: ChatViewModel,
        role: MessageRole,
        text: String,
        order: Int,
        isFinal: Bool = true,
        reasoning: String? = nil,
        finalAnswer: String? = nil,
        isReasoningMode: Bool = false
    ) {
        viewModel.conversation.messages.append(Minnow.Message(
            role: role,
            text: text,
            order: order,
            conversation: viewModel.conversation,
            isFinal: isFinal,
            reasoning: reasoning,
            finalAnswer: finalAnswer,
            isReasoningMode: isReasoningMode
        ))
    }

    // MARK: - Reuse Across Turns

    @Test func mlxSessionIsReusedForConsecutiveReasoningTurns() async throws {
        let viewModel = try makeViewModel()
        viewModel.conversation.reasoningMode = true
        appendMessage(to: viewModel, role: .user, text: "Explain Swift actors.", order: 0)
        let firstTurn = try await viewModel.buildMLXPrompt(upToOrderExclusive: 1)

        // The worker records the raw stream: reasoning, the closing tag, a
        // stray Markdown line and the lowercase typo the view model fixes.
        let firstRawReply = "The user wants actors explained briefly.\n</think>\n\n**\nActors protect mutable state on ios and macOS.\u{00A0}"
        let firstStored = try storedSession(afterAnswering: firstTurn, with: firstRawReply)
        appendMessage(
            to: viewModel,
            role: .assistant,
            text: "Actors protect mutable state on iOS and macOS.",
            order: 1,
            reasoning: "The user wants actors explained briefly.",
            finalAnswer: "Actors protect mutable state on iOS and macOS.",
            isReasoningMode: true
        )
        appendMessage(to: viewModel, role: .user, text: "And what does Sendable add?", order: 2)
        let secondTurn = try await viewModel.buildMLXPrompt(upToOrderExclusive: 3)

        #expect(secondTurn.messages.first?.content == firstTurn.messages.first?.content)
        #expect(reuseDecision(for: secondTurn, stored: firstStored) == .reuse)

        // The session keeps matching on later turns once it adopts the
        // replayed form of the turns it answered.
        let secondLatest = try #require(secondTurn.messages.last)
        let secondStored = MLXSessionDescriptor(
            key: sessionKey(),
            cacheConfiguration: unboundedCacheConfiguration,
            transcript: firstStored.transcript.advanced(
                replayedHistory: Array(secondTurn.messages.dropLast()),
                prompt: secondLatest,
                reply: "It checks values crossing actors.\n</think>\n\nSendable marks values safe to share."
            )
        )
        appendMessage(
            to: viewModel,
            role: .assistant,
            text: "Sendable marks values safe to share.",
            order: 3,
            reasoning: "It checks values crossing actors.",
            finalAnswer: "Sendable marks values safe to share.",
            isReasoningMode: true
        )
        appendMessage(to: viewModel, role: .user, text: "Show an example.", order: 4)
        let thirdTurn = try await viewModel.buildMLXPrompt(upToOrderExclusive: 5)

        #expect(reuseDecision(for: thirdTurn, stored: secondStored) == .reuse)
    }

    @Test func mlxSessionIsReusedWhenChatPreferencesWrapTheLatestTurn() async throws {
        let viewModel = try makeViewModel()
        viewModel.conversation.chatPreferences = "Use plain language."
        appendMessage(to: viewModel, role: .user, text: "Explain Swift actors.", order: 0)
        let firstTurn = try await viewModel.buildMLXPrompt(upToOrderExclusive: 1)
        #expect(firstTurn.messages.last?.content.contains("User preferences for this response:") == true)

        let stored = try storedSession(afterAnswering: firstTurn, with: "Actors keep state safe.")
        appendMessage(to: viewModel, role: .assistant, text: "Actors keep state safe.", order: 1)
        appendMessage(to: viewModel, role: .user, text: "Why?", order: 2)
        let secondTurn = try await viewModel.buildMLXPrompt(upToOrderExclusive: 3)

        #expect(secondTurn.messages[1].content == "Explain Swift actors.")
        #expect(reuseDecision(for: secondTurn, stored: stored) == .reuse)
    }

    @Test func mlxSessionIsReusedAfterTimeSensitiveTurnBecauseSystemPromptStaysFixed() async throws {
        let viewModel = try makeViewModel()
        appendMessage(to: viewModel, role: .system, text: "Answer like a pirate.", order: 0)
        appendMessage(to: viewModel, role: .user, text: "What is the latest Swift release today?", order: 1)
        let firstTurn = try await viewModel.buildMLXPrompt(upToOrderExclusive: 2, toolsAvailable: true)
        let firstSystem = try #require(firstTurn.messages.first).content

        #expect(!firstSystem.contains("Current date and time:"))
        #expect(firstSystem.contains("Answer like a pirate."))
        #expect(firstTurn.stableSystemPrompt == firstSystem)
        #expect(firstTurn.messages.last?.content.contains("Current date and time:") == true)

        let stored = try storedSession(afterAnswering: firstTurn, with: "Swift 6.2 is the latest release.")
        appendMessage(to: viewModel, role: .assistant, text: "Swift 6.2 is the latest release.", order: 2)
        appendMessage(to: viewModel, role: .user, text: "Explain it simply.", order: 3)
        let secondTurn = try await viewModel.buildMLXPrompt(upToOrderExclusive: 4, toolsAvailable: true)

        #expect(secondTurn.messages.first?.content == firstSystem)
        #expect(!secondTurn.messages.contains { $0.content.contains("Current date and time:") })
        #expect(reuseDecision(for: secondTurn, stored: stored) == .reuse)
    }

    @Test func mlxForcedWebSearchInstructionStaysOutOfTheSystemPrompt() async throws {
        let viewModel = try makeViewModel()
        appendMessage(to: viewModel, role: .user, text: "Compare Xcode releases.", order: 0)

        let forced = try await viewModel.buildMLXPrompt(
            upToOrderExclusive: 1,
            toolsAvailable: true,
            forceWebSearch: true
        )
        let unforced = try await viewModel.buildMLXPrompt(upToOrderExclusive: 1, toolsAvailable: true)

        #expect(forced.messages.first?.content == unforced.messages.first?.content)
        #expect(forced.messages.last?.content.contains("you must call webSearch before answering") == true)
        #expect(forced.messages.last?.content.hasSuffix("User request:\nCompare Xcode releases.") == true)
    }

    // MARK: - Rejected Reuse

    @Test func mlxSessionIsNotReusedWhenHistoryDiverges() async throws {
        let viewModel = try makeViewModel()
        appendMessage(to: viewModel, role: .user, text: "Explain Swift actors.", order: 0)
        let firstTurn = try await viewModel.buildMLXPrompt(upToOrderExclusive: 1)
        let stored = try storedSession(afterAnswering: firstTurn, with: "Actors protect mutable state.")

        // A reply that is not the one the session generated.
        appendMessage(to: viewModel, role: .assistant, text: "Structs are value types.", order: 1)
        appendMessage(to: viewModel, role: .user, text: "Why?", order: 2)
        let otherReply = try await viewModel.buildMLXPrompt(upToOrderExclusive: 3)
        #expect(reuseDecision(for: otherReply, stored: stored) == .historyChanged)

        // An earlier user turn that changed.
        viewModel.conversation.messages[1].text = "Actors protect mutable state."
        viewModel.conversation.messages[0].text = "Explain Swift classes."
        let editedQuestion = try await viewModel.buildMLXPrompt(upToOrderExclusive: 3)
        #expect(reuseDecision(for: editedQuestion, stored: stored) == .historyChanged)

        // A request that skips the reply the session holds.
        viewModel.conversation.messages[0].text = "Explain Swift actors."
        let regeneration = try await viewModel.buildMLXPrompt(upToOrderExclusive: 1)
        #expect(reuseDecision(for: regeneration, stored: stored) == .historyChanged)
    }

    @Test func mlxSessionReuseIgnoresThinkingButRequiresSameModelToolsAndCache() throws {
        let history: [Chat.Message] = [.system("System"), .user("Hi"), .assistant("Hello!")]
        let stored = MLXSessionDescriptor(
            key: sessionKey(enableThinking: true),
            cacheConfiguration: unboundedCacheConfiguration,
            transcript: MLXSessionTranscript(
                history: [.system("System")],
                prompt: .user("Hi"),
                reply: "Hello!"
            )
        )
        func decision(
            key: MLXSessionKey,
            cache: MLXSessionCacheConfiguration? = nil
        ) -> MLXSessionReuseDecision {
            MLXInferenceWorker.sessionReuseDecision(
                stored: stored,
                requestKey: key,
                requestCacheConfiguration: cache ?? unboundedCacheConfiguration,
                history: history
            )
        }

        #expect(decision(key: sessionKey(enableThinking: false)) == .reuse)
        #expect(decision(key: sessionKey(modelID: "lfm2.5-2.6b-4bit")) == .incompatibleKey)
        #expect(decision(key: sessionKey(toolsEnabled: true)) == .incompatibleKey)
        #expect(decision(key: sessionKey(instructions: "Other system")) == .incompatibleKey)
        #expect(decision(key: sessionKey(conversationID: UUID())) == .incompatibleKey)
        #expect(decision(
            key: sessionKey(),
            cache: MLXSessionCacheConfiguration(parameters: GenerateParameters(maxKVSize: 4_096))
        ) == .cacheConfigurationChanged)
        #expect(MLXInferenceWorker.sessionReuseDecision(
            stored: nil,
            requestKey: sessionKey(),
            requestCacheConfiguration: unboundedCacheConfiguration,
            history: history
        ) == .noSession)
    }

    @Test func mlxSessionIsRebuiltOnceItHoldsMoreThanTheContextWindow() {
        let history: [Chat.Message] = [.system("System"), .user("Hi"), .assistant("Hello!")]
        var stored = MLXSessionDescriptor(
            key: sessionKey(),
            cacheConfiguration: unboundedCacheConfiguration,
            transcript: MLXSessionTranscript(history: [.system("System")], prompt: .user("Hi"), reply: "Hello!"),
            cachedTokenCount: 4_096
        )
        func decision(limit: Int?) -> MLXSessionReuseDecision {
            MLXInferenceWorker.sessionReuseDecision(
                stored: stored,
                requestKey: sessionKey(),
                requestCacheConfiguration: unboundedCacheConfiguration,
                history: history,
                sessionTokenLimit: limit
            )
        }

        #expect(decision(limit: 4_096) == .reuse)
        #expect(decision(limit: nil) == .reuse)
        // Earlier reasoning and per-turn context stay in the KV, so it can outgrow
        // the window the replayed history was budgeted for.
        stored.cachedTokenCount = 4_097
        #expect(decision(limit: 4_096) == .sessionTooLong)
    }

    @Test func lfmSessionsAreNeverContinuedBecauseItsTemplateRepeatsBOS() {
        #expect(!MLXModelManager.MLXModelInfo.Family.lfm25.continuesPersistentSessions)
        #expect(MLXModelManager.MLXModelInfo.Family.qwen35.continuesPersistentSessions)

        let history: [Chat.Message] = [.system("System"), .user("Hi"), .assistant("Hello!")]
        let stored = MLXSessionDescriptor(
            key: sessionKey(),
            cacheConfiguration: unboundedCacheConfiguration,
            transcript: MLXSessionTranscript(history: [.system("System")], prompt: .user("Hi"), reply: "Hello!")
        )
        #expect(MLXInferenceWorker.sessionReuseDecision(
            stored: stored,
            requestKey: sessionKey(),
            requestCacheConfiguration: unboundedCacheConfiguration,
            history: history,
            continuesSessions: false
        ) == .templateCannotContinue)
    }

    @Test func mlxSessionTranscriptRejectsHistoryCarryingMedia() {
        let transcript = MLXSessionTranscript(
            history: [.system("System")],
            prompt: .user("Describe it."),
            reply: "A red sign."
        )
        let image = UserInput.Image.url(URL(fileURLWithPath: "/tmp/sign.jpg"))

        #expect(transcript.isReplayed(by: [.system("System"), .user("Describe it."), .assistant("A red sign.")]))
        #expect(!transcript.isReplayed(by: [
            .system("System"), .user("Describe it.", images: [image]), .assistant("A red sign.")
        ]))
    }

    @Test func mlxPendingTurnAcceptsOnlyCleanedUpFormsOfWhatItHolds() {
        let reply = MLXPendingTurnSignature(
            role: .assistant,
            content: "Plan the answer.\n</think>\n\n<search>swift</search>Swift 6.2 adds ios 26 support."
        )

        #expect(reply.isReplayed(by: .assistant("Swift 6.2 adds iOS 26 support.")))
        #expect(!reply.isReplayed(by: .assistant("Swift 6.3 adds iOS 26 support.")))
        #expect(!reply.isReplayed(by: .user("Swift 6.2 adds iOS 26 support.")))
    }

    // MARK: - Stale Sessions

    @Test func mlxReplacementSessionReleasesOnlyItsConversationsStaleSessionFirst() {
        let current = UUID()
        let other = UUID()
        let stored = [current, other]

        for decision in [
            MLXSessionReuseDecision.noSession, .incompatibleKey, .cacheConfigurationChanged, .historyChanged, .mediaTurn,
            .sessionTooLong, .templateCannotContinue
        ] {
            let scope = MLXInferenceWorker.staleSessionReleaseScope(decision: decision, maxKVSize: nil)
            #expect(scope == .conversation, "\(decision)")
            #expect(MLXInferenceWorker.conversationsToRelease(
                scope: scope, conversationID: current, stored: stored
            ) == [current])
        }

        let reuseScope = MLXInferenceWorker.staleSessionReleaseScope(decision: .reuse, maxKVSize: nil)
        #expect(reuseScope == .none)
        #expect(MLXInferenceWorker.conversationsToRelease(
            scope: reuseScope, conversationID: current, stored: stored
        ).isEmpty)

        let boundedToolLoop = MLXInferenceWorker.staleSessionReleaseScope(
            decision: .explicitMessageHistory, maxKVSize: 4_096
        )
        #expect(boundedToolLoop == .all)
        #expect(Set(MLXInferenceWorker.conversationsToRelease(
            scope: boundedToolLoop, conversationID: current, stored: stored
        )) == Set(stored))
    }

    // MARK: - Cancellation

    @Test func mlxGenerationStreamThrowsCancellationInsteadOfFinishingQuietly() async {
        let (generations, continuation) = AsyncThrowingStream<Generation, Error>.makeStream()
        let (firstChunk, firstChunkContinuation) = AsyncStream<Void>.makeStream()
        let consumer = Task {
            try await MLXInferenceWorker.forEachGeneration(in: generations) { _ in
                firstChunkContinuation.yield()
                return .next
            }
        }

        continuation.yield(.chunk("Hello"))
        var firstChunkIterator = firstChunk.makeAsyncIterator()
        _ = await firstChunkIterator.next()
        consumer.cancel()

        switch await consumer.result {
        case .success:
            Issue.record("A cancelled stream finished as if the response were complete.")
        case .failure(let error):
            #expect(error is CancellationError)
        }
        continuation.finish()
    }

    @Test func mlxGenerationStreamStopsAtToolCallAndFinishesNormally() async throws {
        let (generations, continuation) = AsyncThrowingStream<Generation, Error>.makeStream()
        continuation.yield(.chunk("A"))
        continuation.yield(.chunk("B"))
        continuation.yield(.chunk("C"))
        continuation.finish()

        var seen: [String] = []
        try await MLXInferenceWorker.forEachGeneration(in: generations) { generation in
            if case .chunk(let text) = generation { seen.append(text) }
            return seen.count == 2 ? .stop : .next
        }
        #expect(seen == ["A", "B"])

        let (finished, finishedContinuation) = AsyncThrowingStream<Generation, Error>.makeStream()
        finishedContinuation.yield(.chunk("Done"))
        finishedContinuation.finish()
        var finishedCount = 0
        try await MLXInferenceWorker.forEachGeneration(in: finished) { _ in
            finishedCount += 1
            return .next
        }
        #expect(finishedCount == 1)
    }

    // MARK: - Prompt Construction

    @Test func mlxPromptHistoryLimitCountsOnlyUsableTurns() async throws {
        let viewModel = try makeViewModel()
        appendMessage(to: viewModel, role: .user, text: "First question", order: 0)
        appendMessage(to: viewModel, role: .assistant, text: "Generation failed: timeout", order: 1)
        appendMessage(to: viewModel, role: .user, text: "Second question", order: 2)
        appendMessage(to: viewModel, role: .assistant, text: "Partial", order: 3, isFinal: false)
        appendMessage(to: viewModel, role: .user, text: "Third question", order: 4)

        let messages = try await viewModel.buildMLXPrompt(upToOrderExclusive: 5, maxMessages: 3).messages

        #expect(messages.filter { $0.role == .user }.map(\.content) == [
            "First question", "Second question", "Third question"
        ])
    }

    @Test func mlxRegenerationInstructionMergesIntoTheLatestUserTurn() async throws {
        let viewModel = try makeViewModel()
        appendMessage(to: viewModel, role: .user, text: "Explain Swift actors.", order: 0)

        let messages = try await viewModel.buildMLXPrompt(
            upToOrderExclusive: 1,
            additionalInstruction: "Use three paragraphs."
        ).messages

        #expect(messages.map(\.role) == [.system, .user])
        #expect(messages.last?.content == "Explain Swift actors.\n\nUse three paragraphs.")
    }

    @Test func mlxHistoryBudgetLeavesRoomForSystemPromptToolsAndImages() {
        let budget = ChatViewModel.mlxHistoryTokenBudget(
            promptBudget: 6_000,
            systemPromptTokens: 1_000,
            toolsAvailable: true,
            latestTurnContextTokens: 100,
            imageCount: 2
        )
        #expect(budget == 6_000 - 1_000 - ChatViewModel.mlxToolSchemaTokenEstimate - 100
            - 2 * ChatViewModel.mlxImageTokenEstimate)

        let withoutTools = ChatViewModel.mlxHistoryTokenBudget(
            promptBudget: 6_000,
            systemPromptTokens: 1_000,
            toolsAvailable: false,
            latestTurnContextTokens: 0,
            imageCount: 0
        )
        #expect(withoutTools == 5_000)

        // A custom system prompt larger than the window still leaves the
        // newest turn some room.
        let oversized = ChatViewModel.mlxHistoryTokenBudget(
            promptBudget: 2_000,
            systemPromptTokens: 50_000,
            toolsAvailable: true,
            latestTurnContextTokens: 0,
            imageCount: 0
        )
        #expect(oversized > 0)
        #expect(oversized == ChatViewModel.mlxHistoryTokenBudget(
            promptBudget: 2_000,
            systemPromptTokens: 90_000,
            toolsAvailable: true,
            latestTurnContextTokens: 0,
            imageCount: 0
        ))
    }

    // MARK: - Tool Markup Filter

    @Test func wrappedXMLToolCallStreamFilterMatchesMarkersRegardlessOfCase() {
        var filter = WrappedXMLToolCallStreamFilter()
        let visible = filter.consume("Before <TOOL_CALL><function=webSearch></function></TOOL_CALL>After")
        #expect(visible == "Before After")
        #expect(filter.finish() == nil)

        var split = WrappedXMLToolCallStreamFilter()
        #expect(split.consume("Answer <TOO") == "Answer ")
        #expect(split.consume("L_CALL><function=webSearch>") == nil)
        split.didDispatchToolCall()
        #expect(split.finish() == nil)
    }

    @Test func disabledWrappedXMLToolCallStreamFilterPassesTextThrough() {
        var filter = WrappedXMLToolCallStreamFilter(isEnabled: false)
        #expect(filter.consume("<tool_call>kept</tool_call>") == "<tool_call>kept</tool_call>")
        #expect(filter.finish() == nil)
    }
}
