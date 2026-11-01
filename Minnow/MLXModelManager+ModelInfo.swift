//
//  MLXModelManager+ModelInfo
//  Minnow
//
//  Split out of MLXModelManager.swift as part of the Type+Concern organization.
//

import Foundation

extension MLXModelManager {

    // MARK: - Model Info

    struct MLXModelInfo: Identifiable, Sendable {
        /// The checkpoint family. Sampling defaults, chat-template quirks and
        /// the tool-loop style follow from it, so behavior is keyed on this
        /// instead of model-ID strings scattered across files.
        nonisolated enum Family: Equatable, Sendable {
            case qwen35
            case lfm25
            case other

            /// Catalog IDs are `<family>-<size>-...`; this is the one place
            /// that maps those prefixes to a family.
            init(modelID: String) {
                if modelID.hasPrefix("qwen3.5-") {
                    self = .qwen35
                } else if modelID.hasPrefix("lfm2.5-") {
                    self = .lfm25
                } else {
                    self = .other
                }
            }

            /// The chat template always opens a thinking block.
            var alwaysOpensThinkingBlock: Bool { self == .lfm25 }

            /// Expects tool results as a user turn wrapped in `<tool_response>`.
            var prefersUserWrappedToolResponses: Bool { self == .qwen35 }

            /// Replays each tool round (assistant call, then result) as LFM2.5's
            /// template renders it.
            var usesLFMToolTurns: Bool { self == .lfm25 }

            var supportsReasoning: Bool { self != .other }

            /// Whether a persistent session can append the next turn. LFM2.5's
            /// template prepends BOS on every render, so a reused session would
            /// put a BOS token in the middle of the conversation.
            var continuesPersistentSessions: Bool { self != .lfm25 }
        }

        enum LoadPolicy: Equatable, Sendable {
            case standard
            case qwenMultimodal

            var packageDescription: String {
                switch self {
                case .standard:
                    return String(localized: "Standard package", bundle: .appLocalized)
                case .qwenMultimodal:
                    return String(localized: "Full multimodal package", bundle: .appLocalized)
                }
            }

            var architectureHint: String? {
                switch self {
                case .standard:
                    return nil
                case .qwenMultimodal:
                    return "Qwen3_5ForConditionalGeneration"
                }
            }

            var defersAutomaticPrewarm: Bool {
                switch self {
                case .standard:
                    return false
                case .qwenMultimodal:
                    return true
                }
            }
        }

        let id: String
        let family: Family
        let name: String
        let localDirName: String
        let hfRepoId: String
        /// Hugging Face commit the download is pinned to, so an upstream push
        /// cannot change or mix the files a given app build installs.
        let hfRevision: String
        let parameters: String
        let downloadSizeLabel: String
        /// When set, the size is formatted for the app language ("2,66 GB" in German)
        /// instead of showing `downloadSizeLabel` as written.
        let downloadSizeBytes: Int64?
        let loadPolicy: LoadPolicy
        private let descriptionValue: String.LocalizationValue
        let contextLength: Int
        var isAvailable: Bool
        let supportsReasoning: Bool
        let supportsNativeImages: Bool
        let requiredProcessorClass: String?
        let minimumPhoneMemoryBytes: UInt64?
        let minimumPhoneMemoryForToolCallsBytes: UInt64?
        /// Per-device-tier context window override. Keys are minimum RAM in GiB; the
        /// highest matching key wins. Falls through to the device default if no key matches.
        let phoneContextWindowOverride: [Int: Int]?

        init(
            id: String,
            name: String,
            localDirName: String,
            hfRepoId: String,
            hfRevision: String = "main",
            parameters: String,
            downloadSizeLabel: String,
            downloadSizeBytes: Int64? = nil,
            loadPolicy: LoadPolicy = .standard,
            description: String.LocalizationValue,
            contextLength: Int,
            isAvailable: Bool,
            supportsReasoning: Bool,
            supportsNativeImages: Bool = false,
            requiredProcessorClass: String? = nil,
            minimumPhoneMemoryBytes: UInt64? = nil,
            minimumPhoneMemoryForToolCallsBytes: UInt64? = nil,
            phoneContextWindowOverride: [Int: Int]? = nil,
            family: Family? = nil
        ) {
            self.id = id
            self.family = family ?? Family(modelID: id)
            self.name = name
            self.localDirName = localDirName
            self.hfRepoId = hfRepoId
            self.hfRevision = hfRevision
            self.parameters = parameters
            self.downloadSizeLabel = downloadSizeLabel
            self.downloadSizeBytes = downloadSizeBytes
            self.loadPolicy = loadPolicy
            self.descriptionValue = description
            self.contextLength = contextLength
            self.isAvailable = isAvailable
            self.supportsReasoning = supportsReasoning
            self.supportsNativeImages = supportsNativeImages
            self.requiredProcessorClass = requiredProcessorClass
            self.minimumPhoneMemoryBytes = minimumPhoneMemoryBytes
            self.minimumPhoneMemoryForToolCallsBytes = minimumPhoneMemoryForToolCallsBytes
            self.phoneContextWindowOverride = phoneContextWindowOverride
        }

        var description: String {
            String(localized: descriptionValue, bundle: .appLocalized)
        }

        /// This checkpoint always opens a thinking block in its chat template.
        var requiresReasoning: Bool { family.alwaysOpensThinkingBlock }

        func downloadSize(locale: Locale) -> String {
            downloadSizeBytes.map { $0.formatted(.byteCount(style: .file).locale(locale)) } ?? downloadSizeLabel
        }

        /// "Qwen 3.5 0.8B (4-bit)": `parameters` already carries its own parenthetical.
        var displayName: String { "\(name) \(parameters)" }

        var parameterCount: String {
            parameters.components(separatedBy: " ").first ?? parameters
        }

        var promptIdentity: String {
            let trimmedParameterCount = parameterCount.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedParameterCount.isEmpty else {
                return name
            }
            return "\(name) \(trimmedParameterCount)"
        }
    }
}
