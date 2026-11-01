//
//  BackgroundModelDownloadSession.swift
//  Minnow
//
//  Owns the background URLSession used for large model file transfers.
//

import Foundation
import OSLog

nonisolated private let backgroundDownloadLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Minnow",
    category: "BackgroundModelDownload"
)

nonisolated final class BackgroundModelDownloadSession: NSObject, @unchecked Sendable {
    static let shared = BackgroundModelDownloadSession()
    static let sessionIdentifier = "Nevio.Minnow.model-downloads"

    typealias ProgressObserver = @Sendable (Int64, Int64) -> Void
    /// The system's background-events handler, which must be called on the main thread.
    typealias EventsCompletionHandler = @MainActor @Sendable () -> Void

    struct PreparedDownload: Sendable {
        let remoteURL: URL
        let destinationURL: URL
        let transferID: String
        let onProgress: ProgressObserver
    }

    /// Persisted in `URLSessionTask.taskDescription` so a relaunched process
    /// can tell which file a surviving background task belongs to.
    struct TransferDescriptor: Codable, Sendable, Equatable {
        let id: String
        let destinationPath: String
        /// Absent in descriptors written by older builds.
        let remoteURL: String?

        init(id: String, destinationPath: String, remoteURL: String? = nil) {
            self.id = id
            self.destinationPath = destinationPath
            self.remoteURL = remoteURL
        }
    }

    /// Resume data is stored next to the partial file, together with the URL
    /// it belongs to, so a later run never resumes a different revision.
    private struct ResumeRecord: Codable {
        let remoteURL: String
        let data: Data
    }

    private typealias Continuation = CheckedContinuation<URL, any Error>

    private let stateLock = NSLock()
    private var registry = BackgroundTransferRegistry<Continuation>()
    private var eventsCompletion = BackgroundEventsCompletion<EventsCompletionHandler>()

    private var session: URLSession!

    private override init() {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        // Background sessions always wait for connectivity, so
        // `waitsForConnectivity` is not set here. Downloads start only when the
        // user taps Download next to the model's size, so they may also use
        // cellular, expensive, and Low Data Mode networks.
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.httpMaximumConnectionsPerHost = 3
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    // MARK: - Transfers

    func download(
        from remoteURL: URL,
        to destinationURL: URL,
        transferID: String
    ) async throws -> URL {
        // Registered before the cancellation handler is installed, so a task
        // that is already cancelled still finds this waiter and stops it.
        let token = UUID()
        withRegistry { $0.beginWaiter(token) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                attachOrCreateTask(
                    from: remoteURL,
                    to: destinationURL,
                    transferID: transferID,
                    token: token,
                    continuation: continuation
                )
            }
        } onCancel: {
            cancelWaiter(token)
        }
    }

    /// Enqueues every remaining repository file before the app can be suspended.
    /// The background session keeps these tasks alive even when no in-process
    /// continuation is currently waiting for a particular file.
    func prepareDownloads(_ downloads: [PreparedDownload]) async {
        guard !downloads.isEmpty else { return }

        await withCheckedContinuation { continuation in
            session.getAllTasks { [weak self] tasks in
                guard let self else {
                    continuation.resume()
                    return
                }

                for download in downloads {
                    guard !FileManager.default.fileExists(
                        atPath: download.destinationURL.path
                    ) else {
                        continue
                    }

                    let descriptor = TransferDescriptor(
                        id: download.transferID,
                        destinationPath: download.destinationURL.path,
                        remoteURL: download.remoteURL.absoluteString
                    )

                    if let existing = self.adoptableTask(in: tasks, for: descriptor) {
                        self.withRegistry {
                            $0.setProgressObserver(
                                download.onProgress,
                                taskID: existing.task.taskIdentifier,
                                descriptor: existing.descriptor
                            )
                        }
                        if existing.task.state == .suspended {
                            existing.task.resume()
                        }
                        continue
                    }

                    guard let task = self.makeTask(remoteURL: download.remoteURL, descriptor: descriptor) else {
                        continue
                    }
                    self.withRegistry {
                        $0.setProgressObserver(
                            download.onProgress,
                            taskID: task.taskIdentifier,
                            descriptor: descriptor
                        )
                    }
                    task.resume()
                }

                continuation.resume()
            }
        }
    }

    /// Cancels every task whose transfer ID starts with `prefix`. By default it keeps
    /// resume data so a retry continues where each file stopped; a caller that is
    /// discarding the partial download passes false and skips producing it.
    func cancelTransfers(withIDPrefix prefix: String, preservingResumeData: Bool = true) {
        let sequence = withRegistry { $0.beginPrefixCancel(prefix) }
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let tasksToCancel = self.withRegistry { registry in
                tasks.filter { task in
                    guard let descriptor = Self.descriptor(of: task),
                          descriptor.id.hasPrefix(prefix) else {
                        return false
                    }
                    return registry.shouldCancel(
                        taskID: task.taskIdentifier,
                        forCancelSequence: sequence
                    )
                }
            }
            for task in tasksToCancel {
                if preservingResumeData {
                    self.cancelPreservingResumeData(task)
                } else {
                    task.cancel()
                }
            }
            self.withRegistry { $0.endPrefixCancel(sequence) }
        }
    }

    func handleEventsForBackgroundSession(completionHandler: @escaping EventsCompletionHandler) {
        // Touching `shared` creates the session, which can deliver
        // `urlSessionDidFinishEvents` before this line runs. The state
        // remembers that and hands the handler straight back.
        let readyHandler = withRegistryLock { eventsCompletion.store(completionHandler) }
        guard let readyHandler else { return }
        DispatchQueue.main.async {
            readyHandler()
        }
    }

    // MARK: - Task Management

    private func attachOrCreateTask(
        from remoteURL: URL,
        to destinationURL: URL,
        transferID: String,
        token: UUID,
        continuation: Continuation
    ) {
        let descriptor = TransferDescriptor(
            id: transferID,
            destinationPath: destinationURL.path,
            remoteURL: remoteURL.absoluteString
        )

        session.getAllTasks { [weak self] tasks in
            guard let self else {
                continuation.resume(throwing: CancellationError())
                return
            }

            if self.withRegistry({ $0.consumeCancellationBeforeAttach(token) }) {
                continuation.resume(throwing: CancellationError())
                return
            }

            if let existing = self.adoptableTask(in: tasks, for: descriptor) {
                let outcome = self.withRegistry {
                    $0.attach(
                        continuation,
                        token: token,
                        taskID: existing.task.taskIdentifier,
                        descriptor: existing.descriptor
                    )
                }
                if case .finished(let result) = outcome {
                    continuation.resume(with: result)
                    return
                }
                if existing.task.state == .suspended {
                    existing.task.resume()
                }
                return
            }

            if FileManager.default.fileExists(atPath: descriptor.destinationPath) {
                self.withRegistry { $0.finishWaiterWithoutTask(token) }
                continuation.resume(
                    returning: URL(fileURLWithPath: descriptor.destinationPath)
                )
                return
            }

            guard let task = self.makeTask(remoteURL: remoteURL, descriptor: descriptor) else {
                self.withRegistry { $0.finishWaiterWithoutTask(token) }
                continuation.resume(throwing: BackgroundDownloadError.missingTaskDescription)
                return
            }
            let outcome = self.withRegistry {
                $0.attach(
                    continuation,
                    token: token,
                    taskID: task.taskIdentifier,
                    descriptor: descriptor
                )
            }
            if case .finished(let result) = outcome {
                // Cancelled while the task was being created; it never started.
                task.cancel()
                continuation.resume(with: result)
                return
            }
            task.resume()
        }
    }

    /// Creates a task for `descriptor`, resuming from stored resume data when
    /// it exists. The task is registered but not resumed.
    private func makeTask(remoteURL: URL, descriptor: TransferDescriptor) -> URLSessionDownloadTask? {
        guard let encodedDescriptor = Self.encodeDescriptor(descriptor) else { return nil }

        let resumeData = Self.takeResumeData(
            forDestinationPath: descriptor.destinationPath,
            remoteURL: remoteURL
        )
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
            backgroundDownloadLogger.notice(
                "Resuming model transfer from saved resume data: id=\(descriptor.id, privacy: .public)"
            )
        } else {
            task = session.downloadTask(with: remoteURL)
        }
        task.taskDescription = encodedDescriptor
        task.priority = URLSessionTask.highPriority
        withRegistry {
            $0.recordTaskCreation(
                taskID: task.taskIdentifier,
                descriptor: descriptor,
                resumeFallbackURL: resumeData == nil ? nil : remoteURL
            )
        }
        return task
    }

    private func adoptableTask(
        in tasks: [URLSessionTask],
        for descriptor: TransferDescriptor
    ) -> (task: URLSessionTask, descriptor: TransferDescriptor)? {
        withRegistry { registry in
            for task in tasks {
                guard let existing = Self.descriptor(of: task) else { continue }
                let isLive = task.state == .running || task.state == .suspended
                if registry.isAdoptable(
                    taskID: task.taskIdentifier,
                    isLive: isLive,
                    existing: existing,
                    requested: descriptor
                ) {
                    return (task, existing)
                }
            }
            return nil
        }
    }

    private func cancelWaiter(_ token: UUID) {
        switch withRegistry({ $0.cancelWaiter(token) }) {
        case .notWaiting, .cancelledBeforeAttach:
            return
        case .detached(let continuation, let taskID):
            continuation.resume(throwing: CancellationError())
            session.getAllTasks { [weak self] tasks in
                guard let self else { return }
                for task in tasks where task.taskIdentifier == taskID {
                    self.cancelPreservingResumeData(task)
                }
            }
        }
    }

    private func cancelPreservingResumeData(_ task: URLSessionTask) {
        guard let downloadTask = task as? URLSessionDownloadTask,
              let descriptor = Self.descriptor(of: task) else {
            task.cancel()
            return
        }
        let remoteURL = descriptor.remoteURL ?? task.originalRequest?.url?.absoluteString
        downloadTask.cancel(byProducingResumeData: { resumeData in
            guard let resumeData, let remoteURL else { return }
            Self.storeResumeData(
                resumeData,
                remoteURL: remoteURL,
                destinationPath: descriptor.destinationPath
            )
        })
    }

    private func stageDownloadedFile(
        from location: URL,
        for task: URLSessionDownloadTask
    ) -> Result<URL, any Error> {
        guard let http = task.response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let statusCode = (task.response as? HTTPURLResponse)?.statusCode
            return .failure(BackgroundDownloadError.badResponse(statusCode: statusCode))
        }

        guard let descriptor = Self.descriptor(of: task) else {
            return .failure(BackgroundDownloadError.missingTaskDescription)
        }

        let destinationURL = URL(fileURLWithPath: descriptor.destinationPath)
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fileManager.removeItem(at: destinationURL)
            try fileManager.moveItem(at: location, to: destinationURL)
            try? fileManager.removeItem(at: Self.resumeDataURL(forDestinationPath: descriptor.destinationPath))
            return .success(destinationURL)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Locking

    private func withRegistry<T>(_ body: (inout BackgroundTransferRegistry<Continuation>) -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body(&registry)
    }

    private func withRegistryLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    // MARK: - Resume Data

    static func resumeDataURL(forDestinationPath destinationPath: String) -> URL {
        URL(fileURLWithPath: destinationPath + ".resume")
    }

    private static func storeResumeData(
        _ data: Data,
        remoteURL: String,
        destinationPath: String
    ) {
        let url = resumeDataURL(forDestinationPath: destinationPath)
        // A missing folder means the partial download was discarded.
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else {
            return
        }
        do {
            let encoded = try PropertyListEncoder().encode(
                ResumeRecord(remoteURL: remoteURL, data: data)
            )
            try encoded.write(to: url, options: .atomic)
        } catch {
            backgroundDownloadLogger.error(
                "Could not save model transfer resume data: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Reads and removes the stored resume data. A new task will produce fresh
    /// resume data if it is interrupted again.
    private static func takeResumeData(forDestinationPath destinationPath: String, remoteURL: URL) -> Data? {
        let url = resumeDataURL(forDestinationPath: destinationPath)
        guard let encoded = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        guard let record = try? PropertyListDecoder().decode(ResumeRecord.self, from: encoded),
              record.remoteURL == remoteURL.absoluteString,
              !record.data.isEmpty else {
            return nil
        }
        return record.data
    }

    // MARK: - Descriptors

    internal static func encodeDescriptor(
        id: String,
        destinationPath: String,
        remoteURL: String? = nil
    ) -> String? {
        encodeDescriptor(TransferDescriptor(id: id, destinationPath: destinationPath, remoteURL: remoteURL))
    }

    internal static func decodeDescriptorForTesting(_ value: String) -> (id: String, destinationPath: String)? {
        guard let descriptor = decodeDescriptor(value) else { return nil }
        return (descriptor.id, descriptor.destinationPath)
    }

    static func encodeDescriptor(_ descriptor: TransferDescriptor) -> String? {
        guard let data = try? JSONEncoder().encode(descriptor) else { return nil }
        return data.base64EncodedString()
    }

    static func decodeDescriptor(_ value: String) -> TransferDescriptor? {
        guard let data = Data(base64Encoded: value) else { return nil }
        return try? JSONDecoder().decode(TransferDescriptor.self, from: data)
    }

    private static func descriptor(of task: URLSessionTask) -> TransferDescriptor? {
        task.taskDescription.flatMap(decodeDescriptor)
    }

    enum BackgroundDownloadError: LocalizedError {
        case badResponse(statusCode: Int?)
        case missingTaskDescription
        case noFileDelivered

        var errorDescription: String? {
            switch self {
            case .badResponse(let statusCode):
                if let statusCode {
                    return String(localized: "The model server returned HTTP \(statusCode).", bundle: .appLocalized)
                }
                return String(localized: "The model server returned an unexpected response.", bundle: .appLocalized)
            case .missingTaskDescription:
                return String(localized: "The background model download lost its destination information.", bundle: .appLocalized)
            case .noFileDelivered:
                return String(localized: "The model server finished the transfer without delivering a file.", bundle: .appLocalized)
            }
        }
    }
}

// MARK: - URLSession Delegate

extension BackgroundModelDownloadSession: URLSessionDownloadDelegate, URLSessionTaskDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let observer = withRegistry {
            $0.progressObserverToNotify(
                taskID: downloadTask.taskIdentifier,
                bytesWritten: totalBytesWritten,
                bytesExpected: totalBytesExpectedToWrite,
                now: now
            )
        }
        observer?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let result = stageDownloadedFile(from: location, for: downloadTask)
        let descriptor = Self.descriptor(of: downloadTask)
        withRegistry {
            $0.stage(result, taskID: downloadTask.taskIdentifier, descriptor: descriptor)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let descriptor = Self.descriptor(of: task)
        let resumeData = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        if let resumeData,
           let descriptor,
           let remoteURL = descriptor.remoteURL ?? task.originalRequest?.url?.absoluteString {
            Self.storeResumeData(
                resumeData,
                remoteURL: remoteURL,
                destinationPath: descriptor.destinationPath
            )
        }

        let completion = withRegistry {
            $0.complete(
                taskID: task.taskIdentifier,
                error: error,
                producedResumeData: resumeData != nil
            )
        }

        switch completion {
        case .untracked:
            return
        case .finished(let continuations, let result):
            if error == nil, case .failure = result {
                let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? -1
                backgroundDownloadLogger.error(
                    "Model transfer finished without a staged file: task=\(task.taskIdentifier, privacy: .public) status=\(statusCode, privacy: .public)"
                )
            }
            for continuation in continuations {
                continuation.resume(with: result)
            }
        case .retryFromScratch(let remoteURL):
            backgroundDownloadLogger.notice(
                "Saved resume data was rejected; restarting model transfer: task=\(task.taskIdentifier, privacy: .public)"
            )
            let retryTask = session.downloadTask(with: remoteURL)
            retryTask.taskDescription = task.taskDescription
            retryTask.priority = URLSessionTask.highPriority
            withRegistry {
                $0.moveTransfer(fromTaskID: task.taskIdentifier, toTaskID: retryTask.taskIdentifier)
            }
            retryTask.resume()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completionHandler = withRegistryLock { eventsCompletion.finishEvents() }
        guard let completionHandler else { return }
        DispatchQueue.main.async {
            completionHandler()
        }
    }
}

// MARK: - Background Events Completion

/// Pairs the system's background-events completion handler with
/// `urlSessionDidFinishEvents`, in whichever order the two arrive.
nonisolated struct BackgroundEventsCompletion<Handler> {
    private var handler: Handler?
    private var finishedBeforeHandlerArrived = false

    /// Returns the handler when it should be called right away.
    mutating func store(_ newHandler: Handler) -> Handler? {
        if finishedBeforeHandlerArrived {
            finishedBeforeHandlerArrived = false
            return newHandler
        }
        handler = newHandler
        return nil
    }

    /// Returns the stored handler, or remembers that events finished first.
    mutating func finishEvents() -> Handler? {
        guard let stored = handler else {
            finishedBeforeHandlerArrived = true
            return nil
        }
        handler = nil
        return stored
    }
}

// MARK: - Progress Throttle

/// Limits progress callbacks to meaningful changes: URLSession reports every
/// received chunk, often hundreds of times per second.
nonisolated struct TransferProgressThrottle {
    static let minimumFraction = 0.005
    static let minimumInterval: TimeInterval = 0.1

    private var lastBytes: Int64?
    private var lastTime: TimeInterval = 0

    mutating func shouldNotify(bytesWritten: Int64, bytesExpected: Int64, now: TimeInterval) -> Bool {
        let notify: Bool
        if let lastBytes {
            if bytesWritten < lastBytes {
                notify = true
            } else if bytesExpected > 0, bytesWritten >= bytesExpected {
                notify = bytesWritten != lastBytes
            } else if bytesExpected > 0,
                      Double(bytesWritten - lastBytes) >= Double(bytesExpected) * Self.minimumFraction {
                notify = true
            } else {
                notify = now - lastTime >= Self.minimumInterval && bytesWritten != lastBytes
            }
        } else {
            notify = true
        }

        if notify {
            lastBytes = bytesWritten
            lastTime = now
        }
        return notify
    }
}

// MARK: - Transfer Registry

/// The bookkeeping behind `BackgroundModelDownloadSession`, kept free of
/// URLSession so it can be tested directly. Callers hold a lock around it.
nonisolated struct BackgroundTransferRegistry<Waiter> {
    typealias Descriptor = BackgroundModelDownloadSession.TransferDescriptor
    typealias ProgressObserver = BackgroundModelDownloadSession.ProgressObserver

    struct Transfer {
        let descriptor: Descriptor
        var waiters: [(token: UUID, waiter: Waiter)] = []
        var progressObserver: ProgressObserver?
        var stagedResult: Result<URL, any Error>?
        var throttle = TransferProgressThrottle()
        /// Set when the task resumed from saved data; a rejected resume
        /// restarts from this URL once.
        var resumeFallbackURL: URL?
    }

    enum WaiterState {
        case awaitingTask
        case cancelledBeforeAttach
        case attached(taskID: Int)
    }

    enum CancelOutcome {
        case notWaiting
        case cancelledBeforeAttach
        case detached(Waiter, taskID: Int)
    }

    enum AttachOutcome {
        case attached
        case finished(Result<URL, any Error>)
    }

    enum Completion {
        case untracked
        case finished([Waiter], Result<URL, any Error>)
        case retryFromScratch(URL)
    }

    private static var recentCompletionLimit: Int { 32 }

    private(set) var transfers: [Int: Transfer] = [:]
    private var waiterStates: [UUID: WaiterState] = [:]
    private var recentCompletions: [Int: Result<URL, any Error>] = [:]
    private var recentCompletionOrder: [Int] = []
    private var cancelSequence = 0
    private var taskCreationSequence: [Int: Int] = [:]
    private var pendingPrefixCancels: [Int: String] = [:]

    var pendingWaiterCount: Int { waiterStates.count }

    // MARK: Waiters

    mutating func beginWaiter(_ token: UUID) {
        waiterStates[token] = .awaitingTask
    }

    /// Cancels one `download` call. Cancellation is scoped to that call, so a
    /// later run for the same transfer is never affected.
    mutating func cancelWaiter(_ token: UUID) -> CancelOutcome {
        switch waiterStates[token] {
        case nil, .cancelledBeforeAttach:
            return .notWaiting
        case .awaitingTask:
            waiterStates[token] = .cancelledBeforeAttach
            return .cancelledBeforeAttach
        case .attached(let taskID):
            waiterStates.removeValue(forKey: token)
            guard var transfer = transfers[taskID],
                  let index = transfer.waiters.firstIndex(where: { $0.token == token }) else {
                return .notWaiting
            }
            let waiter = transfer.waiters.remove(at: index).waiter
            transfers[taskID] = transfer
            return .detached(waiter, taskID: taskID)
        }
    }

    /// True when the waiter was cancelled before it found a task; the state is
    /// cleared because the caller finishes the waiter.
    mutating func consumeCancellationBeforeAttach(_ token: UUID) -> Bool {
        guard case .cancelledBeforeAttach = waiterStates[token] else { return false }
        waiterStates.removeValue(forKey: token)
        return true
    }

    mutating func attach(
        _ waiter: Waiter,
        token: UUID,
        taskID: Int,
        descriptor: Descriptor
    ) -> AttachOutcome {
        if consumeCancellationBeforeAttach(token) {
            return .finished(.failure(CancellationError()))
        }
        // The task can finish between listing it and attaching to it.
        if let result = recentCompletions[taskID] {
            waiterStates.removeValue(forKey: token)
            return .finished(result)
        }
        var transfer = transfers[taskID] ?? Transfer(descriptor: descriptor)
        transfer.waiters.append((token, waiter))
        transfers[taskID] = transfer
        waiterStates[token] = .attached(taskID: taskID)
        return .attached
    }

    mutating func finishWaiterWithoutTask(_ token: UUID) {
        waiterStates.removeValue(forKey: token)
    }

    // MARK: Tasks

    mutating func recordTaskCreation(taskID: Int, descriptor: Descriptor, resumeFallbackURL: URL?) {
        taskCreationSequence[taskID] = cancelSequence
        var transfer = transfers[taskID] ?? Transfer(descriptor: descriptor)
        transfer.resumeFallbackURL = resumeFallbackURL
        transfers[taskID] = transfer
    }

    /// Keeps only the newest run's observer, so restarts do not pile up callbacks.
    mutating func setProgressObserver(
        _ observer: @escaping ProgressObserver,
        taskID: Int,
        descriptor: Descriptor
    ) {
        var transfer = transfers[taskID] ?? Transfer(descriptor: descriptor)
        transfer.progressObserver = observer
        transfers[taskID] = transfer
    }

    /// A task is reused only when it is still live, belongs to the same file
    /// and URL, and is not about to be cancelled.
    func isAdoptable(
        taskID: Int,
        isLive: Bool,
        existing: Descriptor,
        requested: Descriptor
    ) -> Bool {
        guard isLive,
              existing.id == requested.id,
              existing.destinationPath == requested.destinationPath else {
            return false
        }
        if let existingURL = existing.remoteURL,
           let requestedURL = requested.remoteURL,
           existingURL != requestedURL {
            return false
        }
        return !isPendingCancellation(taskID: taskID, transferID: existing.id)
    }

    // MARK: Prefix Cancellation

    mutating func beginPrefixCancel(_ prefix: String) -> Int {
        cancelSequence += 1
        pendingPrefixCancels[cancelSequence] = prefix
        return cancelSequence
    }

    /// Tasks created after the cancel was requested belong to a newer run.
    /// Tasks from an earlier process are unknown here and count as older.
    func shouldCancel(taskID: Int, forCancelSequence sequence: Int) -> Bool {
        (taskCreationSequence[taskID] ?? Int.min) < sequence
    }

    mutating func endPrefixCancel(_ sequence: Int) {
        pendingPrefixCancels.removeValue(forKey: sequence)
    }

    private func isPendingCancellation(taskID: Int, transferID: String) -> Bool {
        pendingPrefixCancels.contains { sequence, prefix in
            transferID.hasPrefix(prefix) && shouldCancel(taskID: taskID, forCancelSequence: sequence)
        }
    }

    // MARK: Delegate Events

    mutating func progressObserverToNotify(
        taskID: Int,
        bytesWritten: Int64,
        bytesExpected: Int64,
        now: TimeInterval
    ) -> ProgressObserver? {
        guard var transfer = transfers[taskID], let observer = transfer.progressObserver else {
            return nil
        }
        let notify = transfer.throttle.shouldNotify(
            bytesWritten: bytesWritten,
            bytesExpected: bytesExpected,
            now: now
        )
        transfers[taskID] = transfer
        return notify ? observer : nil
    }

    mutating func stage(_ result: Result<URL, any Error>, taskID: Int, descriptor: Descriptor?) {
        if var transfer = transfers[taskID] {
            transfer.stagedResult = result
            transfers[taskID] = transfer
        } else if let descriptor {
            var transfer = Transfer(descriptor: descriptor)
            transfer.stagedResult = result
            transfers[taskID] = transfer
        }
    }

    mutating func complete(
        taskID: Int,
        error: (any Error)?,
        producedResumeData: Bool
    ) -> Completion {
        guard var transfer = transfers[taskID] else {
            taskCreationSequence.removeValue(forKey: taskID)
            return .untracked
        }

        // A resume the server refuses ends either with a transport error or, when
        // the signed CDN URL saved in the resume data has expired, with an HTTP
        // error status and no transport error.
        let resumeWasRejected = if let error {
            !Self.isCancellation(error) && !producedResumeData
        } else {
            Self.isBadResponse(transfer.stagedResult)
        }
        if resumeWasRejected, let fallbackURL = transfer.resumeFallbackURL {
            transfer.resumeFallbackURL = nil
            transfer.stagedResult = nil
            transfers[taskID] = transfer
            return .retryFromScratch(fallbackURL)
        }

        transfers.removeValue(forKey: taskID)
        taskCreationSequence.removeValue(forKey: taskID)

        let result: Result<URL, any Error>
        if let error {
            result = .failure(error)
        } else if let stagedResult = transfer.stagedResult {
            result = stagedResult
        } else {
            result = .failure(BackgroundModelDownloadSession.BackgroundDownloadError.noFileDelivered)
        }

        for (token, _) in transfer.waiters {
            waiterStates.removeValue(forKey: token)
        }
        rememberCompletion(result, taskID: taskID)
        return .finished(transfer.waiters.map(\.waiter), result)
    }

    private static func isBadResponse(_ result: Result<URL, any Error>?) -> Bool {
        guard case .failure(let error)? = result,
              case .badResponse? = error as? BackgroundModelDownloadSession.BackgroundDownloadError else {
            return false
        }
        return true
    }

    /// Moves a transfer onto the task that replaced its rejected resume.
    mutating func moveTransfer(fromTaskID oldTaskID: Int, toTaskID newTaskID: Int) {
        guard var transfer = transfers.removeValue(forKey: oldTaskID) else { return }
        transfer.throttle = TransferProgressThrottle()
        transfers[newTaskID] = transfer
        taskCreationSequence[newTaskID] = taskCreationSequence.removeValue(forKey: oldTaskID)
            ?? cancelSequence
        for (token, _) in transfer.waiters {
            waiterStates[token] = .attached(taskID: newTaskID)
        }
    }

    private mutating func rememberCompletion(_ result: Result<URL, any Error>, taskID: Int) {
        recentCompletions[taskID] = result
        recentCompletionOrder.append(taskID)
        while recentCompletionOrder.count > Self.recentCompletionLimit {
            recentCompletions.removeValue(forKey: recentCompletionOrder.removeFirst())
        }
    }

    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
