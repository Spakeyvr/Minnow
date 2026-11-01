import Foundation
import Synchronization

/// The interface language is independent of prompts and conversation content.
nonisolated enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case german = "de"
    case spanish = "es"

    var id: String { rawValue }

    // Keep names in their own language so users can always find their way back.
    var nativeName: String {
        switch self {
        case .english: "English"
        case .german: "Deutsch"
        case .spanish: "Español"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    static func resolve(_ identifier: String) -> AppLanguage {
        AppLanguage(rawValue: identifier) ?? .english
    }

    /// The first of `identifiers` (BCP 47, most preferred first) that the app is
    /// translated into, or English when none is.
    static func preferred(from identifiers: [String]) -> AppLanguage {
        for identifier in identifiers {
            if let code = Locale.Language(identifier: identifier).languageCode?.identifier,
               let language = AppLanguage(rawValue: code) {
                return language
            }
        }
        return .english
    }

    /// The language used until the user picks one: the device's preferred
    /// language when the app is translated into it, otherwise English.
    static var systemDefault: AppLanguage {
        preferred(from: Locale.preferredLanguages)
    }

    /// The selected interface language, or `systemDefault` when none is saved.
    static var current: AppLanguage {
        AppLanguageSelection.shared.current
    }

    /// Pins `current` to `language` whatever the saved setting says, or follows the
    /// setting again for `nil`. Unit tests use it so localized strings stay
    /// deterministic without writing the host app's standard defaults.
    static func overrideCurrent(with language: AppLanguage?) {
        AppLanguageSelection.shared.override = language
    }

    var bundle: Bundle {
        Self.bundles[self] ?? .main
    }

    private static let bundles: [AppLanguage: Bundle] = Dictionary(
        uniqueKeysWithValues: allCases.compactMap { language in
            guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { return nil }
            return (language, bundle)
        }
    )

    /// A draft may have been created before the user changed the interface language.
    static func isDefaultConversationTitle(_ title: String) -> Bool {
        title == "New Chat" || allCases.contains {
            title == String(localized: "New Chat", bundle: $0.bundle, locale: $0.locale)
        }
    }
}

/// Caches the saved interface language, which every localized string reads.
/// Key-value observation drops the cache whenever the setting is written, by
/// Settings, `@AppStorage` or anything else using the same defaults.
nonisolated final class AppLanguageSelection: NSObject, Sendable {
    static let shared = AppLanguageSelection(defaults: .standard)

    nonisolated private struct State {
        var generation: UInt64 = 0
        var language: AppLanguage?
        var override: AppLanguage?
    }

    // UserDefaults is documented as thread-safe; it just isn't annotated Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let state = Mutex(State())

    /// Follows the interface language saved in `defaults`. The app uses `shared`;
    /// tests pass their own domain.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init()
        defaults.addObserver(self, forKeyPath: AppSettingsKeys.appLanguage, options: [], context: nil)
    }

    deinit {
        defaults.removeObserver(self, forKeyPath: AppSettingsKeys.appLanguage)
    }

    /// When set, `current` returns it instead of the saved setting.
    var override: AppLanguage? {
        get { state.withLock { $0.override } }
        set { state.withLock { $0.override = newValue } }
    }

    var current: AppLanguage {
        let (generation, cached, override) = state.withLock { ($0.generation, $0.language, $0.override) }
        if let override {
            return override
        }
        if let cached {
            return cached
        }
        let language = defaults.string(forKey: AppSettingsKeys.appLanguage)
            .map(AppLanguage.resolve) ?? AppLanguage.systemDefault
        // A write that landed while resolving bumped the generation; caching the
        // value read before it would keep the old language.
        state.withLock {
            if $0.generation == generation {
                $0.language = language
            }
        }
        return language
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        state.withLock {
            $0.generation &+= 1
            $0.language = nil
        }
    }
}

extension Bundle {
    /// Foundation/UIKit strings need the selected bundle as well as SwiftUI's locale.
    nonisolated static var appLocalized: Bundle { AppLanguage.current.bundle }
}
