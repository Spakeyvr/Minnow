//
//  MLXPromptPrefixCache.swift
//  ChatLLM
//
//  Persists the KV cache of a prompt's system turn so a fresh session only
//  prefills what follows it. The system prompt (plus tool definitions when web
//  search is on) is several hundred tokens and identical across new chats and
//  across Qwen's per-iteration tool-loop sessions, so restoring it from disk
//  removes most of their prefill without keeping anything resident.
//

import CryptoKit
import Foundation
import MLX
// MLXLMCommon is vendored upstream code still built in Swift 5 mode, so its
// `UserInput` is not Sendable. Each input here is built for one `prepare`
// call that is awaited before anything else touches it.
@preconcurrency import MLXLMCommon
import OSLog
import os
import Synchronization
import Tokenizers

/// A restored or freshly prefilled prefix cache, plus what it cost to obtain.
nonisolated struct MLXPromptPrefix: @unchecked Sendable {
    /// Per-layer cache holding the system turn. Owned by the session it is
    /// handed to; it is never shared between sessions.
    let cache: [KVCache]
    /// The rest of the rendered prompt, to be prefilled on top of `cache`.
    let remainingInput: LMInput
    /// Tokens restored from disk without running the model.
    let restoredTokenCount: Int
    /// Tokens prefilled now because no saved prefix matched.
    let prefilledTokenCount: Int
    let prefillTime: TimeInterval
}

nonisolated struct MLXPromptPrefixCache: Sendable {
    /// Each entry is roughly 40-60 MB on disk for Qwen 3.5 4B; four cover the
    /// variants a user moves between (web search on or off, with or without
    /// the date line) for the loaded model.
    static let maximumEntries = 4
    /// Below this, restoring from disk saves too little to be worth a file.
    static let minimumPrefixTokens = 64
    private static let prefixTokenCountMetadataKey = "chatllm.prefixTokenCount"
    private static let entryExtension = "safetensors"
    private static let partialEntrySuffix = ".partial.safetensors"

    let directory: URL
    private let logger: Logger
    /// Results that depend only on the model and the stable part of the
    /// prompt. Shared by copies of this value so the actor that owns it and
    /// any helper copies see the same entries.
    private let memo: Memo

    init(directory: URL = Self.defaultDirectory, subsystem: String) {
        self.directory = directory
        self.logger = Logger(subsystem: subsystem, category: "MLXPromptPrefixCache")
        self.memo = Memo()
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MLXPromptPrefixCache", isDirectory: true)
    }

    // MARK: - Eligibility

    /// Text-only prompts that open with a system turn. Media turns use a
    /// single-pass prefill whose positions depend on the whole sequence.
    static func isEligible(messages: [Chat.Message]) -> Bool {
        guard messages.count >= 2, messages[0].role == .system else { return false }
        return messages.allSatisfy { $0.images.isEmpty && $0.videos.isEmpty }
    }

    /// Length of the shared token prefix between the full prompt and renders
    /// of the stable system prompt followed by different probe messages.
    /// Taking the shortest match stops the prefix before any token that
    /// depends on the conversation, including the first token of the next
    /// message. Returns nil when the prefix is too short to be worth a file or
    /// leaves nothing to prefill.
    static func prefixTokenCount(full: [Int32], probes: [[Int32]]) -> Int? {
        guard !probes.isEmpty else { return nil }
        return prefixTokenCount(full: full, stablePrefix: commonPrefix(of: probes))
    }

    /// Same as ``prefixTokenCount(full:probes:)`` for probes already reduced
    /// to their common prefix. The shortest match against every probe equals
    /// the match against the probes' common prefix, so the probes only need
    /// rendering once per stable prompt.
    static func prefixTokenCount(full: [Int32], stablePrefix: [Int32]) -> Int? {
        let count = zip(full, stablePrefix).prefix { $0 == $1 }.count
        guard count >= minimumPrefixTokens, count < full.count else { return nil }
        return count
    }

    static func commonPrefix(of sequences: [[Int32]]) -> [Int32] {
        guard var prefix = sequences.first else { return [] }
        for sequence in sequences.dropFirst() {
            let length = zip(prefix, sequence).prefix { $0 == $1 }.count
            prefix.removeSubrange(length...)
        }
        return prefix
    }

    /// Identifies a prefix by model, the weights it was computed with, exact
    /// token sequence, and the cache layout the generation parameters
    /// produce, so a restored cache always matches what
    /// `newCache(parameters:)` would have built with the loaded weights.
    static func entryKey(
        modelID: String,
        weightsFingerprint: String = "",
        prefixTokens: ArraySlice<Int32>,
        parameters: GenerateParameters
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(modelID.utf8))
        hasher.update(data: Data("|weights=\(weightsFingerprint)".utf8))
        hasher.update(data: Data("|maxKV=\(parameters.maxKVSize ?? -1)".utf8))
        hasher.update(data: Data("|compression=\(cacheLayoutDescription(parameters.resolvedCacheCompression))|".utf8))
        Array(prefixTokens).withUnsafeBytes { hasher.update(bufferPointer: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Spells out every field that shapes the cache, so the key does not
    /// change when an unrelated field is added to the configuration type.
    static func cacheLayoutDescription(_ compression: KVCacheCompressionMode?) -> String {
        switch compression {
        case nil:
            return "none"
        case .quantized(let bits, let groupSize, let startStep):
            return "quantized(bits:\(bits),group:\(groupSize),start:\(startStep))"
        case .rotorQuant(let configuration):
            return "rotorquant(variant:\(configuration.variant.rawValue),k:\(configuration.keyBits),v:\(configuration.valueBits),seed:\(configuration.seed),exact:\(configuration.exactBufferSize),block:\(configuration.attentionBlockTokens),prefill:\(configuration.prefillExactLimit.map(String.init) ?? "none"))"
        }
    }

    /// Identifies a weights package by its config and safetensors files, so a
    /// re-downloaded or updated package never restores KV computed with the
    /// previous weights.
    static func weightsFingerprint(forModelDirectory directory: URL) -> String {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        let components = files
            .filter { $0.pathExtension == entryExtension || $0.lastPathComponent == "config.json" }
            .map { url -> String in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let size = values?.fileSize ?? -1
                let modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
                return "\(url.lastPathComponent):\(size):\(modified)"
            }
            .sorted()
        var hasher = SHA256()
        hasher.update(data: Data(components.joined(separator: "|").utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Entries for one model live in their own folder so deleting or
    /// re-downloading that model can drop them without reading every file.
    func modelDirectory(forModelID modelID: String) -> URL {
        Self.modelDirectory(forModelID: modelID, in: directory)
    }

    private static func modelDirectory(forModelID modelID: String, in directory: URL) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let folderName = String(String.UnicodeScalarView(modelID.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? scalar : "_"
        }))
        return directory.appendingPathComponent(folderName, isDirectory: true)
    }

    // MARK: - Lookup

    /// Returns a cache holding the stable system turn of `messages` and the
    /// remaining prompt input, restoring the cache from disk when a matching
    /// entry exists and otherwise prefilling and saving it. Returns nil when
    /// the request is not eligible, the task is cancelled, or anything fails,
    /// in which case the caller prefills the full prompt as before.
    ///
    /// - Parameter stableSystemPrompt: the leading part of the system message
    ///   that does not change between requests (it excludes the date line).
    ///   The cached prefix ends where the rendered prompt departs from it.
    func prefix(
        container: ModelContainer,
        modelID: String,
        messages: [Chat.Message],
        stableSystemPrompt: String?,
        tools: [ToolSpec]?,
        processing: UserInput.Processing,
        additionalContext: [String: any Sendable]?,
        parameters: GenerateParameters,
        scope: RequestScope? = nil,
        keepsPrefixForRequest: Bool = false
    ) async -> MLXPromptPrefix? {
        guard Self.isEligible(messages: messages) else { return nil }
        let stableSystemPrompt = stableSystemPrompt ?? messages[0].content
        guard messages[0].content.hasPrefix(stableSystemPrompt) else { return nil }
        let promptMessages = SendableMessages(messages: messages)
        let containerID = ObjectIdentifier(container)
        let stablePrefixKey = Self.stablePrefixMemoKey(
            containerID: containerID,
            modelID: modelID,
            stableSystemPrompt: stableSystemPrompt,
            tools: tools,
            processing: processing,
            additionalContext: additionalContext
        )
        let tools = tools.map(SendableTools.init)
        let cacheDirectory = modelDirectory(forModelID: modelID)
        let rootDirectory = directory
        let logger = logger
        let memo = memo

        do {
            return try await container.perform { context in
                func render(_ chat: [Chat.Message]) async throws -> LMInput {
                    try await context.processor.prepare(
                        input: UserInput(
                            chat: chat,
                            processing: processing,
                            tools: tools?.specs,
                            additionalContext: additionalContext
                        )
                    )
                }
                func tokens(_ input: LMInput) -> [Int32] {
                    input.text.tokens.asType(.int32).reshaped(-1).asArray(Int32.self)
                }

                let fullInput = try await render(promptMessages.messages)
                let fullTokens = tokens(fullInput)
                // The probes depend only on the model and the stable prompt,
                // so they are rendered once rather than on every new session
                // and every explicit-history tool-loop iteration.
                let stablePrefix: [Int32]
                if let memoized = memo.stablePrefix(for: stablePrefixKey) {
                    stablePrefix = memoized
                } else {
                    var probes: [[Int32]] = []
                    for probe in ["A", "B"] {
                        probes.append(tokens(try await render([.system(stableSystemPrompt), .user(probe)])))
                    }
                    stablePrefix = Self.commonPrefix(of: probes)
                    memo.storeStablePrefix(stablePrefix, for: stablePrefixKey)
                }
                guard let prefixCount = Self.prefixTokenCount(full: fullTokens, stablePrefix: stablePrefix) else {
                    logger.notice("MLX prompt prefix skipped: no stable prefix of useful length")
                    return nil
                }

                let weightsFingerprint = memo.weightsFingerprint(
                    for: "\(containerID.hashValue)|\(modelID)"
                ) {
                    switch context.configuration.id {
                    case .directory(let url):
                        return Self.weightsFingerprint(forModelDirectory: url)
                    case .id(let id, let revision):
                        return "\(id)@\(revision)"
                    }
                }
                let key = Self.entryKey(
                    modelID: modelID,
                    weightsFingerprint: weightsFingerprint,
                    prefixTokens: fullTokens[..<prefixCount],
                    parameters: parameters
                )
                let url = cacheDirectory.appendingPathComponent("\(key).\(Self.entryExtension)")
                let expectedLayout = context.model.newCache(parameters: parameters)
                let remainingInput = LMInput(
                    text: LMInput.Text(tokens: fullInput.text.tokens[.ellipsis, prefixCount...])
                )

                // An earlier stream of this request already holds the prefix.
                if let held = scope?.heldPrefix(for: key),
                   let cache = Self.copy(of: held, into: expectedLayout) {
                    logger.notice("MLX prompt prefix reused within request: tokens=\(prefixCount, privacy: .public)")
                    return MLXPromptPrefix(
                        cache: cache,
                        remainingInput: remainingInput,
                        restoredTokenCount: prefixCount,
                        prefilledTokenCount: 0,
                        prefillTime: 0
                    )
                }

                if let restored = Self.restore(
                    from: url, prefixCount: prefixCount, expectedLayout: expectedLayout, logger: logger
                ) {
                    if keepsPrefixForRequest, let scope,
                       let snapshot = Self.copy(of: restored, into: context.model.newCache(parameters: parameters)) {
                        scope.hold(snapshot, for: key)
                    }
                    logger.notice("MLX prompt prefix restored: tokens=\(prefixCount, privacy: .public)")
                    return MLXPromptPrefix(
                        cache: restored,
                        remainingInput: remainingInput,
                        restoredTokenCount: prefixCount,
                        prefilledTokenCount: 0,
                        prefillTime: 0
                    )
                }

                try Task.checkCancellation()
                let startedAt = Date()
                let cache = expectedLayout
                let prefixInput = LMInput(
                    text: LMInput.Text(tokens: fullInput.text.tokens[.ellipsis, ..<prefixCount])
                )
                // `prepare` checks for cancellation between chunks, so Stop
                // during a long prefix prefill releases the container early.
                switch try context.model.prepare(
                    prefixInput, cache: cache, windowSize: parameters.prefillStepSize
                ) {
                case .tokens(let remaining):
                    // LLM `prepare` leaves its last chunk for the token
                    // iterator; run it so the cache covers the whole prefix.
                    if remaining.tokens.size > 0 {
                        _ = context.model(remaining[text: .newAxis], cache: cache, state: nil)
                    }
                case .logits:
                    break
                }
                eval(cache)
                let prefillTime = Date().timeIntervalSince(startedAt)
                // A cancelled request does not need the entry; skip the write.
                try Task.checkCancellation()

                // Writing tens of megabytes here would hold up the first token. With a
                // request scope, a snapshot is written once the response has finished.
                if let scope,
                   let snapshot = Self.copy(of: cache, into: context.model.newCache(parameters: parameters)) {
                    scope.deferSave(PendingSave(
                        cache: snapshot, url: url, prefixCount: prefixCount,
                        directory: cacheDirectory, root: rootDirectory
                    ))
                    if keepsPrefixForRequest {
                        scope.hold(snapshot, for: key)
                    }
                } else {
                    Self.save(
                        cache, to: url, prefixCount: prefixCount,
                        in: cacheDirectory, root: rootDirectory, logger: logger
                    )
                }
                logger.notice(
                    "MLX prompt prefix prefilled: tokens=\(prefixCount, privacy: .public) seconds=\(String(format: "%.3f", prefillTime), privacy: .public)"
                )
                return MLXPromptPrefix(
                    cache: cache,
                    remainingInput: remainingInput,
                    restoredTokenCount: 0,
                    prefilledTokenCount: prefixCount,
                    prefillTime: prefillTime
                )
            }
        } catch is CancellationError {
            logger.notice("MLX prompt prefix cancelled")
            return nil
        } catch {
            logger.error("MLX prompt prefix unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Writes the entries `scope` prefilled, once the request that prefilled them has
    /// finished. Runs inside the model container's `perform`, like every other access
    /// to model state.
    func writeDeferredSaves(of scope: RequestScope, container: ModelContainer) async {
        let saves = DeferredSaves(saves: scope.takePendingSaves())
        guard !saves.saves.isEmpty else { return }
        let logger = logger
        await container.perform { _ in
            for save in saves.saves {
                Self.save(
                    save.cache, to: save.url, prefixCount: save.prefixCount,
                    in: save.directory, root: save.root, logger: logger
                )
            }
            logger.notice("MLX prompt prefix saved after response: entries=\(saves.saves.count, privacy: .public)")
        }
    }

    /// Removes every saved prefix for `modelID`. Called when the model's files
    /// are deleted or replaced, so its entries do not wait for eviction.
    func removeEntries(forModelID modelID: String) {
        memo.removeAll()
        let folder = modelDirectory(forModelID: modelID)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
            logger.notice("MLX prompt prefixes removed: model=\(modelID, privacy: .public)")
        } catch {
            logger.error("MLX prompt prefix removal failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Memoization

    static func stablePrefixMemoKey(
        containerID: ObjectIdentifier,
        modelID: String,
        stableSystemPrompt: String,
        tools: [ToolSpec]?,
        processing: UserInput.Processing,
        additionalContext: [String: any Sendable]?
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("\(containerID.hashValue)|\(modelID)|".utf8))
        hasher.update(data: Data(stableSystemPrompt.utf8))
        hasher.update(data: Data("|tools=".utf8))
        hasher.update(data: canonicalDescription(of: tools))
        hasher.update(data: Data("|context=".utf8))
        hasher.update(data: canonicalDescription(of: additionalContext))
        hasher.update(data: Data("|processing=\(String(describing: processing))".utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Sorted-key JSON when the value is JSON-like (tool specs and template
    /// context are), else its description. Two equal inputs always produce
    /// the same bytes; an unusual value can only cost a memo miss.
    private static func canonicalDescription(of value: Any?) -> Data {
        guard let value else { return Data("nil".utf8) }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            return data
        }
        return Data(String(describing: value).utf8)
    }

    nonisolated final class Memo: Sendable {
        /// A handful of stable prompts (tools on/off, thinking on/off) per model.
        private static let maximumEntries = 16

        private struct State {
            var stablePrefixes: [String: [Int32]] = [:]
            var weightsFingerprints: [String: String] = [:]
        }

        private let state = Mutex(State())

        func stablePrefix(for key: String) -> [Int32]? {
            state.withLock { $0.stablePrefixes[key] }
        }

        func storeStablePrefix(_ prefix: [Int32], for key: String) {
            state.withLock { state in
                if state.stablePrefixes.count >= Self.maximumEntries {
                    state.stablePrefixes.removeAll(keepingCapacity: true)
                }
                state.stablePrefixes[key] = prefix
            }
        }

        func weightsFingerprint(for key: String, compute: () -> String) -> String {
            if let cached = state.withLock({ $0.weightsFingerprints[key] }) {
                return cached
            }
            let fingerprint = compute()
            state.withLock { state in
                if state.weightsFingerprints.count >= Self.maximumEntries {
                    state.weightsFingerprints.removeAll(keepingCapacity: true)
                }
                state.weightsFingerprints[key] = fingerprint
            }
            return fingerprint
        }

        func removeAll() {
            state.withLock { $0 = State() }
        }
    }

    // MARK: - Request Scope

    /// An entry prefilled during a request, written once the request ends.
    struct PendingSave {
        /// A copy of the prefilled cache that the session never writes to.
        let cache: [KVCache]
        let url: URL
        let prefixCount: Int
        let directory: URL
        let root: URL
    }

    /// `KVCache` is not Sendable. These copies are handed to the one task that
    /// writes them and nothing else touches them afterwards.
    private struct DeferredSaves: @unchecked Sendable {
        let saves: [PendingSave]
    }

    /// Prefix state for one generation request. Entries the request prefills are
    /// written after its response instead of before the first token, and an
    /// explicit-history tool loop, which builds a new session for every stream,
    /// restores the system turn from memory instead of re-reading the entry.
    /// Released when the request ends, so nothing stays resident between requests.
    ///
    /// The caches it holds are copies no session writes to; every session gets
    /// its own copy. A request uses its scope from one task at a time.
    nonisolated final class RequestScope: @unchecked Sendable {
        private struct State {
            var held: [String: [KVCache]] = [:]
            var pendingSaves: [PendingSave] = []
        }

        private let state = OSAllocatedUnfairLock(uncheckedState: State())

        init() {}

        var hasPendingSaves: Bool {
            state.withLockUnchecked { !$0.pendingSaves.isEmpty }
        }

        var heldPrefixCount: Int {
            state.withLockUnchecked { $0.held.count }
        }

        func heldPrefix(for key: String) -> [KVCache]? {
            state.withLockUnchecked { $0.held[key] }
        }

        func hold(_ cache: [KVCache], for key: String) {
            state.withLockUnchecked { $0.held[key] = cache }
        }

        func deferSave(_ save: PendingSave) {
            state.withLockUnchecked { state in
                // A later stream that prefilled the same entry replaces the earlier copy.
                state.pendingSaves.removeAll { $0.url == save.url }
                state.pendingSaves.append(save)
            }
        }

        func takePendingSaves() -> [PendingSave] {
            state.withLockUnchecked { state in
                defer { state.pendingSaves = [] }
                return state.pendingSaves
            }
        }

        /// Drops the prefixes kept for later streams of the request.
        func releaseHeldPrefixes() {
            state.withLockUnchecked { $0.held = [:] }
        }
    }

    /// Fills `layout`, a fresh cache from `newCache(parameters:)`, with the contents
    /// of `source` without sharing array objects, so neither cache's later updates
    /// reach the other. Returns nil when the layouts differ or a layer is empty.
    static func copy(of source: [KVCache], into layout: [KVCache]) -> [KVCache]? {
        guard source.count == layout.count else { return nil }
        for (from, target) in zip(source, layout) {
            // Every cache is a class, so setting through this copy fills `layout`'s cache.
            var to = target
            guard type(of: from) == type(of: to) else { return nil }
            // `stopGradient` is an identity op: a new array object over the same data.
            let state = from.state.map { stopGradient($0) }
            guard !state.isEmpty else { return nil }
            let metaState = from.metaState
            // Same order as `loadPromptCache`: RotorQuant builds its quantizers from metaState.
            if to is RotorQuantKVCache {
                to.metaState = metaState
                to.state = state
            } else {
                to.state = state
                to.metaState = metaState
            }
        }
        return layout
    }

    // Text-only messages and JSON-like tool specs are only read inside the
    // model container's serialized `perform`.
    private struct SendableMessages: @unchecked Sendable {
        let messages: [Chat.Message]
    }

    private struct SendableTools: @unchecked Sendable {
        let specs: [ToolSpec]
    }

    // MARK: - Storage

    private static func restore(
        from url: URL,
        prefixCount: Int,
        expectedLayout: [KVCache],
        logger: Logger
    ) -> [KVCache]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let (cache, metadata) = try loadPromptCache(url: url)
            let layoutMatches = cache.count == expectedLayout.count
                && zip(cache, expectedLayout).allSatisfy { type(of: $0) == type(of: $1) }
            guard layoutMatches,
                  metadata[prefixTokenCountMetadataKey] == String(prefixCount) else {
                logger.notice("MLX prompt prefix discarded: saved layout no longer matches")
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            // Keeps least-recently-used eviction honest.
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: url.path
            )
            return cache
        } catch {
            logger.error("MLX prompt prefix restore failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private static func save(
        _ cache: [KVCache],
        to url: URL,
        prefixCount: Int,
        in directory: URL,
        root: URL,
        logger: Logger
    ) {
        let fileManager = FileManager.default
        // Write beside the destination and move into place so a reader never
        // sees a partially written entry.
        let temporaryURL = directory.appendingPathComponent("\(UUID().uuidString)\(partialEntrySuffix)")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try savePromptCache(
                url: temporaryURL,
                cache: cache,
                metadata: [prefixTokenCountMetadataKey: String(prefixCount)]
            )
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            try fileManager.moveItem(at: temporaryURL, to: url)
        } catch {
            // A failed write must not leave tens of megabytes behind.
            try? fileManager.removeItem(at: temporaryURL)
            logger.error("MLX prompt prefix save failed: \(error.localizedDescription, privacy: .public)")
        }
        evictOldEntries(in: root)
    }

    /// Keeps the newest `maximumEntries` complete entries across all models.
    /// Partial writes (left by a crash or a killed app) and files from the
    /// earlier flat layout are deleted instead of counting as entries. Saves
    /// run inside the model container's serialized `perform`, so no partial
    /// file is still being written when this runs.
    static func evictOldEntries(in root: URL) {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let topLevel = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, modified: Date)] = []
        for item in topLevel {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else {
                // Flat-layout entries use keys that no longer match anything.
                try? fileManager.removeItem(at: item)
                continue
            }
            let files = (try? fileManager.contentsOfDirectory(
                at: item, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            )) ?? []
            for file in files {
                if file.lastPathComponent.hasSuffix(partialEntrySuffix) || file.pathExtension != entryExtension {
                    try? fileManager.removeItem(at: file)
                    continue
                }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                entries.append((file, modified))
            }
        }

        let sorted = entries.sorted { $0.modified > $1.modified }
        for entry in sorted.dropFirst(maximumEntries) {
            try? fileManager.removeItem(at: entry.url)
        }
    }
}
