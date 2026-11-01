//
//  ChatViewModel.swift
//  ChatLLM
//
//  Created by Nevio on 10/24/25.
//

import Foundation
import SwiftData
import Combine
import UIKit
import FoundationModels
import os.log
@preconcurrency import MLXLMCommon

// Resolve ambiguities between MLXLMCommon and SwiftData/FoundationModels
typealias ModelContext = SwiftData.ModelContext

@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - Logging
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ChatLLM", category: "ChatViewModel")

    @Published var isGenerating = false {
        didSet { streamingState.isGenerating = isGenerating }
    }
    @Published var streamingMessageID: UUID? {
        didSet { streamingState.streamingMessageID = streamingMessageID }
    }
    /// The live status label for the streaming reply. Changes wait for the shimmer to finish
    /// its sweep; see `requestStreamingActivity(_:)`.
    @Published var streamingActivity: StreamingActivity = .loading {
        didSet { streamingState.activity = streamingActivity }
    }
    internal var pendingStreamingActivity: StreamingActivity?
    internal var streamingActivityTask: Task<Void, Never>?

    /// Mirrors `isGenerating`, `streamingMessageID` and `streamingActivity` with per-property
    /// observation, so a message cell can depend on its own streaming state alone instead of
    /// every `@Published` change of this object.
    let streamingState: ChatStreamingState

    /// Unsent composer contents. Kept here rather than in ChatView so they survive the view
    /// being rebuilt, e.g. when a size-class change swaps the iPhone drawer for the split view.
    var composerDraft = ComposerDraft()

    /// Regeneration lock to prevent concurrent regenerations. Published because `send` refuses
    /// new messages while it is set, so the composer can show that it can't send yet.
    @Published var isRegenerating = false

    /// True while a new message would be refused: a reply is streaming or a regeneration
    /// is waiting for the previous reply to unwind.
    var isBusy: Bool { isGenerating || isRegenerating }

    internal let backendBridge: ModelBackendBridge
    internal let defaults: UserDefaults
    internal let generator: LLMGenerator
    internal let context: ModelContext

    // Tavily search service (user-configurable). Published so the composer's
    // Web Search toggle updates when a key is added or removed mid-chat.
    @Published var searchService: TavilySearchService?
    private var keyChangeCancellable: AnyCancellable?
    private var modelPipelineResetCancellable: AnyCancellable?

    internal var nextOrder: Int {
        (conversation.messages.max(by: { $0.order < $1.order })?.order ?? -1) + 1
    }

    private(set) var conversation: Conversation

    // Track the active streaming task so we can cancel it
    internal var currentStreamTask: Task<Void, Never>?
    var currentGenerationTask: Task<Void, Never>?
    var generationTaskID: UUID?
    var streamingGenerationID: UUID?
    var scheduledRegenerationTask: Task<Void, Never>?
    /// Names the chat after a reply. It runs after the turn's lifecycle has ended, so the
    /// composer is usable while it runs; anything that changes the chat cancels it first.
    var autoNamingTask: Task<Void, Never>?
    var autoNamingTaskID: UUID?
    var isActive = true
    var activeGenerationID: UUID?
    let canPromoteDraft: Bool
    var didPromoteDraft = false

    // Serializes concurrent Foundation Models sessions via continuation queue.
    static let fmGate = FoundationModelsGate()

    internal var streamTimeouts = StreamTimeouts()

    /// Shortest gap between two repaints of a streaming reply. Tests set it to zero
    /// so every chunk is written straight away instead of depending on timing.
    internal var streamRepaintInterval: TimeInterval = 0.12

    /// True while a reply is waiting for a model load that was already running.
    internal var isWaitingForModelLoad = false

    // MARK: - Coalesced saving with optimized debouncing
    var pendingSaveTask: Task<Void, Never>?
    let saveInterval: Duration = .milliseconds(300) // Optimized for streaming performance
    var saveCount: Int = 0
    let forceSaveThreshold: Int = 25 // Balance between persistence and performance
    private var lifecycleSaveCancellables: [AnyCancellable] = []

    // MARK: - Initializer
    init(
        generator: LLMGenerator,
        context: ModelContext,
        conversation: Conversation,
        backendBridge: ModelBackendBridge? = nil,
        defaults: UserDefaults = .standard,
        observesAPIKeyChanges: Bool = true
    ) {
        self.backendBridge = backendBridge ?? .shared
        self.defaults = defaults
        self.generator = generator
        self.context = context
        self.conversation = conversation
        self.canPromoteDraft = conversation.modelContext == nil
        self.streamingState = ChatStreamingState()

        if observesAPIKeyChanges {
            loadTavilyAPIKey()

            keyChangeCancellable = NotificationCenter.default.publisher(for: TavilyAPIKeyStore.didChangeNotification)
                .sink { [weak self] _ in
                    self?.loadTavilyAPIKey(reloadingStore: true)
                }
        }

        modelPipelineResetCancellable = NotificationCenter.default.publisher(
            for: .modelPipelineWillReset, object: self.backendBridge
        )
        .sink { [weak self] _ in
            // The bridge posts synchronously on the main actor. Cancel before
            // it changes pipelines, rather than queueing a reset behind a new turn.
            MainActor.assumeIsolated { self?.cancelGeneration() }
        }

        // Streaming writes are saved through scheduleCoalescedSave(), which can
        // trail the model output by up to the force-save threshold plus the
        // debounce interval. Persist at the moments iOS is most likely to kill
        // the process — backgrounding, app switch, and memory-pressure jetsam —
        // so a mid-generation kill loses at most the tokens received since the
        // previous coalesced save, not the final tail.
        func makeLifecycleSaveSink(_ notification: Notification.Name) -> AnyCancellable {
            NotificationCenter.default.publisher(for: notification)
                .sink { [weak self] _ in
                    guard let self else { return }
                    // UIApplication lifecycle notifications are posted on the
                    // main thread, so run the save synchronously instead of
                    // hopping to a Task: a scheduled Task queues behind
                    // whatever the main actor is already doing — precisely the
                    // situation when memory-pressure jetsam is imminent.
                    MainActor.assumeIsolated {
                        // Skip unsent draft conversations: saving would promote
                        // an empty "New Chat" into the store just because the
                        // user backgrounded the app.
                        guard self.conversation.modelContext != nil else { return }
                        self.immediateSave()
                    }
                }
        }
        lifecycleSaveCancellables = [
            makeLifecycleSaveSink(UIApplication.willResignActiveNotification),
            makeLifecycleSaveSink(UIApplication.didEnterBackgroundNotification),
            makeLifecycleSaveSink(UIApplication.didReceiveMemoryWarningNotification)
        ]

        // The launch falls back to an in-memory store when the on-disk one was
        // too corrupted to open (see ChatLLMApp.makeModelContainer). Every save
        // then "succeeds" without persisting anything; say so loudly rather
        // than letting the durability guarantees silently evaporate.
        if context.container.configurations.contains(where: \.isStoredInMemoryOnly) {
            logger.error("SwiftData opened the in-memory fallback store; conversation persistence is NOT durable for this launch (the on-disk store could not be opened).")
        }
    }

    // Isolated so the Combine cancellables, which are not Sendable, are
    // released on the main actor that created them.
    isolated deinit {
        pendingSaveTask?.cancel()
        scheduledRegenerationTask?.cancel()
        autoNamingTask?.cancel()
        currentStreamTask?.cancel()
        currentGenerationTask?.cancel()
        keyChangeCancellable?.cancel()
        modelPipelineResetCancellable?.cancel()
        lifecycleSaveCancellables.forEach { $0.cancel() }
    }

}
