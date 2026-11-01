import Foundation

nonisolated enum AppSettingsKeys {
    static let chatPreferences = "chatPreferences"
    static let legacyDefaultSystemPrompt = "defaultSystemPrompt"
    static let appAppearance = "appAppearance"
    static let appLanguage = "appLanguage"
    static let sendOnReturn = "sendOnReturn"
    static let enableHaptics = "enableHaptics"
    static let reasoningModeDefault = "reasoningModeDefault"
    static let messageFontSize = "messageFontSize"
    static let mlxMaxOutputTokens = "mlxMaxOutputTokens"
    static let mlxContextWindowTokens = "mlxContextWindowTokens"
    static let mlxEnableRotorQuant = "mlxEnableRotorQuant"
    static let mlxRepetitionPenalty = "mlxRepetitionPenalty"
    static let autoDeleteOldChats = "autoDeleteOldChats"
    static let autoDeleteDays = "autoDeleteDays"
    static let developerModeEnabled = "developerModeEnabled"
    static let disableRAMPrecautions = "disableRAMPrecautions"
    static let forcePersistentKVCache = "forcePersistentKVCache"
    static let overrideContextWindowLimit = "overrideContextWindowLimit"
    static let disableToolCalls = "disableToolCalls"
    static let selectedLLMBackend = "selectedLLMBackend"
    static let selectedCustomModelID = "selectedCustomModelID"
    static let hasCompletedOnboarding = "hasCompletedOnboarding"
}

/// Defaults that differ from the type's zero value, shared by `AppSettingsDraft.defaults()`
/// and the `UserDefaults` accessors that read a setting directly.
nonisolated enum AppSettingsDefaults {
    static let appAppearance = "system"
    static let enableHaptics = true
    static let messageFontSize = 16.0
    /// 0 leaves the output length to the model.
    static let mlxMaxOutputTokens = 0
    /// 0 uses the device maximum.
    static let mlxContextWindowTokens = 0
    static let mlxEnableRotorQuant = true
    static let mlxRepetitionPenalty = 1.0
    static let autoDeleteDays = 30
}

struct AppSettingsDraft: Equatable {
    var chatPreferences: String
    var appAppearance: String
    var appLanguage: String
    var tavilyApiKey: String
    var sendOnReturn: Bool
    var enableHaptics: Bool
    var reasoningModeDefault: Bool
    var messageFontSize: Double
    var mlxMaxOutputTokens: Int
    var mlxContextWindowTokens: Int
    var mlxEnableRotorQuant: Bool
    var mlxRepetitionPenalty: Double
    var autoDeleteOldChats: Bool
    var autoDeleteDays: Int
    var developerModeEnabled: Bool
    var disableRAMPrecautions: Bool
    var forcePersistentKVCache: Bool
    var overrideContextWindowLimit: Bool
    var disableToolCalls: Bool

    /// Saved settings, with `defaults()` filling in every value that was never saved.
    static func load(from defaults: UserDefaults = .standard) -> Self {
        func ifSaved<Value>(_ key: String, _ read: () -> Value) -> Value? {
            defaults.object(forKey: key) == nil ? nil : read()
        }

        var draft = Self.defaults()
        if let chatPreferences = defaults.string(forKey: AppSettingsKeys.chatPreferences)
            ?? defaults.string(forKey: AppSettingsKeys.legacyDefaultSystemPrompt) {
            draft.chatPreferences = chatPreferences
        }
        if let appAppearance = defaults.string(forKey: AppSettingsKeys.appAppearance) {
            draft.appAppearance = appAppearance
        }
        if let appLanguage = defaults.string(forKey: AppSettingsKeys.appLanguage) {
            draft.appLanguage = AppLanguage.resolve(appLanguage).rawValue
        }
        if let tavilyApiKey = TavilyAPIKeyStore.currentKey(userDefaults: defaults) {
            draft.tavilyApiKey = tavilyApiKey
        }
        // The typed accessors also clamp saved values into their valid range.
        if let value = ifSaved(AppSettingsKeys.sendOnReturn, { defaults.sendOnReturn }) {
            draft.sendOnReturn = value
        }
        if let value = ifSaved(AppSettingsKeys.enableHaptics, { defaults.enableHapticsPreference }) {
            draft.enableHaptics = value
        }
        if let value = ifSaved(AppSettingsKeys.reasoningModeDefault, { defaults.bool(forKey: AppSettingsKeys.reasoningModeDefault) }) {
            draft.reasoningModeDefault = value
        }
        if let value = ifSaved(AppSettingsKeys.messageFontSize, { defaults.double(forKey: AppSettingsKeys.messageFontSize) }) {
            draft.messageFontSize = value
        }
        if let value = ifSaved(AppSettingsKeys.mlxMaxOutputTokens, { defaults.mlxMaxOutputTokens }) {
            draft.mlxMaxOutputTokens = value
        }
        if let value = ifSaved(AppSettingsKeys.mlxContextWindowTokens, { defaults.integer(forKey: AppSettingsKeys.mlxContextWindowTokens) }) {
            draft.mlxContextWindowTokens = value
        }
        if let value = ifSaved(AppSettingsKeys.mlxEnableRotorQuant, { defaults.mlxEnableRotorQuant }) {
            draft.mlxEnableRotorQuant = value
        }
        if let value = ifSaved(AppSettingsKeys.mlxRepetitionPenalty, { defaults.mlxRepetitionPenalty }) {
            draft.mlxRepetitionPenalty = value
        }
        if let value = ifSaved(AppSettingsKeys.autoDeleteOldChats, { defaults.bool(forKey: AppSettingsKeys.autoDeleteOldChats) }) {
            draft.autoDeleteOldChats = value
        }
        if let value = ifSaved(AppSettingsKeys.autoDeleteDays, { defaults.integer(forKey: AppSettingsKeys.autoDeleteDays) }) {
            draft.autoDeleteDays = value
        }
        if let value = ifSaved(AppSettingsKeys.developerModeEnabled, { defaults.bool(forKey: AppSettingsKeys.developerModeEnabled) }) {
            draft.developerModeEnabled = value
        }
        if let value = ifSaved(AppSettingsKeys.disableRAMPrecautions, { defaults.bool(forKey: AppSettingsKeys.disableRAMPrecautions) }) {
            draft.disableRAMPrecautions = value
        }
        if let value = ifSaved(AppSettingsKeys.forcePersistentKVCache, { defaults.bool(forKey: AppSettingsKeys.forcePersistentKVCache) }) {
            draft.forcePersistentKVCache = value
        }
        if let value = ifSaved(AppSettingsKeys.overrideContextWindowLimit, { defaults.bool(forKey: AppSettingsKeys.overrideContextWindowLimit) }) {
            draft.overrideContextWindowLimit = value
        }
        if let value = ifSaved(AppSettingsKeys.disableToolCalls, { defaults.disableToolCalls }) {
            draft.disableToolCalls = value
        }
        return draft
    }

    /// Every setting's value on a fresh install and after Reset All Settings.
    static func defaults() -> Self {
        Self(
            chatPreferences: "",
            appAppearance: AppSettingsDefaults.appAppearance,
            appLanguage: AppLanguage.systemDefault.rawValue,
            tavilyApiKey: "",
            sendOnReturn: false,
            enableHaptics: AppSettingsDefaults.enableHaptics,
            reasoningModeDefault: false,
            messageFontSize: AppSettingsDefaults.messageFontSize,
            mlxMaxOutputTokens: AppSettingsDefaults.mlxMaxOutputTokens,
            mlxContextWindowTokens: AppSettingsDefaults.mlxContextWindowTokens,
            mlxEnableRotorQuant: AppSettingsDefaults.mlxEnableRotorQuant,
            mlxRepetitionPenalty: AppSettingsDefaults.mlxRepetitionPenalty,
            autoDeleteOldChats: false,
            autoDeleteDays: AppSettingsDefaults.autoDeleteDays,
            developerModeEnabled: false,
            disableRAMPrecautions: false,
            forcePersistentKVCache: false,
            overrideContextWindowLimit: false,
            disableToolCalls: false
        )
    }

    mutating func resetToDefaults() {
        self = Self.defaults()
    }

    // Live settings edits pass the prior snapshot so an unrelated preference
    // never rewrites credentials or overwrites values changed elsewhere.
    /// Returns false when the Tavily key could not be stored; every other setting is
    /// saved regardless. `saveTavilyKey` stands in for the Keychain in tests.
    @discardableResult
    func persist(
        to defaults: UserDefaults = .standard,
        comparedTo previous: Self? = nil,
        saveTavilyKey: (String, UserDefaults) -> Bool = { key, defaults in
            TavilyAPIKeyStore.save(key, userDefaults: defaults)
        }
    ) -> Bool {
        if previous?.chatPreferences != chatPreferences || defaults.object(forKey: AppSettingsKeys.legacyDefaultSystemPrompt) != nil {
            defaults.set(chatPreferences, forKey: AppSettingsKeys.chatPreferences)
            defaults.removeObject(forKey: AppSettingsKeys.legacyDefaultSystemPrompt)
        }
        if previous?.appAppearance != appAppearance {
            defaults.set(appAppearance, forKey: AppSettingsKeys.appAppearance)
        }
        if previous?.appLanguage != appLanguage {
            defaults.set(appLanguage, forKey: AppSettingsKeys.appLanguage)
        }
        if previous?.sendOnReturn != sendOnReturn {
            defaults.sendOnReturn = sendOnReturn
        }
        if previous?.enableHaptics != enableHaptics {
            defaults.enableHapticsPreference = enableHaptics
        }
        if previous?.reasoningModeDefault != reasoningModeDefault {
            defaults.set(reasoningModeDefault, forKey: AppSettingsKeys.reasoningModeDefault)
        }
        if previous?.messageFontSize != messageFontSize {
            defaults.set(messageFontSize, forKey: AppSettingsKeys.messageFontSize)
        }
        if previous?.mlxMaxOutputTokens != mlxMaxOutputTokens {
            defaults.mlxMaxOutputTokens = mlxMaxOutputTokens
        }
        if previous?.mlxContextWindowTokens != mlxContextWindowTokens {
            defaults.set(mlxContextWindowTokens, forKey: AppSettingsKeys.mlxContextWindowTokens)
        }
        if previous?.mlxEnableRotorQuant != mlxEnableRotorQuant {
            defaults.mlxEnableRotorQuant = mlxEnableRotorQuant
        }
        if previous?.mlxRepetitionPenalty != mlxRepetitionPenalty {
            defaults.mlxRepetitionPenalty = mlxRepetitionPenalty
        }
        if previous?.autoDeleteOldChats != autoDeleteOldChats {
            defaults.set(autoDeleteOldChats, forKey: AppSettingsKeys.autoDeleteOldChats)
        }
        if previous?.autoDeleteDays != autoDeleteDays {
            defaults.set(autoDeleteDays, forKey: AppSettingsKeys.autoDeleteDays)
        }
        if previous?.developerModeEnabled != developerModeEnabled {
            defaults.set(developerModeEnabled, forKey: AppSettingsKeys.developerModeEnabled)
        }
        if previous?.disableRAMPrecautions != disableRAMPrecautions {
            defaults.set(disableRAMPrecautions, forKey: AppSettingsKeys.disableRAMPrecautions)
        }
        if previous?.forcePersistentKVCache != forcePersistentKVCache {
            defaults.set(forcePersistentKVCache, forKey: AppSettingsKeys.forcePersistentKVCache)
        }
        if previous?.overrideContextWindowLimit != overrideContextWindowLimit {
            defaults.set(overrideContextWindowLimit, forKey: AppSettingsKeys.overrideContextWindowLimit)
        }
        if previous?.disableToolCalls != disableToolCalls {
            defaults.disableToolCalls = disableToolCalls
        }

        let trimmedKey = tavilyApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard previous == nil || previous?.tavilyApiKey.trimmingCharacters(in: .whitespacesAndNewlines) != trimmedKey else {
            return true
        }
        // An empty key clears the stored key.
        return saveTavilyKey(trimmedKey, defaults)
    }

    /// The draft to show after `persist` returned false: the Tavily key goes back to
    /// the one still stored, so Settings never shows a key that wasn't saved.
    func revertingTavilyKey(to previous: Self) -> Self {
        var reverted = self
        reverted.tavilyApiKey = previous.tavilyApiKey
        return reverted
    }

}

extension UserDefaults {
    var sendOnReturn: Bool {
        get { bool(forKey: AppSettingsKeys.sendOnReturn) }
        set { set(newValue, forKey: AppSettingsKeys.sendOnReturn) }
    }

    var enableHapticsPreference: Bool {
        get {
            guard object(forKey: AppSettingsKeys.enableHaptics) != nil else {
                return AppSettingsDefaults.enableHaptics
            }
            return bool(forKey: AppSettingsKeys.enableHaptics)
        }
        set { set(newValue, forKey: AppSettingsKeys.enableHaptics) }
    }
}
