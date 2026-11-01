//
//  MinnowTests+Factories.swift
//  MinnowTests
//
//  Shared factory methods used by multiple MinnowTests topic files.
//

import Testing
import Foundation
import SwiftUI
import SwiftData
import WebKit
import UIKit
import FoundationModels
@testable import Minnow

extension MinnowTests {
    func makeDeviceProfile(
        isPhone: Bool,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        ramPrecautionsDisabledOverride: Bool? = false
    ) -> MLXDeviceSupportProfile {
        MLXDeviceSupportProfile(isPhone: isPhone, physicalMemoryBytes: physicalMemoryBytes,
                               ramPrecautionsDisabledOverride: ramPrecautionsDisabledOverride)
    }

    func makeModelManager(deviceSupportProfile: MLXDeviceSupportProfile? = nil) -> MLXModelManager {
        MLXModelManager(
            deviceSupportProfile: deviceSupportProfile ?? makeDeviceProfile(isPhone: true),
            defaults: testEnvironment.defaults,
            documentsDirectory: testEnvironment.directory.appendingPathComponent(UUID().uuidString),
            restoresBackgroundDownloads: false
        )
    }

    func makeBackendBridge() -> ModelBackendBridge {
        ModelBackendBridge(defaults: testEnvironment.defaults, modelManager: makeModelManager())
    }

    func makeIsolatedChatViewModel(
        generator: LLMGenerator, context: SwiftData.ModelContext, conversation: Conversation
    ) -> ChatViewModel {
        ChatViewModel(generator: generator, context: context, conversation: conversation,
                      backendBridge: testEnvironment.bridge, defaults: testEnvironment.defaults,
                      observesAPIKeyChanges: false)
    }

    // MARK: - Test helpers
    /// A context over a fresh in-memory store with the app's full schema. The
    /// context keeps its container alive, so tests reach it through `context.container`.
    func makeContext() throws -> SwiftData.ModelContext {
        let schema = Schema([Conversation.self, Minnow.Message.self, MessageAttachment.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    /// A persisted conversation seeded with finished turns, for editing tests.
    func makeChat(_ turns: [(MessageRole, String)]) throws -> ChatViewModel {
        let context = try makeContext()
        let conversation = Conversation(title: "Test")
        context.insert(conversation)
        conversation.messages = turns.enumerated().map { index, turn in
            Minnow.Message(
                role: turn.0,
                text: turn.1,
                order: index,
                conversation: conversation,
                isFinal: true
            )
        }
        try context.save()
        return makeIsolatedChatViewModel(generator: TestLLMGenerator(), context: context, conversation: conversation)
    }


    /// An isolated `UserDefaults` domain so settings tests never touch the
    /// simulator's real preferences or each other's. The test environment
    /// removes the domain when the test ends.
    func makeScratchDefaults(_ label: String) throws -> UserDefaults {
        try testEnvironment.makeScratchDefaults(label)
    }

    /// An image store rooted in the test's temporary directory, which the test
    /// environment deletes, so store tests never touch the app's real attachments.
    func makeImageStore() -> ImageStore {
        ImageStore(attachmentsDirectory: testEnvironment.directory.appending(path: "Attachments", directoryHint: .isDirectory))
    }

    /// Polls `condition` for up to five seconds and records an issue if it
    /// never holds.
    func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }

    /// `waitUntil` for a condition that has to be awaited, such as actor state.
    func waitUntilAsync(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition())
    }

    /// Returns once every block already queued on the main dispatch queue has run,
    /// such as a Combine sink that receives on `DispatchQueue.main`. The queue is
    /// serial, so a block enqueued now runs after them.
    func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func makeTestImage(width: Int, height: Int) -> UIImage {
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    func makeSearchBridge() throws -> AppWebSearchToolBridge {
        MockTavilyURLProtocol.responseStatusCode = 200
        MockTavilyURLProtocol.responseData = """
        {
          "query": "latest swift release",
          "answer": "Swift 6.2 is the latest stable release.",
          "auto_parameters": {
            "topic": "news",
            "search_depth": "basic",
            "time_range": "week"
          },
          "response_time": "1.67",
          "results": [
            {
              "title": "Swift 6.2 Released",
              "url": "https://example.com/swift",
              "content": "Swift 6.2 adds more concurrency fixes.",
              "score": 0.99,
              "published_date": "2026-02-28"
            }
          ]
        }
        """.data(using: .utf8)!

        let service = try makeSearchService()
        return AppWebSearchToolBridge(searchService: service)
    }

    func makeSearchService() throws -> TavilySearchService {
        MockTavilyURLProtocol.lastRequest = nil
        MockTavilyURLProtocol.lastRequestBody = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockTavilyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return try TavilySearchService(apiKey: "test-key", session: session)
    }

    func makeViewModel(generator: LLMGenerator = TestLLMGenerator()) throws -> ChatViewModel {
        let context = try makeContext()
        let conversation = Conversation(title: "Test")
        return makeIsolatedChatViewModel(
            generator: generator,
            context: context,
            conversation: conversation
        )
    }

}
