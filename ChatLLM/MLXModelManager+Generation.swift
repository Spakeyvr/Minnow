//
//  MLXModelManager+Generation
//  ChatLLM
//
//  Split out of MLXModelManager.swift as part of the Type+Concern organization.
//

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import OSLog

extension MLXModelManager {
    // MARK: - Generation

    /// 4-bit keys and values. With 3-bit keys or 2- or 3-bit values, LFM2.5
    /// looped instead of answering after a 10K-token prompt; 4/4 matched the
    /// uncompressed answer and still keeps the KV about 3.5x smaller.
    nonisolated private static let rotorQuantKeyBits = 4
    nonisolated private static let rotorQuantValueBits = 4
    nonisolated private static let rotorQuantSeed: UInt64 = 42
    nonisolated private static let rotorQuantExactBufferSize = 128
    nonisolated private static let rotorQuantAttentionBlockTokens = 128
    nonisolated private static let rotorQuantMediaExactBufferSize = 32
    nonisolated private static let rotorQuantMediaAttentionBlockTokens = 64
    /// Prompts longer than this compress their earlier prefill chunks, trading a
    /// little prompt fidelity for a bounded dense KV peak. Shorter prompts stay exact.
    nonisolated private static let rotorQuantPrefillExactLimit = 4096
    nonisolated private static let memoryConstrainedMaxKVSize = 4096
    /// Output cap for tool turns, which loop through several generations.
    nonisolated static let toolTurnMaxOutputTokens = 4096
    /// Safety cap when the user picked "Unlimited Output". Long enough for
    /// any real answer with reasoning, but it stops a model stuck in a loop
    /// before its KV cache grows until the app is terminated.
    nonisolated static let unlimitedOutputSafetyCapTokens = 8192
    /// Output cap after a memory warning.
    nonisolated static let memoryConstrainedMaxOutputTokens = 1024

    func tokenCountForLoadedModelText(
        role: Chat.Message.Role,
        content: String
    ) async -> Int? {
        guard let currentModel, let container else { return nil }
        let cacheKey = PromptTokenCountCacheKey(modelID: currentModel.id, role: role, content: content)
        if let cachedCount = promptTokenCountCache.value(for: cacheKey) {
            return cachedCount
        }
        let tokenCount = await container.encode(content).count
        promptTokenCountCache.insert(tokenCount, for: cacheKey)
        return tokenCount
    }

    /// Identifies message content by model, role and SHA-256 digest, so two
    /// different messages never share a count and the cache does not keep a
    /// second copy of the conversation text.
    nonisolated struct PromptTokenCountCacheKey: Hashable, Sendable {
        let modelID: String
        let digest: SHA256Digest

        init(modelID: String, role: Chat.Message.Role, content: String) {
            self.modelID = modelID
            var hasher = SHA256()
            hasher.update(data: Data(role.rawValue.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(content.utf8))
            self.digest = hasher.finalize()
        }
    }

    /// Least-recently-used token counts. Lookups and inserts are O(1);
    /// eviction drops the oldest quarter at once, so its sort is amortized
    /// over many inserts instead of shifting an array on every hit.
    nonisolated struct PromptTokenCountCache: Sendable {
        static let maximumEntries = 256

        private var entries: [PromptTokenCountCacheKey: (count: Int, lastUse: UInt64)] = [:]
        private var clock: UInt64 = 0

        var count: Int { entries.count }

        mutating func value(for key: PromptTokenCountCacheKey) -> Int? {
            guard let entry = entries[key] else { return nil }
            clock &+= 1
            entries[key] = (entry.count, clock)
            return entry.count
        }

        mutating func insert(_ count: Int, for key: PromptTokenCountCacheKey) {
            clock &+= 1
            entries[key] = (count, clock)
            guard entries.count > Self.maximumEntries else { return }
            let evictionCount = entries.count - Self.maximumEntries * 3 / 4
            let oldest = entries.sorted { $0.value.lastUse < $1.value.lastUse }.prefix(evictionCount)
            for (key, _) in oldest {
                entries.removeValue(forKey: key)
            }
        }

        mutating func removeAll() {
            entries.removeAll(keepingCapacity: false)
        }
    }

    struct MLXGenerationResult: Sendable {
        let toolInvocationCount: Int
        let metrics: GenerationMetrics
    }

    enum CacheCompressionMode: Equatable, Sendable {
        case none
        case rotorQuant(RotorQuantConfiguration)

        nonisolated var diagnosticLabel: String {
            switch self {
            case .none:
                return "none"
            case .rotorQuant(let configuration):
                return "rotorquant(\(configuration.variant.rawValue),k\(configuration.keyBits),v\(configuration.valueBits),exact\(configuration.exactBufferSize),block\(configuration.attentionBlockTokens))"
            }
        }

        nonisolated var generateParametersCompression: KVCacheCompressionMode? {
            switch self {
            case .none:
                return nil
            case .rotorQuant(let configuration):
                return .rotorQuant(configuration)
            }
        }
    }

    struct GenerationConfiguration: Equatable, Sendable {
        let maxTokens: Int?
        let cachePolicy: MLXCachePolicy
        let cacheCompression: CacheCompressionMode

        var maxKVSize: Int? {
            cachePolicy.maxKVSize
        }

    }
    /// Devices under 12 GB use a sliding window unless the Developer setting
    /// keeps the full (RotorQuant-eligible) cache.
    var prefersBoundedKVCacheAcrossTurns: Bool {
        deviceSupportProfile.hasLowMemoryForPersistentKVCache
            && !defaults.bool(forKey: AppSettingsKeys.forcePersistentKVCache)
    }

    func configuredContextWindowLimit(for model: MLXModelInfo? = nil) -> Int {
        defaults.mlxContextWindowTokens(
            deviceMaximum: deviceSupportProfile.maxContextWindowTokens(for: model ?? currentModel)
        )
    }

    var isRotorQuantEnabled: Bool {
        defaults.mlxEnableRotorQuant
    }

    /// Generation degrades to a bounded cache and a short output cap after
    /// iOS has warned about memory since the current model loaded.
    var isMemoryConstrainedForGeneration: Bool {
        hasSeenMemoryWarningSinceCurrentLoad
    }

    func generateTextStream(
        conversationID: UUID,
        messages: [Chat.Message],
        enableThinking: Bool,
        memoryConstrained: Bool = false,
        tools: [MLXToolSpec] = [],
        toolDispatch: (@Sendable (MLXToolCall) async throws -> String)? = nil,
        stableSystemPrompt: String? = nil,
        onToken: @escaping @Sendable (String) -> Void,
        onToolCall: @escaping @Sendable (MLXToolCall) -> Void = { _ in }
    ) async throws -> MLXGenerationResult {
        guard let container, let currentModel else {
            throw GenerationError.modelNotLoaded
        }
        let enableThinking = currentModel.requiresReasoning || enableThinking
        await cancelDeferredTuningBeforeGeneration(for: currentModel)
        guard self.container === container, self.currentModel?.id == currentModel.id else {
            throw GenerationError.modelNotLoaded
        }
        let memoryConstrained = memoryConstrained || isMemoryConstrainedForGeneration
        let includesMedia = messages.contains { !$0.images.isEmpty || !$0.videos.isEmpty }
        let configuredMaxOutputTokens = defaults.mlxMaxOutputTokensLimit
        let configuredContextWindow = configuredContextWindowLimit(for: currentModel)
        let generationConfiguration = Self.generationConfiguration(
            rotorQuantEnabled: isRotorQuantEnabled,
            hasTools: !tools.isEmpty,
            hasMedia: includesMedia,
            enableThinking: enableThinking,
            memoryConstrained: memoryConstrained,
            prefersBoundedCache: prefersBoundedKVCacheAcrossTurns,
            configuredMaxOutputTokens: configuredMaxOutputTokens,
            configuredContextWindow: configuredContextWindow,
            contextWindowLimitRaised: defaults.bool(forKey: AppSettingsKeys.overrideContextWindowLimit)
        )
        if deferredPrewarmModelID == currentModel.id && !memoryConstrained {
            await prewarmModelShaders(for: currentModel, reason: "first-generation")
        }
        logger.notice(
            "MLX generation start: model=\(currentModel.localDirName, privacy: .public) conversation=\(conversationID.uuidString, privacy: .public) messages=\(messages.count, privacy: .public) thinking=\(enableThinking, privacy: .public) memory_constrained=\(memoryConstrained, privacy: .public) tools=\(tools.count, privacy: .public) media=\(includesMedia, privacy: .public) cache_policy=\(generationConfiguration.cachePolicy.diagnosticLabel, privacy: .public) cache_compression=\(generationConfiguration.cacheCompression.diagnosticLabel, privacy: .public) max_kv=\(generationConfiguration.maxKVSize ?? -1, privacy: .public)"
        )
        MLXMemoryDiagnostics.log(logger, "generation.start")
        let toolCallFormat = await container.configuration.toolCallFormat
        let suppressWrappedXMLToolMarkup: Bool
        if !tools.isEmpty, toolCallFormat == .xmlFunction {
            suppressWrappedXMLToolMarkup = await usesWrappedXMLToolCalls(for: currentModel)
        } else {
            suppressWrappedXMLToolMarkup = false
        }
        if suppressWrappedXMLToolMarkup {
            logger.notice("MLX wrapped XML tool-call filter enabled: model=\(currentModel.localDirName, privacy: .public)")
        }

        // A prompt shorter than the tuned step is one chunk either way, so
        // the tuned step is used as is.
        let prefillStepSize = await inferenceWorker.prefillStepSize(for: currentModel.id)
        let params = Self.makeGenerateParameters(
            maxTokens: generationConfiguration.maxTokens,
            maxKVSize: generationConfiguration.maxKVSize,
            cacheCompression: generationConfiguration.cacheCompression,
            enableThinking: enableThinking,
            includesMedia: includesMedia,
            currentModelID: currentModel.id,
            prefillStepSize: prefillStepSize,
            repetitionPenalty: defaults.mlxRepetitionPenaltyValue
        )
        let additionalContext: [String: any Sendable]? = ["enable_thinking": enableThinking]
        let processing = UserInput.Processing()

        if !tools.isEmpty {
            try await validateToolTemplateSupport(for: currentModel)
        }

        let sessionKey = MLXSessionKey(
            conversationID: conversationID,
            modelID: currentModel.id,
            enableThinking: enableThinking,
            toolsEnabled: !tools.isEmpty,
            includesMedia: includesMedia,
            instructionFingerprint: messages.first(where: { $0.role == .system })?.content.hashValue ?? 0
        )
        let request = MLXInferenceRequest(
            conversationID: conversationID,
            sessionKey: sessionKey,
            model: currentModel,
            messages: messages,
            additionalContext: additionalContext,
            processing: processing,
            tools: tools,
            params: params,
            suppressWrappedXMLToolMarkup: suppressWrappedXMLToolMarkup,
            stableSystemPrompt: stableSystemPrompt,
            sessionTokenLimit: configuredContextWindow
        )

        prepareMemoryForGeneration()
        do {
            let response = try await inferenceWorker.generate(
                request: request,
                toolDispatch: toolDispatch,
                onToken: onToken,
                onToolCall: onToolCall
            )
            cleanupMemoryAfterGeneration()
            // A stopped response returns normally; tuning right after it
            // would compete with the message the user is about to send.
            if !memoryConstrained, !Task.isCancelled {
                await startDeferredTuningIfNeeded(container: container, model: currentModel)
            }
            return MLXGenerationResult(
                toolInvocationCount: response.toolInvocationCount,
                metrics: response.metrics
            )
        } catch is CancellationError {
            // A user Stop or a superseded turn; not a failure.
            logger.notice("MLX generation cancelled")
            cleanupMemoryAfterGenerationError()
            throw CancellationError()
        } catch {
            logger.error("MLX generation failed: \(error.localizedDescription, privacy: .public)")
            cleanupMemoryAfterGenerationError()
            throw error
        }
    }

    // MARK: - Errors

    enum GenerationError: LocalizedError {
        case modelNotLoaded
        case invalidChatHistory
        case missingToolDispatch
        case unsupportedToolTemplate(String)

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return String(localized: "No MLX model is loaded. Select the MLX backend and wait for the model to finish loading.", bundle: .appLocalized)
            case .invalidChatHistory:
                return String(localized: "The MLX chat history is empty, so generation cannot start.", bundle: .appLocalized)
            case .missingToolDispatch:
                return String(localized: "The model emitted a tool call, but no MLX tool dispatcher was configured.", bundle: .appLocalized)
            case .unsupportedToolTemplate(let message):
                return message
            }
        }
    }
    /// - Parameter configuredMaxOutputTokens: the user's output limit, or nil
    ///   for "Unlimited Output". Every turn is still capped: tool turns at
    ///   `toolTurnMaxOutputTokens` (each tool-loop step is one generation),
    ///   other memory-constrained turns at `memoryConstrainedMaxOutputTokens`, and
    ///   all others at `unlimitedOutputSafetyCapTokens`.
    /// - Parameter enableThinking: thinking turns skip the memory-constrained
    ///   cap, which reasoning alone can use up and leave no answer; the bounded
    ///   KV cache already holds their memory down.
    nonisolated internal static func generationConfiguration(
        rotorQuantEnabled: Bool,
        hasTools: Bool,
        hasMedia: Bool,
        enableThinking: Bool = false,
        memoryConstrained: Bool,
        prefersBoundedCache: Bool,
        configuredMaxOutputTokens: Int?,
        configuredContextWindow: Int,
        contextWindowLimitRaised: Bool = false
    ) -> GenerationConfiguration {
        var maxTokens = configuredMaxOutputTokens ?? unlimitedOutputSafetyCapTokens
        if hasTools {
            maxTokens = min(maxTokens, toolTurnMaxOutputTokens)
        } else if memoryConstrained && !enableThinking {
            maxTokens = min(maxTokens, memoryConstrainedMaxOutputTokens)
        }
        let cachePolicy = cachePolicy(
            isEnabled: rotorQuantEnabled,
            hasTools: hasTools,
            prefersBoundedCache: prefersBoundedCache,
            memoryConstrained: memoryConstrained
        )
        let clampedCachePolicy = clampedCachePolicy(
            cachePolicy,
            configuredContextWindow: configuredContextWindow,
            contextWindowLimitRaised: contextWindowLimitRaised
        )
        return GenerationConfiguration(
            maxTokens: maxTokens,
            cachePolicy: clampedCachePolicy,
            cacheCompression: cacheCompressionMode(
                cachePolicy: clampedCachePolicy,
                hasMedia: hasMedia
            )
        )
    }

    nonisolated internal static func cachePolicy(
        isEnabled: Bool,
        hasTools: Bool,
        prefersBoundedCache: Bool,
        memoryConstrained: Bool
    ) -> MLXCachePolicy {
        if memoryConstrained || prefersBoundedCache {
            return .boundedRotating(maxKVSize: memoryConstrainedMaxKVSize)
        }
        guard !hasTools else {
            return .persistentSimple
        }

        return isEnabled ? .persistentRotorQuant : .persistentSimple
    }

    nonisolated internal static func cachePolicy(for parameters: GenerateParameters) -> MLXCachePolicy {
        if let maxKVSize = parameters.maxKVSize {
            return .boundedRotating(maxKVSize: maxKVSize)
        }
        if parameters.resolvedCacheCompression != nil {
            return .persistentRotorQuant
        }
        return .persistentSimple
    }

    /// The sliding window never outgrows the context window. While the
    /// Developer override raises the context limit it matches the window, so
    /// a prompt budgeted past 4,096 tokens is not evicted during prefill.
    nonisolated private static func clampedCachePolicy(
        _ cachePolicy: MLXCachePolicy,
        configuredContextWindow: Int,
        contextWindowLimitRaised: Bool
    ) -> MLXCachePolicy {
        switch cachePolicy {
        case .boundedRotating(let maxKVSize):
            return .boundedRotating(maxKVSize: contextWindowLimitRaised
                ? configuredContextWindow
                : min(maxKVSize, configuredContextWindow))
        case .persistentSimple, .persistentRotorQuant:
            return cachePolicy
        }
    }

    /// The cache policy already reflects whether RotorQuant is enabled; it is
    /// `.persistentRotorQuant` only then.
    nonisolated internal static func cacheCompressionMode(
        cachePolicy: MLXCachePolicy,
        hasMedia: Bool = false
    ) -> CacheCompressionMode {
        guard cachePolicy.usesRotorQuantCompression else {
            return .none
        }

        let exactBufferSize = hasMedia ? rotorQuantMediaExactBufferSize : rotorQuantExactBufferSize
        let attentionBlockTokens =
            hasMedia ? rotorQuantMediaAttentionBlockTokens : rotorQuantAttentionBlockTokens
        return .rotorQuant(
            RotorQuantConfiguration(
                keyBits: rotorQuantKeyBits,
                valueBits: rotorQuantValueBits,
                seed: rotorQuantSeed,
                exactBufferSize: exactBufferSize,
                attentionBlockTokens: attentionBlockTokens,
                variant: .iso,
                prefillExactLimit: rotorQuantPrefillExactLimit
            )
        )
    }

    nonisolated internal static func makeGenerateParameters(
        maxTokens: Int?,
        maxKVSize: Int?,
        cacheCompression: CacheCompressionMode,
        enableThinking: Bool,
        includesMedia: Bool,
        currentModelID: String,
        prefillStepSize: Int,
        repetitionPenalty: Float?
    ) -> GenerateParameters {
        let family = MLXModelInfo.Family(modelID: currentModelID)
        let isQwen35Model = family == .qwen35

        // LiquidAI's generation_config.json: temperature 0.1, top-k 50, repetition 1.1.
        if family == .lfm25 {
            return GenerateParameters(
                maxTokens: maxTokens,
                maxKVSize: maxKVSize,
                cacheCompression: cacheCompression.generateParametersCompression,
                temperature: 0.1,
                topP: 1.0,
                topK: 50,
                repetitionPenalty: repetitionPenalty ?? 1.1,
                prefillStepSize: prefillStepSize
            )
        }

        if enableThinking && isQwen35Model {
            let qwen35ThinkingTemperature: Float = includesMedia ? 0.6 : 1.0
            let qwen35ThinkingPresencePenalty: Float = includesMedia ? 0.0 : 1.5
            return GenerateParameters(
                maxTokens: maxTokens,
                maxKVSize: maxKVSize,
                cacheCompression: cacheCompression.generateParametersCompression,
                temperature: qwen35ThinkingTemperature,
                topP: 0.95,
                topK: 20,
                minP: 0.0,
                presencePenalty: qwen35ThinkingPresencePenalty,
                repetitionPenalty: 1.0,
                prefillStepSize: prefillStepSize
            )
        } else if enableThinking {
            return GenerateParameters(
                maxTokens: maxTokens,
                maxKVSize: maxKVSize,
                cacheCompression: cacheCompression.generateParametersCompression,
                temperature: 0.6,
                topP: 0.95,
                topK: nil,
                minP: 0.0,
                presencePenalty: nil,
                repetitionPenalty: repetitionPenalty,
                prefillStepSize: prefillStepSize
            )
        } else if isQwen35Model {
            let qwen35NonThinkingTemperature: Float = includesMedia ? 0.7 : 1.0
            let qwen35NonThinkingTopP: Float = includesMedia ? 0.8 : 1.0
            let qwen35NonThinkingPresencePenalty: Float = includesMedia ? 1.5 : 2.0
            return GenerateParameters(
                maxTokens: maxTokens,
                maxKVSize: maxKVSize,
                cacheCompression: cacheCompression.generateParametersCompression,
                temperature: qwen35NonThinkingTemperature,
                topP: qwen35NonThinkingTopP,
                topK: 20,
                minP: 0.0,
                presencePenalty: qwen35NonThinkingPresencePenalty,
                repetitionPenalty: 1.0,
                prefillStepSize: prefillStepSize
            )
        } else {
            return GenerateParameters(
                maxTokens: maxTokens,
                maxKVSize: maxKVSize,
                cacheCompression: cacheCompression.generateParametersCompression,
                temperature: 0.7,
                topP: 0.8,
                topK: nil,
                minP: 0.0,
                presencePenalty: nil,
                repetitionPenalty: repetitionPenalty,
                prefillStepSize: prefillStepSize
            )
        }
    }
}
