//
//  MLXModelManager+Loading
//  Minnow
//
//  Split out of MLXModelManager.swift as part of the Type+Concern organization.
//

import Foundation
import MLX
import MLXNN
import MLXLMCommon
import OSLog

extension MLXModelManager {
    // MARK: - Loading

    func invalidateConversationSession(_ conversationID: UUID, reason: String) {
        Task {
            await inferenceWorker.invalidateConversation(conversationID, reason: reason)
        }
    }

    func startLoading(modelID: String? = nil, source: String = "unknown") {
        let preferredModel = modelID.flatMap { id in
            availableModels.first(where: { $0.id == id })
        }
        guard let model = preferredModel ?? availableModels.first else {
            return
        }
        guard model.isAvailable else {
            loadError = compatibilityError(for: model) ??
                String(localized: "\(model.displayName) is not downloaded. Download it before loading.", bundle: .appLocalized)
            return
        }

        if currentModel?.id == model.id, container != nil, !isLoading {
            logger.notice("MLX load request ignored: model already loaded id=\(model.id, privacy: .public) source=\(source, privacy: .public)")
            return
        }

        if pendingModelToLoad?.id == model.id, isLoading {
            logger.notice("MLX load request ignored: model already loading id=\(model.id, privacy: .public) source=\(source, privacy: .public)")
            return
        }

        let loadID = UUID()
        hasSeenMemoryWarningSinceCurrentLoad = false
        logger.notice("MLX load requested: id=\(model.id, privacy: .public) source=\(source, privacy: .public)")

        if let architecture = packageArchitecture(for: model) {
            logger.notice(
                "MLX package metadata: id=\(model.id, privacy: .public) architecture=\(architecture, privacy: .public) package=\(model.loadPolicy.packageDescription, privacy: .public)"
            )
        }

        let replacingWorkerLoadID = installedWorkerLoadID
        cancelCurrentLoad(reason: "superseded by \(model.id)", tearDownModel: false)
        tearDownCurrentModel(reason: "preparing to load \(model.id)", clearInferenceWorker: false)
        activeLoadID = loadID
        load(
            model,
            loadID: loadID,
            replacingWorkerLoadID: replacingWorkerLoadID,
            source: source
        )
    }

    /// Shows a model-selection problem found outside the manager, e.g. by
    /// the backend bridge, in the same place as load failures.
    func reportLoadError(_ message: String) {
        loadError = message
    }

    func clearLoadError() {
        loadError = nil
    }

    func model(withID id: String) -> MLXModelInfo? {
        availableModels.first(where: { $0.id == id })
    }

    /// Models that are downloaded and compatible, i.e. selectable in the model picker.
    var installedModels: [MLXModelInfo] {
        availableModels.filter(\.isAvailable)
    }
    func cancelCurrentLoad(reason: String = "cancelled", tearDownModel: Bool = true) {
        loadTask?.cancel()
        loadTask = nil
        logger.notice("MLX load cancelled: reason=\(reason, privacy: .public)")
        if isLoading {
            isLoading = false
            pendingModelToLoad = nil
        }
        if activeLoadID != nil {
            activeLoadID = nil
        }
        if tearDownModel {
            tearDownCurrentModel(reason: "cancelCurrentLoad(\(reason))")
        }
    }

    private func load(
        _ model: MLXModelInfo,
        loadID: UUID,
        replacingWorkerLoadID: UUID?,
        source: String
    ) {
        guard model.isAvailable, let modelURL = modelDirectoryURL(for: model) else {
            activeLoadID = nil
            isLoading = false
            pendingModelToLoad = nil
            if let compatibilityError = compatibilityError(for: model) {
                loadError = compatibilityError
            } else {
                loadError = String(localized: "\(model.displayName)'s files are missing. Download it again in Manage Models.", bundle: .appLocalized)
            }
            return
        }
        pendingModelToLoad = model
        isLoading = true
        loadError = nil
        let recommendedPrefillStepSize = Self.persistedPrefillStepSize(
            for: model.id,
            deviceSupportProfile: deviceSupportProfile,
            defaults: defaults
        ) ?? Self.defaultPrefillStepSize
        let wiredMemoryCap = Self.recommendedWiredMemoryCapBytes(
            deviceSupportProfile: deviceSupportProfile
        )

        // Created on the main actor, so the task body runs there; only the
        // awaited container and worker calls leave it.
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let replacingWorkerLoadID {
                    _ = await self.inferenceWorker.clearLoadedModel(
                        ifLoadID: replacingWorkerLoadID
                    )
                }
                self.prepareMemoryForModelLoadTransition()
                await Task.yield()
                self.logger.notice(
                    "MLX container load start: id=\(model.id, privacy: .public) source=\(source, privacy: .public) path=\(modelURL.lastPathComponent, privacy: .public)"
                )
                let loaded = try await loadModelContainer(directory: modelURL)
                #if targetEnvironment(simulator)
                // CoreSimulator's Metal compiler cannot lower BF16 kernels. Widen
                // only floating BF16 parameters exactly; packed 4/6-bit weights
                // stay quantized and physical devices retain native BF16 execution.
                try await loaded.perform { context in
                    let parameters = context.model.parameters().mapValues { value in
                        guard value.dtype == .bfloat16 else { return value }
                        let widened = value.asType(.float32, stream: .cpu)
                        widened.eval()
                        return widened
                    }
                    try context.model.update(parameters: parameters, verify: [.all])
                }
                #endif
                try Task.checkCancellation()
                guard self.activeLoadID == loadID else {
                    self.logger.notice("MLX container load discarded before install: stale load id=\(model.id, privacy: .public)")
                    self.cleanupMemoryAfterLoadInterruption()
                    return
                }
                await self.applyPreferredToolCallFormatIfNeeded(to: loaded, for: model)
                let weightBytes = await Self.estimateWeightBytes(for: loaded)
                let wiredMemoryPolicy = MLXLMCommon.WiredSumPolicy(cap: wiredMemoryCap)
                let reservationTicket = await Self.startReservationTicketIfNeeded(
                    weightBytes: weightBytes,
                    policy: wiredMemoryPolicy
                )
                await self.inferenceWorker.setLoadedModel(
                    MLXLoadedModelState(
                        loadID: loadID,
                        container: loaded,
                        model: model,
                        wiredMemoryPolicy: wiredMemoryPolicy,
                        reservationTicket: reservationTicket,
                        activeBytesEstimate: 0,
                        prefillStepSize: recommendedPrefillStepSize
                    )
                )
                guard !Task.isCancelled else {
                    _ = await self.inferenceWorker.clearLoadedModel(ifLoadID: loadID)
                    self.finishInterruptedLoad(loadID: loadID)
                    return
                }
                guard self.activeLoadID == loadID else {
                    self.logger.notice("MLX container load discarded: stale load id=\(model.id, privacy: .public)")
                    _ = await self.inferenceWorker.clearLoadedModel(ifLoadID: loadID)
                    self.cleanupMemoryAfterLoadInterruption()
                    return
                }
                self.container = loaded
                self.currentModel = model
                self.installedWorkerLoadID = loadID
                self.isLoading = false
                self.pendingModelToLoad = nil
                self.activeLoadID = nil
                self.applySteadyStateMemoryCachePolicy()
                self.loadTask = nil
                self.logger.notice("MLX model loaded: \(model.displayName, privacy: .public)")
                self.logger.notice("MLX container load finished: id=\(model.id, privacy: .public)")
                MLXMemoryDiagnostics.log(self.logger, "load.finished")
                await self.logToolTemplateSupport(for: model)
                // Another load or a teardown may have run during the await.
                guard self.installedWorkerLoadID == loadID else { return }
                self.schedulePrefillTuningIfNeeded(
                    model: model,
                    initialPrefillStepSize: recommendedPrefillStepSize
                )
                if model.loadPolicy.defersAutomaticPrewarm {
                    self.deferredPrewarmModelID = model.id
                    self.logger.notice("MLX prewarm deferred until first generation: id=\(model.id, privacy: .public)")
                } else {
                    self.startPostLoadPrewarm(for: model)
                }
            } catch is CancellationError {
                self.finishInterruptedLoad(loadID: loadID)
                self.logger.notice("MLX container load cancelled during execution: id=\(model.id, privacy: .public)")
            } catch {
                guard self.activeLoadID == loadID else {
                    self.cleanupMemoryAfterLoadInterruption()
                    return
                }
                self.isLoading = false
                self.pendingModelToLoad = nil
                self.loadTask = nil
                self.activeLoadID = nil
                self.loadError = String(localized: "Failed to load model: \(error.localizedDescription)", bundle: .appLocalized)
                self.tearDownCurrentModel(reason: "load failure for \(model.id)")
                self.logger.error("MLX model load error: \((error as NSError).localizedDescription, privacy: .public)")
                self.logger.error("MLX container load failed: id=\(model.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Ends a cancelled load. `cancelCurrentLoad` already cleared
    /// `activeLoadID`, so the loading state is reset only while this load
    /// still owns it, but the buffers a half-finished load allocated are
    /// always freed.
    private func finishInterruptedLoad(loadID: UUID) {
        if activeLoadID == loadID {
            isLoading = false
            pendingModelToLoad = nil
            loadTask = nil
            activeLoadID = nil
        }
        cleanupMemoryAfterLoadInterruption()
    }

    /// Runs the post-load prewarm as its own task, so teardown and the next
    /// load can cancel it rather than waiting while it holds the container.
    private func startPostLoadPrewarm(for model: MLXModelInfo) {
        prewarmTask?.cancel()
        prewarmTask = Task { [weak self] in
            await self?.prewarmModelShaders(for: model, reason: "post-load")
        }
    }

    nonisolated private static func estimateWeightBytes(for container: ModelContainer) async -> Int {
        await container.perform { context in
            context.model.parameters().flattened().reduce(0) { partialResult, parameter in
                partialResult + parameter.1.nbytes
            }
        }
    }

    nonisolated private static func startReservationTicketIfNeeded(
        weightBytes: Int,
        policy: MLXLMCommon.WiredSumPolicy
    ) async -> MLX.WiredMemoryTicket? {
        guard weightBytes > 0 else { return nil }
        let ticket = MLX.WiredMemoryTicket(size: weightBytes, policy: policy, kind: .reservation)
        _ = await ticket.start()
        return ticket
    }
    func unloadAllModels() {
        cancelCurrentLoad(reason: "unloadAllModels", tearDownModel: false)
        tearDownCurrentModel(reason: "unloadAllModels")
        logger.notice("Unloaded all MLX models")
    }

    // MARK: - Shader Pre-warming

    /// Runs a minimal text forward pass immediately after model load to pre-compile all LM Metal
    /// shaders (SSM, full-attention, MoE layers). Without this the compiler spike hits on the
    /// first real inference, when the device is also holding a user image in memory.
    /// Skipped on the simulator — the Metal compute stack there can't handle a full LM forward
    /// pass and triggers EXC_BAD_ACCESS.
    func prewarmModelShaders(for model: MLXModelInfo, reason: String) async {
        #if targetEnvironment(simulator)
        logger.notice("Skipping LM shader pre-warm on simulator")
        return
        #else
        guard let container else { return }
        guard currentModel?.id == model.id else { return }
        if deferredPrewarmModelID != model.id && prewarmInFlightModelID == nil && reason != "post-load" {
            return
        }
        if prewarmInFlightModelID == model.id {
            return
        }
        prewarmInFlightModelID = model.id
        logger.notice("MLX prewarm start: id=\(model.id, privacy: .public) reason=\(reason, privacy: .public)")
        MLXMemoryDiagnostics.log(logger, "prewarm.start")
        logger.notice("Pre-warming LM Metal shaders")
        // Free every cached Metal buffer before shader compilation so the compilation
        // spike has the maximum possible headroom on top of the ~3 GB model weights.
        prepareMemoryForPrewarm()
        // Prewarm can outlive this model (a teardown cancels it); only clear
        // markers that still refer to it.
        func clearPrewarmMarkers(includingDeferred: Bool) {
            if prewarmInFlightModelID == model.id {
                prewarmInFlightModelID = nil
            }
            if includingDeferred, deferredPrewarmModelID == model.id {
                deferredPrewarmModelID = nil
            }
        }
        do {
            let warmupMsg = Chat.Message.user("Hi")
            let userInput = UserInput(chat: [warmupMsg], processing: UserInput.Processing())
            let input = try await container.prepare(input: userInput)
            // Real sampling and cache settings, so the pipelines a plain turn
            // uses (penalties, top-k, RotorQuant cache) are the ones compiled.
            let params = defaultGenerateParameters(
                for: model,
                maxTokens: 1,
                prefillStepSize: await inferenceWorker.prefillStepSize(for: model.id)
            )
            let stream = try await container.generate(input: input, parameters: params)
            for await _ in stream {
                if Task.isCancelled {
                    throw CancellationError()
                }
            }
            try Task.checkCancellation()
            cleanupMemoryAfterPrewarm()
            clearPrewarmMarkers(includingDeferred: true)
            logger.notice("LM Metal shaders pre-warmed")
            logger.notice("MLX prewarm finished: id=\(model.id, privacy: .public)")
            MLXMemoryDiagnostics.log(logger, "prewarm.finished")
        } catch is CancellationError {
            cleanupMemoryAfterPrewarm()
            clearPrewarmMarkers(includingDeferred: false)
            logger.notice("MLX prewarm cancelled: id=\(model.id, privacy: .public)")
        } catch {
            cleanupMemoryAfterPrewarm()
            clearPrewarmMarkers(includingDeferred: false)
            logger.warning("Shader pre-warm failed (non-fatal): \(error.localizedDescription, privacy: .public)")
            logger.error("MLX prewarm failed: id=\(model.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
        #endif
    }
}
