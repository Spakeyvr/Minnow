//
//  MLXInferenceWorker.swift
//  ChatLLM
//
//  Actor-isolated inference executor for MLX models. Owns the loaded container,
//  persistent chat sessions, and the generation loop including tool-call
//  dispatch. `MLXModelManager` drives it by submitting `MLXInferenceRequest`
//  values and receiving `MLXInferenceResponse`.
//

import Foundation
import CryptoKit
import MLX
// MLXLMCommon is vendored upstream code still built in Swift 5 mode. Its
// `ChatSession` is not Sendable, and its async methods run off this actor.
// The worker owns each session and never uses one from two tasks at once.
@preconcurrency import MLXLMCommon
import MLXVLM
import Tokenizers
import OSLog
import UIKit
import os

/// Formats the process's remaining jetsam budget alongside MLX allocator
/// stats. `os_proc_available_memory` reports how many bytes the app can
/// still allocate before iOS terminates it, which is the number that
/// actually matters when chasing out-of-memory kills.
nonisolated enum MLXMemoryDiagnostics {
    static func status() -> String {
        // One snapshot rather than three separate reads, so active/cache/peak
        // describe the same instant. `os_proc_available_memory` reports 0 when
        // the process has no jetsam limit (Simulator, Mac Catalyst), so the
        // headroom field is only meaningful on device.
        let snapshot = Memory.snapshot()
        let headroom = os_proc_available_memory()
        let headroomMB = Double(headroom) / 1_048_576
        let activeMB = Double(snapshot.activeMemory) / 1_048_576
        let cacheMB = Double(snapshot.cacheMemory) / 1_048_576
        let peakMB = Double(snapshot.peakMemory) / 1_048_576
        let headroomField = headroom > 0
            ? String(format: "headroom=%.0fMB", headroomMB)
            : "headroom=n/a"
        return String(
            format: "%@ mlx_active=%.0fMB mlx_cache=%.0fMB mlx_peak=%.0fMB",
            headroomField, activeMB, cacheMB, peakMB
        )
    }

    /// Single place the `MLX mem[...]` log line is built, so its format, level
    /// and privacy stay consistent across the ~11 checkpoints that emit it.
    static func log(_ logger: Logger, _ tag: String, _ detail: String = "") {
        let suffix = detail.isEmpty ? "" : " \(detail)"
        logger.notice(
            "MLX mem[\(tag, privacy: .public)]\(suffix, privacy: .public): \(status(), privacy: .public)"
        )
    }
}

// MARK: - Session Transcript

/// Content identity of a turn the client authored and replays byte for byte.
nonisolated struct MLXVisibleMessageSignature: Equatable, Sendable {
    let role: Chat.Message.Role
    /// Fixed-size content identity used only for prefix reuse checks. Keeping
    /// the original text here duplicates the complete conversation alongside
    /// the SwiftData message graph for every warm session.
    let contentFingerprint: [UInt8]

    init(message: Chat.Message) {
        self.role = message.role
        self.contentFingerprint = Array(SHA256.hash(data: Data(message.content.utf8)))
    }
}

/// A turn a session holds in a form the client does not replay: the prompt it
/// answered, which carried per-turn context such as the date or chat
/// preferences, and the reply exactly as the model generated it, reasoning and
/// markup included. The client later replays a cleaned-up form of each, so the
/// session keeps only the letters and digits of the content and accepts a
/// replay whose letters and digits appear in the same order. Every cleanup the
/// view model applies (reasoning and tag removal, trimming, whitespace and
/// case fixes) only deletes text or changes case, so a genuine replay always
/// passes, while a different message almost never does.
nonisolated struct MLXPendingTurnSignature: Equatable, Sendable {
    let role: Chat.Message.Role
    let contentSkeleton: String

    init(role: Chat.Message.Role, content: String) {
        self.role = role
        self.contentSkeleton = Self.skeleton(of: content)
    }

    func isReplayed(by message: Chat.Message) -> Bool {
        guard message.role == role,
              message.images.isEmpty,
              message.videos.isEmpty else { return false }
        return Self.isOrderedSubset(Self.skeleton(of: message.content), of: contentSkeleton)
    }

    static func skeleton(of text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars
        where scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Whether every scalar of `candidate` appears in `source`, in order.
    private static func isOrderedSubset(_ candidate: String, of source: String) -> Bool {
        var remaining = source.unicodeScalars.makeIterator()
        candidateLoop: for scalar in candidate.unicodeScalars {
            while let next = remaining.next() {
                if next == scalar { continue candidateLoop }
            }
            return false
        }
        return true
    }
}

/// The conversation a persistent session's KV cache holds, in the form later
/// requests must replay for the session to be reused.
nonisolated struct MLXSessionTranscript: Equatable, Sendable {
    /// Turns whose replay form is known, compared byte for byte.
    private(set) var committed: [MLXVisibleMessageSignature]
    /// The last prompt and reply, until a request replays them.
    private(set) var pending: [MLXPendingTurnSignature]

    /// Transcript of a session that answered `prompt` after `history`.
    init(history: [Chat.Message], prompt: Chat.Message, reply: String) {
        self.init(
            committed: history.map(MLXVisibleMessageSignature.init(message:)),
            prompt: prompt,
            reply: reply
        )
    }

    private init(committed: [MLXVisibleMessageSignature], prompt: Chat.Message, reply: String) {
        self.committed = committed
        self.pending = [
            MLXPendingTurnSignature(role: prompt.role, content: prompt.content),
            MLXPendingTurnSignature(role: .assistant, content: reply)
        ]
    }

    var turnCount: Int { committed.count + pending.count }

    /// Whether `history`, every request message before the new prompt, is the
    /// conversation this session holds and nothing else.
    func isReplayed(by history: [Chat.Message]) -> Bool {
        guard history.count == turnCount,
              history.allSatisfy({ $0.images.isEmpty && $0.videos.isEmpty }) else { return false }
        for (signature, message) in zip(committed, history)
        where signature != MLXVisibleMessageSignature(message: message) {
            return false
        }
        for (turn, message) in zip(pending, history.dropFirst(committed.count))
        where !turn.isReplayed(by: message) {
            return false
        }
        return true
    }

    /// The transcript once the session answers `prompt` after `history`, which
    /// `isReplayed(by:)` accepted. The pending turns adopt the form the client
    /// replayed them in, so only the new prompt and reply stay pending.
    func advanced(replayedHistory history: [Chat.Message], prompt: Chat.Message, reply: String) -> MLXSessionTranscript {
        let adopted = history.dropFirst(committed.count).map(MLXVisibleMessageSignature.init(message:))
        return MLXSessionTranscript(committed: committed + adopted, prompt: prompt, reply: reply)
    }
}

// MARK: - Requests

nonisolated struct MLXSessionKey: Hashable, Sendable {
    let conversationID: UUID
    let modelID: String
    let enableThinking: Bool
    let toolsEnabled: Bool
    let includesMedia: Bool
    let instructionFingerprint: Int

    /// Whether a session created for `self` can answer a request for `other`.
    /// Thinking is not part of it: each prompt is rendered with the request's
    /// own `enable_thinking`, so a conversation whose turns switch between
    /// thinking and answering directly keeps its session.
    func canServe(_ other: MLXSessionKey) -> Bool {
        conversationID == other.conversationID &&
            modelID == other.modelID &&
            toolsEnabled == other.toolsEnabled &&
            includesMedia == other.includesMedia &&
            instructionFingerprint == other.instructionFingerprint
    }
}

nonisolated struct MLXSessionCacheConfiguration: Equatable, Sendable {
    let maxKVSize: Int?
    let cacheCompression: KVCacheCompressionMode?

    init(maxKVSize: Int?, cacheCompression: KVCacheCompressionMode?) {
        self.maxKVSize = maxKVSize
        self.cacheCompression = cacheCompression
    }

    init(parameters: GenerateParameters) {
        self.init(
            maxKVSize: parameters.maxKVSize,
            cacheCompression: parameters.resolvedCacheCompression
        )
    }
}

/// What the worker knows about a stored session, without the session itself.
nonisolated struct MLXSessionDescriptor: Equatable, Sendable {
    let key: MLXSessionKey
    let cacheConfiguration: MLXSessionCacheConfiguration
    let transcript: MLXSessionTranscript
    /// Tokens the session's KV cache holds. A reused session keeps every earlier
    /// turn as generated, reasoning and per-turn context included, so this can
    /// outgrow the history the client budgets from its replay text.
    var cachedTokenCount: Int = 0
}

nonisolated enum MLXSessionReuseDecision: Equatable, Sendable {
    case reuse
    case noSession
    case incompatibleKey
    case cacheConfigurationChanged
    case historyChanged
    case explicitMessageHistory
    case mediaTurn
    /// The session holds more tokens than the context window allows, so it is
    /// rebuilt from the budgeted history.
    case sessionTooLong
    /// The model's template cannot append a turn to an existing session.
    case templateCannotContinue

    var diagnosticLabel: String {
        switch self {
        case .reuse: "reuse"
        case .noSession: "no-session"
        case .incompatibleKey: "key-changed"
        case .cacheConfigurationChanged: "cache-configuration-changed"
        case .historyChanged: "history-changed"
        case .explicitMessageHistory: "explicit-message-history"
        case .mediaTurn: "media-turn"
        case .sessionTooLong: "session-too-long"
        case .templateCannotContinue: "template-cannot-continue"
        }
    }
}

nonisolated struct MLXLoadedModelState: @unchecked Sendable {
    let loadID: UUID
    let container: ModelContainer
    let model: MLXModelManager.MLXModelInfo
    let wiredMemoryPolicy: MLXLMCommon.WiredSumPolicy
    var reservationTicket: MLX.WiredMemoryTicket?
    var activeBytesEstimate: Int
    var prefillStepSize: Int
}

nonisolated struct MLXInferenceRequest: @unchecked Sendable {
    let conversationID: UUID
    let sessionKey: MLXSessionKey
    let model: MLXModelManager.MLXModelInfo
    let messages: [Chat.Message]
    let additionalContext: [String: any Sendable]?
    let processing: UserInput.Processing
    let tools: [MLXToolSpec]
    let params: GenerateParameters
    let suppressWrappedXMLToolMarkup: Bool
    /// Leading part of the system message that is identical across requests;
    /// bounds the cached prompt prefix.
    var stableSystemPrompt: String? = nil
    /// Most tokens a reused session may hold before it is rebuilt.
    var sessionTokenLimit: Int? = nil
}

nonisolated struct MLXInferenceResponse: Sendable {
    let toolInvocationCount: Int
    let metrics: GenerationMetrics
}

nonisolated enum MLXPersistentSessionReleaseScope: Equatable, Sendable {
    case none
    case conversation
    case all
}

/// Whether a generation stream keeps going after an element.
nonisolated enum MLXStreamStep: Equatable, Sendable {
    case next
    case stop
}

// MARK: - Worker

actor MLXInferenceWorker {
    private struct SessionState {
        let descriptor: MLXSessionDescriptor
        let session: ChatSession
        var lastAccessed: Date
    }

    private struct AcquiredSession {
        /// The session every stream of this turn appends to, or nil when each
        /// stream builds a disposable one.
        let persistentSession: ChatSession?
        let promptPrefix: MLXPromptPrefix?
        /// Transcript of a reused session before this turn.
        let reusedTranscript: MLXSessionTranscript?
        /// Tokens a reused session held before this turn.
        var reusedTokenCount = 0
    }

    /// State of one response across its streams: the first answers the user,
    /// each later one answers a tool result.
    private struct GenerationRun {
        let startedAt: Date
        var firstTokenAt: Date?
        var assistantVisibleText = ""
        var promptTokenCount: Int
        var promptTime: TimeInterval
        var cachedPromptTokenCount: Int
        var outputTokenCount = 0
        var generationTime: TimeInterval = 0
        var toolInvocationCount = 0
        /// The message the next stream answers.
        var prompt: Chat.Message
        var tools: [MLXToolSpec]
        /// Seeds every stream that builds its own `ChatSession`, not just the
        /// explicit tool loop. Media turns also skip session reuse, and leaving
        /// this empty for them dropped the system prompt and the entire prior
        /// conversation from the fresh session.
        var explicitMessageHistory: [Chat.Message]
        /// Remainder of the prompt for the first stream of a session created
        /// from a cached prefix; the session itself renders later prompts.
        var pendingPreparedInput: LMInput?
        /// The disposable session whose stream is running, so a failure can
        /// wait for it and release its cache.
        var inFlightDisposableSession: ChatSession?
        /// Prompt prefixes this request prefilled (written after the response)
        /// or restored for its later explicit-history streams.
        let promptPrefixScope: MLXPromptPrefixCache.RequestScope

        init(
            startedAt: Date,
            prompt: Chat.Message,
            tools: [MLXToolSpec],
            history: [Chat.Message],
            promptPrefix: MLXPromptPrefix?,
            promptPrefixScope: MLXPromptPrefixCache.RequestScope
        ) {
            self.startedAt = startedAt
            self.promptPrefixScope = promptPrefixScope
            self.prompt = prompt
            self.tools = tools
            self.explicitMessageHistory = history
            self.pendingPreparedInput = promptPrefix?.remainingInput
            // A prefix prefilled on a cache miss is part of this turn's prompt work.
            self.promptTokenCount = promptPrefix?.prefilledTokenCount ?? 0
            self.promptTime = promptPrefix?.prefillTime ?? 0
            self.cachedPromptTokenCount = promptPrefix?.restoredTokenCount ?? 0
        }

        mutating func record(_ prefix: MLXPromptPrefix) {
            cachedPromptTokenCount += prefix.restoredTokenCount
            promptTokenCount += prefix.prefilledTokenCount
            promptTime += prefix.prefillTime
        }

        mutating func record(_ info: GenerateCompletionInfo) {
            promptTokenCount += info.promptTokenCount
            promptTime += info.promptTime
            outputTokenCount += info.generationTokenCount
            generationTime += info.generateTime
        }

        var timeToFirstToken: TimeInterval? {
            firstTokenAt.map { $0.timeIntervalSince(startedAt) }
        }

        var decodeTokensPerSecond: Double? {
            generationTime > 0 ? Double(outputTokenCount) / generationTime : nil
        }

        var metrics: GenerationMetrics {
            GenerationMetrics(
                promptTokenCount: promptTokenCount,
                cachedPromptTokenCount: cachedPromptTokenCount,
                promptTime: promptTime,
                outputTokenCount: outputTokenCount,
                decodeTime: generationTime,
                timeToFirstToken: timeToFirstToken
            )
        }
    }

    private struct StreamResult {
        var toolCall: MLXToolCall?
        /// Text this stream produced, replayed into the assistant turn when
        /// the stream ends in a tool call.
        var visibleText = ""
    }

    private let logger: Logger
    private var loadedModel: MLXLoadedModelState?
    /// At most one persistent session per conversation. Once a request's
    /// history moves past a session it can never match again, so it is
    /// released before a replacement prefills.
    private var sessions: [UUID: SessionState] = [:]
    /// Incremented before every operation that invalidates model/session state.
    /// A generation captures this value before its first suspension and may only
    /// publish cached state if the value still matches when generation ends.
    private var stateRevision: UInt64 = 0
    private let maxPersistentSessions = 2
    private let promptPrefixCache: MLXPromptPrefixCache
    /// One generation at a time. A cancelled generation keeps the slot until
    /// its session has finished with the KV cache, which can take the rest of
    /// a prefill, so the next request never prefills alongside it.
    private var generationInProgress = false
    private var generationWaiters: [CheckedContinuation<Void, Never>] = []
    /// Writes the prompt prefixes the last request prefilled. Started once its
    /// response has been delivered, and awaited before the next generation or a
    /// model change, so the write never delays a first token or outlives the model.
    private var deferredPrefixSave: Task<Void, Never>?

    init(subsystem: String, promptPrefixCache: MLXPromptPrefixCache? = nil) {
        self.logger = Logger(subsystem: subsystem, category: "MLXInferenceWorker")
        self.promptPrefixCache = promptPrefixCache ?? MLXPromptPrefixCache(subsystem: subsystem)
    }

    func setLoadedModel(_ state: MLXLoadedModelState) async {
        await finishDeferredPrefixSave()
        stateRevision &+= 1
        let previousReservationTicket = loadedModel?.reservationTicket
        loadedModel = state
        await discardSessions(conversationIDs: Array(sessions.keys))
        if let previousReservationTicket {
            _ = await previousReservationTicket.end()
        }
    }

    func updateLoadedModelTuning(
        modelID: String,
        prefillStepSize: Int,
        activeBytesEstimate: Int
    ) {
        guard var loadedModel, loadedModel.model.id == modelID else { return }
        loadedModel.prefillStepSize = prefillStepSize
        loadedModel.activeBytesEstimate = max(0, activeBytesEstimate)
        self.loadedModel = loadedModel
    }

    func prefillStepSize(for modelID: String) -> Int {
        guard let loadedModel, loadedModel.model.id == modelID else {
            return MLXModelManager.defaultPrefillStepSize
        }
        return loadedModel.prefillStepSize
    }

    @discardableResult
    func clearLoadedModel(ifLoadID expectedLoadID: UUID? = nil) async -> Bool {
        if let expectedLoadID, loadedModel?.loadID != expectedLoadID {
            return false
        }
        await finishDeferredPrefixSave()
        if let expectedLoadID, loadedModel?.loadID != expectedLoadID {
            return false
        }
        stateRevision &+= 1
        let reservationTicket = loadedModel?.reservationTicket
        loadedModel = nil
        await discardSessions(conversationIDs: Array(sessions.keys))
        if let reservationTicket {
            _ = await reservationTicket.end()
        }
        return true
    }

    func invalidateConversation(_ conversationID: UUID, reason: String) async {
        // Bump even when no persistent session exists yet: an in-flight
        // generation may otherwise install one after this method returns.
        stateRevision &+= 1
        guard sessions[conversationID] != nil else { return }
        await discardSessions(conversationIDs: [conversationID])
        logger.notice(
            "MLX session invalidated: conversation=\(conversationID.uuidString, privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    func invalidateAll(reason: String) async {
        // Bump even when the cache is currently empty so in-flight generations
        // cannot repopulate it with state that predates this invalidation.
        stateRevision &+= 1
        guard !sessions.isEmpty else { return }
        await discardSessions(conversationIDs: Array(sessions.keys))
        logger.notice("MLX invalidated all sessions: reason=\(reason, privacy: .public)")
    }

    // MARK: - Generation

    func generate(
        request: MLXInferenceRequest,
        toolDispatch: (@Sendable (MLXToolCall) async throws -> String)?,
        onToken: @escaping @Sendable (String) -> Void,
        onToolCall: @escaping @Sendable (MLXToolCall) -> Void
    ) async throws -> MLXInferenceResponse {
        await acquireGenerationSlot()
        defer { releaseGenerationSlot() }
        await finishDeferredPrefixSave()

        guard let loadedModel, loadedModel.model.id == request.model.id else {
            throw MLXModelManager.GenerationError.modelNotLoaded
        }
        let generationStateRevision = stateRevision
        guard let latestUserMessage = request.messages.last else {
            throw MLXModelManager.GenerationError.invalidChatHistory
        }
        // Starts before session setup so time to first token includes any
        // prompt-prefix restore or prefill.
        let startedAt = Date()
        let history = Array(request.messages.dropLast())
        let cacheConfiguration = MLXSessionCacheConfiguration(parameters: request.params)

        let promptPrefixScope = MLXPromptPrefixCache.RequestScope()
        let acquired = try await acquireSession(
            request: request,
            loadedModel: loadedModel,
            history: history,
            cacheConfiguration: cacheConfiguration,
            promptPrefixScope: promptPrefixScope
        )
        let persistentSession = acquired.persistentSession
        persistentSession?.generateParameters = request.params
        persistentSession?.processing = request.processing
        persistentSession?.additionalContext = request.additionalContext
        persistentSession?.toolDispatch = nil

        Memory.peakMemory = 0
        var run = GenerationRun(
            startedAt: startedAt,
            prompt: latestUserMessage,
            tools: request.tools,
            history: history,
            promptPrefix: acquired.promptPrefix,
            promptPrefixScope: promptPrefixScope
        )
        let effectiveCachePolicy = MLXModelManager.cachePolicy(for: request.params)

        // Started and ended by hand rather than with `withWiredLimit`, whose
        // cancellation handler ends the ticket while a non-cancellable
        // prefill is still running.
        let activeTicket = makeActiveInferenceTicket(from: loadedModel)
        if let activeTicket {
            _ = await activeTicket.start()
        }
        MLXMemoryDiagnostics.log(logger, "generate.entry")

        do {
            try await streamResponse(
                &run,
                request: request,
                loadedModel: loadedModel,
                persistentSession: persistentSession,
                toolDispatch: toolDispatch,
                onToken: onToken,
                onToolCall: onToolCall
            )
        } catch {
            await releaseFailedGeneration(
                run,
                persistentSession: persistentSession,
                conversationID: request.conversationID,
                loadedModel: loadedModel,
                generationStateRevision: generationStateRevision
            )
            if let activeTicket {
                _ = await activeTicket.end()
            }
            // A stopped reply leaves a valid prefix behind; a failed one may not.
            if error is CancellationError {
                scheduleDeferredPrefixSave(promptPrefixScope, container: loadedModel.container)
            } else {
                promptPrefixScope.releaseHeldPrefixes()
            }
            throw error
        }
        if let activeTicket {
            _ = await activeTicket.end()
        }
        scheduleDeferredPrefixSave(promptPrefixScope, container: loadedModel.container)

        let finishedAt = Date()
        MLXMemoryDiagnostics.log(logger, "generate.end")

        if let persistentSession {
            await persistSession(
                persistentSession,
                request: request,
                history: history,
                prompt: latestUserMessage,
                cacheConfiguration: cacheConfiguration,
                reusedTranscript: acquired.reusedTranscript,
                cachedTokenCount: acquired.reusedTokenCount + run.cachedPromptTokenCount
                    + run.promptTokenCount + run.outputTokenCount,
                reply: run.assistantVisibleText,
                loadedModel: loadedModel,
                generationStateRevision: generationStateRevision,
                finishedAt: finishedAt
            )
        }

        let totalLatency = finishedAt.timeIntervalSince(startedAt)
        logger.notice(
            "MLX performance sample: conversation=\(request.conversationID.uuidString, privacy: .public) prompt_tokens=\(run.promptTokenCount, privacy: .public) output_tokens=\(run.outputTokenCount, privacy: .public) ttft=\(String(format: "%.3f", run.timeToFirstToken ?? 0), privacy: .public)s latency=\(String(format: "%.3f", totalLatency), privacy: .public)s tok_s=\(String(format: "%.2f", run.decodeTokensPerSecond ?? 0), privacy: .public) cache_policy=\(effectiveCachePolicy.diagnosticLabel, privacy: .public) max_kv=\(request.params.maxKVSize ?? -1, privacy: .public)"
        )

        return MLXInferenceResponse(
            toolInvocationCount: run.toolInvocationCount,
            metrics: run.metrics
        )
    }

    private func acquireGenerationSlot() async {
        while generationInProgress {
            await withCheckedContinuation { continuation in
                generationWaiters.append(continuation)
            }
        }
        generationInProgress = true
    }

    /// Writes what `scope` prefilled without making the finished request wait for it.
    private func scheduleDeferredPrefixSave(
        _ scope: MLXPromptPrefixCache.RequestScope,
        container: ModelContainer
    ) {
        scope.releaseHeldPrefixes()
        guard scope.hasPendingSaves else { return }
        let promptPrefixCache = promptPrefixCache
        let previous = deferredPrefixSave
        deferredPrefixSave = Task {
            await previous?.value
            await promptPrefixCache.writeDeferredSaves(of: scope, container: container)
        }
    }

    private func finishDeferredPrefixSave() async {
        guard let save = deferredPrefixSave else { return }
        await save.value
        // Another request may have scheduled a newer write while this one was awaited.
        if deferredPrefixSave == save {
            deferredPrefixSave = nil
        }
    }

    private func releaseGenerationSlot() {
        generationInProgress = false
        if !generationWaiters.isEmpty {
            generationWaiters.removeFirst().resume()
        }
    }

    // MARK: - Session Acquisition

    private func acquireSession(
        request: MLXInferenceRequest,
        loadedModel: MLXLoadedModelState,
        history: [Chat.Message],
        cacheConfiguration: MLXSessionCacheConfiguration,
        promptPrefixScope: MLXPromptPrefixCache.RequestScope
    ) async throws -> AcquiredSession {
        let conversationID = request.conversationID
        let usesExplicitMessageHistory =
            !request.tools.isEmpty &&
            MLXModelManager.requiresExplicitMessageHistoryForToolLoop(for: loadedModel.model)
        let decision: MLXSessionReuseDecision = if usesExplicitMessageHistory {
            .explicitMessageHistory
        } else if request.sessionKey.includesMedia {
            .mediaTurn
        } else {
            Self.sessionReuseDecision(
                stored: sessions[conversationID]?.descriptor,
                requestKey: request.sessionKey,
                requestCacheConfiguration: cacheConfiguration,
                history: history,
                continuesSessions: loadedModel.model.family.continuesPersistentSessions,
                sessionTokenLimit: request.sessionTokenLimit
            )
        }

        if decision == .reuse, var stored = sessions[conversationID] {
            stored.lastAccessed = Date()
            sessions[conversationID] = stored
            logger.notice("MLX reusing persistent chat session: conversation=\(conversationID.uuidString, privacy: .public)")
            return AcquiredSession(
                persistentSession: stored.session,
                promptPrefix: nil,
                reusedTranscript: stored.descriptor.transcript,
                reusedTokenCount: stored.descriptor.cachedTokenCount
            )
        }

        // Whatever this conversation's session holds can no longer match, so
        // its KV cache goes before the replacement below prefills.
        try await releasePersistentSessions(
            conversationIDs: Self.conversationsToRelease(
                scope: Self.staleSessionReleaseScope(
                    decision: decision,
                    maxKVSize: request.params.maxKVSize
                ),
                conversationID: conversationID,
                stored: sessions.keys
            ),
            reason: decision.diagnosticLabel,
            requestingConversationID: conversationID,
            expectedLoadID: loadedModel.loadID
        )

        switch decision {
        case .explicitMessageHistory:
            logger.notice(
                "MLX using explicit message-history tool loop: conversation=\(conversationID.uuidString, privacy: .public)"
            )
            return AcquiredSession(persistentSession: nil, promptPrefix: nil, reusedTranscript: nil)
        case .mediaTurn:
            logger.notice(
                "MLX not reusing persistent session for media turn: conversation=\(conversationID.uuidString, privacy: .public)"
            )
            return AcquiredSession(persistentSession: nil, promptPrefix: nil, reusedTranscript: nil)
        case .reuse, .noSession, .incompatibleKey, .cacheConfigurationChanged, .historyChanged,
             .sessionTooLong, .templateCannotContinue:
            break
        }

        if let promptPrefix = await promptPrefixCache.prefix(
            container: loadedModel.container,
            modelID: loadedModel.model.id,
            messages: request.messages,
            stableSystemPrompt: request.stableSystemPrompt,
            tools: request.tools,
            processing: request.processing,
            additionalContext: request.additionalContext,
            parameters: request.params,
            scope: promptPrefixScope
        ) {
            let session = ChatSession(
                loadedModel.container,
                cache: promptPrefix.cache,
                generateParameters: request.params,
                processing: request.processing,
                additionalContext: request.additionalContext,
                tools: request.tools,
                toolDispatch: nil
            )
            logger.notice("MLX created chat session from cached prompt prefix: conversation=\(conversationID.uuidString, privacy: .public) restored_tokens=\(promptPrefix.restoredTokenCount, privacy: .public) reason=\(decision.diagnosticLabel, privacy: .public)")
            return AcquiredSession(persistentSession: session, promptPrefix: promptPrefix, reusedTranscript: nil)
        }

        let session = ChatSession(
            loadedModel.container,
            history: history,
            generateParameters: request.params,
            processing: request.processing,
            additionalContext: request.additionalContext,
            tools: request.tools,
            toolDispatch: nil
        )
        logger.notice("MLX created fresh chat session: conversation=\(conversationID.uuidString, privacy: .public) reason=\(decision.diagnosticLabel, privacy: .public)")
        return AcquiredSession(persistentSession: session, promptPrefix: nil, reusedTranscript: nil)
    }

    /// Whether the session stored for a conversation can answer a request
    /// whose messages before the new prompt are `history`.
    nonisolated static func sessionReuseDecision(
        stored: MLXSessionDescriptor?,
        requestKey: MLXSessionKey,
        requestCacheConfiguration: MLXSessionCacheConfiguration,
        history: [Chat.Message],
        continuesSessions: Bool = true,
        sessionTokenLimit: Int? = nil
    ) -> MLXSessionReuseDecision {
        guard continuesSessions else { return .templateCannotContinue }
        guard let stored else { return .noSession }
        guard stored.key.canServe(requestKey) else { return .incompatibleKey }
        guard stored.cacheConfiguration == requestCacheConfiguration else { return .cacheConfigurationChanged }
        guard stored.transcript.isReplayed(by: history) else { return .historyChanged }
        if let sessionTokenLimit, stored.cachedTokenCount > sessionTokenLimit { return .sessionTooLong }
        return .reuse
    }

    /// Which persistent sessions a request releases before it prefills.
    nonisolated static func staleSessionReleaseScope(
        decision: MLXSessionReuseDecision,
        maxKVSize: Int?
    ) -> MLXPersistentSessionReleaseScope {
        switch decision {
        case .reuse:
            .none
        case .explicitMessageHistory:
            persistentSessionReleaseScope(usesExplicitMessageHistory: true, maxKVSize: maxKVSize)
        case .noSession, .incompatibleKey, .cacheConfigurationChanged, .historyChanged, .mediaTurn,
             .sessionTooLong, .templateCannotContinue:
            .conversation
        }
    }

    nonisolated static func conversationsToRelease(
        scope: MLXPersistentSessionReleaseScope,
        conversationID: UUID,
        stored: some Sequence<UUID>
    ) -> [UUID] {
        switch scope {
        case .none:
            []
        case .conversation:
            stored.filter { $0 == conversationID }
        case .all:
            Array(stored)
        }
    }

    nonisolated static func persistentSessionReleaseScope(
        usesExplicitMessageHistory: Bool,
        maxKVSize: Int?
    ) -> MLXPersistentSessionReleaseScope {
        guard usesExplicitMessageHistory else { return .none }
        return maxKVSize == nil ? .conversation : .all
    }

    // MARK: - Streaming

    private func streamResponse(
        _ run: inout GenerationRun,
        request: MLXInferenceRequest,
        loadedModel: MLXLoadedModelState,
        persistentSession: ChatSession?,
        toolDispatch: (@Sendable (MLXToolCall) async throws -> String)?,
        onToken: @escaping @Sendable (String) -> Void,
        onToolCall: @escaping @Sendable (MLXToolCall) -> Void
    ) async throws {
        var streamIteration = 0
        while true {
            streamIteration += 1
            try Task.checkCancellation()
            MLXMemoryDiagnostics.log(logger, "prefill.start", "iteration=\(streamIteration)")

            let (session, preparedInput) = await sessionForNextStream(
                &run,
                request: request,
                loadedModel: loadedModel,
                persistentSession: persistentSession
            )
            let result = try await consumeStream(
                of: session,
                preparedInput: preparedInput,
                streamIteration: streamIteration,
                suppressWrappedXMLToolMarkup: request.suppressWrappedXMLToolMarkup,
                run: &run,
                onToken: onToken,
                onToolCall: onToolCall
            )

            // The session's task can still hold the KV cache briefly after its
            // stream ends; let it finish before the cache is cleared, stored,
            // or another prefill starts.
            await session.synchronize()
            if persistentSession == nil {
                await session.clear()
                run.inFlightDisposableSession = nil
                Memory.clearCache()
                MLXMemoryDiagnostics.log(
                    logger, "disposable-session.cleared",
                    "iteration=\(streamIteration) reason=\(result.toolCall == nil ? "response-complete" : "tool-call")")
            }

            guard let toolCall = result.toolCall else { return }
            let continues = try await answerToolCall(
                toolCall,
                generatedText: result.visibleText,
                run: &run,
                request: request,
                loadedModel: loadedModel,
                toolDispatch: toolDispatch
            )
            guard continues else { return }
        }
    }

    private func sessionForNextStream(
        _ run: inout GenerationRun,
        request: MLXInferenceRequest,
        loadedModel: MLXLoadedModelState,
        persistentSession: ChatSession?
    ) async -> (ChatSession, LMInput?) {
        if let persistentSession {
            persistentSession.tools = run.tools
            let preparedInput = run.pendingPreparedInput
            run.pendingPreparedInput = nil
            return (persistentSession, preparedInput)
        }

        let session: ChatSession
        var preparedInput: LMInput?
        if let iterationPrefix = await promptPrefixCache.prefix(
            container: loadedModel.container,
            modelID: loadedModel.model.id,
            messages: run.explicitMessageHistory + [run.prompt],
            stableSystemPrompt: request.stableSystemPrompt,
            tools: run.tools,
            processing: request.processing,
            additionalContext: request.additionalContext,
            parameters: request.params,
            scope: run.promptPrefixScope,
            keepsPrefixForRequest: true
        ) {
            // Explicit-history tool loops rebuild the session every
            // iteration; the first restores (or prefills) the shared system
            // turn and the rest copy it from memory.
            run.record(iterationPrefix)
            session = ChatSession(
                loadedModel.container,
                cache: iterationPrefix.cache,
                generateParameters: request.params,
                processing: request.processing,
                additionalContext: request.additionalContext,
                tools: run.tools,
                toolDispatch: nil
            )
            preparedInput = iterationPrefix.remainingInput
        } else {
            session = ChatSession(
                loadedModel.container,
                history: run.explicitMessageHistory,
                generateParameters: request.params,
                processing: request.processing,
                additionalContext: request.additionalContext,
                tools: run.tools,
                toolDispatch: nil
            )
        }
        run.inFlightDisposableSession = session
        return (session, preparedInput)
    }

    private func consumeStream(
        of session: ChatSession,
        preparedInput: LMInput?,
        streamIteration: Int,
        suppressWrappedXMLToolMarkup: Bool,
        run: inout GenerationRun,
        onToken: @escaping @Sendable (String) -> Void,
        onToolCall: @escaping @Sendable (MLXToolCall) -> Void
    ) async throws -> StreamResult {
        var outputFilter = WrappedXMLToolCallStreamFilter(isEnabled: suppressWrappedXMLToolMarkup)
        var result = StreamResult()
        var chunkEventCount = 0
        // Each post-tool iteration reopens `<think>` in the prompt; keep
        // its reasoning a separate paragraph so it does not run into the
        // previous step and search results anchor between the two.
        var pendingSeparator = Self.iterationSeparator(
            afterVisibleText: run.assistantVisibleText,
            streamIteration: streamIteration
        )

        let generations = if let preparedInput {
            session.streamDetails(prepared: preparedInput)
        } else {
            session.streamDetails(
                to: run.prompt.content,
                role: run.prompt.role,
                images: run.prompt.images,
                videos: run.prompt.videos
            )
        }
        try await Self.forEachGeneration(in: generations) { generation in
            switch generation {
            case .chunk(let text):
                if run.firstTokenAt == nil {
                    run.firstTokenAt = Date()
                    MLXMemoryDiagnostics.log(logger, "first-token")
                }
                chunkEventCount += 1
                if chunkEventCount % 128 == 0 {
                    MLXMemoryDiagnostics.log(logger, "decode", "chunks=\(chunkEventCount)")
                }
                if let visibleChunk = outputFilter.consume(text), !visibleChunk.isEmpty {
                    result.visibleText += visibleChunk
                    let emitted = (pendingSeparator ?? "") + visibleChunk
                    pendingSeparator = nil
                    run.assistantVisibleText += emitted
                    onToken(emitted)
                }
                return .next
            case .toolCall(let toolCall):
                result.toolCall = toolCall
                MLXMemoryDiagnostics.log(logger, "tool-call.emitted")
                onToolCall(toolCall)
                outputFilter.didDispatchToolCall()
                return .stop
            case .info(let info):
                run.record(info)
                return .next
            }
        }

        if let trailingText = outputFilter.finish(), !trailingText.isEmpty {
            if run.firstTokenAt == nil {
                run.firstTokenAt = Date()
            }
            result.visibleText += trailingText
            let emitted = (pendingSeparator ?? "") + trailingText
            run.assistantVisibleText += emitted
            onToken(emitted)
        }
        return result
    }

    /// Feeds each element of one generation stream to `handle` until the
    /// stream ends or `handle` stops it. A consumer that is cancelled sees the
    /// stream simply end, without an error, so cancellation is rethrown here
    /// rather than passing for a finished response.
    nonisolated static func forEachGeneration<Generations: AsyncSequence>(
        in generations: Generations,
        _ handle: (Generation) async throws -> MLXStreamStep
    ) async throws where Generations.Element == Generation {
        for try await generation in generations {
            try Task.checkCancellation()
            if try await handle(generation) == .stop {
                return
            }
        }
        try Task.checkCancellation()
    }

    /// Runs the tool the model called and sets up the stream that answers it.
    /// Returns false when the response ends here instead.
    private func answerToolCall(
        _ toolCall: MLXToolCall,
        generatedText: String,
        run: inout GenerationRun,
        request: MLXInferenceRequest,
        loadedModel: MLXLoadedModelState,
        toolDispatch: (@Sendable (MLXToolCall) async throws -> String)?
    ) async throws -> Bool {
        run.toolInvocationCount += 1
        let invocationCount = run.toolInvocationCount
        if MLXModelManager.shouldEndToolLoop(afterInvocationCount: invocationCount) {
            logger.error(
                "MLX ending response: model kept calling tools after shutdown notice count=\(invocationCount, privacy: .public)"
            )
            return false
        }

        let toolResult: String
        if invocationCount > MLXModelManager.maxToolInvocationsPerResponse {
            logger.error(
                "MLX forcing tool shutdown after excessive tool calls: count=\(invocationCount, privacy: .public) max=\(MLXModelManager.maxToolInvocationsPerResponse, privacy: .public)"
            )
            toolResult = MLXModelManager.excessiveToolCallToolResponse(
                maximum: MLXModelManager.maxToolInvocationsPerResponse
            )
            run.tools = []
        } else {
            guard let toolDispatch else {
                throw MLXModelManager.GenerationError.missingToolDispatch
            }

            logger.notice("MLX dispatching tool call: name=\(toolCall.function.name, privacy: .public)")
            toolResult = try await toolDispatch(toolCall)
            MLXMemoryDiagnostics.log(logger, "tool.dispatched", "result_chars=\(toolResult.count)")
            if MLXModelManager.shouldDisableTools(after: toolResult) {
                logger.notice("MLX disabling tools for remainder of response after search limit was reached")
                run.tools = []
            } else if AppWebSearchToolBridge.isInternalToolErrorResponse(toolResult) {
                logger.notice("MLX received recoverable internal tool error; leaving tools enabled so the model can retry with corrected arguments")
                run.tools = request.tools
            }
        }

        // Unconditional: this is only ever read when there is no persistent
        // session and the loop rebuilds a session per iteration, which
        // includes media turns. Skipping it there dropped the current question
        // from every post-tool-call iteration. When a session is being reused
        // the value is never read, so appending is inert.
        run.explicitMessageHistory.append(run.prompt)
        if let assistantTurn = MLXModelManager.assistantToolCallTurnContent(
            for: loadedModel.model,
            generatedText: generatedText,
            toolCall: toolCall
        ) {
            run.explicitMessageHistory.append(.assistant(assistantTurn))
        }

        run.prompt = Chat.Message(
            role: MLXModelManager.toolResponsePromptRole(for: loadedModel.model),
            content: MLXModelManager.toolResponsePromptContent(
                for: loadedModel.model,
                toolResult: toolResult
            ),
            images: [],
            videos: []
        )
        return true
    }

    nonisolated static func iterationSeparator(
        afterVisibleText visibleText: String,
        streamIteration: Int
    ) -> String? {
        guard streamIteration > 1,
              !visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !visibleText.hasSuffix("\n\n") else { return nil }
        return visibleText.hasSuffix("\n") ? "\n" : "\n\n"
    }

    // MARK: - Session Lifecycle

    private func persistSession(
        _ session: ChatSession,
        request: MLXInferenceRequest,
        history: [Chat.Message],
        prompt: Chat.Message,
        cacheConfiguration: MLXSessionCacheConfiguration,
        reusedTranscript: MLXSessionTranscript?,
        cachedTokenCount: Int,
        reply: String,
        loadedModel: MLXLoadedModelState,
        generationStateRevision: UInt64,
        finishedAt: Date
    ) async {
        let conversationID = request.conversationID
        let ownsState = Self.generationStateIsCurrent(
            expectedLoadID: loadedModel.loadID,
            currentLoadID: self.loadedModel?.loadID,
            expectedStateRevision: generationStateRevision,
            currentStateRevision: stateRevision
        )
        // A blank reply is never replayed, so no later request could match, and a
        // model that cannot continue a session would only hold its KV in memory.
        let discardReason: String? = if !ownsState {
            "stale-generation"
        } else if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            "blank-reply"
        } else if !loadedModel.model.family.continuesPersistentSessions {
            "template-cannot-continue"
        } else {
            nil
        }
        if let discardReason {
            if sessions[conversationID]?.session === session {
                sessions.removeValue(forKey: conversationID)
            }
            await session.clear()
            Memory.clearCache()
            logger.notice(
                "MLX discarded generation session: conversation=\(conversationID.uuidString, privacy: .public) reason=\(discardReason, privacy: .public)"
            )
            return
        }

        let transcript = reusedTranscript.map {
            $0.advanced(replayedHistory: history, prompt: prompt, reply: reply)
        } ?? MLXSessionTranscript(history: history, prompt: prompt, reply: reply)
        sessions[conversationID] = SessionState(
            descriptor: MLXSessionDescriptor(
                key: request.sessionKey,
                cacheConfiguration: cacheConfiguration,
                transcript: transcript,
                cachedTokenCount: cachedTokenCount
            ),
            session: session,
            lastAccessed: finishedAt
        )
        await evictPersistentSessionsIfNeeded()
    }

    private func releaseFailedGeneration(
        _ run: GenerationRun,
        persistentSession: ChatSession?,
        conversationID: UUID,
        loadedModel: MLXLoadedModelState,
        generationStateRevision: UInt64
    ) async {
        let generationStillOwnsState = Self.generationStateIsCurrent(
            expectedLoadID: loadedModel.loadID,
            currentLoadID: self.loadedModel?.loadID,
            expectedStateRevision: generationStateRevision,
            currentStateRevision: stateRevision
        )
        var failedSessions: [ChatSession] = []
        // Never remove a session installed after this generation was
        // invalidated. The local sessions can still be cleared to release
        // any KV state they own.
        if generationStillOwnsState, let stored = sessions.removeValue(forKey: conversationID) {
            failedSessions.append(stored.session)
        }
        if let persistentSession, !failedSessions.contains(where: { $0 === persistentSession }) {
            failedSessions.append(persistentSession)
        }
        if let disposableSession = run.inFlightDisposableSession {
            failedSessions.append(disposableSession)
        }
        // `clear()` waits for exclusive access to the KV cache, so it also
        // waits out a stream that is still prefilling after cancellation.
        for session in failedSessions {
            await session.clear()
        }
        Memory.clearCache()
    }

    nonisolated static func generationStateIsCurrent(
        expectedLoadID: UUID,
        currentLoadID: UUID?,
        expectedStateRevision: UInt64,
        currentStateRevision: UInt64
    ) -> Bool {
        currentLoadID == expectedLoadID && currentStateRevision == expectedStateRevision
    }

    private func makeActiveInferenceTicket(from loadedModel: MLXLoadedModelState) -> MLX.WiredMemoryTicket? {
        let size = max(0, loadedModel.activeBytesEstimate)
        guard size > 0 else { return nil }
        return MLX.WiredMemoryTicket(
            size: size,
            policy: loadedModel.wiredMemoryPolicy,
            kind: .active
        )
    }

    private func releasePersistentSessions(
        conversationIDs: [UUID],
        reason: String,
        requestingConversationID: UUID,
        expectedLoadID: UUID
    ) async throws {
        guard !conversationIDs.isEmpty else { return }
        let discardedSessions = conversationIDs.compactMap { conversationID -> ChatSession? in
            sessions.removeValue(forKey: conversationID)?.session
        }
        for session in discardedSessions {
            await session.clear()
        }

        // An invalidation that ran meanwhile only stops this turn from
        // storing its session; an unloaded model ends the turn.
        guard loadedModel?.loadID == expectedLoadID else {
            throw MLXModelManager.GenerationError.modelNotLoaded
        }

        // MLX retains freed buffers in its allocator cache. Releasing them here
        // prevents a fresh full-history prefill from overlapping old KV
        // allocations on memory-constrained devices.
        Memory.clearCache()
        logger.notice(
            "MLX released persistent sessions before prefill: reason=\(reason, privacy: .public) count=\(discardedSessions.count, privacy: .public) conversation=\(requestingConversationID.uuidString, privacy: .public)"
        )
    }

    private func evictPersistentSessionsIfNeeded() async {
        guard sessions.count > maxPersistentSessions else { return }
        let overflow = sessions.count - maxPersistentSessions
        let conversationIDs = sessions
            .sorted { $0.value.lastAccessed < $1.value.lastAccessed }
            .prefix(overflow)
            .map(\.key)
        await discardSessions(conversationIDs: conversationIDs)
        logger.notice("MLX evicted \(conversationIDs.count, privacy: .public) persistent session(s) to cap KV memory")
    }

    /// Removes session ownership before awaiting cache teardown so no later
    /// actor re-entry can observe a session whose cache is being cleared.
    private func discardSessions(conversationIDs: [UUID]) async {
        let discardedSessions = conversationIDs.compactMap { conversationID in
            sessions.removeValue(forKey: conversationID)?.session
        }
        guard !discardedSessions.isEmpty else { return }
        for session in discardedSessions {
            await session.clear()
        }
        Memory.clearCache()
    }
}
