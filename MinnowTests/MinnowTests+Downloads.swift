//
//  MinnowTests+Downloads
//  MinnowTests
//
//  Model download state machine, resume, checksum and progress coverage, plus
//  Tavily networking behavior. Part of the single @Suite(.serialized) MinnowTests suite.
//

import Testing
import Foundation
@testable import Minnow

// MARK: - Test Doubles

/// Serves scripted responses for every request on sessions that install it.
/// State is static because URLSession instantiates the protocol itself; the
/// suite is serialized, so tests never overlap.
internal final class ScriptedURLProtocol: URLProtocol, @unchecked Sendable {
    enum Step {
        case respond(statusCode: Int, body: Data)
        case fail(URLError.Code)
        /// Never answers; the request ends only when its task is cancelled.
        case hang
    }

    nonisolated(unsafe) static var steps: [Step] = []
    nonisolated(unsafe) static var requestCount = 0
    private static let lock = NSLock()

    static func reset(_ newSteps: [Step]) {
        lock.withLock {
            steps = newSteps
            requestCount = 0
        }
    }

    static var recordedRequestCount: Int {
        lock.withLock { requestCount }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let step: Step = Self.lock.withLock {
            Self.requestCount += 1
            return Self.steps.isEmpty ? .fail(.resourceUnavailable) : Self.steps.removeFirst()
        }
        switch step {
        case .respond(let statusCode, let body):
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang:
            break
        }
    }

    override func stopLoading() {}
}

internal final class ProgressCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var labels: [String] = []

    func record(_ label: String) {
        lock.withLock { labels.append(label) }
    }

    var recorded: [String] {
        lock.withLock { labels }
    }
}

@MainActor
internal final class RecordingSearchProvider: WebSearchProviding {
    private(set) var queries: [String] = []

    func search(query: String, maxResults: Int, searchDepth: String?) async throws -> WebSearchResponse {
        queries.append(query)
        return WebSearchResponse(
            query: query,
            sources: [WebSearchSource(title: "Result", url: "https://example.com/result", snippet: "Snippet")]
        )
    }
}

private let tavilySuccessBody = Data("""
{"query":"swift concurrency","results":[{"title":"Swift Concurrency","url":"https://example.com/swift","content":"Actors and tasks.","score":0.9}]}
""".utf8)

extension MinnowTests {
    private typealias Registry = BackgroundTransferRegistry<String>
    private typealias Descriptor = BackgroundModelDownloadSession.TransferDescriptor

    private func makeDescriptor(
        _ name: String = "model.safetensors",
        remoteURL: String? = "https://huggingface.co/owner/model/resolve/abc/model.safetensors"
    ) -> Descriptor {
        Descriptor(
            id: "owner/model/\(name)",
            destinationPath: "/tmp/models/\(name).download",
            remoteURL: remoteURL
        )
    }

    // MARK: - Transfer Registry

    @Test func cancellingAnAttachedDownloadResumesItsWaiterExactlyOnce() {
        var registry = Registry()
        let descriptor = makeDescriptor()
        let token = UUID()
        registry.beginWaiter(token)

        guard case .attached = registry.attach("waiter", token: token, taskID: 1, descriptor: descriptor) else {
            Issue.record("Waiter should attach to a live task")
            return
        }
        guard case .detached(let waiter, let taskID) = registry.cancelWaiter(token) else {
            Issue.record("Cancelling an attached waiter should detach it")
            return
        }
        #expect(waiter == "waiter")
        #expect(taskID == 1)

        guard case .notWaiting = registry.cancelWaiter(token) else {
            Issue.record("A second cancel must not resume the waiter again")
            return
        }
        guard case .finished(let waiters, _) = registry.complete(
            taskID: 1,
            error: URLError(.cancelled),
            producedResumeData: false
        ) else {
            Issue.record("The cancelled task should still complete")
            return
        }
        #expect(waiters.isEmpty)
        #expect(registry.pendingWaiterCount == 0)
    }

    @Test func downloadCancelledBeforeItFindsATaskNeverAttaches() {
        var registry = Registry()
        let token = UUID()
        registry.beginWaiter(token)

        guard case .cancelledBeforeAttach = registry.cancelWaiter(token) else {
            Issue.record("Cancel before attach should be remembered")
            return
        }
        guard case .finished(.failure(let error)) = registry.attach(
            "waiter",
            token: token,
            taskID: 1,
            descriptor: makeDescriptor()
        ) else {
            Issue.record("Attach after cancel should finish with cancellation")
            return
        }
        #expect(error is CancellationError)
        #expect(registry.transfers[1] == nil)
        #expect(registry.pendingWaiterCount == 0)
    }

    @Test func restartingADownloadIsNotStoppedByTheEarlierRunsCancellation() {
        var registry = Registry()
        let descriptor = makeDescriptor()
        let oldRun = UUID()
        registry.beginWaiter(oldRun)
        _ = registry.cancelWaiter(oldRun)

        let newRun = UUID()
        registry.beginWaiter(newRun)
        let newRunWasCancelled = registry.consumeCancellationBeforeAttach(newRun)
        #expect(!newRunWasCancelled)
        guard case .attached = registry.attach("new", token: newRun, taskID: 2, descriptor: descriptor) else {
            Issue.record("The new run must not consume the old run's cancellation")
            return
        }

        registry.stage(.success(URL(fileURLWithPath: descriptor.destinationPath)), taskID: 2, descriptor: descriptor)
        guard case .finished(let waiters, .success(let url)) = registry.complete(
            taskID: 2,
            error: nil,
            producedResumeData: false
        ) else {
            Issue.record("The new run should receive its staged file")
            return
        }
        #expect(waiters == ["new"])
        #expect(url.path == descriptor.destinationPath)
    }

    @Test func waiterAttachingAfterItsTaskFinishedReceivesTheResult() {
        var registry = Registry()
        let descriptor = makeDescriptor()
        registry.setProgressObserver({ _, _ in }, taskID: 7, descriptor: descriptor)
        registry.stage(.success(URL(fileURLWithPath: descriptor.destinationPath)), taskID: 7, descriptor: descriptor)
        guard case .finished(let waiters, _) = registry.complete(taskID: 7, error: nil, producedResumeData: false) else {
            Issue.record("Prepared task should complete")
            return
        }
        #expect(waiters.isEmpty)

        let token = UUID()
        registry.beginWaiter(token)
        guard case .finished(.success(let url)) = registry.attach("late", token: token, taskID: 7, descriptor: descriptor) else {
            Issue.record("A late waiter must not wait forever on a finished task")
            return
        }
        #expect(url.path == descriptor.destinationPath)
        #expect(registry.pendingWaiterCount == 0)
    }

    @Test func transferWithoutAStagedFileReportsThatNoFileWasDelivered() {
        var registry = Registry()
        let token = UUID()
        registry.beginWaiter(token)
        _ = registry.attach("waiter", token: token, taskID: 3, descriptor: makeDescriptor())

        guard case .finished(let waiters, .failure(let error)) = registry.complete(
            taskID: 3,
            error: nil,
            producedResumeData: false
        ) else {
            Issue.record("A transfer with no file should fail")
            return
        }
        #expect(waiters == ["waiter"])
        guard case .noFileDelivered? = error as? BackgroundModelDownloadSession.BackgroundDownloadError else {
            Issue.record("Expected noFileDelivered, got \(error)")
            return
        }
    }

    @Test func rejectedResumeDataRestartsTheTransferOnceFromScratch() throws {
        var registry = Registry()
        let descriptor = makeDescriptor()
        let remoteURL = try #require(descriptor.remoteURL)
        let fallbackURL = try #require(URL(string: remoteURL))
        registry.recordTaskCreation(taskID: 4, descriptor: descriptor, resumeFallbackURL: fallbackURL)
        let token = UUID()
        registry.beginWaiter(token)
        _ = registry.attach("waiter", token: token, taskID: 4, descriptor: descriptor)

        guard case .retryFromScratch(let retryURL) = registry.complete(
            taskID: 4,
            error: URLError(.cannotDecodeContentData),
            producedResumeData: false
        ) else {
            Issue.record("A failed resume should restart from the remote URL")
            return
        }
        #expect(retryURL == fallbackURL)

        registry.moveTransfer(fromTaskID: 4, toTaskID: 5)
        guard case .finished(let waiters, .failure) = registry.complete(
            taskID: 5,
            error: URLError(.timedOut),
            producedResumeData: false
        ) else {
            Issue.record("The fresh task must not retry again")
            return
        }
        #expect(waiters == ["waiter"])
    }

    @Test func resumeRefusedWithAnHTTPErrorRestartsFromScratch() throws {
        var registry = Registry()
        let descriptor = makeDescriptor()
        let remoteURL = try #require(descriptor.remoteURL)
        let fallbackURL = try #require(URL(string: remoteURL))
        registry.recordTaskCreation(taskID: 8, descriptor: descriptor, resumeFallbackURL: fallbackURL)
        // An expired signed URL in the resume data: the task ends without a
        // transport error, with a 403 staged instead of a file.
        registry.stage(
            .failure(BackgroundModelDownloadSession.BackgroundDownloadError.badResponse(statusCode: 403)),
            taskID: 8,
            descriptor: descriptor
        )

        guard case .retryFromScratch(let retryURL) = registry.complete(
            taskID: 8, error: nil, producedResumeData: false
        ) else {
            Issue.record("A resume refused with an HTTP error should restart from the remote URL")
            return
        }
        #expect(retryURL == fallbackURL)
    }

    @Test func cancelledResumedTransferIsNotRestarted() throws {
        var registry = Registry()
        let descriptor = makeDescriptor()
        let remoteURL = try #require(descriptor.remoteURL)
        let fallbackURL = try #require(URL(string: remoteURL))
        registry.recordTaskCreation(taskID: 6, descriptor: descriptor, resumeFallbackURL: fallbackURL)

        guard case .finished = registry.complete(taskID: 6, error: URLError(.cancelled), producedResumeData: true) else {
            Issue.record("A cancelled transfer should finish")
            return
        }
    }

    @Test func pendingPrefixCancelOnlyTargetsTasksCreatedBeforeIt() {
        var registry = Registry()
        let descriptor = makeDescriptor()
        registry.recordTaskCreation(taskID: 10, descriptor: descriptor, resumeFallbackURL: nil)

        let sequence = registry.beginPrefixCancel("owner/model/")
        #expect(registry.shouldCancel(taskID: 10, forCancelSequence: sequence))
        // Tasks restored from an earlier process are unknown and count as older.
        #expect(registry.shouldCancel(taskID: 99, forCancelSequence: sequence))
        #expect(!registry.isAdoptable(taskID: 10, isLive: true, existing: descriptor, requested: descriptor))

        registry.recordTaskCreation(taskID: 11, descriptor: descriptor, resumeFallbackURL: nil)
        #expect(!registry.shouldCancel(taskID: 11, forCancelSequence: sequence))
        #expect(registry.isAdoptable(taskID: 11, isLive: true, existing: descriptor, requested: descriptor))

        let otherModel = Descriptor(id: "other/model/a", destinationPath: "/tmp/other/a.download", remoteURL: nil)
        #expect(registry.isAdoptable(taskID: 12, isLive: true, existing: otherModel, requested: otherModel))

        registry.endPrefixCancel(sequence)
        #expect(registry.isAdoptable(taskID: 10, isLive: true, existing: descriptor, requested: descriptor))
    }

    @Test func onlyLiveTasksForTheSameFileAndURLAreAdopted() {
        let registry = Registry()
        let requested = makeDescriptor()
        let otherRevision = makeDescriptor(remoteURL: "https://huggingface.co/owner/model/resolve/old/model.safetensors")
        let legacy = makeDescriptor(remoteURL: nil)
        let otherDestination = Descriptor(
            id: requested.id,
            destinationPath: "/tmp/elsewhere/model.safetensors.download",
            remoteURL: requested.remoteURL
        )

        #expect(registry.isAdoptable(taskID: 1, isLive: true, existing: requested, requested: requested))
        #expect(!registry.isAdoptable(taskID: 1, isLive: false, existing: requested, requested: requested))
        #expect(!registry.isAdoptable(taskID: 1, isLive: true, existing: otherRevision, requested: requested))
        #expect(!registry.isAdoptable(taskID: 1, isLive: true, existing: otherDestination, requested: requested))
        #expect(registry.isAdoptable(taskID: 1, isLive: true, existing: legacy, requested: requested))
    }

    @Test func preparingATaskAgainReplacesItsProgressObserver() {
        var registry = Registry()
        let descriptor = makeDescriptor()
        let recorder = ProgressCallRecorder()
        registry.setProgressObserver({ _, _ in recorder.record("old") }, taskID: 1, descriptor: descriptor)
        registry.setProgressObserver({ _, _ in recorder.record("new") }, taskID: 1, descriptor: descriptor)

        let observer = registry.progressObserverToNotify(taskID: 1, bytesWritten: 10, bytesExpected: 100, now: 0)
        observer?(10, 100)

        #expect(recorder.recorded == ["new"])
    }

    @Test func transferProgressIsThrottledToMeaningfulChanges() {
        var throttle = TransferProgressThrottle()

        let samples: [(bytes: Int64, time: TimeInterval)] = [
            (0, 0), (1, 0.01), (5, 0.02), (6, 0.03), (7, 0.2), (1_000, 0.21), (1_000, 0.5), (0, 0.51)
        ]
        let decisions = samples.map {
            throttle.shouldNotify(bytesWritten: $0.bytes, bytesExpected: 1_000, now: $0.time)
        }

        #expect(decisions == [true, false, true, false, true, true, false, true])
    }

    @Test func backgroundEventsHandlerRunsWhicheverEventArrivesFirst() {
        var handlerFirst = BackgroundEventsCompletion<String>()
        let storedEarly = handlerFirst.store("handler")
        let finishedLate = handlerFirst.finishEvents()
        #expect(storedEarly == nil)
        #expect(finishedLate == "handler")

        var eventsFirst = BackgroundEventsCompletion<String>()
        let finishedEarly = eventsFirst.finishEvents()
        let storedLate = eventsFirst.store("handler")
        let finishedAgain = eventsFirst.finishEvents()
        #expect(finishedEarly == nil)
        #expect(storedLate == "handler")
        #expect(finishedAgain == nil)
    }

    @Test func transferDescriptorsFromOlderBuildsStillDecode() throws {
        let legacyJSON = Data(#"{"id":"owner/model/a","destinationPath":"/tmp/a.download"}"#.utf8)
        let decoded = try #require(
            BackgroundModelDownloadSession.decodeDescriptor(legacyJSON.base64EncodedString())
        )

        #expect(decoded.id == "owner/model/a")
        #expect(decoded.remoteURL == nil)
        #expect(
            BackgroundModelDownloadSession.resumeDataURL(forDestinationPath: "/tmp/a.download").path
                == "/tmp/a.download.resume"
        )
    }

    // MARK: - Progress Aggregation

    @Test func aggregateDownloadProgressNeverReachesCompletionWhileTransferring() {
        var aggregator = DownloadProgressAggregator(
            completedBytesBeforeTransfers: 100,
            completedFilesBeforeTransfers: 1,
            totalExpectedBytes: 300,
            fileCount: 3
        )

        let half = aggregator.record(transferID: "a", bytesWritten: 50, serverExpectedBytes: 100, declaredExpectedBytes: 100)
        #expect(half == 0.5)
        // Unknown Content-Length falls back to the declared size.
        let more = aggregator.record(transferID: "b", bytesWritten: 100, serverExpectedBytes: -1, declaredExpectedBytes: 100)
        #expect(more == 250.0 / 300.0)
        let all = aggregator.record(transferID: "a", bytesWritten: 500, serverExpectedBytes: 100, declaredExpectedBytes: 100)
        #expect(all == 0.999)
    }

    @Test func aggregateDownloadProgressCountsFilesWhenSizesAreUnknown() {
        var aggregator = DownloadProgressAggregator(
            completedBytesBeforeTransfers: 0,
            completedFilesBeforeTransfers: 1,
            totalExpectedBytes: 0,
            fileCount: 2
        )

        let progress = aggregator.record(transferID: "a", bytesWritten: 50, serverExpectedBytes: 100, declaredExpectedBytes: 0)
        #expect(progress == 0.75)
    }

    @Test func reportedDownloadProgressOnlyMovesForward() {
        var reporter = DownloadProgressReporter()

        let decisions = [0.2, 0.205, 0.1, 0.25].map { reporter.shouldReport($0) }
        reporter.markComplete()
        let afterCompletion = reporter.shouldReport(0.999)

        #expect(decisions == [true, false, false, true])
        #expect(!afterCompletion)
    }

    // MARK: - Checksums

    @Test func verifiedChecksumMarkerRoundTripsAndRejectsChangedFiles() throws {
        let marker = VerifiedFileMarker(sha256: "ABC", size: 42, modificationTime: 123.456789)
        let decoded = try #require(VerifiedFileMarker(encoded: marker.encoded))

        #expect(decoded == marker)
        #expect(decoded.matches(sha256: "abc", size: 42, modificationTime: 123.456789))
        #expect(!decoded.matches(sha256: "abc", size: 43, modificationTime: 123.456789))
        #expect(!decoded.matches(sha256: "abc", size: 42, modificationTime: 124))
        #expect(!decoded.matches(sha256: "def", size: 42, modificationTime: 123.456789))
        #expect(VerifiedFileMarker(encoded: "garbage") == nil)
    }

    @Test func verifiedFilesAreNotHashedAgainUntilTheyChange() async throws {
        let directory = testEnvironment.directory.appendingPathComponent("checksums", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("weights.safetensors")
        try Data("model weights".utf8).write(to: file)
        let size = Int64(Data("model weights".utf8).count)
        let realSHA = try await ModelDownloader.sha256Hex(of: file)

        // A correct checksum is accepted and remembered.
        #expect(try await ModelDownloader.fileMatches(at: file, expectedSize: size, expectedSHA256: realSHA))
        #expect(ModelDownloader.hasVerifiedChecksum(realSHA, at: file))

        // A marker for a different checksum short-circuits hashing entirely,
        // which shows that a verified file is trusted without being re-read.
        let claimedSHA = String(repeating: "a", count: 64)
        ModelDownloader.recordVerifiedChecksum(claimedSHA, at: file)
        #expect(try await ModelDownloader.fileMatches(at: file, expectedSize: size, expectedSHA256: claimedSHA))

        // Touching the file invalidates the marker, so it is hashed again.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: file.path
        )
        #expect(!ModelDownloader.hasVerifiedChecksum(claimedSHA, at: file))
        #expect(try await ModelDownloader.fileMatches(at: file, expectedSize: size, expectedSHA256: claimedSHA) == false)
        #expect(try await ModelDownloader.fileMatches(at: file, expectedSize: size + 1, expectedSHA256: realSHA) == false)
    }

    // MARK: - Backups

    @Test func modelFoldersAreExcludedFromBackups() throws {
        let documents = testEnvironment.directory.appendingPathComponent("backup-docs", isDirectory: true)
        let models = documents.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)

        _ = MLXModelManager(
            deviceSupportProfile: MLXDeviceSupportProfile(isPhone: true, ramPrecautionsDisabledOverride: false),
            defaults: testEnvironment.defaults,
            documentsDirectory: documents,
            restoresBackgroundDownloads: false
        )

        let values = try URL(fileURLWithPath: models.path).resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)

        let missing = documents.appendingPathComponent("Missing", isDirectory: true)
        ModelDownloader.excludeFromBackup(missing)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    // MARK: - Model File List

    @Test func modelFileListRetriesOneServerErrorAndParsesLFSMetadata() async throws {
        let body = Data("""
        {"siblings":[{"rfilename":"config.json","size":12},{"rfilename":"model.safetensors","size":10,"lfs":{"size":2048,"sha256":"ABCDEF"}}]}
        """.utf8)
        ScriptedURLProtocol.reset([.respond(statusCode: 503, body: Data()), .respond(statusCode: 200, body: body)])
        let downloader = ModelDownloader(metadataSession: ScriptedURLProtocol.makeSession())

        let files = try await downloader.fetchFileList(repoId: "owner/model", revision: "abc")

        #expect(ScriptedURLProtocol.recordedRequestCount == 2)
        #expect(files.map(\.name) == ["config.json", "model.safetensors"])
        #expect(files.last?.size == 2048)
        #expect(files.last?.sha256 == "abcdef")
    }

    @Test func gatedModelFileListExplainsThatAccessIsRequired() async {
        ScriptedURLProtocol.reset([.respond(statusCode: 403, body: Data())])
        let downloader = ModelDownloader(metadataSession: ScriptedURLProtocol.makeSession())

        do {
            _ = try await downloader.fetchFileList(repoId: "owner/model", revision: "abc")
            Issue.record("A 403 listing should fail")
        } catch let error as ModelDownloader.DownloadError {
            guard case .metadataHTTPStatus(403) = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
            #expect(error.localizedDescription.contains("requires access"))
        } catch {
            Issue.record("Unexpected error \(error)")
        }
        #expect(ScriptedURLProtocol.recordedRequestCount == 1)
    }

    @Test func modelFileListStatusCodesMapToSpecificMessages() {
        let notFound = ModelDownloader.DownloadError.metadataHTTPStatus(404).localizedDescription
        let limited = ModelDownloader.DownloadError.metadataHTTPStatus(429).localizedDescription
        let unavailable = ModelDownloader.DownloadError.metadataHTTPStatus(502).localizedDescription

        #expect(notFound.contains("not found"))
        #expect(limited.contains("Try again in a few minutes"))
        #expect(unavailable.contains("502"))
        #expect(!notFound.contains("internet connection"))
    }

    // MARK: - Tavily

    @Test func tavilyNestedErrorDetailIsShownAsText() async throws {
        ScriptedURLProtocol.reset([
            .respond(statusCode: 400, body: Data(#"{"detail":{"error":"Query is invalid."}}"#.utf8))
        ])
        let service = try TavilySearchService(apiKey: "test-key", session: ScriptedURLProtocol.makeSession())

        do {
            _ = try await service.search(query: "swift concurrency")
            Issue.record("A 400 response should fail")
        } catch {
            #expect(error.localizedDescription.contains("Query is invalid."))
            #expect(!error.localizedDescription.contains("{"))
        }
    }

    @Test func tavilyPlanLimitStatusReportsUsageLimit() async throws {
        ScriptedURLProtocol.reset([
            .respond(statusCode: 432, body: Data(#"{"detail":{"error":"Plan limit exceeded."}}"#.utf8))
        ])
        let service = try TavilySearchService(apiKey: "test-key", session: ScriptedURLProtocol.makeSession())

        await #expect {
            _ = try await service.search(query: "swift concurrency")
        } throws: { error in
            if case .usageLimitReached? = error as? TavilySearchError { return true }
            return false
        }
    }

    @Test func cancelledTavilyKeyValidationThrowsCancellation() async throws {
        ScriptedURLProtocol.reset([.hang])
        let service = try TavilySearchService(apiKey: "test-key", session: ScriptedURLProtocol.makeSession())

        let validation = Task { try await service.validateAPIKey() }
        for _ in 0..<100 where ScriptedURLProtocol.recordedRequestCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        validation.cancel()

        let result = await validation.result
        guard case .failure(let error) = result else {
            Issue.record("Cancelled validation should fail")
            return
        }
        #expect(error is CancellationError)
    }

    @Test func tavilySearchRetriesOnlyTransientNetworkErrors() async throws {
        let session = ScriptedURLProtocol.makeSession()

        ScriptedURLProtocol.reset([.fail(.badURL)])
        let failing = try TavilySearchService(apiKey: "test-key", session: session)
        await #expect(throws: TavilySearchError.self) {
            _ = try await failing.search(query: "swift concurrency")
        }
        #expect(ScriptedURLProtocol.recordedRequestCount == 1)

        ScriptedURLProtocol.reset([.fail(.timedOut), .respond(statusCode: 200, body: tavilySuccessBody)])
        let recovering = try TavilySearchService(apiKey: "test-key", session: session)
        let response = try await recovering.search(query: "swift concurrency")
        #expect(ScriptedURLProtocol.recordedRequestCount == 2)
        #expect(response.sources.first?.url == "https://example.com/swift")
    }

    @Test func tavilyResultsAreSharedAcrossServicesForTheSameKey() async throws {
        let cache = TavilySearchResultCache()
        let session = ScriptedURLProtocol.makeSession()
        ScriptedURLProtocol.reset([.respond(statusCode: 200, body: tavilySuccessBody)])
        let first = try TavilySearchService(apiKey: "shared-key", session: session, cache: cache)
        _ = try await first.search(query: "swift concurrency")

        ScriptedURLProtocol.reset([.respond(statusCode: 500, body: Data())])
        let recreated = try TavilySearchService(apiKey: "shared-key", session: session, cache: cache)
        let cached = try await recreated.search(query: "swift concurrency")
        #expect(cached.sources.first?.url == "https://example.com/swift")
        #expect(ScriptedURLProtocol.recordedRequestCount == 0)

        ScriptedURLProtocol.reset([.respond(statusCode: 500, body: Data()), .respond(statusCode: 500, body: Data())])
        let otherKey = try TavilySearchService(apiKey: "other-key", session: session, cache: cache)
        await #expect(throws: TavilySearchError.self) {
            _ = try await otherKey.search(query: "swift concurrency")
        }
    }

    @Test func liveQueryDetectionMatchesWholeWordsOnly() {
        #expect(!TavilySearchService.isLiveQuery("how to deliver olive oil"))
        #expect(!TavilySearchService.isLiveQuery("Diskurs über Philosophie"))
        #expect(!TavilySearchService.isLiveQuery("python underscore naming"))
        #expect(!TavilySearchService.isLiveQuery("I actually believe it"))
        #expect(TavilySearchService.isLiveQuery("live score Real Madrid"))
        #expect(TavilySearchService.isLiveQuery("tech news this week"))
        #expect(TavilySearchService.isLiveQuery("Wie ist das Wetter jetzt?"))
    }

    // MARK: - Web Search Tool

    @Test func emptyWebSearchQueryDoesNotUseASearchSlot() async throws {
        let provider = RecordingSearchProvider()
        let bridge = AppWebSearchToolBridge(searchService: provider)

        let result = try await bridge.executeSearch(query: "   \n ")

        #expect(result == AppWebSearchToolBridge.invalidArgumentsToolResponse())
        #expect(bridge.allInvocations.isEmpty)
        #expect(provider.queries.isEmpty)
    }

    @Test func overlongWebSearchQueryIsShortenedAtAWordBoundary() async throws {
        let provider = RecordingSearchProvider()
        let bridge = AppWebSearchToolBridge(searchService: provider)
        let longQuery = Array(repeating: "swift", count: 120).joined(separator: " ")

        _ = try await bridge.executeSearch(query: longQuery)

        let sent = try #require(provider.queries.first)
        #expect(sent.count <= TavilySearchService.maximumQueryLength)
        #expect(sent.hasSuffix("swift"))
        #expect(bridge.allInvocations.first?.status == .completed)
    }

    @Test func legacySourceHeadingsAreRecognizedWithoutRegularExpressions() {
        let line = "[12]  Example Title"
        let end = WebSearchSource.legacyHeadingPrefixEnd(in: line)
        #expect(end.map { String(line[$0...]) } == "Example Title")
        #expect(WebSearchSource.legacyHeadingPrefixEnd(in: "[12]Example") == nil)
        #expect(WebSearchSource.legacyHeadingPrefixEnd(in: "[] Example") == nil)
        #expect(WebSearchSource.legacyHeadingPrefixEnd(in: "Example [1] title") == nil)
    }

    // MARK: - Tavily Key Store

    @Test func tavilyKeySaveReportsSuccessAndClearForgetsTheKey() throws {
        let suiteName = "tavily-save-result-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let service = "test.service.\(UUID().uuidString)"
        let account = "test.account"
        defer {
            TavilyAPIKeyStore.clear(userDefaults: defaults, service: service, account: account, postNotification: false)
            defaults.removePersistentDomain(forName: suiteName)
        }

        #expect(TavilyAPIKeyStore.currentKey(userDefaults: defaults, service: service, account: account) == nil)
        #expect(TavilyAPIKeyStore.save("first-key", userDefaults: defaults, service: service, account: account))
        #expect(TavilyAPIKeyStore.currentKey(userDefaults: defaults, service: service, account: account) == "first-key")
        #expect(TavilyAPIKeyStore.save("second-key", userDefaults: defaults, service: service, account: account))
        #expect(TavilyAPIKeyStore.currentKey(userDefaults: defaults, service: service, account: account) == "second-key")

        TavilyAPIKeyStore.clear(userDefaults: defaults, service: service, account: account, postNotification: false)
        #expect(TavilyAPIKeyStore.currentKey(userDefaults: defaults, service: service, account: account) == nil)
    }

    @Test func downloadAndSearchLimitErrorsAreTranslated() {
        let statusCode = 503
        #expect(String(localized: "This model version was not found on Hugging Face.", bundle: AppLanguage.german.bundle)
            == "Diese Modellversion wurde auf Hugging Face nicht gefunden.")
        #expect(String(localized: "Hugging Face is temporarily unavailable (HTTP \(statusCode)). Try again later.", bundle: AppLanguage.spanish.bundle)
            == "Hugging Face no está disponible temporalmente (HTTP 503). Vuelve a intentarlo más tarde.")
        #expect(String(localized: "Your Tavily plan has run out of search credits. Check your plan on tavily.com.", bundle: AppLanguage.german.bundle)
            == "Dein Tavily-Tarif hat keine Suchguthaben mehr. Prüfe deinen Tarif auf tavily.com.")
    }
}
