//
//  MLXModelManager+Catalog
//  Minnow
//
//  Split out of MLXModelManager.swift as part of the Type+Concern organization.
//

import Foundation
import OSLog

extension MLXModelManager {
    // MARK: - Catalog

    static let uiTestFakeDownloadsArgument = "-ui-test-fake-mlx-downloads"
    /// With fake downloads, finishes them in well under a second instead of holding
    /// them in progress for tests that look at the progress UI.
    static let uiTestFastFakeDownloadsArgument = "-ui-test-fast-fake-mlx-downloads"
    /// Model directories left behind by superseded releases. Nothing in
    /// `modelDefinitions` refers to them, so the picker cannot show or delete
    /// them; they are removed at startup instead of stranding gigabytes in
    /// Documents.
    nonisolated private static let obsoleteModelDirNames = [
        "Qwen3.5-4B-MLX-mixed36",
        "SmolLM3-3B-MLX-4bit"
    ]

    static let modelDefinitions: [MLXModelInfo] = [
        MLXModelInfo(
            id: "qwen3.5-4b-4bit-hybrid",
            name: "Qwen 3.5",
            localDirName: "Qwen3.5-4B-MLX-4bit-hybrid",
            hfRepoId: "Spakie/Qwen3.5-4B-MLX-4bit-hybrid",
            hfRevision: "f9baa8c99dab634c59929a36ee6117f2b4885022",
            parameters: "4B (4-bit hybrid)",
            downloadSizeLabel: "2.66 GB",
            downloadSizeBytes: 2_660_000_000,
            loadPolicy: .qwenMultimodal,
            description: "Qwen 3.5 4B multimodal model with native reasoning and vision.",
            contextLength: 262144,
            isAvailable: false,
            supportsReasoning: true,
            supportsNativeImages: true,
            requiredProcessorClass: "Qwen3VLProcessor",
            minimumPhoneMemoryBytes: 8 * MLXDeviceSupportProfile.gibibyte,
            minimumPhoneMemoryForToolCallsBytes: 8 * MLXDeviceSupportProfile.gibibyte
        ),
        MLXModelInfo(
            id: "qwen3.5-2b-4bit",
            name: "Qwen 3.5",
            localDirName: "Qwen3.5-2B-MLX-4bit",
            hfRepoId: "mlx-community/Qwen3.5-2B-4bit",
            hfRevision: "674aaa7240b91e8012fcad5d791b7dfe5ba90207",
            parameters: "2B (4-bit)",
            downloadSizeLabel: "1.75 GB",
            downloadSizeBytes: 1_750_000_000,
            loadPolicy: .qwenMultimodal,
            description: "Qwen 3.5 2B multimodal model with native reasoning and vision.",
            contextLength: 262144,
            isAvailable: false,
            supportsReasoning: true,
            supportsNativeImages: true,
            requiredProcessorClass: "Qwen3VLProcessor",
            minimumPhoneMemoryBytes: 6 * MLXDeviceSupportProfile.gibibyte,
            minimumPhoneMemoryForToolCallsBytes: 8 * MLXDeviceSupportProfile.gibibyte
        ),
        MLXModelInfo(
            id: "qwen3.5-0.8b-4bit",
            name: "Qwen 3.5",
            localDirName: "Qwen3.5-0.8B-MLX-4bit",
            hfRepoId: "mlx-community/Qwen3.5-0.8B-4bit",
            hfRevision: "da28692b5f139cb0ec58a356b437486b7dac7462",
            parameters: "0.8B (4-bit)",
            downloadSizeLabel: "625 MB",
            downloadSizeBytes: 625_000_000,
            loadPolicy: .qwenMultimodal,
            description: "Qwen 3.5 0.8B multimodal model with native reasoning and vision.",
            contextLength: 262144,
            isAvailable: false,
            supportsReasoning: true,
            supportsNativeImages: true,
            requiredProcessorClass: "Qwen3VLProcessor",
            minimumPhoneMemoryBytes: 4 * MLXDeviceSupportProfile.gibibyte,
            minimumPhoneMemoryForToolCallsBytes: 6 * MLXDeviceSupportProfile.gibibyte,
            phoneContextWindowOverride: [8: 4_096, 12: 6_144]
        ),
        MLXModelInfo(
            id: "lfm2.5-2.6b-4bit",
            name: "LFM2.5",
            localDirName: "LFM2.5-2.6B-MLX-4bit",
            hfRepoId: "LiquidAI/LFM2.5-2.6B-MLX-4bit",
            hfRevision: "04efa23776ce61ec34ec95ec34c859854c89542b",
            parameters: "2.6B (4-bit)",
            downloadSizeLabel: "1.60 GB",
            downloadSizeBytes: 1_600_000_000,
            loadPolicy: .standard,
            description: "LiquidAI LFM2.5 2.6B text model with always-on reasoning and tool calling.",
            contextLength: 131072,
            isAvailable: false,
            supportsReasoning: true,
            supportsNativeImages: false,
            requiredProcessorClass: nil,
            minimumPhoneMemoryBytes: 6 * MLXDeviceSupportProfile.gibibyte,
            minimumPhoneMemoryForToolCallsBytes: 8 * MLXDeviceSupportProfile.gibibyte
        )
    ]

    // MARK: - Model Directory (Documents)

    func modelDirectoryURL(for info: MLXModelInfo) -> URL? {
        let dir = documentsDirectory.appendingPathComponent("Models/\(info.localDirName)")
        let config = dir.appendingPathComponent("config.json")
        return FileManager.default.fileExists(atPath: config.path) ? dir : nil
    }

    func installationStatus(for info: MLXModelInfo) -> ModelInstallationStatus {
        installationStatus(for: info, scan: nil)
    }

    /// Combines a package scan with device limits. `scan` is read from disk
    /// when the caller has none; only the scan touches the file system.
    func installationStatus(for info: MLXModelInfo, scan: ModelPackageScan?) -> ModelInstallationStatus {
        if Self.isUITestFakeDownloadsEnabled {
            if simulatedDownloadedModelIDs.contains(info.id) {
                return ModelInstallationStatus(isInstalled: true, isCompatible: true, compatibilityError: nil)
            }
            return ModelInstallationStatus(isInstalled: false, isCompatible: true, compatibilityError: nil)
        }

        let scan = scan ?? Self.scanModelPackage(at: packageDirectoryURL(for: info))
        if let metadata = scan.metadata {
            packageMetadataCache[info.id] = metadata
        }
        let hasConfig = scan.hasConfig
        let hasWeights = scan.hasWeights

        if let deviceIssue = deviceSupportProfile.availabilityIssue(for: info) {
            return ModelInstallationStatus(
                isInstalled: hasConfig && hasWeights,
                isCompatible: false,
                compatibilityError: deviceIssue
            )
        }

        guard hasConfig else {
            return ModelInstallationStatus(isInstalled: false, isCompatible: false, compatibilityError: nil)
        }
        guard hasWeights else {
            return ModelInstallationStatus(isInstalled: false, isCompatible: false, compatibilityError: nil)
        }

        guard info.supportsNativeImages else {
            return ModelInstallationStatus(isInstalled: true, isCompatible: true, compatibilityError: nil)
        }

        guard let expectedProcessor = info.requiredProcessorClass else {
            return ModelInstallationStatus(isInstalled: true, isCompatible: true, compatibilityError: nil)
        }

        let detectedProcessorClass = scan.metadata?.processorClass

        guard let detectedProcessorClass else {
            return ModelInstallationStatus(
                isInstalled: true,
                isCompatible: false,
                compatibilityError:
                    String(localized: "Installed model '\(info.localDirName)' is missing processor metadata for native image support. Re-download \(info.localDirName) to enable native images.", bundle: .appLocalized)
            )
        }

        guard detectedProcessorClass == expectedProcessor else {
            return ModelInstallationStatus(
                isInstalled: true,
                isCompatible: false,
                compatibilityError:
                    String(localized: "Installed model '\(info.localDirName)' is incompatible with native image support (processor '\(detectedProcessorClass)'). Re-download \(info.localDirName) to get the correct multimodal files.", bundle: .appLocalized)
            )
        }

        return ModelInstallationStatus(isInstalled: true, isCompatible: true, compatibilityError: nil)
    }

    /// `Documents/Models/<localDirName>`, whether or not it exists.
    func packageDirectoryURL(for info: MLXModelInfo) -> URL {
        documentsDirectory.appendingPathComponent("Models/\(info.localDirName)")
    }

    func compatibilityError(for info: MLXModelInfo) -> String? {
        compatibilityErrors[info.id]
    }

    static var isUITestFakeDownloadsEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(uiTestFakeDownloadsArgument)
    }

    static var isUITestFastFakeDownloadsEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(uiTestFastFakeDownloadsArgument)
    }

    func availabilityIssue(for info: MLXModelInfo) -> String? {
        compatibilityError(for: info)
    }

    func supportsToolCalls(for info: MLXModelInfo) -> Bool {
        deviceSupportProfile.supportsToolCalls(for: info)
    }

    func toolCallIssue(for info: MLXModelInfo) -> String? {
        deviceSupportProfile.toolCallIssue(for: info)
    }

    func packageArchitecture(for info: MLXModelInfo) -> String? {
        packageMetadata(for: info)?.architecture
    }
    /// Removes superseded model directories and interrupted deletions. Both
    /// can be gigabytes, so the removal runs off the main actor.
    func removeObsoleteModelDirectories() {
        let modelsDir = documentsDirectory.appendingPathComponent("Models", isDirectory: true)
        let fm = FileManager.default
        var leftovers = Self.obsoleteModelDirNames
            .map { modelsDir.appendingPathComponent($0, isDirectory: true) }
            .filter { fm.fileExists(atPath: $0.path) }
        let contents = (try? fm.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil)) ?? []
        leftovers += contents.filter { $0.lastPathComponent.hasSuffix(Self.pendingDeletionSuffix) }
        guard !leftovers.isEmpty else { return }
        let logger = logger
        Task {
            for url in leftovers {
                do {
                    try await Self.removeItemInBackground(at: url)
                    logger.notice("Removed obsolete model directory '\(url.lastPathComponent, privacy: .public)' from Documents/Models/")
                } catch {
                    logger.error("Could not remove obsolete model directory '\(url.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: - File System Work

    nonisolated static let pendingDeletionSuffix = ".deleting"

    /// What a model package directory holds, read without any main-actor state.
    nonisolated struct ModelPackageScan: Sendable {
        let hasConfig: Bool
        let hasWeights: Bool
        let metadata: ModelPackageMetadata?
    }

    nonisolated static func scanModelPackage(at directory: URL) -> ModelPackageScan {
        let fm = FileManager.default
        let configURL = directory.appendingPathComponent("config.json")
        let hasConfig = fm.fileExists(atPath: configURL.path)
        guard hasConfig else {
            return ModelPackageScan(hasConfig: false, hasWeights: false, metadata: nil)
        }
        let contents = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        let hasWeights = contents.contains(where: { $0.hasSuffix(".safetensors") })
        return ModelPackageScan(
            hasConfig: true,
            hasWeights: hasWeights,
            metadata: readPackageMetadata(in: directory)
        )
    }

    @concurrent
    nonisolated static func scanModelPackagesInBackground(
        _ directories: [String: URL]
    ) async -> [String: ModelPackageScan] {
        directories.mapValues { scanModelPackage(at: $0) }
    }

    @concurrent
    nonisolated static func removeItemInBackground(at url: URL) async throws {
        try FileManager.default.removeItem(at: url)
    }

    nonisolated static func readPackageMetadata(in modelURL: URL) -> ModelPackageMetadata {
        let configURL = modelURL.appendingPathComponent("config.json")
        let configJSON = (
            (try? Data(contentsOf: configURL))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        ) ?? [:]
        let architecture = (configJSON["architectures"] as? [String])?.first
        let modelType = configJSON["model_type"] as? String

        let processorURLCandidates = [
            modelURL.appendingPathComponent("preprocessor_config.json"),
            modelURL.appendingPathComponent("processor_config.json")
        ]

        var processorClass: String?
        for url in processorURLCandidates {
            guard let data = try? Data(contentsOf: url),
                  let rawObject = try? JSONSerialization.jsonObject(with: data),
                  let json = rawObject as? [String: Any],
                  let detected = json["processor_class"] as? String else {
                continue
            }
            processorClass = detected
            break
        }

        return ModelPackageMetadata(
            architecture: architecture,
            processorClass: processorClass,
            modelType: modelType
        )
    }

    // MARK: - Diagnostics / Management

    /// Re-reads every model package synchronously. Prefer
    /// `refreshModelAvailabilityInBackground` where the caller can await.
    ///
    /// - Parameter changedModelID: a model whose files were just replaced or
    ///   removed; its cached package and tool-template inspection are dropped.
    ///   Other models keep theirs, since their files did not change.
    func refreshModelAvailability(changedModelID: String? = nil) {
        availabilityRefreshGeneration += 1
        invalidatePackageCaches(for: changedModelID)
        applyAvailability(scans: [:])
    }

    /// Same as `refreshModelAvailability`, with the directory listings and
    /// JSON parsing done off the main actor.
    func refreshModelAvailabilityInBackground(changedModelID: String? = nil) async {
        availabilityRefreshGeneration += 1
        let generation = availabilityRefreshGeneration
        invalidatePackageCaches(for: changedModelID)
        let directories = Dictionary(
            uniqueKeysWithValues: availableModels.map { ($0.id, packageDirectoryURL(for: $0)) }
        )
        let scans = Self.isUITestFakeDownloadsEnabled
            ? [:]
            : await Self.scanModelPackagesInBackground(directories)
        // A delete or another refresh while this scan ran has already applied
        // newer file state.
        guard generation == availabilityRefreshGeneration else { return }
        applyAvailability(scans: scans)
    }

    private func invalidatePackageCaches(for changedModelID: String?) {
        guard let changedModelID else { return }
        toolTemplateInspectionCache.removeValue(forKey: changedModelID)
        packageMetadataCache.removeValue(forKey: changedModelID)
    }

    private func applyAvailability(scans: [String: ModelPackageScan]) {
        var errors: [String: String] = [:]
        availableModels = availableModels.map { model in
            var updated = model
            let status = installationStatus(for: model, scan: scans[model.id])
            updated.isAvailable = status.isInstalled && status.isCompatible
            if let error = status.compatibilityError {
                errors[model.id] = error
            }
            return updated
        }
        compatibilityErrors = errors
        if let currentModel,
           let refreshed = availableModels.first(where: { $0.id == currentModel.id }),
           !refreshed.isAvailable {
            tearDownCurrentModel(reason: "availability refresh invalidated \(currentModel.id)")
        }
    }

    func deleteModel(_ model: MLXModelInfo) throws {
        if isDownloading(modelID: model.id) {
            cancelDownload()
        }
        if pendingModelToLoad?.id == model.id {
            cancelCurrentLoad(reason: "delete \(model.id)", tearDownModel: false)
        }
        if currentModel?.id == model.id {
            tearDownCurrentModel(reason: "delete \(model.id)")
        }
        simulatedDownloadedModelIDs.remove(model.id)
        let dir = packageDirectoryURL(for: model)
        // Renaming is instant on the same volume; removing gigabytes of
        // weights is not, so that part runs off the main actor. A removal cut
        // short by the app exiting is finished at the next launch.
        let pendingDeletion = dir.deletingLastPathComponent().appendingPathComponent(
            ".\(model.localDirName).\(UUID().uuidString)\(Self.pendingDeletionSuffix)",
            isDirectory: true
        )
        do {
            try FileManager.default.moveItem(at: dir, to: pendingDeletion)
        } catch let error as NSError where error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError {
            refreshModelAvailability(changedModelID: model.id)
            removePromptPrefixEntries(forModelID: model.id)
            logger.debug("Model '\(model.localDirName, privacy: .public)' was not installed; nothing to delete")
            return
        }
        refreshModelAvailability(changedModelID: model.id)
        removePromptPrefixEntries(forModelID: model.id)
        logger.notice("Deleted model '\(model.localDirName, privacy: .public)' from Documents/Models/")
        let logger = logger
        Task {
            do {
                try await Self.removeItemInBackground(at: pendingDeletion)
            } catch {
                logger.error("Model files removal failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Saved prompt prefixes were computed with this model's weights; drop
    /// them when the weights are deleted or replaced.
    func removePromptPrefixEntries(forModelID modelID: String) {
        let prefixCache = promptPrefixCache
        Task {
            await Self.removePromptPrefixEntriesInBackground(prefixCache, modelID: modelID)
        }
    }

    @concurrent
    nonisolated private static func removePromptPrefixEntriesInBackground(
        _ prefixCache: MLXPromptPrefixCache,
        modelID: String
    ) async {
        prefixCache.removeEntries(forModelID: modelID)
    }

    func packageMetadata(for info: MLXModelInfo) -> ModelPackageMetadata? {
        if let cached = packageMetadataCache[info.id] {
            return cached
        }

        guard let modelURL = modelDirectoryURL(for: info) else {
            return nil
        }

        let metadata = Self.readPackageMetadata(in: modelURL)
        packageMetadataCache[info.id] = metadata
        return metadata
    }
}
