//
//  ChatViewModel+Streaming.swift
//  Minnow
//
//  The reply pipeline: reset the target message, prepare the backend request,
//  consume the generation stream, then finalize and persist the reply.
//

import Foundation
import Combine
import SwiftData
import FoundationModels
import os
@preconcurrency import MLXLMCommon

extension ChatViewModel {

    // MARK: - Streaming

    // Add optional transient instruction that is appended to the prompt for this run only.
    @discardableResult
    internal func streamAssistant(
        into assistantMessage: Message,
        basedOnHistoryUpTo order: Int,
        additionalUserInstruction: String? = nil,
        disableWebSearch: Bool = false,
        allowNativeImages: Bool = true,
        reasoningMode: Bool? = nil,
        generationID: UUID? = nil
    ) async -> StreamOutcome {
        logger.debug("streamAssistant starting: order=\(order, privacy: .public) message_id=\(assistantMessage.id.uuidString, privacy: .public)")

        let lifecycleID: UUID
        let ownsLifecycle: Bool
        if let generationID {
            guard isGenerationActive(generationID) else { return .cancelled }
            lifecycleID = generationID
            ownsLifecycle = false
        } else {
            guard let newID = beginGenerationLifecycle() else { return .cancelled }
            lifecycleID = newID
            ownsLifecycle = true
        }
        defer {
            if ownsLifecycle {
                endGenerationLifecycle(lifecycleID)
            }
        }

        guard isGenerationActive(lifecycleID) else {
            logger.debug("streamAssistant cancelled before starting")
            return .cancelled
        }

        resetStreamingActivity()
        streamingMessageID = assistantMessage.id

        guard let resetState = prepareStreamResetState(
            from: assistantMessage,
            reasoningMode: reasoningMode
        ) else {
            streamingMessageID = nil
            return .failedBeforeOutput
        }

        var streamOutcome: StreamOutcome = .succeeded

        // Own preparation and consumption with the same cancellable task. This
        // also lets chat deletion wait for placeholder cleanup before deleting.
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.isGenerationActive(lifecycleID),
                  let preparation = await self.prepareStream(
                    from: resetState,
                    basedOnHistoryUpTo: order,
                    additionalUserInstruction: additionalUserInstruction,
                    disableWebSearch: disableWebSearch,
                    allowNativeImages: allowNativeImages,
                    generationID: lifecycleID
                  ), self.isGenerationActive(lifecycleID) else {
                let cancelled = !self.isGenerationActive(lifecycleID)
                if cancelled { self.discardOrRestoreResetPlaceholder(resetState) }
                streamOutcome = cancelled ? .cancelled : .failedBeforeOutput
                self.finishStreamingSession(generationID: lifecycleID)
                return
            }
            let consumption = await self.performStreaming(preparation: preparation)
            guard self.streamingGenerationID == lifecycleID else {
                // Another session took over; keep what this one wrote.
                self.immediateSave()
                return
            }
            let capturedInvocations = self.captureSearchInvocations(
                from: preparation.webSearchBridge,
                into: preparation.target
            )
            let outcome = self.finalizeStreaming(
                preparation: preparation,
                consumption: consumption,
                capturedInvocations: capturedInvocations
            )
            streamOutcome = outcome
            self.finishStreamingSession(generationID: lifecycleID)
            if outcome == .succeeded {
                // A short two-tap pattern; it outlives nothing and needs no owner.
                Task { await AppHaptics.generationCompleted() }
            }
        }

        streamingGenerationID = lifecycleID
        currentStreamTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        return streamOutcome
    }

    /// Whether the message a stream writes into still belongs to the chat. A model the
    /// store tracks answers from its own state; otherwise fall back to the relationship.
    private func isStreamTargetLive(_ target: Message) -> Bool {
        if target.modelContext != nil {
            return !target.isDeleted
        }
        return conversation.messages.contains { $0.id == target.id }
    }

    /// Puts back the reply a run replaced, or removes the placeholder of a new turn that
    /// has nothing to show. Returns false when the placeholder was removed.
    @discardableResult
    private func restorePreviousReplyOrDiscard(_ resetState: StreamResetState) -> Bool {
        let target = resetState.target
        if resetState.hasPreviousContent {
            target.restore(resetState.previousReply)
            return true
        }
        conversation.messages.removeAll { $0.id == target.id }
        context.delete(target)
        return false
    }

    /// Undoes `prepareStreamResetState` for a turn cancelled before streaming
    /// began. Mirrors the cancellation branch of `finalizeStreaming`: restore
    /// prior content when regenerating, otherwise drop the empty placeholder.
    private func discardOrRestoreResetPlaceholder(_ resetState: StreamResetState) {
        let target = resetState.target
        guard isStreamTargetLive(target), target.generationError == nil else { return }

        if restorePreviousReplyOrDiscard(resetState) {
            target.markAsComplete()
        }
        conversation.lastUpdated = Date()
        immediateSave()
    }

    /// `reasoningMode` replaces the message's mode for this run only; a run that
    /// is stopped or fails puts the previous reply back with its own mode.
    /// Nothing is saved here: until the prompt is ready, the store still holds
    /// the previous reply, which is what a crash in between should keep.
    private func prepareStreamResetState(
        from target: Message,
        reasoningMode: Bool?
    ) -> StreamResetState? {
        guard target.role == .assistant, isStreamTargetLive(target) else { return nil }

        let previousReply = target.regenerationSnapshot()
        let hasPreviousContent = Self.hasNonBlankContent(
            text: target.text,
            finalAnswer: target.finalAnswer,
            reasoning: target.reasoning
        )
        let forcedSearchRequirement = target.requiresWebSearch
        let forcedSearchQuery = forcedSearchRequirement == true ? target.searchQuery : nil
        let forceSearchRequired = forcedSearchRequirement == true ||
            (target.searchInvocations == nil && target.searchQuery != nil)

        target.resetForRegeneration()
        if let reasoningMode, target.isReasoningMode != reasoningMode {
            target.isReasoningMode = reasoningMode
        }
        if target.requiresWebSearch != forcedSearchRequirement {
            target.requiresWebSearch = forcedSearchRequirement
        }
        if target.searchQuery != forcedSearchQuery {
            target.searchQuery = forcedSearchQuery
        }
        // A new turn's placeholder was just saved and the reset leaves it
        // untouched, so only a real reset marks the chat updated.
        if context.hasChanges {
            conversation.lastUpdated = Date()
        }

        return StreamResetState(
            target: target,
            previousReply: previousReply,
            hasPreviousContent: hasPreviousContent,
            forceSearchRequired: forceSearchRequired
        )
    }

    private func prepareStream(
        from resetState: StreamResetState,
        basedOnHistoryUpTo order: Int,
        additionalUserInstruction: String?,
        disableWebSearch: Bool,
        allowNativeImages: Bool,
        generationID: UUID
    ) async -> StreamPreparation? {
        let promptBridge = backendBridge
        let selectedBackend = promptBridge.selectedBackend
        let selectedModelID = promptBridge.selectedModelID
        let toolCallsDisabled = disableWebSearch || defaults.disableToolCalls
        let backendSupportsWebSearchTools = promptBridge.toolCallsAvailableForCurrentBackend
        let webSearchAvailable = !toolCallsDisabled && searchService != nil && backendSupportsWebSearchTools
        let webSearchBridge: AppWebSearchToolBridge? = if webSearchAvailable, let service = searchService {
            AppWebSearchToolBridge(searchService: service)
        } else {
            nil
        }

        logger.notice(
            "streamAssistant tool setup: backend=\(selectedBackend.rawValue, privacy: .public) force_search=\(resetState.forceSearchRequired, privacy: .public) tools_disabled=\(toolCallsDisabled, privacy: .public) backend_tool_support=\(backendSupportsWebSearchTools, privacy: .public) search_service=\(self.searchService != nil, privacy: .public) web_tool_available=\(webSearchAvailable, privacy: .public) search_query_present=\(resetState.target.searchQuery != nil, privacy: .public)"
        )

        let foundationModelTools: [any FoundationModelTool] = webSearchBridge.map { [$0.foundationModelTool] } ?? []
        let mlxTools: [MLXToolSpec] = webSearchBridge.map { [$0.mlxToolSpec] } ?? []
        let mlxToolDispatch: (@Sendable (MLXToolCall) async throws -> String)? = if let bridge = webSearchBridge {
            { toolCall in
                try await bridge.dispatchMLXToolCall(toolCall)
            }
        } else {
            nil
        }

        logger.notice(
            "streamAssistant tools prepared: foundation_tools=\(foundationModelTools.count, privacy: .public) mlx_tools=\(mlxTools.count, privacy: .public)"
        )

        if resetState.forceSearchRequired && webSearchBridge == nil {
            let failureMessage: String
            if let backendIssue = promptBridge.toolCallAvailabilityIssueForCurrentBackend {
                failureMessage = String(localized: "\(backendIssue) Disable forced web search for this response or switch to a supported backend.", bundle: .appLocalized)
            } else if toolCallsDisabled {
                failureMessage = String(localized: "Web search was explicitly required for this response, but tool calls are disabled. Re-enable tool calls or turn off forced web search.", bundle: .appLocalized)
            } else {
                failureMessage = String(localized: "Web search was explicitly required for this response, but no search tool is configured. Add a Tavily API key.", bundle: .appLocalized)
            }
            failStreamPreparation(
                resetState,
                message: failureMessage,
                clearVisibleContent: true
            )
            return nil
        }

        let backendRequest: StreamBackendRequest
        guard isGenerationActive(generationID) else { return nil }

        if selectedBackend == .mlx, let manager = promptBridge.modelManager {
            // A chat's model is locked once it has messages, so a failed load would leave
            // it unable to reply. Retry the load; generation waits for it and, if it fails
            // again, reports why.
            if let selectedModelID, manager.currentModel?.id != selectedModelID && !manager.isLoading {
                manager.startLoading(modelID: selectedModelID, source: "send.retry")
            }
            do {
                let prompt = try await buildMLXPrompt(
                    upToOrderExclusive: order,
                    modelIdentity: manager.currentModel?.promptIdentity ?? "MLX model",
                    additionalInstruction: additionalUserInstruction,
                    includeLatestUserImages: allowNativeImages && promptBridge.nativeImageInputAvailable,
                    maxMessages: webSearchAvailable ? 10 : nil,
                    toolsAvailable: webSearchAvailable,
                    forceWebSearch: resetState.forceSearchRequired
                )
                guard isGenerationActive(generationID) else { return nil }
                backendRequest = .mlx(
                    manager: manager,
                    conversationID: conversation.id,
                    messages: prompt.messages,
                    enableThinking: resetState.target.isReasoningMode,
                    tools: mlxTools,
                    toolDispatch: mlxToolDispatch,
                    stableSystemPrompt: prompt.stableSystemPrompt
                )
            } catch {
                failStreamPreparation(
                    resetState,
                    message: String(localized: "Failed to prepare image for native inference: \(error.localizedDescription)", bundle: .appLocalized)
                )
                return nil
            }
        } else {
            var request = buildFoundationRequest(
                upToOrderExclusive: order,
                currentReasoningActive: resetState.target.isReasoningMode,
                modelIdentity: ModelBackendBridge.Backend.foundationModels.displayName,
                webSearchAvailable: webSearchAvailable,
                forceWebSearchRequired: resetState.forceSearchRequired,
                includeImages: allowNativeImages && promptBridge.nativeImageInputAvailable
            )
            if let instruction = additionalUserInstruction, !instruction.isEmpty {
                request.prompt += "\n\n" + instruction
            }
            backendRequest = .foundation(request: request, tools: foundationModelTools)
        }

        guard isGenerationActive(generationID) else { return nil }

        // Persist the reset of a regenerated reply (and promote a draft chat) before
        // generation starts. A new turn's placeholder was already saved with it.
        if context.hasChanges || conversation.modelContext == nil {
            immediateSave()
        }

        return StreamPreparation(
            reset: resetState,
            webSearchBridge: webSearchBridge,
            backendRequest: backendRequest
        )
    }

    private func failStreamPreparation(
        _ resetState: StreamResetState,
        message: String,
        clearVisibleContent: Bool = false
    ) {
        let target = resetState.target
        target.generationError = message
        if resetState.hasPreviousContent {
            keepPreviousReply(resetState.previousReply, in: target, after: message)
        } else if clearVisibleContent {
            // The error callout renders `generationError`; keep `text` empty.
            target.text = ""
            target.finalAnswer = nil
            target.reasoning = nil
        }
        target.markAsComplete()
        conversation.lastUpdated = Date()
        immediateSave()
    }

    /// A retry that failed before writing anything keeps the answer it was
    /// replacing, with the failure noted below it.
    private func keepPreviousReply(
        _ previousReply: Message.RegenerationSnapshot,
        in target: Message,
        after failure: String
    ) {
        target.restore(previousReply)
        target.generationError = String(localized: "Couldn't regenerate: \(failure)", bundle: .appLocalized)
    }

    /// Writes everything the stream produced into the message with the final cleanup,
    /// including tokens that arrived after the last throttled repaint. Every way a
    /// stream can end (finished, timed out, stopped or failed) goes through here.
    private func flushStreamedOutput(
        _ result: StreamConsumptionResult,
        into target: Message,
        from webSearchBridge: AppWebSearchToolBridge?
    ) {
        syncLiveSearchInvocations(into: target, from: webSearchBridge)
        guard result.wroteAny else { return }
        updateMessageWithReasoningContent(target, fullText: result.cumulativeText, finalize: true)
        target.completeGenerationCapture(
            rawText: result.cumulativeText,
            captureRawText: capturesRawGenerationText
        )
    }

    private func performStreaming(preparation: StreamPreparation) async -> StreamConsumptionResult {
        // Resolved once: re-finding the message by ID walks the relationship on every event.
        let target = preparation.target
        guard isStreamTargetLive(target) else {
            return StreamConsumptionResult(outcome: .failedBeforeOutput)
        }

        var result = StreamConsumptionResult()
        var lastModelWrite: Date = .distantPast
        let webSearchBridge = preparation.webSearchBridge
        let prefillAllowance: Duration = switch preparation.backendRequest {
        case .mlx(_, _, let messages, _, _, _, _):
            Self.prefillAllowance(forPromptTokens: messages.reduce(0) {
                $0 + Self.heuristicPromptTokenCount(for: $1.content)
            })
        case .foundation:
            .zero
        }
        let generationStartedAt = Date()
        let backendLabel: String
        let modelName: String?

        switch preparation.backendRequest {
        case .mlx(let manager, _, _, _, _, _, _):
            backendLabel = "MLX"
            modelName = manager.currentModel?.displayName
        case .foundation:
            backendLabel = ModelBackendBridge.Backend.foundationModels.displayName
            modelName = "Foundation Models"
        }

        target.beginGenerationCapture(
            backend: backendLabel,
            modelName: modelName,
            startedAt: generationStartedAt
        )

        @MainActor
        func renderIfThrottled() {
            // Limit repaint frequency without waiting for a minimum chunk size:
            // a newline or closing Markdown delimiter can change the entire layout.
            let now = Date()
            guard now.timeIntervalSince(lastModelWrite) >= streamRepaintInterval else { return }
            updateMessageWithReasoningContent(target, fullText: result.cumulativeText, finalize: false)
            lastModelWrite = now
            // lastUpdated is set when the turn starts and ends, not on every repaint:
            // the sidebar sorts and groups by it, so each write re-renders the sidebar.
            scheduleCoalescedSave()
        }

        @MainActor
        func updateStreamingActivity() {
            requestStreamingActivity(.current(
                // A finished search counts as output: the model is now reading the results.
                hasReceivedOutput: result.wroteAny || !(webSearchBridge?.allInvocations.isEmpty ?? true),
                isSearching: webSearchBridge?.hasSearchInProgress == true
            ))
        }

        let watchdog = StreamWatchdog(
            timeouts: streamTimeouts,
            chunkTimeout: target.isReasoningMode ? streamTimeouts.reasoningChunk : streamTimeouts.chunk,
            prefillAllowance: prefillAllowance,
            isSearching: { webSearchBridge?.hasSearchInProgress == true }
        )
        defer { watchdog.stop() }

        do {
            let generation = try await makeGenerationStream(from: preparation)
            let continuation = generation.continuation
            watchdog.start { timeout in
                // Ending the stream also cancels its producer.
                continuation.finish(throwing: GenerationTimeoutError(timeout: timeout))
            }

            for try await event in generation.events {
                if Task.isCancelled { break }
                watchdog.recordEvent()
                guard isStreamTargetLive(target) else { break }

                switch event {
                case .text(let newText):
                    // Prompt processing is over until the next tool result.
                    watchdog.awaitingPrefill = false
                    let isFirstOutput = !result.wroteAny
                    guard Self.appendStreamingChunk(newText, to: &result.cumulativeText) else { continue }
                    result.wroteAny = true
                    watchdog.hasOutput = true
                    if isFirstOutput { updateStreamingActivity() }
                    renderIfThrottled()
                case .toolCall:
                    // The tool result is processed as a new prompt before more output.
                    watchdog.awaitingPrefill = true
                    if target.isReasoningMode {
                        target.reopenReasoningForToolCall(
                            closeTagCount: Self.reasoningCloseTagCount(in: result.cumulativeText)
                        )
                        syncLiveSearchInvocations(into: target, from: webSearchBridge)
                        // Text between `</think>` and the call was shown as a provisional
                        // answer; re-render now so it moves back into reasoning.
                        updateMessageWithReasoningContent(target, fullText: result.cumulativeText)
                        lastModelWrite = Date()
                    }
                case .searchActivityChanged:
                    updateStreamingActivity()
                    syncLiveSearchInvocations(into: target, from: webSearchBridge)
                    conversation.lastUpdated = Date()
                    scheduleCoalescedSave()
                case .metrics(let metrics):
                    // Persisted with the final message when the session ends.
                    target.recordGenerationMetrics(metrics)
                }
            }

            if Task.isCancelled {
                result.outcome = .cancelled
            }
            if isStreamTargetLive(target) {
                flushStreamedOutput(result, into: target, from: webSearchBridge)
            }

            logger.notice(
                "streamAssistant raw output: chars=\(result.cumulativeText.count, privacy: .public) wrote_any=\(result.wroteAny, privacy: .public)"
            )
        } catch let timeout as GenerationTimeoutError {
            logger.warning("streamAssistant timed out: partial_chars=\(result.cumulativeText.count, privacy: .public)")
            result.outcome = result.wroteAny ? .failedAfterPartialOutput : .failedBeforeOutput
            if isStreamTargetLive(target) {
                flushStreamedOutput(result, into: target, from: webSearchBridge)
                target.generationError = timeout.localizedDescription
            }
        } catch is CancellationError {
            logger.debug("streamAssistant generation cancelled")
            result.outcome = .cancelled
            // Preserve tokens received since the last throttled UI write.
            if isStreamTargetLive(target) {
                flushStreamedOutput(result, into: target, from: webSearchBridge)
            }
        } catch {
            logger.error(
                "streamAssistant generation error: partial_chars=\(result.cumulativeText.count, privacy: .public) error=\((error as NSError).localizedDescription, privacy: .public)"
            )
            result.outcome = result.wroteAny ? .failedAfterPartialOutput : .failedBeforeOutput
            if isStreamTargetLive(target) {
                flushStreamedOutput(result, into: target, from: webSearchBridge)
                target.generationError = isContextWindowError(error)
                    ? contextWindowError(for: preparation.backendRequest).localizedDescription
                    : (error as NSError).localizedDescription
            }
        }

        return result
    }

    /// Creates the event stream with its producer task; ending the stream cancels the producer.
    private func makeEventStream(
        startProducer: (AsyncThrowingStream<StreamEvent, Error>.Continuation) -> Task<Void, Never>
    ) -> GenerationEventStream {
        let (events, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        let producer = startProducer(continuation)
        continuation.onTermination = { @Sendable _ in
            producer.cancel()
        }
        return GenerationEventStream(events: events, continuation: continuation)
    }

    private func makeGenerationStream(from preparation: StreamPreparation) async throws -> GenerationEventStream {
        switch preparation.backendRequest {
        case .mlx(let manager, let conversationID, let messages, let enableThinking, let tools, let toolDispatch, let stableSystemPrompt):
            logger.notice("streamAssistant entering MLX generation path")
            let finishedLoading = await waitForModelLoad(manager, timeout: streamTimeouts.modelLoad)
            try Task.checkCancellation()
            guard finishedLoading, manager.currentModel != nil else {
                let reason = manager.loadError ?? String(localized: "The model hasn't finished loading.", bundle: .appLocalized)
                throw NSError(domain: "MLXGeneration", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "The selected MLX model isn't ready. \(reason)\n\nTry again, or start a new chat and choose Apple Intelligence from the model menu.", bundle: .appLocalized)
                ])
            }

            let webSearchBridge = preparation.webSearchBridge
            return makeEventStream { continuation in
                let logger = self.logger
                webSearchBridge?.setInvocationObserver {
                    continuation.yield(.searchActivityChanged)
                }
                // MLXModelManager is main-actor isolated and hands decoding to its worker
                // actor, so a detached task would only hop straight back here.
                return Task { @MainActor in
                    defer { webSearchBridge?.setInvocationObserver(nil) }
                    do {
                        let generationResult = try await manager.generateTextStream(
                            conversationID: conversationID,
                            messages: messages,
                            enableThinking: enableThinking,
                            tools: tools,
                            toolDispatch: toolDispatch,
                            stableSystemPrompt: stableSystemPrompt,
                            onToken: { token in continuation.yield(.text(token)) },
                            onToolCall: { toolCall in continuation.yield(.toolCall(toolCall)) }
                        )
                        logger.notice(
                            "streamAssistant MLX generation finished: tool_invocations=\(generationResult.toolInvocationCount, privacy: .public)"
                        )
                        continuation.yield(.metrics(generationResult.metrics))
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        case .foundation(let request, let tools):
            logger.notice("streamAssistant entering Foundation Models generation path")
            let webSearchBridge = preparation.webSearchBridge
            return makeEventStream { continuation in
                webSearchBridge?.setInvocationObserver {
                    continuation.yield(.searchActivityChanged)
                }
                return Task { @MainActor in
                    defer { webSearchBridge?.setInvocationObserver(nil) }
                    do {
                        try await Self.fmGate.acquire()
                        let gateLease = FoundationModelsGateLease(gate: Self.fmGate)
                        do {
                            try Task.checkCancellation()
                            let textStream = try await self.generator.streamResponse(
                                to: request,
                                tools: tools,
                                onMetrics: { metrics in continuation.yield(.metrics(metrics)) }
                            )
                            for try await chunk in textStream {
                                try Task.checkCancellation()
                                continuation.yield(.text(chunk))
                            }
                            await gateLease.release()
                            continuation.finish()
                        } catch {
                            await gateLease.release()
                            throw error
                        }
                    } catch is CancellationError {
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    /// Waits for a model load already in progress by observing `isLoading` rather than
    /// polling it. Returns false when the load is still running after `timeout`, so a
    /// stuck load ends in an error instead of leaving the reply on "Loading…".
    private func waitForModelLoad(_ manager: MLXModelManager, timeout: Duration) async -> Bool {
        guard manager.isLoading else { return true }
        isWaitingForModelLoad = true
        defer { isWaitingForModelLoad = false }
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await Self.waitForLoadingToEnd(manager)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !finished && !Task.isCancelled {
            logger.error("MLX model was still loading after \(timeout.components.seconds, privacy: .public) s; failing the reply")
        }
        return finished
    }

    /// True once `isLoading` turns false; false if the publisher ends first.
    private static func waitForLoadingToEnd(_ manager: MLXModelManager) async -> Bool {
        for await isLoading in manager.$isLoading.values where !isLoading {
            return true
        }
        return false
    }

    /// Appends a streamed delta in place. Both backend adapters expose deltas: Foundation
    /// Models converts its cumulative partials in OnDeviceLLMGenerator, while MLX emits
    /// chunks. Nothing is de-duplicated: content cannot tell a provider retry apart from
    /// intentional repetition in code, tables, lists or prose. Returns false for an empty delta.
    internal static func appendStreamingChunk(_ newText: String, to text: inout String) -> Bool {
        guard !newText.isEmpty else { return false }
        text.append(newText)
        return true
    }

    /// `currentText` with `newText` appended, or nil for an empty delta.
    internal static func mergedStreamingChunk(currentText: String, newText: String) -> String? {
        var merged = currentText
        return appendStreamingChunk(newText, to: &merged) ? merged : nil
    }

    private func captureSearchInvocations(
        from webSearchBridge: AppWebSearchToolBridge?,
        into target: Message
    ) -> [SearchInvocation] {
        let capturedInvocations = webSearchBridge?.allInvocations ?? []
        logger.notice(
            "streamAssistant search summary: invocations=\(capturedInvocations.count, privacy: .public)"
        )

        guard !capturedInvocations.isEmpty, isStreamTargetLive(target) else {
            return capturedInvocations
        }

        let storedInvocations = Self.mergeSearchInvocations(
            capturedInvocations,
            preservingAnchorsFrom: target.searchInvocations ?? [],
            currentChunkCount: reasoningChunkCount(for: target.reasoning)
        )
        target.searchInvocations = storedInvocations

        let legacyResults = storedInvocations
            .filter { $0.response == nil && $0.succeeded }
            .map { Self.escapeSourcesPayload($0.userVisibleResults) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !legacyResults.isEmpty else { return storedInvocations }

        let sourcesBlock = "<sources>\n\(legacyResults)\n</sources>\n\n"
        if target.isReasoningMode {
            let existing = target.finalAnswer ?? ""
            if !existing.contains("<sources>") {
                target.finalAnswer = sourcesBlock + existing
            }
        } else if !target.text.contains("<sources>") {
            target.text = sourcesBlock + target.text
        }

        return storedInvocations
    }

    private static func escapeSourcesPayload(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<sources>", with: "&lt;sources&gt;", options: [.caseInsensitive])
            .replacingOccurrences(of: "</sources>", with: "&lt;/sources&gt;", options: [.caseInsensitive])
    }

    private func finalizeStreaming(
        preparation: StreamPreparation,
        consumption: StreamConsumptionResult,
        capturedInvocations: [SearchInvocation]
    ) -> StreamOutcome {
        var outcome = consumption.outcome
        let resetState = preparation.reset
        let target = preparation.target

        guard isStreamTargetLive(target) else {
            return outcome
        }

        // A failed search is still recorded as an invocation, so presence alone
        // does not prove the answer is grounded -- require one that succeeded.
        if outcome != .cancelled && resetState.forceSearchRequired && !capturedInvocations.contains(where: { $0.succeeded }) {
            target.text = ""
            target.finalAnswer = nil
            target.reasoning = nil
            target.searchInvocations = nil
            target.generationError = capturedInvocations.isEmpty
                ? String(localized: "Search was explicitly required for this response, but the model did not call the webSearch tool.", bundle: .appLocalized)
                : String(localized: "Search was explicitly required for this response, but every webSearch attempt failed.", bundle: .appLocalized)
            outcome = .failedBeforeOutput
        }

        let hasVisibleFinal: Bool = {
            guard let final = target.finalAnswer else { return false }
            let stripped = final.removingSourcesBlocks()
            return !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }()
        let hasVisibleText = !target.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasVisibleReasoning = !(target.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasAnyVisibleContent = hasVisibleText || hasVisibleFinal || hasVisibleReasoning
        let hasPreviousContent = resetState.hasPreviousContent

        // Output that stops inside the reasoning (usually the output token limit) leaves
        // a finished bubble with only a reasoning section; say the answer is missing.
        if outcome == .succeeded, target.generationError == nil, target.isReasoningMode,
           hasVisibleReasoning, !hasVisibleText, !hasVisibleFinal,
           target.streamingReasoningPhase == .postToolReasoning ||
            Self.outputEndsInsideReasoning(
                consumption.cumulativeText,
                reasoningOpensInPrompt: preparation.backendRequest.isMLX
            ) {
            target.generationError = String(
                localized: "The reply stopped while the model was still thinking, so there's no answer. Try regenerating it.",
                bundle: .appLocalized
            )
            outcome = .failedAfterPartialOutput
        }

        if outcome == .cancelled && !hasAnyVisibleContent && target.generationError == nil {
            // Persist the deletion here rather than relying on the caller's
            // save so the "cancelled before any output" cleanup is durable
            // on its own.
            guard restorePreviousReplyOrDiscard(resetState) else {
                conversation.lastUpdated = Date()
                immediateSave()
                return outcome
            }
        }

        if outcome != .cancelled && !hasAnyVisibleContent && target.generationError == nil {
            logger.warning(
                "streamAssistant empty visible output: wrote_any=\(consumption.wroteAny, privacy: .public) raw_chars=\(consumption.cumulativeText.count, privacy: .public) tool_invocations=\(capturedInvocations.count, privacy: .public)"
            )

            if hasPreviousContent {
                target.restore(resetState.previousReply)
            } else {
                target.generationError = String(localized: "The model returned an empty response. Try regenerating or rephrasing.", bundle: .appLocalized)
                outcome = .failedBeforeOutput
            }
        }

        if outcome != .cancelled, let failure = target.generationError, !hasAnyVisibleContent, hasPreviousContent {
            keepPreviousReply(resetState.previousReply, in: target, after: failure)
        } else if target.generationError != nil, !hasAnyVisibleContent {
            // The error callout renders `generationError`; drop whitespace-only text.
            target.text = ""
        }

        // The final flush already removed legacy search tags and glitches; only
        // the edges can still carry whitespace (short replies skip that cleanup).
        let trimmedText = target.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText != target.text {
            target.text = trimmedText
        }
        if let final = target.finalAnswer {
            let trimmedFinal = final.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedFinal != final {
                target.finalAnswer = trimmedFinal
            }
        }

        target.markAsComplete()
        logger.notice(
            "streamAssistant finalized: outcome=\(String(describing: outcome), privacy: .public) error=\(target.generationError ?? "", privacy: .public) final_text_chars=\(target.text.count, privacy: .public)"
        )

        return outcome
    }

    private func finishStreamingSession(generationID: UUID) {
        guard streamingGenerationID == generationID else { return }
        streamingGenerationID = nil
        streamingMessageID = nil
        resetStreamingActivity()
        immediateSave()
        currentStreamTask = nil
    }

    // MARK: - Streaming Helpers

    private func contextWindowError(for backendRequest: StreamBackendRequest) -> ContextWindowError {
        switch backendRequest {
        case .mlx:
            ContextWindowError(tokenLimit: effectiveContextWindowTokenLimit(), backend: .mlx)
        case .foundation:
            ContextWindowError(
                tokenLimit: ModelBackendBridge.foundationModelsContextSize,
                backend: .appleIntelligence
            )
        }
    }

    private var capturesRawGenerationText: Bool {
        defaults.bool(forKey: AppSettingsKeys.developerModeEnabled)
    }

    private static func hasNonBlankContent(text: String, finalAnswer: String?, reasoning: String?) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !(finalAnswer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
            !(reasoning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    // MARK: - Search Invocations

    internal static func mergeSearchInvocations(
        _ liveInvocations: [SearchInvocation],
        preservingAnchorsFrom existingInvocations: [SearchInvocation],
        currentChunkCount: Int
    ) -> [SearchInvocation] {
        guard !liveInvocations.isEmpty else { return [] }

        let existingByID = Dictionary(existingInvocations.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })

        return liveInvocations.map { invocation in
            if let existing = existingByID[invocation.id] {
                var merged = invocation
                merged.anchorStepNumber = existing.anchorStepNumber ?? invocation.anchorStepNumber
                return merged
            }

            var anchored = invocation
            if anchored.anchorStepNumber == nil {
                anchored.anchorStepNumber = max(0, currentChunkCount)
            }
            return anchored
        }
    }

    private func syncLiveSearchInvocations(into message: Message, from bridge: AppWebSearchToolBridge?) {
        guard let bridge else { return }
        let liveInvocations = bridge.allInvocations
        guard !liveInvocations.isEmpty else { return }

        // Called only when the bridge reports a change (and once when the reply
        // ends), not on every repaint: the setter JSON-encodes every result and
        // dirties the row, and the next read decodes it all again.
        let existing = message.searchInvocations ?? []
        let existingIDs = Set(existing.map(\.id))
        // Only a search that just appeared needs an anchor in the reasoning.
        let hasNewInvocation = liveInvocations.contains { !existingIDs.contains($0.id) }
        let merged = Self.mergeSearchInvocations(
            liveInvocations,
            preservingAnchorsFrom: existing,
            currentChunkCount: hasNewInvocation ? reasoningChunkCount(for: message.reasoning) : 0
        )

        message.searchInvocations = merged
    }

    private func reasoningChunkCount(for reasoning: String?) -> Int {
        Self.reasoningPieceCount(for: reasoning)
    }

    /// The blank-line pieces of the reasoning written so far, counted the way the
    /// reasoning sheet splits it (`ReasoningStepSegmenter`): on the sanitized text, where
    /// reasoning tags between passes become paragraph breaks. A search anchored here then
    /// appears after the step it followed.
    nonisolated static func reasoningPieceCount(for reasoning: String?) -> Int {
        guard let reasoning else { return 0 }
        let sanitized = ReasoningTextSanitizer.string(from: reasoning)
        guard !sanitized.isEmpty else { return 0 }

        let pieces = sanitized
            .components(separatedBy: "\n\n")
            .filter { $0.contains(where: { !$0.isWhitespace }) }

        return max(1, pieces.count)
    }
}
