//
//  MLXModelManager+ToolCalling
//  Minnow
//
//  Split out of MLXModelManager.swift as part of the Type+Concern organization.
//

import Foundation
import MLXLMCommon
import OSLog

extension MLXModelManager {
    // MARK: - Tool Calling

    nonisolated enum ToolTemplateSupport: Equatable, Sendable {
        case supported
        case unsupported(String)
    }

    nonisolated struct ToolTemplateInspection: Sendable {
        let support: ToolTemplateSupport
        let preferredToolCallFormat: ToolCallFormat?
        let usesWrappedXMLToolCalls: Bool
    }
    nonisolated internal static let maxToolInvocationsPerResponse = 6

    /// Tool calls past `maxToolInvocationsPerResponse` get one shutdown notice;
    /// a model that keeps calling after it ends the response instead of looping.
    nonisolated internal static func shouldEndToolLoop(afterInvocationCount count: Int) -> Bool {
        count > maxToolInvocationsPerResponse + 1
    }

    nonisolated internal static func shouldDisableTools(after toolResult: String) -> Bool {
        AppWebSearchToolBridge.isSearchLimitToolResponse(toolResult)
    }

    nonisolated internal static func excessiveToolCallToolResponse(maximum: Int) -> String {
        "[tool internal error: limit reached after \(maximum) tool invocations for this response. Do not call tools again. Continue with the available information already available.]"
    }
    nonisolated internal static func wrappedToolResponseContent(_ content: String) -> String {
        "<tool_response>\n\(content)\n</tool_response>"
    }

    nonisolated internal static func toolResponsePromptContent(
        for model: MLXModelInfo,
        toolResult: String
    ) -> String {
        guard prefersUserWrappedToolResponses(for: model) else {
            return toolResult
        }
        return wrappedToolResponseContent(toolResult)
    }

    nonisolated internal static func toolResponsePromptRole(for model: MLXModelInfo) -> Chat.Message.Role {
        prefersUserWrappedToolResponses(for: model) ? .user : .tool
    }

    nonisolated internal static func prefersUserWrappedToolResponses(for model: MLXModelInfo) -> Bool {
        model.family.prefersUserWrappedToolResponses
    }

    /// LFM2.5's template prepends BOS and re-emits the "List of tools" system
    /// block on every render, so a persistent session that appends only the
    /// tool turn injects both mid-conversation. Rebuilding from explicit history
    /// renders each tool round exactly as the model was trained on.
    nonisolated internal static func usesLFMToolTurns(for model: MLXModelInfo) -> Bool {
        model.family.usesLFMToolTurns
    }

    nonisolated internal static func requiresExplicitMessageHistoryForToolLoop(for model: MLXModelInfo) -> Bool {
        prefersUserWrappedToolResponses(for: model) || usesLFMToolTurns(for: model)
    }

    /// The assistant turn that issued `toolCall`, as LFM2.5's chat template renders
    /// it: `<think>…</think>`, any content, then the Pythonic call. Thinking after
    /// the last user turn is kept by the template, so the model sees its own
    /// reasoning and query when it reads the result. `nil` for models whose tool
    /// loop does not replay the assistant turn.
    nonisolated internal static func assistantToolCallTurnContent(
        for model: MLXModelInfo,
        generatedText: String,
        toolCall: MLXToolCall
    ) -> String? {
        guard usesLFMToolTurns(for: model) else { return nil }
        // The generation prompt already opened `<think>`; a call made before the
        // model closed it is normalized to the template's closed form.
        let thinking = generatedText.contains("</think>")
            ? generatedText
            : generatedText.trimmingCharacters(in: .whitespacesAndNewlines) + "</think>"
        return "<think>" + thinking + lfmToolCallMarkup(for: toolCall)
    }

    /// Mirrors `render_tool_calls` and `format_arg_value` in the LFM2.5 template.
    nonisolated internal static func lfmToolCallMarkup(for toolCall: MLXToolCall) -> String {
        let arguments = toolCall.function.arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(lfmArgumentLiteral($0.value))" }
            .joined(separator: ", ")
        return "<|tool_call_start|>[\(toolCall.function.name)(\(arguments))]<|tool_call_end|>"
    }

    nonisolated private static func lfmArgumentLiteral(_ value: JSONValue) -> String {
        switch value {
        case .string(let string):
            let escaped = string
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            return "'\(escaped)'"
        case .null:
            return "None"
        case .bool(let bool):
            return bool ? "True" : "False"
        case .int(let int):
            return String(int)
        case .double(let double):
            return String(double)
        case .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        }
    }

    func applyPreferredToolCallFormatIfNeeded(
        to loaded: ModelContainer,
        for model: MLXModelInfo
    ) async {
        guard let preferredToolCallFormat = await toolTemplateInspection(for: model).preferredToolCallFormat else {
            return
        }

        let currentToolCallFormat = await loaded.configuration.toolCallFormat
        guard currentToolCallFormat != preferredToolCallFormat else {
            logger.notice(
                "MLX tool-call format retained: id=\(model.id, privacy: .public) format=\(preferredToolCallFormat.rawValue, privacy: .public)"
            )
            return
        }

        await loaded.update { context in
            context.configuration.toolCallFormat = preferredToolCallFormat
        }
        logger.notice(
            "MLX tool-call format override applied: id=\(model.id, privacy: .public) format=\(preferredToolCallFormat.rawValue, privacy: .public)"
        )
    }

    func validateToolTemplateSupport(for model: MLXModelInfo) async throws {
        switch await toolTemplateInspection(for: model).support {
        case .supported:
            return
        case .unsupported(let message):
            throw GenerationError.unsupportedToolTemplate(message)
        }
    }

    func logToolTemplateSupport(for model: MLXModelInfo) async {
        let inspection = await toolTemplateInspection(for: model)
        switch inspection.support {
        case .supported:
            logger.notice("MLX tool template support confirmed for \(model.displayName, privacy: .public)")
            if let preferredToolCallFormat = inspection.preferredToolCallFormat {
                logger.notice(
                    "MLX tool template inspection: id=\(model.id, privacy: .public) format=\(preferredToolCallFormat.rawValue, privacy: .public) wrapped_xml=\(inspection.usesWrappedXMLToolCalls, privacy: .public)"
                )
            }
        case .unsupported(let message):
            logger.warning("MLX tool template support unavailable: \(message, privacy: .public)")
        }
    }

    func usesWrappedXMLToolCalls(for model: MLXModelInfo) async -> Bool {
        await toolTemplateInspection(for: model).usesWrappedXMLToolCalls
    }

    /// Cached per model until its files change. The files are read off the
    /// main actor.
    func toolTemplateInspection(for model: MLXModelInfo) async -> ToolTemplateInspection {
        if let cached = toolTemplateInspectionCache[model.id] {
            return cached
        }

        let inspection: ToolTemplateInspection
        if let modelURL = modelDirectoryURL(for: model) {
            inspection = await Self.inspectToolTemplateInBackground(
                modelDirectory: modelURL,
                modelType: packageMetadata(for: model)?.modelType,
                localDirName: model.localDirName
            )
        } else {
            inspection = ToolTemplateInspection(
                support: .unsupported(
                    "Installed model '\(model.localDirName)' could not be inspected for tool support. Re-download the model package to restore the tokenizer chat template."
                ),
                preferredToolCallFormat: nil,
                usesWrappedXMLToolCalls: false
            )
        }
        toolTemplateInspectionCache[model.id] = inspection
        return inspection
    }

    @concurrent
    nonisolated private static func inspectToolTemplateInBackground(
        modelDirectory: URL,
        modelType: String?,
        localDirName: String
    ) async -> ToolTemplateInspection {
        inspectToolTemplate(
            chatTemplate: chatTemplateText(inModelDirectory: modelDirectory),
            modelType: modelType,
            localDirName: localDirName
        )
    }

    /// Judges tool support from the chat template alone. The tokenizer
    /// vocabulary is left out: it is several megabytes for Qwen 3.5 and
    /// contains strings like "tool_call" for practically any model, which
    /// made every package look tool-aware.
    nonisolated internal static func inspectToolTemplate(
        chatTemplate: String,
        modelType: String?,
        localDirName: String
    ) -> ToolTemplateInspection {
        let lowered = chatTemplate.lowercased()
        let hasToolsContext = lowered.contains("tools")
        let hasToolRole = lowered.contains("\"tool\"") ||
            lowered.contains("'tool'") ||
            lowered.contains("role == 'tool'") ||
            lowered.contains("role != 'tool'")
        let hasToolCalls = lowered.contains("tool_call") || lowered.contains("tool_calls")

        let support: ToolTemplateSupport
        if hasToolsContext && (hasToolRole || hasToolCalls) {
            support = .supported
        } else {
            support = .unsupported(
                "Installed model '\(localDirName)' does not expose a tool-aware chat template. Re-download or update this MLX model package to enable MLX tool calling."
            )
        }

        return ToolTemplateInspection(
            support: support,
            preferredToolCallFormat: inferToolCallFormat(loweredTemplate: lowered, modelType: modelType),
            usesWrappedXMLToolCalls: usesWrappedXMLToolCallTemplate(loweredTemplate: lowered)
        )
    }

    /// The chat template text of a package: `chat_template.jinja`, plus the
    /// `chat_template` field of `tokenizer_config.json`, `chat_template.json`,
    /// and the processor configs (string or named-template list).
    nonisolated internal static func chatTemplateText(inModelDirectory modelURL: URL) -> String {
        var templates: [String] = []
        let jinjaURL = modelURL.appendingPathComponent("chat_template.jinja")
        if let data = try? Data(contentsOf: jinjaURL), let text = String(data: data, encoding: .utf8) {
            templates.append(text)
        }
        for fileName in [
            "tokenizer_config.json",
            "chat_template.json",
            "processor_config.json",
            "preprocessor_config.json"
        ] {
            let url = modelURL.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: url),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            templates.append(contentsOf: chatTemplates(in: json["chat_template"]))
        }
        return templates.joined(separator: "\n")
    }

    nonisolated private static func chatTemplates(in value: Any?) -> [String] {
        if let template = value as? String {
            return [template]
        }
        if let named = value as? [[String: Any]] {
            return named.compactMap { $0["template"] as? String }
        }
        return []
    }

    nonisolated internal static func inferToolCallFormat(
        packageContents: String,
        modelType: String?
    ) -> ToolCallFormat? {
        inferToolCallFormat(loweredTemplate: packageContents.lowercased(), modelType: modelType)
    }

    nonisolated private static func inferToolCallFormat(
        loweredTemplate lowered: String,
        modelType: String?
    ) -> ToolCallFormat? {
        if lowered.contains("<|tool_call_start|>") && lowered.contains("<|tool_call_end|>") {
            return .lfm2
        }

        if lowered.contains("<function=") && lowered.contains("<parameter=") {
            return .xmlFunction
        }

        let hasJSONToolCallExample =
            lowered.contains("<tool_call>") &&
            lowered.contains("\"name\"") &&
            lowered.contains("\"arguments\"")
        if hasJSONToolCallExample {
            return .json
        }

        if let modelType,
           modelType.lowercased().hasPrefix("qwen3_5"),
           lowered.contains("tool_call") &&
           lowered.contains("function") {
            return .xmlFunction
        }

        return nil
    }

    nonisolated internal static func usesWrappedXMLToolCallTemplate(packageContents: String) -> Bool {
        usesWrappedXMLToolCallTemplate(loweredTemplate: packageContents.lowercased())
    }

    nonisolated private static func usesWrappedXMLToolCallTemplate(loweredTemplate lowered: String) -> Bool {
        lowered.contains("<tool_call>") &&
            lowered.contains("<function=") &&
            lowered.contains("<parameter=")
    }
}
