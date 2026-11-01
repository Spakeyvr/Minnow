//
//  ChatLLMTests+ModelManagerRuntime.swift
//  ChatLLMTests
//
//  Model-manager runtime behavior: output caps, memory signals, caches,
//  tool-template inspection, prompt-prefix storage and backend-bridge
//  observation. Part of the single @Suite(.serialized) ChatLLMTests suite.
//

import Combine
import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import ChatLLM

extension ChatLLMTests {
    // MARK: - Output Caps

    @Test func unlimitedOutputStillCapsEveryTurn() {
        func maxTokens(configured: Int?, tools: Bool, memoryConstrained: Bool) -> Int? {
            MLXModelManager.generationConfiguration(
                rotorQuantEnabled: false,
                hasTools: tools,
                hasMedia: false,
                memoryConstrained: memoryConstrained,
                prefersBoundedCache: false,
                configuredMaxOutputTokens: configured,
                configuredContextWindow: 32_768
            ).maxTokens
        }

        #expect(maxTokens(configured: nil, tools: false, memoryConstrained: false)
            == MLXModelManager.unlimitedOutputSafetyCapTokens)
        #expect(maxTokens(configured: nil, tools: true, memoryConstrained: false)
            == MLXModelManager.toolTurnMaxOutputTokens)
        #expect(maxTokens(configured: nil, tools: false, memoryConstrained: true)
            == MLXModelManager.memoryConstrainedMaxOutputTokens)
        #expect(maxTokens(configured: 512, tools: false, memoryConstrained: false) == 512)
        #expect(maxTokens(configured: 2_048, tools: false, memoryConstrained: true) == 1_024)
        // Tool-loop steps keep the tool cap when memory is constrained.
        #expect(maxTokens(configured: nil, tools: true, memoryConstrained: true)
            == MLXModelManager.toolTurnMaxOutputTokens)
    }

    @Test func memoryWarningMakesLaterGenerationsMemoryConstrainedUntilTheNextLoad() {
        let manager = makeModelManager()
        #expect(!manager.isMemoryConstrainedForGeneration)

        manager.handleMemoryWarning()
        #expect(manager.isMemoryConstrainedForGeneration)

        manager.tearDownCurrentModel(reason: "test")
        #expect(!manager.isMemoryConstrainedForGeneration)
    }

    @Test func generationBufferCacheIsBoundedByRemainingMemory() {
        let mebibyte = 1024 * 1024
        // No jetsam limit reported (Simulator): the fixed upper bound.
        #expect(MLXModelManager.generationMemoryCacheLimitBytes(availableMemoryBytes: 0) == 256 * mebibyte)
        #expect(MLXModelManager.generationMemoryCacheLimitBytes(availableMemoryBytes: 4096 * mebibyte) == 256 * mebibyte)
        #expect(MLXModelManager.generationMemoryCacheLimitBytes(availableMemoryBytes: 1024 * mebibyte) == 128 * mebibyte)
        #expect(MLXModelManager.generationMemoryCacheLimitBytes(availableMemoryBytes: 4 * mebibyte) == mebibyte)
    }

    // MARK: - Device Profile

    @Test func deviceProfileReadsRAMPrecautionsFromInjectedDefaults() {
        let defaults = testEnvironment.defaults
        defaults.set(false, forKey: AppSettingsKeys.disableRAMPrecautions)
        let profile = MLXDeviceSupportProfile(
            isPhone: true,
            physicalMemoryBytes: 4 * MLXDeviceSupportProfile.gibibyte,
            ramPrecautionsDisabledOverride: nil,
            defaults: defaults
        )
        #expect(!profile.ramPrecautionsDisabled)

        defaults.set(true, forKey: AppSettingsKeys.disableRAMPrecautions)
        #expect(profile.ramPrecautionsDisabled)

        let manager = MLXModelManager(
            defaults: defaults,
            documentsDirectory: testEnvironment.directory.appendingPathComponent(UUID().uuidString),
            restoresBackgroundDownloads: false
        )
        #expect(manager.deviceSupportProfile.defaults === defaults)
        #expect(manager.deviceSupportProfile.ramPrecautionsDisabled)
    }

    /// UserDefaults posts its change notification on the thread that wrote the
    /// value. The manager's observer must not assume the main actor, or the
    /// Swift 6 runtime isolation check traps on a background write.
    @Test func modelManagerFollowsRAMPrecautionsWrittenOffTheMainActor() async {
        let manager = makeModelManager(deviceSupportProfile: MLXDeviceSupportProfile(
            isPhone: true,
            physicalMemoryBytes: 8 * MLXDeviceSupportProfile.gibibyte,
            ramPrecautionsDisabledOverride: nil,
            defaults: testEnvironment.defaults
        ))
        #expect(!manager.deviceSupportProfile.ramPrecautionsDisabled)

        await Self.writeRAMPrecautionsDisabled(true, suiteName: testEnvironment.suiteName)

        #expect(manager.deviceSupportProfile.ramPrecautionsDisabled)
    }

    @concurrent
    private nonisolated static func writeRAMPrecautionsDisabled(_ value: Bool, suiteName: String) async {
        UserDefaults(suiteName: suiteName)?.set(value, forKey: AppSettingsKeys.disableRAMPrecautions)
    }

    @Test func contextWindowCeilingIncludesPerModelOverrides() {
        let eightGigabyteProfile = makeDeviceProfile(
            isPhone: true,
            physicalMemoryBytes: 8 * MLXDeviceSupportProfile.gibibyte
        )
        // Qwen 3.5 0.8B gets 4,096 tokens on 8 GB phones; the device default is 2,048.
        #expect(eightGigabyteProfile.maxContextWindowTokens == 2_048)
        #expect(eightGigabyteProfile.maxContextWindowTokensForAnyModel == 4_096)
    }

    // MARK: - Model Families

    @Test func modelFamilyDrivesSamplingAndToolLoopStyle() throws {
        let catalog = MLXModelManager.modelDefinitions
        let lfm = try #require(catalog.first { $0.id == "lfm2.5-2.6b-4bit" })
        let qwen = try #require(catalog.first { $0.id == "qwen3.5-2b-4bit" })
        #expect(lfm.family == .lfm25)
        #expect(lfm.requiresReasoning)
        #expect(qwen.family == .qwen35)
        #expect(!qwen.requiresReasoning)
        #expect(MLXModelManager.prefersUserWrappedToolResponses(for: qwen))
        #expect(MLXModelManager.usesLFMToolTurns(for: lfm))
        #expect(MLXModelManager.MLXModelInfo.Family(modelID: "smollm3-3b-4bit") == .other)

        let parameters = MLXModelManager.makeGenerateParameters(
            maxTokens: 64, maxKVSize: nil, cacheCompression: .none,
            enableThinking: false, includesMedia: false,
            currentModelID: qwen.id, prefillStepSize: 256, repetitionPenalty: nil
        )
        #expect(parameters.presencePenalty == 2.0)
        #expect(parameters.topK == 20)
    }

    @Test func storedLFMSelectionRequiresReasoningWithoutACatalogMatch() {
        let bridge = makeBackendBridge()
        bridge.selectedBackend = .mlx
        bridge.selectedModelID = "lfm2.5-unreleased"
        #expect(bridge.reasoningRequired)
        #expect(bridge.reasoningAvailable)
        bridge.selectedModelID = "unknown-model"
        #expect(!bridge.reasoningRequired)
        #expect(!bridge.reasoningAvailable)
    }

    // MARK: - Prompt Token Counts

    @Test func promptTokenCountCacheKeepsRecentlyUsedEntriesWithinItsLimit() {
        typealias Key = MLXModelManager.PromptTokenCountCacheKey
        var cache = MLXModelManager.PromptTokenCountCache()
        let limit = MLXModelManager.PromptTokenCountCache.maximumEntries
        let pinned = Key(modelID: "m", role: .user, content: "pinned")
        cache.insert(7, for: pinned)
        for index in 0 ..< limit * 2 {
            cache.insert(index, for: Key(modelID: "m", role: .user, content: "message \(index)"))
            _ = cache.value(for: pinned)
        }

        #expect(cache.count <= limit)
        #expect(cache.value(for: pinned) == 7)
        #expect(cache.value(for: Key(modelID: "m", role: .user, content: "message 0")) == nil)
        #expect(Key(modelID: "m", role: .user, content: "Hi") != Key(modelID: "m", role: .assistant, content: "Hi"))
        #expect(Key(modelID: "m", role: .user, content: "Hi") == Key(modelID: "m", role: .user, content: "Hi"))
    }

    // MARK: - Tool Templates

    @Test func toolTemplateInspectionIgnoresTheTokenizerVocabulary() throws {
        let directory = testEnvironment.directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The vocabulary mentions tools and tool calls, as real ones do.
        try Data(#"{"model":{"vocab":{"tools":1,"\"tool\"":2,"<tool_call>":3}}}"#.utf8)
            .write(to: directory.appendingPathComponent("tokenizer.json"))
        try Data(#"{"chat_template":"{% for message in messages %}{{ message.content }}{% endfor %}"}"#.utf8)
            .write(to: directory.appendingPathComponent("tokenizer_config.json"))

        let plainTemplate = MLXModelManager.chatTemplateText(inModelDirectory: directory)
        #expect(!plainTemplate.contains("tool_call"))
        let plain = MLXModelManager.inspectToolTemplate(
            chatTemplate: plainTemplate, modelType: "qwen3_5", localDirName: "Plain"
        )
        #expect(plain.support != .supported)

        try Data("""
        {%- if tools %}{{ tools }}{%- endif %}{%- if message.role == 'tool' %}<tool_call>
        <function=webSearch>
        <parameter=query>
        {%- endif %}
        """.utf8).write(to: directory.appendingPathComponent("chat_template.jinja"))
        let toolTemplate = MLXModelManager.chatTemplateText(inModelDirectory: directory)
        let tooled = MLXModelManager.inspectToolTemplate(
            chatTemplate: toolTemplate, modelType: "qwen3_5", localDirName: "Tooled"
        )
        #expect(tooled.support == .supported)
        #expect(tooled.preferredToolCallFormat == .xmlFunction)
        #expect(tooled.usesWrappedXMLToolCalls)
    }

    @Test func chatTemplateTextReadsNamedTemplateLists() throws {
        let directory = testEnvironment.directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"chat_template":[{"name":"default","template":"A"},{"name":"tool_use","template":"<|tool_call_start|>"}]}"#.utf8)
            .write(to: directory.appendingPathComponent("tokenizer_config.json"))

        let template = MLXModelManager.chatTemplateText(inModelDirectory: directory)
        #expect(template.contains("A"))
        #expect(template.contains("<|tool_call_start|>"))
    }

    // MARK: - Prompt Prefix Cache

    @Test func promptPrefixFromProbeCommonPrefixMatchesPerProbeMatching() {
        let shared = (0 ..< Int32(MLXPromptPrefixCache.minimumPrefixTokens)).map { $0 + 1_000 }
        let probes = [shared + [7, 1], shared + [2, 1]]
        let stable = MLXPromptPrefixCache.commonPrefix(of: probes)
        #expect(stable == shared)
        for full in [shared + [7, 8, 9], shared + [2, 1, 4], Array(shared.prefix(10)) + [5], shared] {
            #expect(MLXPromptPrefixCache.prefixTokenCount(full: full, stablePrefix: stable)
                == MLXPromptPrefixCache.prefixTokenCount(full: full, probes: probes))
        }
    }

    @Test func promptPrefixKeyChangesWithWeightsAndEveryCompressionField() {
        let tokens: [Int32] = [1, 2, 3]
        let base = MLXPromptPrefixCache.entryKey(
            modelID: "qwen", weightsFingerprint: "a", prefixTokens: tokens[...],
            parameters: GenerateParameters())
        #expect(base != MLXPromptPrefixCache.entryKey(
            modelID: "qwen", weightsFingerprint: "b", prefixTokens: tokens[...],
            parameters: GenerateParameters()))

        let configuration = RotorQuantConfiguration()
        var changedSeed = configuration
        changedSeed.seed += 1
        #expect(MLXPromptPrefixCache.cacheLayoutDescription(.rotorQuant(configuration))
            != MLXPromptPrefixCache.cacheLayoutDescription(.rotorQuant(changedSeed)))
        #expect(MLXPromptPrefixCache.cacheLayoutDescription(nil) == "none")
    }

    @Test func weightsFingerprintChangesWhenWeightFilesChange() throws {
        let directory = testEnvironment.directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data(count: 16).write(to: directory.appendingPathComponent("model.safetensors"))
        let original = MLXPromptPrefixCache.weightsFingerprint(forModelDirectory: directory)
        #expect(original == MLXPromptPrefixCache.weightsFingerprint(forModelDirectory: directory))

        try Data(count: 32).write(to: directory.appendingPathComponent("model.safetensors"))
        #expect(original != MLXPromptPrefixCache.weightsFingerprint(forModelDirectory: directory))
    }

    @Test func promptPrefixEvictionDropsPartialAndLegacyFilesAndKeepsNewestEntries() throws {
        let fileManager = FileManager.default
        let root = testEnvironment.directory.appendingPathComponent(UUID().uuidString)
        let cache = MLXPromptPrefixCache(directory: root, subsystem: "ChatLLMTests")
        let modelFolder = cache.modelDirectory(forModelID: "qwen3.5-2b-4bit")
        try fileManager.createDirectory(at: modelFolder, withIntermediateDirectories: true)

        let legacy = root.appendingPathComponent("legacy.safetensors")
        try Data(count: 4).write(to: legacy)
        let partial = modelFolder.appendingPathComponent("\(UUID().uuidString).partial.safetensors")
        try Data(count: 4).write(to: partial)
        var entries: [URL] = []
        for index in 0 ..< MLXPromptPrefixCache.maximumEntries + 2 {
            let entry = modelFolder.appendingPathComponent("entry\(index).safetensors")
            try Data(count: 4).write(to: entry)
            try fileManager.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: Double(index - 100))],
                ofItemAtPath: entry.path
            )
            entries.append(entry)
        }

        MLXPromptPrefixCache.evictOldEntries(in: root)

        #expect(!fileManager.fileExists(atPath: legacy.path))
        #expect(!fileManager.fileExists(atPath: partial.path))
        #expect(!fileManager.fileExists(atPath: entries[0].path))
        #expect(!fileManager.fileExists(atPath: entries[1].path))
        #expect(entries.dropFirst(2).allSatisfy { fileManager.fileExists(atPath: $0.path) })

        cache.removeEntries(forModelID: "qwen3.5-2b-4bit")
        #expect(!fileManager.fileExists(atPath: modelFolder.path))
    }

    // MARK: - Presence Penalty

    @Test func presencePenaltyAppliesOncePerSeenToken() {
        Device.withDefaultDevice(.cpu) {
            var context = PresenceContext(presencePenalty: 1.5)
            context.prompt(MLXArray([Int32(1), 3, 3]))
            let logits = MLXArray.zeros([1, 6], dtype: .float32)
            #expect(context.process(logits: logits).asArray(Float.self) == [0, -1.5, 0, -1.5, 0, 0])

            context.didSample(token: MLXArray([Int32(4)]))
            context.didSample(token: MLXArray([Int32(4)]))
            #expect(context.process(logits: logits).asArray(Float.self) == [0, -1.5, 0, -1.5, -1.5, 0])
        }
    }

    // MARK: - Tuning

    @Test func benchmarkPromptIsSizedFromOneSampleEncoding() {
        #expect(MLXModelManager.benchmarkRepeatCount(
            targetTokenCount: 2_048, sampleRepeats: 128, sampleTokenCount: 128) == 2_048)
        #expect(MLXModelManager.benchmarkRepeatCount(
            targetTokenCount: 2_048, sampleRepeats: 128, sampleTokenCount: 256) == 1_024)
        #expect(MLXModelManager.benchmarkRepeatCount(
            targetTokenCount: 10, sampleRepeats: 128, sampleTokenCount: 0) >= 10)
    }

    // MARK: - Files

    @Test func deletingAModelMakesItUnavailableAtOnceAndRemovesItsFiles() async throws {
        let manager = makeModelManager(deviceSupportProfile: makeDeviceProfile(isPhone: false))
        let model = try #require(manager.availableModels.first { $0.id == "lfm2.5-2.6b-4bit" })
        let directory = manager.packageDirectoryURL(for: model)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data(count: 4).write(to: directory.appendingPathComponent("model.safetensors"))
        await manager.refreshModelAvailabilityInBackground(changedModelID: model.id)
        #expect(manager.model(withID: model.id)?.isAvailable == true)

        try manager.deleteModel(model)
        #expect(manager.model(withID: model.id)?.isAvailable == false)
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        let modelsDirectory = directory.deletingLastPathComponent()
        var leftovers: [String] = []
        for _ in 0 ..< 50 {
            leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: modelsDirectory.path)) ?? [])
                .filter { $0.hasSuffix(MLXModelManager.pendingDeletionSuffix) }
            if leftovers.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(leftovers.isEmpty)
    }

    // MARK: - Backend Bridge Observation

    @Test func bridgeLeavesDownloadProgressToManagerObserversAndForwardsLoadStateWithoutAQueueHop() throws {
        let bridge = makeBackendBridge()
        let manager = try #require(bridge.modelManager)
        var bridgeChanges = 0
        var managerChanges = 0
        let bridgeSubscription = bridge.objectWillChange.sink { bridgeChanges += 1 }
        let managerSubscription = manager.objectWillChange.sink { managerChanges += 1 }
        defer {
            bridgeSubscription.cancel()
            managerSubscription.cancel()
        }

        // The manager publishes progress in whole-percent steps.
        manager.publishDownloadProgress(0.001)
        manager.publishDownloadProgress(0.004)
        #expect(managerChanges == 0)

        manager.publishDownloadProgress(0.011)
        #expect(managerChanges == 1)
        // Views that show progress observe the manager; the bridge stays quiet.
        #expect(bridgeChanges == 0)

        manager.isLoading = true
        #expect(bridgeChanges == 1)
    }

    @Test func reassigningTheBridgeManagerObservesTheNewManager() throws {
        let bridge = makeBackendBridge()
        let original = try #require(bridge.modelManager)
        let replacement = makeModelManager()
        bridge.modelManager = replacement
        #expect(bridge.modelManager === replacement)

        var changes = 0
        let subscription = bridge.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        original.isLoading = true
        #expect(changes == 0)
        replacement.isLoading = true
        #expect(changes == 1)

        bridge.modelManager = nil
        #expect(bridge.modelManager === replacement)
    }
}
