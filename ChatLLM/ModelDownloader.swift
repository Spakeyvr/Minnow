//
//  ModelDownloader.swift
//  ChatLLM
//
//  Downloads MLX model files from HuggingFace to the local Documents directory.
//

import CryptoKit
import Darwin
import Foundation
import OSLog

nonisolated private let modelDownloadLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ChatLLM",
    category: "ModelDownloader"
)

actor ModelDownloader {

    struct RemoteFile: Sendable {
        let name: String
        let size: Int64
        /// Present for LFS files (weights, large tokenizers); checked after download.
        let sha256: String?
    }

    private struct FilePlan {
        let name: String
        let size: Int64
        let sha256: String?
        let remoteURL: URL
        let destinationURL: URL
        let temporaryURL: URL
        let transferID: String
    }

    private struct TransferProgress: Sendable {
        let transferID: String
        let bytesWritten: Int64
        let serverExpectedBytes: Int64
        let declaredExpectedBytes: Int64
    }

    private static let hfApiBase     = "https://huggingface.co/api"
    private static let hfResolveBase = "https://huggingface.co"
    private static let disallowedRemotePathComponents: Set<String> = [".", ".."]
    private static let metadataTimeout: TimeInterval = 30
    private static let metadataRetryCount = 1
    private static let metadataRetryDelay: Duration = .milliseconds(500)
    private static let verifiedChecksumAttribute = "com.nevio.chatllm.verified-sha256"
    private let backgroundSession = BackgroundModelDownloadSession.shared
    private let metadataSession: URLSession

    /// Shared by the in-flight delegate callbacks and the per-file path, so
    /// the reported value only moves forward.
    private var progressReporter = DownloadProgressReporter()

    init(metadataSession: URLSession = .shared) {
        self.metadataSession = metadataSession
    }

    // MARK: - File List

    func fetchFileList(repoId: String, revision: String?) async throws -> [RemoteFile] {
        guard let url = Self.metadataURL(repoId: repoId, revision: revision) else {
            throw DownloadError.badResponse
        }
        var request = URLRequest(url: url, timeoutInterval: Self.metadataTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var attempt = 0
        while true {
            do {
                let (data, response) = try await metadataSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw DownloadError.badResponse
                }
                if http.statusCode == 200 {
                    return try Self.parseFileList(from: data)
                }
                if (500...599).contains(http.statusCode), attempt < Self.metadataRetryCount {
                    attempt += 1
                    try await Task.sleep(for: Self.metadataRetryDelay)
                    continue
                }
                throw DownloadError.metadataHTTPStatus(http.statusCode)
            } catch let error as URLError where error.isTransientConnectivityFailure
                && attempt < Self.metadataRetryCount {
                attempt += 1
                modelDownloadLogger.notice(
                    "Retrying model file list after a transient network error: code=\(error.code.rawValue, privacy: .public)"
                )
                try await Task.sleep(for: Self.metadataRetryDelay)
            }
        }
    }

    internal static func parseFileList(from data: Data) throws -> [RemoteFile] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let siblings = json["siblings"] as? [[String: Any]] else {
            return []
        }
        return siblings.compactMap { item in
            guard let name = item["rfilename"] as? String else { return nil }
            let directSize = item["size"] as? Int64 ?? 0
            let lfs = item["lfs"] as? [String: Any]
            let lfsSize = lfs.flatMap { $0["size"] as? Int64 } ?? 0
            let sha256 = (lfs?["sha256"] as? String)?.lowercased()
            return RemoteFile(name: name, size: max(directSize, lfsSize), sha256: sha256)
        }
    }

    /// `revision` pins the listing to a commit; nil lists the default branch.
    internal static func metadataURL(repoId: String, revision: String? = nil) -> URL? {
        let revisionPath = revision.map { "/revision/\($0)" } ?? ""
        guard var components = URLComponents(string: "\(hfApiBase)/models/\(repoId)\(revisionPath)") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        return components.url
    }

    // MARK: - Download

    /// Downloads all model files to `targetDir`, streaming each file and reporting
    /// aggregate 0.0–1.0 progress via `onProgress`.
    func download(
        repoId: String,
        revision: String,
        to targetDir: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let files = try await fetchFileList(repoId: repoId, revision: revision)
        guard !files.isEmpty else { throw DownloadError.noFilesFound }

        let totalExpected = files.reduce(0) { $0 + $1.size }
        let fileCount = files.count
        var totalWritten: Int64 = 0
        var filesCompleted = 0
        progressReporter = DownloadProgressReporter()

        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        // Weights can be downloaded again, so they stay out of iCloud and
        // device backups. The flag covers everything inside the folder and
        // moves with it when the finished download is renamed into place.
        Self.excludeFromBackup(targetDir)

        let plans = try files.map { file in
            try Task.checkCancellation()

            let remotePathComponents = try Self.validatedRemotePathComponents(for: file.name)
            guard let fileURL = Self.resolveDownloadURL(
                repoId: repoId,
                revision: revision,
                remotePathComponents: remotePathComponents
            ) else {
                throw DownloadError.badURL(file: file.name)
            }

            let (destURL, tempURL) = try Self.destinationURLs(for: file.name, inside: targetDir)

            let parentDir = destURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

            return FilePlan(
                name: file.name,
                size: file.size,
                sha256: file.sha256,
                remoteURL: fileURL,
                destinationURL: destURL,
                temporaryURL: tempURL,
                transferID: "\(repoId)/\(file.name)"
            )
        }

        var pendingPlans: [FilePlan] = []
        for plan in plans {
            try Task.checkCancellation()

            if try await Self.reuseCompletedFileIfPossible(
                destination: plan.destinationURL,
                temporary: plan.temporaryURL,
                expectedSize: plan.size,
                expectedSHA256: plan.sha256
            ) {
                let actualSize = Self.fileSize(at: plan.destinationURL) ?? plan.size
                totalWritten += actualSize
                filesCompleted += 1
                let progress = Self.computeProgress(
                    totalWritten: totalWritten,
                    totalExpected: totalExpected,
                    filesCompleted: filesCompleted,
                    fileCount: fileCount
                )
                emitProgress(progress, onProgress: onProgress)
                continue
            }

            pendingPlans.append(plan)
        }

        // One consumer drains every transfer's progress in order, instead of
        // one Task per URLSession chunk callback.
        let (progressUpdates, progressContinuation) = AsyncStream.makeStream(
            of: TransferProgress.self,
            bufferingPolicy: .bufferingNewest(256)
        )
        let aggregator = DownloadProgressAggregator(
            completedBytesBeforeTransfers: totalWritten,
            completedFilesBeforeTransfers: filesCompleted,
            totalExpectedBytes: totalExpected,
            fileCount: fileCount
        )
        let progressConsumer = Task {
            var aggregator = aggregator
            for await update in progressUpdates {
                guard let progress = aggregator.record(
                    transferID: update.transferID,
                    bytesWritten: update.bytesWritten,
                    serverExpectedBytes: update.serverExpectedBytes,
                    declaredExpectedBytes: update.declaredExpectedBytes
                ) else {
                    continue
                }
                self.emitProgress(progress, onProgress: onProgress)
            }
        }
        defer {
            progressContinuation.finish()
            progressConsumer.cancel()
        }

        // Queue the complete repository up front. If iOS suspends or relaunches
        // the app, URLSession can continue every queued file rather than only
        // the one that happened to be active at that moment.
        await backgroundSession.prepareDownloads(pendingPlans.map { plan in
            let transferID = plan.transferID
            let declaredSize = plan.size
            return BackgroundModelDownloadSession.PreparedDownload(
                remoteURL: plan.remoteURL,
                destinationURL: plan.temporaryURL,
                transferID: transferID,
                onProgress: { written, expected in
                    progressContinuation.yield(TransferProgress(
                        transferID: transferID,
                        bytesWritten: written,
                        serverExpectedBytes: expected,
                        declaredExpectedBytes: declaredSize
                    ))
                }
            )
        })

        for plan in pendingPlans {
            try Task.checkCancellation()

            _ = try await backgroundSession.download(
                from: plan.remoteURL,
                to: plan.temporaryURL,
                transferID: plan.transferID
            )
            try Task.checkCancellation()

            let actualSize = Self.fileSize(at: plan.temporaryURL) ?? plan.size
            if plan.size > 0, actualSize != plan.size {
                try? FileManager.default.removeItem(at: plan.temporaryURL)
                throw DownloadError.incorrectFileSize(
                    file: plan.name,
                    expected: plan.size,
                    actual: actualSize
                )
            }
            if let expectedSHA256 = plan.sha256 {
                guard try await Self.sha256Hex(of: plan.temporaryURL) == expectedSHA256 else {
                    try? FileManager.default.removeItem(at: plan.temporaryURL)
                    throw DownloadError.checksumMismatch(file: plan.name)
                }
                Self.recordVerifiedChecksum(expectedSHA256, at: plan.temporaryURL)
            }

            try? FileManager.default.removeItem(at: plan.destinationURL)
            try FileManager.default.moveItem(
                at: plan.temporaryURL,
                to: plan.destinationURL
            )
            totalWritten += actualSize
            filesCompleted += 1
            let progress = Self.computeProgress(
                totalWritten: totalWritten,
                totalExpected: totalExpected,
                filesCompleted: filesCompleted,
                fileCount: fileCount
            )
            emitProgress(progress, onProgress: onProgress)
        }

        // Resume data only matters while a file is incomplete; never move it
        // into the finished model folder.
        for plan in plans {
            try? FileManager.default.removeItem(
                at: BackgroundModelDownloadSession.resumeDataURL(forDestinationPath: plan.temporaryURL.path)
            )
        }

        progressReporter.markComplete()
        onProgress(1.0)
    }

    // MARK: - Backup Exclusion

    /// Marks `url` (and, for a folder, everything inside it) as excluded from
    /// iCloud and device backups. Missing items are skipped.
    nonisolated static func excludeFromBackup(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        do {
            try mutableURL.setResourceValues(values)
        } catch {
            modelDownloadLogger.error(
                "Could not exclude model files from backup: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Helpers

    private func emitProgress(
        _ progress: Double,
        onProgress: @escaping @Sendable (Double) -> Void
    ) {
        guard progressReporter.shouldReport(progress) else { return }
        onProgress(progress)
    }

    private static func reuseCompletedFileIfPossible(
        destination: URL,
        temporary: URL,
        expectedSize: Int64,
        expectedSHA256: String?
    ) async throws -> Bool {
        if try await fileMatches(at: destination, expectedSize: expectedSize, expectedSHA256: expectedSHA256) {
            return true
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        guard try await fileMatches(at: temporary, expectedSize: expectedSize, expectedSHA256: expectedSHA256) else {
            if FileManager.default.fileExists(atPath: temporary.path) {
                try FileManager.default.removeItem(at: temporary)
            }
            return false
        }

        try FileManager.default.moveItem(at: temporary, to: destination)
        return true
    }

    /// Checks size, then the checksum. A file verified earlier carries a
    /// marker tied to its size and modification date, so restarts do not
    /// re-hash gigabytes of weights.
    internal static func fileMatches(
        at url: URL,
        expectedSize: Int64,
        expectedSHA256: String?
    ) async throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let actualSize = fileSize(at: url) else {
            return false
        }
        let sizeMatches = expectedSize > 0 ? actualSize == expectedSize : actualSize > 0
        guard sizeMatches else { return false }
        guard let expectedSHA256 else { return true }
        if hasVerifiedChecksum(expectedSHA256, at: url) {
            return true
        }
        guard try await sha256Hex(of: url) == expectedSHA256 else { return false }
        recordVerifiedChecksum(expectedSHA256, at: url)
        return true
    }

    /// Streams the file so multi-gigabyte weights are never held in memory.
    /// Runs off the actor so progress updates keep flowing while it hashes.
    @concurrent
    nonisolated internal static func sha256Hex(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try autoreleasepool {
                try handle.read(upToCount: 8 * 1_048_576)
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Verified Checksum Marker

    internal static func hasVerifiedChecksum(_ sha256: String, at url: URL) -> Bool {
        guard let stored = readExtendedAttribute(verifiedChecksumAttribute, at: url),
              let marker = VerifiedFileMarker(encoded: stored),
              let current = fileIdentity(at: url) else {
            return false
        }
        return marker.matches(sha256: sha256, size: current.size, modificationTime: current.modificationTime)
    }

    internal static func recordVerifiedChecksum(_ sha256: String, at url: URL) {
        guard let current = fileIdentity(at: url) else { return }
        let marker = VerifiedFileMarker(
            sha256: sha256,
            size: current.size,
            modificationTime: current.modificationTime
        )
        if !writeExtendedAttribute(verifiedChecksumAttribute, value: marker.encoded, at: url) {
            modelDownloadLogger.debug(
                "Could not record checksum marker for \(url.lastPathComponent, privacy: .public)"
            )
        }
    }

    /// Reads attributes straight from the file system. `URL.resourceValues`
    /// can return cached values for a URL that was queried earlier.
    private static func fileIdentity(at url: URL) -> (size: Int64, modificationTime: Double)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date else {
            return nil
        }
        return (size, modified.timeIntervalSinceReferenceDate)
    }

    private static func readExtendedAttribute(_ name: String, at url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let length = getxattr(path, name, nil, 0, 0, 0)
            guard length > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: length)
            let read = getxattr(path, name, &buffer, length, 0, 0)
            guard read == length else { return nil }
            return String(bytes: buffer, encoding: .utf8)
        }
    }

    private static func writeExtendedAttribute(_ name: String, value: String, at url: URL) -> Bool {
        let bytes = Array(value.utf8)
        return url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return setxattr(path, name, bytes, bytes.count, 0, 0) == 0
        }
    }

    private static func fileSize(at url: URL) -> Int64? {
        fileIdentity(at: url)?.size
    }

    private static func computeProgress(
        totalWritten: Int64,
        totalExpected: Int64,
        filesCompleted: Int,
        fileCount: Int
    ) -> Double {
        if totalExpected > 0 {
            return min(Double(totalWritten) / Double(totalExpected), 1.0)
        } else if fileCount > 0 {
            return min(Double(filesCompleted) / Double(fileCount), 1.0)
        }
        return 0
    }

    // MARK: - Paths

    internal static func validatedRemotePathComponents(for remotePath: String) throws -> [String] {
        let trimmed = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else {
            throw DownloadError.invalidRemotePath(file: remotePath)
        }

        let components = trimmed
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)

        guard !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty &&
                  !Self.disallowedRemotePathComponents.contains($0) &&
                  !$0.contains("\\")
              }) else {
            throw DownloadError.invalidRemotePath(file: remotePath)
        }

        return components
    }

    internal static func destinationURLs(
        for remotePath: String,
        inside targetDir: URL
    ) throws -> (destination: URL, temporary: URL) {
        let components = try validatedRemotePathComponents(for: remotePath)
        let targetRoot = targetDir.standardizedFileURL

        let destinationDirectory = components
            .dropLast()
            .reduce(targetRoot) { partialResult, component in
                partialResult.appendingPathComponent(component, isDirectory: true)
            }
        let destination = destinationDirectory.appendingPathComponent(
            components.last ?? "",
            isDirectory: false
        )
        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".download", isDirectory: false)

        try ensureURLIsInsideTarget(destination, targetDir: targetRoot, originalFile: remotePath)
        try ensureURLIsInsideTarget(temporary, targetDir: targetRoot, originalFile: remotePath)

        return (destination, temporary)
    }

    private static func resolveDownloadURL(
        repoId: String,
        revision: String,
        remotePathComponents: [String]
    ) -> URL? {
        let repoComponents = repoId
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !repoComponents.isEmpty,
              let baseURL = URL(string: hfResolveBase) else {
            return nil
        }

        let repoURL = repoComponents.reduce(baseURL) { partialResult, component in
            partialResult.appendingPathComponent(component, isDirectory: false)
        }

        return (["resolve", revision] + remotePathComponents).reduce(repoURL) { partialResult, component in
            partialResult.appendingPathComponent(component, isDirectory: false)
        }
    }

    private static func ensureURLIsInsideTarget(
        _ url: URL,
        targetDir: URL,
        originalFile: String
    ) throws {
        let targetPath = targetDir.standardizedFileURL.path
        let resolvedPath = url.standardizedFileURL.path
        guard resolvedPath == targetPath || resolvedPath.hasPrefix(targetPath + "/") else {
            throw DownloadError.invalidRemotePath(file: originalFile)
        }
    }

    // MARK: - Errors

    enum DownloadError: LocalizedError {
        case badResponse
        case metadataHTTPStatus(Int)
        case noFilesFound
        case badURL(file: String)
        case invalidRemotePath(file: String)
        case incorrectFileSize(file: String, expected: Int64, actual: Int64)
        case checksumMismatch(file: String)

        var errorDescription: String? {
            switch self {
            case .badResponse:       return String(localized: "The server returned an unexpected response. Check your internet connection.", bundle: .appLocalized)
            case .metadataHTTPStatus(let statusCode):
                switch statusCode {
                case 401, 403:
                    return String(localized: "This model requires access on Hugging Face and can't be downloaded.", bundle: .appLocalized)
                case 404:
                    return String(localized: "This model version was not found on Hugging Face.", bundle: .appLocalized)
                case 429:
                    return String(localized: "Hugging Face is limiting requests right now. Try again in a few minutes.", bundle: .appLocalized)
                case 500...599:
                    return String(localized: "Hugging Face is temporarily unavailable (HTTP \(statusCode)). Try again later.", bundle: .appLocalized)
                default:
                    return String(localized: "Hugging Face returned an unexpected response (HTTP \(statusCode)).", bundle: .appLocalized)
                }
            case .noFilesFound:      return String(localized: "No files found for this model on HuggingFace.", bundle: .appLocalized)
            case .badURL(let file):  return String(localized: "Could not construct download URL for file: \(file)", bundle: .appLocalized)
            case .invalidRemotePath(let file):
                return String(localized: "The server returned an unexpected file path for: \(file)", bundle: .appLocalized)
            case .incorrectFileSize(let file, let expected, let actual):
                return String(localized: "Downloaded file '\(file)' has the wrong size (expected \(expected) bytes, received \(actual) bytes).", bundle: .appLocalized, locale: AppLanguage.current.locale)
            case .checksumMismatch(let file):
                return String(localized: "Downloaded file '\(file)' failed its integrity check. Try downloading the model again.", bundle: .appLocalized)
            }
        }
    }
}

// MARK: - Progress Aggregation

/// Combines per-file transfer progress into one overall fraction. Keeps
/// running totals so each update costs O(1).
nonisolated struct DownloadProgressAggregator {
    let completedBytesBeforeTransfers: Int64
    let completedFilesBeforeTransfers: Int
    let totalExpectedBytes: Int64
    let fileCount: Int

    private var bytesByTransfer: [String: Int64] = [:]
    private var transferredBytes: Int64 = 0
    private var fractionsByTransfer: [String: Double] = [:]
    private var transferredFileEquivalents: Double = 0

    init(
        completedBytesBeforeTransfers: Int64,
        completedFilesBeforeTransfers: Int,
        totalExpectedBytes: Int64,
        fileCount: Int
    ) {
        self.completedBytesBeforeTransfers = completedBytesBeforeTransfers
        self.completedFilesBeforeTransfers = completedFilesBeforeTransfers
        self.totalExpectedBytes = totalExpectedBytes
        self.fileCount = fileCount
    }

    /// Returns the overall progress, which stays below 1.0: completion is
    /// only reported once every file has been verified and moved into place.
    mutating func record(
        transferID: String,
        bytesWritten: Int64,
        serverExpectedBytes: Int64,
        declaredExpectedBytes: Int64
    ) -> Double? {
        // `totalBytesExpectedToWrite` is `NSURLSessionTransferSizeUnknown` (-1)
        // when the server omits Content-Length; fall back to the size the
        // HuggingFace API reported for this file.
        let expected = serverExpectedBytes > 0 ? serverExpectedBytes : declaredExpectedBytes
        let clamped = max(0, expected > 0 ? min(bytesWritten, expected) : bytesWritten)

        transferredBytes += clamped - (bytesByTransfer[transferID] ?? 0)
        bytesByTransfer[transferID] = clamped
        if expected > 0 {
            let fraction = min(Double(clamped) / Double(expected), 1.0)
            transferredFileEquivalents += fraction - (fractionsByTransfer[transferID] ?? 0)
            fractionsByTransfer[transferID] = fraction
        }

        if totalExpectedBytes > 0 {
            return min(
                Double(completedBytesBeforeTransfers + transferredBytes) / Double(totalExpectedBytes),
                0.999
            )
        } else if fileCount > 0 {
            return min(
                (Double(completedFilesBeforeTransfers) + transferredFileEquivalents) / Double(fileCount),
                0.999
            )
        }
        return nil
    }
}

/// Throttled, monotonic progress emission: at most one report per 1% change.
nonisolated struct DownloadProgressReporter {
    static let minimumStep = 0.01

    private(set) var lastReported: Double = -1

    mutating func shouldReport(_ progress: Double) -> Bool {
        guard progress - lastReported >= Self.minimumStep else { return false }
        lastReported = progress
        return true
    }

    mutating func markComplete() {
        lastReported = 1.0
    }
}

// MARK: - Verified File Marker

/// Records that a file's SHA-256 was checked, tied to the size and
/// modification time it had then. Any later change invalidates it.
nonisolated struct VerifiedFileMarker: Equatable {
    let sha256: String
    let size: Int64
    let modificationTime: Double

    init(sha256: String, size: Int64, modificationTime: Double) {
        self.sha256 = sha256.lowercased()
        self.size = size
        self.modificationTime = modificationTime
    }

    init?(encoded: String) {
        let parts = encoded.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "v1",
              let size = Int64(parts[2]),
              let modificationTime = Double(parts[3]) else {
            return nil
        }
        self.init(sha256: String(parts[1]), size: size, modificationTime: modificationTime)
    }

    var encoded: String {
        "v1|\(sha256)|\(size)|\(modificationTime)"
    }

    func matches(sha256 expected: String, size currentSize: Int64, modificationTime currentTime: Double) -> Bool {
        sha256 == expected.lowercased() && size == currentSize && modificationTime == currentTime
    }
}
