//
//  ChatViewModel+Errors.swift
//  Minnow
//

import Foundation
import FoundationModels

extension ChatViewModel {

    // MARK: - Errors

    struct GenerationTimeoutError: LocalizedError {
        var timeout: Duration
        var errorDescription: String? {
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            return String(localized: "Generation timed out after \(Int(seconds)) seconds.", bundle: .appLocalized)
        }
    }

    /// Explains a context overflow with the limit and fixes of the backend
    /// that hit it; the MLX Context Window setting means nothing to Apple's model.
    struct ContextWindowError: LocalizedError {
        enum Backend {
            case mlx
            case appleIntelligence
        }

        let tokenLimit: Int
        let backend: Backend

        var errorDescription: String? {
            switch backend {
            case .mlx:
                return String(localized: """
                Context window limit reached. This device is currently capped at about \(tokenLimit) tokens for on-device MLX chats.

                Try one of these solutions:
                • Start a new chat or trim earlier messages
                • Lower the Context Window setting
                • Shorten your response preferences or the latest message
                """, bundle: .appLocalized, locale: AppLanguage.current.locale)
            case .appleIntelligence:
                return String(localized: """
                Context window limit reached. Apple Intelligence can hold about \(tokenLimit) tokens per request on this device.

                Try one of these solutions:
                • Start a new chat or trim earlier messages
                • Attach fewer images
                • Shorten your response preferences or the latest message
                """, bundle: .appLocalized, locale: AppLanguage.current.locale)
            }
        }
    }

    private static let contextWindowErrorCodes: Set<Int> = [-1, 400, 413]

    /// Detects if an error is related to context window/length limits
    func isContextWindowError(_ error: Error) -> Bool {
        // The typed error is checked first: the system's description is localized,
        // so the English keyword match below misses it on other device languages.
        if let error = error as? LanguageModelError {
            if case .contextSizeExceeded = error { return true }
            return false
        }
        let errorString = error.localizedDescription.lowercased()
        let hasContext = errorString.contains("context")
        let hasLimitWord = errorString.contains("length") || errorString.contains("limit") || errorString.contains("window")
        if hasContext && hasLimitWord { return true }
        let nsError = error as NSError
        if Self.contextWindowErrorCodes.contains(nsError.code) &&
           (nsError.domain.contains("LanguageModel") || nsError.domain.contains("FoundationModels")) &&
           hasContext {
            return true
        }
        return false
    }
}
