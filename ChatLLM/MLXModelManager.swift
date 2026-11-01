//
//  MLXModelManager.swift
//  ChatLLM
//
//  Manages MLX-based language models downloaded to Documents/Models/.
//
//  The manager body is split into Type+Concern extension files:
//    MLXCachePolicy.swift              Shared cache-policy types
//    MLXModelManager+ModelInfo.swift    MLXModelInfo and generation result types
//    MLXModelManager+Catalog.swift      Model catalog, installation status, package metadata
//    MLXModelManager+Downloads.swift    Download lifecycle and partial-download cleanup
//    MLXModelManager+Loading.swift      Load/teardown lifecycle and shader pre-warming
//    MLXModelManager+Tuning.swift       Prefill-step-size benchmarking and persistence
//    MLXModelManager+Generation.swift   Generation configuration and stream orchestration
//    MLXModelManager+ToolCalling.swift  Tool-template inspection and tool-response formatting
//    MLXModelManager+Memory.swift       Memory pressure handling and teardown
//
//  Stored state lives here. All of it, published properties included, is
//  internal rather than private(set): Swift has no setter scope that spans an
//  extension in another file, so the Type+Concern files could not write it
//  otherwise. Code outside the manager should treat it as read-only and go
//  through methods such as `reportLoadError(_:)` and `clearLoadError()`.
//

import Foundation
import Combine
import MLX
import MLXLMCommon
import Tokenizers
import OSLog
import UIKit

// MARK: - MLXModelManager

@MainActor
final class MLXModelManager: ObservableObject {
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ChatLLM", category: "MLXModelManager")

    // MARK: - Published Properties

    @Published var availableModels: [MLXModelInfo] = []
    @Published var currentModel: MLXModelInfo?
    @Published var isLoading: Bool = false
    @Published var loadError: String?
    @Published var pendingModelToLoad: MLXModelInfo?

    @Published var downloadProgress: Double = 0
    @Published var isDownloading: Bool = false
    @Published var activeDownloadModelID: String?
    @Published var downloadError: String?
    @Published var downloadErrorModelID: String?


    // MARK: - State
    //
    // Internal (not private) so the Type+Concern extension files can share it.

    var container: ModelContainer?
    var loadTask: Task<Void, Never>?
    let downloader = ModelDownloader()
    var downloaderTask: Task<Void, Never>?
    /// Identifies the download started most recently. A superseded task must
    /// not reset state or cancel transfers that belong to a newer download.
    var activeDownloadRunID: UUID?
    private var memoryWarningCancellable: AnyCancellable?
    private var appWillResignActiveCancellable: AnyCancellable?
    private var appDidEnterBackgroundCancellable: AnyCancellable?
    private var settingsDidChangeCancellable: AnyCancellable?
    var compatibilityErrors: [String: String] = [:]
    var toolTemplateInspectionCache: [String: ToolTemplateInspection] = [:]
    var packageMetadataCache: [String: ModelPackageMetadata] = [:]
    /// Bumped by every availability refresh, so a background scan that finishes
    /// after a newer refresh does not overwrite it with older file state.
    var availabilityRefreshGeneration = 0
    var promptTokenCountCache = PromptTokenCountCache()
    var activeLoadID: UUID?
    var installedWorkerLoadID: UUID?
    var deferredPrewarmModelID: String?
    var deferredTuningModelID: String?
    var prewarmInFlightModelID: String?
    var tuningTask: Task<Void, Never>?
    /// Identifies `tuningTask`, so a finishing task only clears the property
    /// while it still refers to that task and not to a newer one.
    var tuningTaskID: UUID?
    /// Post-load shader prewarm. Tracked so teardown and a superseding load
    /// can cancel it instead of letting it hold the old container.
    var prewarmTask: Task<Void, Never>?
    var hasSeenMemoryWarningSinceCurrentLoad = false
    let deviceSupportProfile: MLXDeviceSupportProfile
    let inferenceWorker: MLXInferenceWorker
    /// Shared with `inferenceWorker`, so deleting or replacing a model can
    /// drop the prompt prefixes saved for its weights.
    let promptPrefixCache: MLXPromptPrefixCache
    var simulatedDownloadedModelIDs: Set<String> = []
    /// Sends a model's ID when its download finishes. Whether to load it is the
    /// backend bridge's call, since only it knows which model the chat is using.
    let downloadCompleted = PassthroughSubject<String, Never>()

    let documentsDirectory: URL
    let defaults: UserDefaults

    nonisolated struct ModelInstallationStatus: Sendable {
        let isInstalled: Bool
        let isCompatible: Bool
        let compatibilityError: String?
    }

    nonisolated struct ModelPackageMetadata: Sendable {
        let architecture: String?
        let processorClass: String?
        let modelType: String?
    }

    // MARK: - Init

    init(
        deviceSupportProfile: MLXDeviceSupportProfile? = nil,
        defaults: UserDefaults = .standard,
        documentsDirectory: URL? = nil,
        restoresBackgroundDownloads: Bool = true
    ) {
        self.defaults = defaults
        self.documentsDirectory = documentsDirectory ?? FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        MLXRuntimeConfiguration.configureForCurrentProcess()
        self.deviceSupportProfile = deviceSupportProfile ?? MLXDeviceSupportProfile.current(defaults: defaults)
        let subsystem = Bundle.main.bundleIdentifier ?? "ChatLLM"
        let promptPrefixCache = MLXPromptPrefixCache(subsystem: subsystem)
        self.promptPrefixCache = promptPrefixCache
        self.inferenceWorker = MLXInferenceWorker(
            subsystem: subsystem,
            promptPrefixCache: promptPrefixCache
        )
        removeObsoleteModelDirectories()
        // Re-downloadable weights must stay out of iCloud and device backups,
        // including models downloaded before the downloader set the flag.
        ModelDownloader.excludeFromBackup(
            self.documentsDirectory.appendingPathComponent("Models", isDirectory: true)
        )
        // Synchronous on purpose: the backend bridge may load the selected
        // model right after init, which needs availability. The scan reads
        // only a config and processor JSON per model; tokenizer files and
        // directory removal happen off the main actor.
        availableModels = Self.modelDefinitions
        refreshModelAvailability()

        memoryWarningCancellable = NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        )
        .sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMemoryWarning()
            }
        }

        appWillResignActiveCancellable = NotificationCenter.default.publisher(
            for: UIApplication.willResignActiveNotification
        )
        .sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleApplicationInactivity(reason: "application.will_resign_active")
            }
        }

        appDidEnterBackgroundCancellable = NotificationCenter.default.publisher(
            for: UIApplication.didEnterBackgroundNotification
        )
        .sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleApplicationInactivity(reason: "application.did_enter_background")
            }
        }

        // `UserDefaults.didChangeNotification` fires on every defaults write in
        // the process — including this manager's own prefill-tuning writes and
        // each of the ~13 keys a settings save persists. Collapse the stream to
        // actual transitions of the one flag before hopping to the main actor.
        // The notification is posted on whichever thread wrote the default, so
        // these closures are @Sendable rather than main-actor isolated.
        // UserDefaults is documented as thread-safe; it just isn't annotated Sendable.
        nonisolated(unsafe) let observedDefaults = defaults
        settingsDidChangeCancellable = NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification
        )
        .map { @Sendable _ in
            observedDefaults.bool(forKey: AppSettingsKeys.disableRAMPrecautions)
        }
        .prepend(defaults.bool(forKey: AppSettingsKeys.disableRAMPrecautions))
        .removeDuplicates()
        .dropFirst()
        .sink { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshModelAvailabilityInBackground()
            }
        }

        if restoresBackgroundDownloads { restoreBackgroundDownloadIfNeeded() }
    }

    // Isolated so the Combine cancellables, which are not Sendable, are
    // released on the main actor that created them.
    isolated deinit {
        memoryWarningCancellable?.cancel()
        appWillResignActiveCancellable?.cancel()
        appDidEnterBackgroundCancellable?.cancel()
        settingsDidChangeCancellable?.cancel()
    }

}
