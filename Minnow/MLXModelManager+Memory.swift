//
//  MLXModelManager+Memory
//  Minnow
//
//  Split out of MLXModelManager.swift as part of the Type+Concern organization.
//

import Foundation
import MLX
import OSLog
import os

extension MLXModelManager {
    // MARK: - Memory Pressure

    /// Between generations freed Metal buffers go straight back to the
    /// system, keeping the app's footprint at weights plus live caches.
    nonisolated private static let aggressiveMemoryCacheLimitBytes = 1 * 1024 * 1024
    /// Upper bound for the buffer cache while a response is generated.
    nonisolated private static let maximumGenerationMemoryCacheLimitBytes = 256 * 1024 * 1024

    /// Lets the allocator reuse prefill activations and vocabulary-sized
    /// sampler intermediates from one step to the next instead of freeing
    /// and reallocating them every token. Bounded by a fraction of the
    /// remaining jetsam headroom, so it never eats into what the KV cache
    /// still needs. `os_proc_available_memory` is 0 where the process has no
    /// limit (Simulator), and then the fixed bound applies.
    nonisolated static func generationMemoryCacheLimitBytes(availableMemoryBytes: Int) -> Int {
        guard availableMemoryBytes > 0 else { return maximumGenerationMemoryCacheLimitBytes }
        return max(
            aggressiveMemoryCacheLimitBytes,
            min(maximumGenerationMemoryCacheLimitBytes, availableMemoryBytes / 8)
        )
    }

    func handleMemoryWarning() {
        logger.notice("MLX received memory warning; clearing caches and invalidating sessions")
        hasSeenMemoryWarningSinceCurrentLoad = true
        deferredTuningModelID = nil
        cancelTuningTask()
        Task {
            await inferenceWorker.invalidateAll(reason: "memory_warning")
        }
        aggressivelyFreeMemory(reason: "memory.warning")
    }

    func applySteadyStateMemoryCachePolicy() {
        Memory.cacheLimit = Self.aggressiveMemoryCacheLimitBytes
    }

    func prepareMemoryForPrewarm() {
        aggressivelyFreeMemory(reason: "prewarm.prepare")
    }

    func cleanupMemoryAfterPrewarm() {
        applySteadyStateMemoryCachePolicy()
    }

    func prepareMemoryForGeneration() {
        Memory.cacheLimit = Self.generationMemoryCacheLimitBytes(
            availableMemoryBytes: Int(os_proc_available_memory())
        )
    }

    /// Returns the buffers kept for reuse during generation and goes back to
    /// the steady-state limit.
    func cleanupMemoryAfterGeneration() {
        Memory.clearCache()
        applySteadyStateMemoryCachePolicy()
    }

    func cleanupMemoryAfterGenerationError() {
        aggressivelyFreeMemory(reason: "generation.error")
    }

    func cleanupMemoryAfterLoadInterruption() {
        aggressivelyFreeMemory(reason: "load.interrupted")
    }

    func prepareMemoryForModelLoadTransition() {
        aggressivelyFreeMemory(reason: "model.load.transition")
    }

    func tearDownCurrentModel(
        reason: String,
        clearInferenceWorker: Bool = true
    ) {
        if container != nil || currentModel != nil || deferredPrewarmModelID != nil || deferredTuningModelID != nil || prewarmInFlightModelID != nil {
            logger.notice("MLX model teardown: reason=\(reason, privacy: .public)")
        }
        container = nil
        currentModel = nil
        let workerLoadID = installedWorkerLoadID
        installedWorkerLoadID = nil
        promptTokenCountCache.removeAll()
        deferredPrewarmModelID = nil
        deferredTuningModelID = nil
        prewarmInFlightModelID = nil
        // The prewarm holds its own reference to the container; cancelling it
        // lets the old weights go before the next model loads.
        prewarmTask?.cancel()
        prewarmTask = nil
        cancelTuningTask()
        hasSeenMemoryWarningSinceCurrentLoad = false
        if clearInferenceWorker, let workerLoadID {
            Task {
                _ = await inferenceWorker.clearLoadedModel(ifLoadID: workerLoadID)
            }
        }
        cleanupMemoryAfterUnload()
    }

    func cleanupMemoryAfterUnload() {
        aggressivelyFreeMemory(reason: "model.unload")
    }

    /// Frees MLX's buffer cache only. The process-wide `URLCache` is left
    /// alone: it is unrelated to MLX memory and trims its own memory part
    /// under pressure.
    func aggressivelyFreeMemory(reason: String) {
        logger.notice("MLX memory cleanup: reason=\(reason, privacy: .public)")
        Memory.clearCache()
        Memory.cacheLimit = Self.aggressiveMemoryCacheLimitBytes
    }
}
