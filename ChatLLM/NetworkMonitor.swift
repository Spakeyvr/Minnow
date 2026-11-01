//
//  NetworkMonitor.swift
//  ChatLLM
//
//  Created by Assistant on 11/07/25.
//

import Combine
import Foundation
import Network
import OSLog

nonisolated private let networkLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ChatLLM", category: "NetworkMonitor")

nonisolated enum NetworkPathStatus: Sendable, Equatable {
    case satisfied
    case unsatisfied
}

protocol PathMonitoring: AnyObject {
    var pathUpdateHandler: (@Sendable (NetworkPathStatus) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func cancel()
}

final class SystemPathMonitor: PathMonitoring {
    private let monitor = NWPathMonitor()

    var pathUpdateHandler: (@Sendable (NetworkPathStatus) -> Void)?

    func start(queue: DispatchQueue) {
        // NWPathMonitor calls back on `queue`. Capture the handler now rather
        // than reading this main-actor property from that queue later.
        let handler = pathUpdateHandler
        monitor.pathUpdateHandler = { @Sendable path in
            handler?(path.status == .satisfied ? .satisfied : .unsatisfied)
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }
}

/// Monitors network connectivity status using Apple's Network framework
@MainActor
final class NetworkMonitor: ObservableObject {
    /// Shared singleton instance for app-wide network monitoring
    static let shared = NetworkMonitor()

    /// Current network connectivity status. Treated as connected until the
    /// first path update arrives, so the UI does not flash an offline state
    /// at launch; requests made in that moment still fail normally if offline.
    @Published private(set) var isConnected = true

    private let monitor: PathMonitoring
    private let queue: DispatchQueue
    private var hasResolvedInitialPath = false

    init(
        monitor: PathMonitoring? = nil,
        queue: DispatchQueue = DispatchQueue(label: "ChatLLM.NetworkMonitor")
    ) {
        self.monitor = monitor ?? SystemPathMonitor()
        self.queue = queue
        startMonitoring()
    }

    private func startMonitoring() {
        // Called on the monitor's queue; hop to the main actor for state.
        monitor.pathUpdateHandler = { @Sendable [weak self] status in
            let resolvedStatus = status == .satisfied
            Task { @MainActor [weak self] in
                self?.applyPathStatus(isConnected: resolvedStatus)
            }
        }

        monitor.start(queue: queue)
    }

    private func applyPathStatus(isConnected resolvedStatus: Bool) {
        let wasConnected = isConnected
        let hadResolvedInitialPath = hasResolvedInitialPath

        hasResolvedInitialPath = true
        isConnected = resolvedStatus

        guard hadResolvedInitialPath, wasConnected != resolvedStatus else {
            return
        }

        if resolvedStatus {
            networkLogger.notice("Network connection restored")
        } else {
            networkLogger.notice("Network connection lost")
        }
    }

    isolated deinit {
        monitor.cancel()
    }
}

extension URLError {
    /// Failures that often clear up on a quick retry. Errors such as
    /// `.notConnectedToInternet` or `.badURL` are not retried.
    nonisolated var isTransientConnectivityFailure: Bool {
        switch code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }
}
