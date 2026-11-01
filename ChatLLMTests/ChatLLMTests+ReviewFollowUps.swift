//
//  ChatLLMTests+ReviewFollowUps.swift
//  ChatLLMTests
//
//  Cross-file behavior: prompt reasoning defaults, the stable MLX history window,
//  reasoning search anchors, settings persistence failures, the context-window
//  ceiling and request-scoped prompt prefixes. Part of the single
//  @Suite(.serialized) ChatLLMTests suite.
//

import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import ChatLLM

extension ChatLLMTests {
    // MARK: - Foundation Reasoning Default

    @Test func foundationRequestWithoutExplicitReasoningFollowsThePerPromptRule() throws {
        let viewModel = try makeViewModel()
        viewModel.conversation.smartReasoningMode = true
        viewModel.conversation.messages = [
            ChatLLM.Message(role: .user, text: "Say hello", order: 0, conversation: viewModel.conversation, isFinal: true)
        ]

        let request = viewModel.buildFoundationRequest(upToOrderExclusive: 1)

        // Smart reasoning is a per-prompt heuristic, not "reasoning on".
        #expect(!viewModel.shouldUseReasoningForPrompt("Say hello"))
        #expect(!request.instructions.contains("Reasoning Mode Instructions:"))
        // An explicit value still wins.
        let forced = viewModel.buildFoundationRequest(upToOrderExclusive: 1, currentReasoningActive: true)
        #expect(forced.instructions.contains("Reasoning Mode Instructions:"))
    }

    // MARK: - Stable MLX History Window

    @Test func stableHistoryWindowMovesInChunksAndNeverExceedsWhatFits() {
        // Everything fits: keep everything.
        #expect(ChatViewModel.stableHistoryWindowCount(total: 8, fitting: 8, chunk: 4) == 8)
        // 31 messages, 30 fit: the start moves a whole chunk, not one message.
        #expect(ChatViewModel.stableHistoryWindowCount(total: 31, fitting: 30, chunk: 10) == 21)
        // Later turns keep the same start until the next chunk boundary.
        var starts: [Int] = []
        for total in stride(from: 31, through: 41, by: 2) {
            let kept = ChatViewModel.stableHistoryWindowCount(total: total, fitting: 30, chunk: 10)
            #expect(kept <= 30)
            starts.append(total - kept)
        }
        #expect(starts == [10, 10, 10, 10, 10, 20])
        // Never drops the latest message.
        #expect(ChatViewModel.stableHistoryWindowCount(total: 3, fitting: 1, chunk: 4) == 1)
        #expect(ChatViewModel.mlxHistoryWindowChunk(forMessageLimit: 30) == 10)
        #expect(ChatViewModel.mlxHistoryWindowChunk(forMessageLimit: 10) == 4)
    }

    @Test func mlxPromptKeepsReplayingTheSameHistoryPrefixInALongChat() async throws {
        let viewModel = try makeViewModel()
        // 34 finished messages (17 turns), then a new question; the 30-message cap applies.
        var messages: [ChatLLM.Message] = []
        for index in 0 ..< 36 {
            let role: MessageRole = index.isMultiple(of: 2) ? .user : .assistant
            messages.append(ChatLLM.Message(
                role: role,
                text: "\(role == .user ? "Question" : "Answer") \(index / 2)",
                order: index,
                conversation: viewModel.conversation,
                isFinal: true
            ))
        }
        viewModel.conversation.messages = messages

        func history(upTo order: Int) async throws -> [String] {
            let prompt = try await viewModel.buildMLXPrompt(upToOrderExclusive: order).messages
            // Drop the system turn and the latest question.
            return prompt.dropFirst().dropLast().map(\.content)
        }

        let earlier = try await history(upTo: 33)
        let later = try await history(upTo: 35)
        #expect(!earlier.isEmpty)
        // The next turn's history extends the previous one, so the session can be reused.
        #expect(Array(later.prefix(earlier.count)) == earlier)
        #expect(later.count == earlier.count + 2)
    }

    // MARK: - Reasoning Search Anchors

    @Test func reasoningPieceCountMatchesTheStepsTheSheetShows() {
        // Passes separated by reasoning tags are separate steps in the sheet.
        let reasoning = "Look up the release.</think><think>Compare the dates."
        let segments = ReasoningStepSegmenter.segments(from: ReasoningTextSanitizer.string(from: reasoning))
        let sheetPieces = (segments.last?.pieces.upperBound ?? -1) + 1
        #expect(sheetPieces == 2)
        #expect(ChatViewModel.reasoningPieceCount(for: reasoning) == sheetPieces)
        #expect(ChatViewModel.reasoningPieceCount(for: "  \n ") == 0)
        #expect(ChatViewModel.reasoningPieceCount(for: nil) == 0)
    }

    // MARK: - Settings Persistence

    @Test func settingsPersistReportsARejectedTavilyKeyAndRevertsOnlyTheKey() throws {
        let defaults = try makeScratchDefaults(#function)

        var previous = AppSettingsDraft.defaults()
        previous.tavilyApiKey = "stored-key"
        var updated = previous
        updated.tavilyApiKey = "new-key"
        updated.sendOnReturn = true

        var attemptedKeys: [String] = []
        let saved = updated.persist(to: defaults, comparedTo: previous) { key, _ in
            attemptedKeys.append(key)
            return false
        }

        #expect(!saved)
        #expect(attemptedKeys == ["new-key"])
        // Other settings are still saved.
        #expect(defaults.sendOnReturn)
        let shown = updated.revertingTavilyKey(to: previous)
        #expect(shown.tavilyApiKey == "stored-key")
        #expect(shown.sendOnReturn)

        // An unchanged key is not saved again, so nothing can fail.
        let unchanged = previous.persist(to: defaults, comparedTo: previous) { _, _ in
            Issue.record("The key was saved although it did not change")
            return false
        }
        #expect(unchanged)
    }

    // MARK: - Context Window Ceiling

    @Test func contextWindowSettingCeilingFollowsTheSelectedModel() throws {
        let profile = makeDeviceProfile(isPhone: true, physicalMemoryBytes: 8 * MLXDeviceSupportProfile.gibibyte)
        let catalog = MLXModelManager.modelDefinitions
        let overridden = try #require(catalog.first { $0.phoneContextWindowOverride != nil })
        let plain = try #require(catalog.first { $0.phoneContextWindowOverride == nil })

        #expect(profile.contextWindowSettingMaximum(selectedModel: nil) == profile.maxContextWindowTokensForAnyModel)
        #expect(profile.contextWindowSettingMaximum(selectedModel: overridden)
            == profile.maxContextWindowTokens(for: overridden))
        #expect(profile.contextWindowSettingMaximum(selectedModel: plain) == profile.maxContextWindowTokens)
        #expect(profile.contextWindowSettingMaximum(selectedModel: plain)
            < profile.contextWindowSettingMaximum(selectedModel: overridden))
    }

    @Test func storedTuningValuesUseTheSharedLimitsAndDefaults() throws {
        let defaults = try makeScratchDefaults(#function)

        #expect(defaults.mlxMaxOutputTokens == AppSettingsDefaults.mlxMaxOutputTokens)
        #expect(defaults.mlxEnableRotorQuant == AppSettingsDefaults.mlxEnableRotorQuant)
        #expect(defaults.mlxRepetitionPenalty == AppSettingsDefaults.mlxRepetitionPenalty)

        defaults.mlxMaxOutputTokens = 1
        #expect(defaults.mlxMaxOutputTokens == MLXTuningLimits.outputTokenRange.lowerBound)
        defaults.mlxMaxOutputTokens = 100_000
        #expect(defaults.mlxMaxOutputTokens == MLXTuningLimits.outputTokenRange.upperBound)
        defaults.mlxMaxOutputTokens = 0
        #expect(defaults.mlxMaxOutputTokens == 0)

        defaults.mlxRepetitionPenalty = 9
        #expect(defaults.mlxRepetitionPenalty == MLXTuningLimits.repetitionPenaltyRange.upperBound)
        defaults.mlxRepetitionPenalty = 0
        #expect(defaults.mlxRepetitionPenalty == MLXTuningLimits.noRepetitionPenalty)

        defaults.set(1, forKey: AppSettingsKeys.mlxContextWindowTokens)
        #expect(defaults.mlxContextWindowTokens(deviceMaximum: 4_096) == MLXTuningLimits.minimumContextWindowTokens)
    }

    // MARK: - Request-Scoped Prompt Prefixes

    @Test func promptPrefixCopyNeverSharesUpdatesWithItsSource() {
        Device.withDefaultDevice(.cpu) {
            let source = KVCacheSimple()
            _ = source.update(
                keys: MLXArray.ones([1, 1, 3, 2], dtype: .float32),
                values: MLXArray.ones([1, 1, 3, 2], dtype: .float32)
            )
            eval(source)

            let copy = MLXPromptPrefixCache.copy(of: [source], into: [KVCacheSimple()])
            #expect(copy?.count == 1)
            guard let copied = copy?.first else { return }
            #expect(copied.offset == 3)

            // The session writing to its copy leaves the held source untouched, and the
            // other way round.
            _ = copied.update(
                keys: MLXArray.zeros([1, 1, 1, 2], dtype: .float32),
                values: MLXArray.zeros([1, 1, 1, 2], dtype: .float32)
            )
            _ = source.update(
                keys: MLXArray.ones([1, 1, 1, 2], dtype: .float32) * 7,
                values: MLXArray.ones([1, 1, 1, 2], dtype: .float32) * 7
            )
            #expect(copied.offset == 4)
            #expect(source.offset == 4)
            #expect(source.state[0].asArray(Float.self) == [1, 1, 1, 1, 1, 1, 7, 7])
            #expect(copied.state[0].asArray(Float.self) == [1, 1, 1, 1, 1, 1, 0, 0])

            // Layouts that differ are refused rather than half-filled.
            #expect(MLXPromptPrefixCache.copy(of: [source], into: []) == nil)
        }
    }

    @Test func promptPrefixRequestScopeKeepsOneSavePerEntryAndReleasesHeldPrefixes() {
        let scope = MLXPromptPrefixCache.RequestScope()
        let root = testEnvironment.directory.appendingPathComponent(UUID().uuidString)
        let entry = root.appendingPathComponent("entry.safetensors")
        func save(_ prefixCount: Int) -> MLXPromptPrefixCache.PendingSave {
            MLXPromptPrefixCache.PendingSave(
                cache: [KVCacheSimple()], url: entry, prefixCount: prefixCount,
                directory: root, root: root
            )
        }

        #expect(!scope.hasPendingSaves)
        scope.deferSave(save(64))
        scope.deferSave(save(80))
        #expect(scope.hasPendingSaves)
        scope.hold([KVCacheSimple()], for: "key")
        #expect(scope.heldPrefix(for: "key") != nil)

        let saves = scope.takePendingSaves()
        #expect(saves.map(\.prefixCount) == [80])
        #expect(!scope.hasPendingSaves)

        scope.releaseHeldPrefixes()
        #expect(scope.heldPrefix(for: "key") == nil)
        #expect(scope.heldPrefixCount == 0)
    }
}
