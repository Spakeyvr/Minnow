//
//  MLXModelManager+Tuning
//  ChatLLM
//
//  Split out of MLXModelManager.swift as part of the Type+Concern organization.
//

import Foundation
import MLX
import MLXLMCommon
import MLXNN
import OSLog
import UIKit

extension MLXModelManager {
    // MARK: - Prefill Tuning

    nonisolated static let defaultPrefillStepSize = 512
    nonisolated private static let tuningStartupDelayNanoseconds: UInt64 = 1_000_000_000
    nonisolated private static let benchmarkPromptTokenCount = 2_048
    nonisolated private static let benchmarkDecodeTokenCount = 16

    nonisolated private static func prefillTuningUserDefaultsKey(
        for modelID: String,
        deviceSupportProfile: MLXDeviceSupportProfile
    ) -> String {
        let deviceClass = deviceSupportProfile.isPhone ? "phone" : "other"
        let bytesPerGiB: UInt64 = 1_073_741_824
        let memoryTier = Int(deviceSupportProfile.physicalMemoryBytes / bytesPerGiB)
        return "mlxPrefillStepSize.\(modelID).\(deviceClass).\(memoryTier)"
    }

    nonisolated static func persistedPrefillStepSize(
        for modelID: String,
        deviceSupportProfile: MLXDeviceSupportProfile,
        defaults: UserDefaults = .standard
    ) -> Int? {
        let key = prefillTuningUserDefaultsKey(for: modelID, deviceSupportProfile: deviceSupportProfile)
        guard defaults.object(forKey: key) != nil else { return nil }
        let storedValue = defaults.integer(forKey: key)
        guard [256, 512, 1024].contains(storedValue) else { return nil }
        return storedValue
    }

    nonisolated private static func storePersistedPrefillStepSize(
        _ prefillStepSize: Int,
        for modelID: String,
        deviceSupportProfile: MLXDeviceSupportProfile,
        defaults: UserDefaults = .standard
    ) {
        let key = prefillTuningUserDefaultsKey(for: modelID, deviceSupportProfile: deviceSupportProfile)
        defaults.set(prefillStepSize, forKey: key)
    }

    nonisolated static func recommendedWiredMemoryCapBytes(
        deviceSupportProfile: MLXDeviceSupportProfile
    ) -> Int? {
        GPU.maxRecommendedWorkingSetBytes() ?? Int(deviceSupportProfile.physicalMemoryBytes)
    }

    nonisolated internal struct TuningBenchmarkResult: Sendable {
        let candidate: Int
        let promptTokensPerSecond: Double
        let decodeTokensPerSecond: Double
        let totalLatency: TimeInterval
        /// KV cache after the benchmark prompt.
        let kvBytes: Int
        /// Peak active memory beyond weights and KV cache.
        let workspaceBytes: Int
        /// Weights, KV cache and workspace together.
        let totalBytes: Int
    }

    nonisolated internal static func selectFastestSafeCandidate(
        _ candidates: [TuningBenchmarkResult],
        wiredMemoryCap: Int?,
        preferLargerCandidateOnTie: Bool
    ) -> TuningBenchmarkResult {
        let safeCandidates = candidates.filter { candidate in
            guard let wiredMemoryCap else { return true }
            return candidate.totalBytes <= Int(Double(wiredMemoryCap) * 0.85)
        }
        let performanceCandidates = safeCandidates.isEmpty ? candidates : safeCandidates
        let bestDecodeSpeed = performanceCandidates.map(\.decodeTokensPerSecond).max() ?? 0
        let decodeFloor = bestDecodeSpeed > 0 ? bestDecodeSpeed * 0.95 : 0
        let decodeSafeCandidates = performanceCandidates.filter { candidate in
            bestDecodeSpeed == 0 || candidate.decodeTokensPerSecond >= decodeFloor
        }
        let rankedCandidates = decodeSafeCandidates.isEmpty ? performanceCandidates : decodeSafeCandidates

        return rankedCandidates.max { lhs, rhs in
            if lhs.promptTokensPerSecond != rhs.promptTokensPerSecond {
                return lhs.promptTokensPerSecond < rhs.promptTokensPerSecond
            }
            if lhs.totalLatency != rhs.totalLatency {
                return lhs.totalLatency > rhs.totalLatency
            }
            if lhs.decodeTokensPerSecond != rhs.decodeTokensPerSecond {
                return lhs.decodeTokensPerSecond < rhs.decodeTokensPerSecond
            }
            return preferLargerCandidateOnTie
                ? lhs.candidate < rhs.candidate
                : lhs.candidate > rhs.candidate
        } ?? candidates[0]
    }

    /// Repeats of a prompt unit needed for `targetTokenCount` tokens,
    /// estimated from one sample of `sampleRepeats` units that encoded to
    /// `sampleTokenCount` tokens.
    nonisolated static func benchmarkRepeatCount(
        targetTokenCount: Int,
        sampleRepeats: Int,
        sampleTokenCount: Int
    ) -> Int {
        let tokensPerRepeat = max(Double(sampleTokenCount) / Double(max(sampleRepeats, 1)), 0.01)
        return max(1, Int((Double(targetTokenCount) / tokensPerRepeat).rounded(.up)))
    }

    /// A synthetic prompt of at least `targetTokenCount` tokens. One sample
    /// encoding sizes it and one encoding verifies it, instead of
    /// re-tokenizing a growing string in fixed increments.
    private func makeBenchmarkPrompt(
        container: ModelContainer,
        targetTokenCount: Int = MLXModelManager.benchmarkPromptTokenCount
    ) async -> String {
        let unit = " hello"
        let sampleRepeats = 128
        let sampleTokenCount = await container.encode(String(repeating: unit, count: sampleRepeats)).count
        var repeats = Self.benchmarkRepeatCount(
            targetTokenCount: targetTokenCount,
            sampleRepeats: sampleRepeats,
            sampleTokenCount: sampleTokenCount
        )
        var prompt = String(repeating: unit, count: repeats)
        var tokenCount = await container.encode(prompt).count
        // Only an unusual tokenizer gets here: top up by the shortfall.
        while tokenCount < targetTokenCount {
            repeats += Self.benchmarkRepeatCount(
                targetTokenCount: targetTokenCount - tokenCount,
                sampleRepeats: sampleRepeats,
                sampleTokenCount: sampleTokenCount
            )
            prompt = String(repeating: unit, count: repeats)
            tokenCount = await container.encode(prompt).count
        }
        return prompt
    }

    /// Prefills the benchmark prompt once, decodes a few tokens, and reads
    /// speed and memory from that same pass. The previous separate memory
    /// pass prefilled the whole prompt a second time per candidate.
    nonisolated private static func measureTuningCandidate(
        container: ModelContainer,
        prompt: String,
        parameters: GenerateParameters,
        candidate: Int
    ) async throws -> TuningBenchmarkResult {
        try Task.checkCancellation()
        return try await container.perform { context in
            let input = try await context.processor.prepare(
                input: UserInput(chat: [.user(prompt)], processing: UserInput.Processing())
            )
            let promptTokenCount = input.text.tokens.size
            let weightBytes = context.model.parameters().flattened().reduce(0) { $0 + $1.1.nbytes }
            let startActive = Memory.activeMemory
            Memory.peakMemory = 0

            let cache = context.model.newCache(parameters: parameters)
            let startedAt = Date()
            // Prefill runs here; `prepare` checks for cancellation between chunks.
            var iterator = try TokenIterator(
                input: input, model: context.model, cache: cache, parameters: parameters
            )
            guard iterator.next() != nil else {
                throw GenerationError.invalidChatHistory
            }
            let firstTokenAt = Date()
            var decodedTokens = 0
            while iterator.next() != nil {
                try Task.checkCancellation()
                decodedTokens += 1
            }
            MLX.Stream().synchronize()
            let finishedAt = Date()

            let cacheArrays = cache.flatMap { layer in
                let arrays = layer.innerState()
                return arrays.isEmpty ? layer.state : arrays
            }
            eval(cacheArrays)
            let kvBytes = cacheArrays.reduce(0) { $0 + $1.nbytes }
            let peakActive = max(Memory.peakMemory, startActive)
            let workspaceBytes = max(0, peakActive - weightBytes - kvBytes)

            let promptTime = firstTokenAt.timeIntervalSince(startedAt)
            let decodeTime = finishedAt.timeIntervalSince(firstTokenAt)
            return TuningBenchmarkResult(
                candidate: candidate,
                promptTokensPerSecond: promptTime > 0 ? Double(promptTokenCount) / promptTime : 0,
                decodeTokensPerSecond: decodeTime > 0 ? Double(decodedTokens) / decodeTime : 0,
                totalLatency: finishedAt.timeIntervalSince(startedAt),
                kvBytes: kvBytes,
                workspaceBytes: workspaceBytes,
                totalBytes: max(0, weightBytes) + kvBytes + workspaceBytes
            )
        }
    }

    private func defaultGenerationConfigurationForCurrentDevice(
        model: MLXModelInfo? = nil
    ) -> GenerationConfiguration {
        Self.generationConfiguration(
            rotorQuantEnabled: isRotorQuantEnabled,
            hasTools: false,
            hasMedia: false,
            memoryConstrained: false,
            prefersBoundedCache: prefersBoundedKVCacheAcrossTurns,
            configuredMaxOutputTokens: defaults.mlxMaxOutputTokensLimit,
            configuredContextWindow: configuredContextWindowLimit(for: model),
            contextWindowLimitRaised: defaults.bool(forKey: AppSettingsKeys.overrideContextWindowLimit)
        )
    }

    /// Parameters a plain text turn uses on this device: sampling, cache
    /// layout and compression. Tuning and shader prewarm run with these so
    /// they measure and compile what real generation runs.
    func defaultGenerateParameters(
        for model: MLXModelInfo,
        maxTokens: Int,
        prefillStepSize: Int
    ) -> GenerateParameters {
        let configuration = defaultGenerationConfigurationForCurrentDevice(model: model)
        return Self.makeGenerateParameters(
            maxTokens: maxTokens,
            maxKVSize: configuration.maxKVSize,
            cacheCompression: configuration.cacheCompression,
            enableThinking: model.requiresReasoning,
            includesMedia: false,
            currentModelID: model.id,
            prefillStepSize: prefillStepSize,
            repetitionPenalty: defaults.mlxRepetitionPenaltyValue
        )
    }

    func schedulePrefillTuningIfNeeded(
        model: MLXModelInfo,
        initialPrefillStepSize: Int
    ) {
        guard tuningNeedsRetry(for: model) else {
            deferredTuningModelID = nil
            return
        }

        deferredTuningModelID = model.id
        logger.notice(
            "MLX tuning deferred until after first successful generation: id=\(model.id, privacy: .public) prefill=\(initialPrefillStepSize, privacy: .public)"
        )
    }

    func startDeferredTuningIfNeeded(
        container: ModelContainer,
        model: MLXModelInfo
    ) async {
        guard deferredTuningModelID == model.id else { return }
        guard currentModel?.id == model.id else { return }
        guard isApplicationActiveForGPUWork else {
            logger.notice(
                "MLX keeping deferred tuning paused until app is active: id=\(model.id, privacy: .public)"
            )
            return
        }
        guard !hasSeenMemoryWarningSinceCurrentLoad else {
            logger.notice(
                "MLX skipping deferred tuning after load-time memory pressure: id=\(model.id, privacy: .public)"
            )
            deferredTuningModelID = nil
            return
        }
        guard tuningTask == nil else { return }

        deferredTuningModelID = nil

        // Tuning only runs while no step size is persisted for this model and
        // device, so the candidates always span the whole range.
        let initialPrefillStepSize = await inferenceWorker.prefillStepSize(for: model.id)
        let prefillCandidates = Array(Set([256, initialPrefillStepSize, 1024])).sorted()
        let candidateParameters = prefillCandidates.map { candidate in
            (candidate, defaultGenerateParameters(
                for: model,
                maxTokens: Self.benchmarkDecodeTokenCount,
                prefillStepSize: candidate
            ))
        }
        let wiredMemoryCap = Self.recommendedWiredMemoryCapBytes(
            deviceSupportProfile: deviceSupportProfile
        )

        let taskID = UUID()
        tuningTaskID = taskID
        // Main-actor isolated like this method; only the benchmark passes
        // leave it, inside the model container.
        tuningTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                // A newer task may have replaced this one after a cancel.
                if self.tuningTaskID == taskID {
                    self.tuningTask = nil
                    self.tuningTaskID = nil
                }
            }

            try? await Task.sleep(nanoseconds: Self.tuningStartupDelayNanoseconds)
            guard !Task.isCancelled else { return }

            guard self.isApplicationActiveForGPUWork else {
                if self.tuningNeedsRetry(for: model) {
                    self.deferredTuningModelID = model.id
                }
                self.logger.notice(
                    "MLX deferred tuning skipped after app left foreground: id=\(model.id, privacy: .public)"
                )
                return
            }

            self.aggressivelyFreeMemory(reason: "tuning.start")

            let benchmarkPrompt = await self.makeBenchmarkPrompt(container: container)
            var prefillResults: [TuningBenchmarkResult] = []

            for (candidate, parameters) in candidateParameters {
                guard !Task.isCancelled else { return }
                do {
                    let result = try await Self.measureTuningCandidate(
                        container: container,
                        prompt: benchmarkPrompt,
                        parameters: parameters,
                        candidate: candidate
                    )
                    prefillResults.append(result)
                    self.aggressivelyFreeMemory(reason: "tuning.candidate.between")
                } catch is CancellationError {
                    self.aggressivelyFreeMemory(reason: "tuning.cancelled")
                    return
                } catch {
                    self.logger.error(
                        "MLX prefill tuning candidate failed: model=\(model.id, privacy: .public) prefill=\(candidate, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                    self.aggressivelyFreeMemory(reason: "tuning.prefill.failure")
                }
            }

            guard !Task.isCancelled else { return }
            guard !prefillResults.isEmpty else { return }

            let selectedPrefill = Self.selectFastestSafeCandidate(
                prefillResults,
                wiredMemoryCap: wiredMemoryCap,
                preferLargerCandidateOnTie: true
            )
            let activeBytesEstimate = selectedPrefill.kvBytes + selectedPrefill.workspaceBytes

            Self.storePersistedPrefillStepSize(
                selectedPrefill.candidate,
                for: model.id,
                deviceSupportProfile: self.deviceSupportProfile,
                defaults: self.defaults
            )
            await self.inferenceWorker.updateLoadedModelTuning(
                modelID: model.id,
                prefillStepSize: selectedPrefill.candidate,
                activeBytesEstimate: activeBytesEstimate
            )
            self.logger.notice(
                "MLX tuning selected: model=\(model.id, privacy: .public) prefill=\(selectedPrefill.candidate, privacy: .public) active_bytes=\(activeBytesEstimate, privacy: .public)"
            )
            self.aggressivelyFreeMemory(reason: "tuning.complete")
        }
    }

    /// Cancels the running tuning task and forgets it, so its deferred reset
    /// cannot clear a task started later.
    func cancelTuningTask() {
        tuningTask?.cancel()
        tuningTask = nil
        tuningTaskID = nil
    }

    private var isApplicationActiveForGPUWork: Bool {
        UIApplication.shared.applicationState == .active
    }

    private func tuningNeedsRetry(for model: MLXModelInfo) -> Bool {
        Self.persistedPrefillStepSize(
            for: model.id,
            deviceSupportProfile: deviceSupportProfile,
            defaults: defaults
        ) == nil
    }

    func handleApplicationInactivity(reason: String) {
        guard tuningTask != nil || deferredTuningModelID != nil else { return }

        if let model = currentModel, tuningNeedsRetry(for: model), !hasSeenMemoryWarningSinceCurrentLoad {
            deferredTuningModelID = model.id
        } else {
            deferredTuningModelID = nil
        }

        cancelTuningTask()
        logger.notice("MLX paused deferred tuning: reason=\(reason, privacy: .public)")
    }

    func cancelDeferredTuningBeforeGeneration(for model: MLXModelInfo) async {
        guard let activeTuningTask = tuningTask else { return }

        let activeTaskID = tuningTaskID
        activeTuningTask.cancel()
        // The benchmark checks for cancellation between prefill chunks and
        // decode steps, so this wait is short.
        await activeTuningTask.value
        if tuningTaskID == activeTaskID {
            tuningTask = nil
            tuningTaskID = nil
        }

        if currentModel?.id == model.id,
           tuningNeedsRetry(for: model),
           !hasSeenMemoryWarningSinceCurrentLoad {
            deferredTuningModelID = model.id
        }
        logger.notice(
            "MLX deferred tuning stopped before user generation: id=\(model.id, privacy: .public)"
        )
    }
}
