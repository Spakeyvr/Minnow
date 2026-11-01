//
//  ChatViewModel+StreamingTypes.swift
//  ChatLLM
//
//  Values passed between the stages of the streaming pipeline in
//  ChatViewModel+Streaming.swift.
//

import Foundation
@preconcurrency import MLXLMCommon

extension ChatViewModel {

    // MARK: - Streaming Types

    enum StreamOutcome {
        case succeeded
        case failedBeforeOutput
        case failedAfterPartialOutput
        case cancelled
    }

    /// The reply a run replaces, captured before the placeholder is reset.
    struct StreamResetState {
        let target: Message
        let previousReply: Message.RegenerationSnapshot
        /// Whether `previousReply` had anything to show. A stopped or failed run puts
        /// such a reply back; an empty one is a new turn's placeholder and is removed.
        let hasPreviousContent: Bool
        let forceSearchRequired: Bool
    }

    enum StreamBackendRequest {
        case mlx(
            manager: MLXModelManager,
            conversationID: UUID,
            messages: [Chat.Message],
            enableThinking: Bool,
            tools: [MLXToolSpec],
            toolDispatch: (@Sendable (MLXToolCall) async throws -> String)?,
            stableSystemPrompt: String?
        )
        case foundation(
            request: LLMRequest,
            tools: [any FoundationModelTool]
        )

        var isMLX: Bool {
            if case .mlx = self { return true }
            return false
        }
    }

    struct StreamPreparation {
        let reset: StreamResetState
        let webSearchBridge: AppWebSearchToolBridge?
        let backendRequest: StreamBackendRequest

        var target: Message { reset.target }
    }

    struct StreamConsumptionResult {
        var cumulativeText = ""
        var wroteAny = false
        var outcome: StreamOutcome = .succeeded
    }

    /// `MLXToolCall` comes from MLXLMCommon, which is still built in Swift 5 mode
    /// and doesn't mark it Sendable; it is a value type of strings and JSON values.
    enum StreamEvent: @unchecked Sendable {
        case text(String)
        case toolCall(MLXToolCall)
        case searchActivityChanged
        case metrics(GenerationMetrics)
    }

    /// A backend's events plus the handle that lets the stream watchdog end them.
    struct GenerationEventStream {
        let events: AsyncThrowingStream<StreamEvent, Error>
        let continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    }
}
