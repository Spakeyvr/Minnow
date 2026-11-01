//
//  ChatViewModel+Keychain.swift
//  Minnow
//
//  Created by Nevio on 10/24/25.
//

import Foundation
import os

/// One Tavily search service for every chat. Each chat switch creates a view model, and
/// reading the key there costs a legacy-migration check and one or two synchronous
/// Keychain queries on the main actor; the store is read again only after the key changes.
/// Only a working service is kept. Without one the store is asked again, which is cheap
/// once it has cached "no key", and recovers a key the Keychain could not read while
/// the device was locked.
@MainActor
enum SharedTavilySearchService {
    private static var service: TavilySearchService?

    static func current(logger: Logger) -> TavilySearchService? {
        if service == nil {
            service = makeService(logger: logger)
        }
        return service
    }

    /// Forgets the loaded service so the next `current` reads the store again.
    static func invalidate() {
        service = nil
    }

    private static func makeService(logger: Logger) -> TavilySearchService? {
        guard let key = TavilyAPIKeyStore.currentKey() else { return nil }
        do {
            let service = try TavilySearchService(apiKey: key)
            logger.info("Tavily service initialized from shared store")
            return service
        } catch {
            logger.error("Error: Invalid Tavily key from shared store: \(error.localizedDescription)")
            return nil
        }
    }
}

extension ChatViewModel {

    /// Load the Tavily search service from the shared Keychain-backed store.
    /// `reloadingStore` re-reads the Keychain, for when the key has just changed.
    func loadTavilyAPIKey(reloadingStore: Bool = false) {
        if reloadingStore {
            SharedTavilySearchService.invalidate()
        }
        searchService = SharedTavilySearchService.current(logger: logger)
    }
}
