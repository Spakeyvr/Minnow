//
//  MLXDeviceSupportProfile.swift
//  Minnow
//
//  Centralizes device-specific MLX availability and tool-call limits.
//

import Foundation
import UIKit

struct MLXDeviceSupportProfile: Equatable, Sendable {
    static let gibibyte: UInt64 = 1024 * 1024 * 1024
    static let minimumMemoryForPersistentKVCacheBytes: UInt64 = 12 * gibibyte
    private static let commonPhoneMemoryTiersInGigabytes = [4, 6, 8, 12, 16]
    @MainActor static var current: Self {
        current(defaults: .standard)
    }

    /// This device, reading the RAM-precautions flag from `defaults`.
    @MainActor static func current(defaults: UserDefaults) -> Self {
        Self(
            isPhone: UIDevice.current.userInterfaceIdiom == .phone,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            ramPrecautionsDisabledOverride: nil,
            defaults: defaults
        )
    }

    let isPhone: Bool
    let physicalMemoryBytes: UInt64
    /// When nil the flag is read live from `defaults`, so toggling the Dev
    /// Settings option takes effect without recreating long-lived holders of
    /// this profile (e.g. MLXModelManager).
    let ramPrecautionsDisabledOverride: Bool?
    /// The settings store the flag is read from: the same one the owning
    /// manager observes, so an injected test suite controls both.
    let defaults: UserDefaults

    init(
        isPhone: Bool,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        ramPrecautionsDisabledOverride: Bool? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.isPhone = isPhone
        self.physicalMemoryBytes = physicalMemoryBytes
        self.ramPrecautionsDisabledOverride = ramPrecautionsDisabledOverride
        self.defaults = defaults
    }

    var ramPrecautionsDisabled: Bool {
        ramPrecautionsDisabledOverride
            ?? defaults.bool(forKey: AppSettingsKeys.disableRAMPrecautions)
    }

    func supportsModel(_ model: MLXModelManager.MLXModelInfo) -> Bool {
        guard isPhone, let minimumBytes = model.minimumPhoneMemoryBytes, !ramPrecautionsDisabled else {
            return true
        }
        return normalizedMemoryBytes >= minimumBytes
    }

    func supportsToolCalls(for model: MLXModelManager.MLXModelInfo) -> Bool {
        guard supportsModel(model) else {
            return false
        }
        guard isPhone, let minimumBytes = model.minimumPhoneMemoryForToolCallsBytes, !ramPrecautionsDisabled else {
            return true
        }
        return normalizedMemoryBytes >= minimumBytes
    }

    func availabilityIssue(for model: MLXModelManager.MLXModelInfo) -> String? {
        guard isPhone,
              !ramPrecautionsDisabled,
              let minimumBytes = model.minimumPhoneMemoryBytes,
              normalizedMemoryBytes < minimumBytes else {
            return nil
        }
        return String(localized: "\(model.displayName) requires an iPhone with at least \(Self.formattedGigabytes(minimumBytes)) GB of RAM.", bundle: .appLocalized)
    }

    func toolCallIssue(for model: MLXModelManager.MLXModelInfo) -> String? {
        guard supportsModel(model),
              isPhone,
              !ramPrecautionsDisabled,
              let minimumBytes = model.minimumPhoneMemoryForToolCallsBytes,
              normalizedMemoryBytes < minimumBytes else {
            return nil
        }
        return String(localized: "Web search and tool calls for \(model.displayName) require an iPhone with at least \(Self.formattedGigabytes(minimumBytes)) GB of RAM.", bundle: .appLocalized)
    }

    /// The device default, before any per-model override.
    var maxContextWindowTokens: Int {
        maxContextWindowTokens(for: nil)
    }

    /// The largest context window any catalog model gets on this device. The
    /// context-window setting is shared by all models, so its ceiling must
    /// include per-model overrides (Qwen 3.5 0.8B gets 4,096 tokens on 8 GB
    /// phones, above the 2,048 default). Each model still clamps the setting
    /// to its own maximum when it generates.
    var maxContextWindowTokensForAnyModel: Int {
        maxContextWindowTokens(forAnyOf: MLXModelManager.modelDefinitions)
    }

    /// The context-window slider's ceiling: the selected local model's own maximum, so
    /// the slider never offers tokens that model would clamp away, or the largest any
    /// model gets while no local model is selected.
    func contextWindowSettingMaximum(selectedModel: MLXModelManager.MLXModelInfo?) -> Int {
        guard let selectedModel else { return maxContextWindowTokensForAnyModel }
        return maxContextWindowTokens(for: selectedModel)
    }

    func maxContextWindowTokens(forAnyOf models: [MLXModelManager.MLXModelInfo]) -> Int {
        models.reduce(maxContextWindowTokens(for: nil)) { partial, model in
            max(partial, maxContextWindowTokens(for: model))
        }
    }

    func maxContextWindowTokens(for model: MLXModelManager.MLXModelInfo?) -> Int {
        let normalizedGigabytes = Int(normalizedMemoryBytes / Self.gibibyte)
        if isPhone, let overrides = model?.phoneContextWindowOverride {
            let tokens = overrides
                .filter { normalizedGigabytes >= $0.key }
                .max(by: { $0.key < $1.key })
                .map(\.value)
            if let tokens { return tokens }
        }
        if normalizedGigabytes >= 12 { return 6_144 }
        if normalizedGigabytes >= 8 { return 2_048 }
        return 1_024
    }

    var hasLowMemoryForPersistentKVCache: Bool {
        normalizedMemoryBytes < Self.minimumMemoryForPersistentKVCacheBytes
    }

    var normalizedMemoryBytes: UInt64 {
        guard isPhone else {
            return physicalMemoryBytes
        }

        let rawGiB = Double(physicalMemoryBytes) / Double(Self.gibibyte)
        if let bucketedTier = Self.commonPhoneMemoryTiersInGigabytes.first(where: {
            rawGiB >= Double($0) - 1.0 && rawGiB <= Double($0)
        }) {
            return UInt64(bucketedTier) * Self.gibibyte
        }

        return physicalMemoryBytes
    }

    private static func formattedGigabytes(_ bytes: UInt64) -> String {
        String(bytes / gibibyte)
    }
}
