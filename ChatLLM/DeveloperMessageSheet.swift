//
//  DeveloperMessageSheet.swift
//  ChatLLM
//

import SwiftUI

// MARK: - Developer diagnostics

struct DeveloperMessageSheet: View {
    @Environment(\.locale) private var locale
    let message: Message

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private var rawText: String {
        let raw = message.developerRawText
        return raw.isEmpty ? String(localized: "No raw output captured for this message.", bundle: .appLocalized, locale: locale) : raw
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Stats")
                            .font(.headline)

                        DeveloperStatRow(label: String(localized: "Backend", bundle: .appLocalized, locale: locale), value: message.generationBackend ?? String(localized: "Unknown", bundle: .appLocalized, locale: locale))

                        if let generationModelName = message.generationModelName, !generationModelName.isEmpty {
                            DeveloperStatRow(label: String(localized: "Model", bundle: .appLocalized, locale: locale), value: generationModelName)
                        }

                        if let startedAt = message.generationStartedAt {
                            DeveloperStatRow(
                                label: String(localized: "Started", bundle: .appLocalized, locale: locale),
                                value: Self.dateFormatter.string(from: startedAt)
                            )
                        }

                        if let completedAt = message.generationCompletedAt {
                            DeveloperStatRow(
                                label: String(localized: "Finished", bundle: .appLocalized, locale: locale),
                                value: Self.dateFormatter.string(from: completedAt)
                            )
                        }

                        if let duration = message.generationDuration {
                            DeveloperStatRow(label: String(localized: "Duration", bundle: .appLocalized, locale: locale), value: String(format: "%.2fs", duration))
                        }

                        if let decodeTokensPerSecond = message.decodeTokensPerSecond,
                           let outputTokenCount = message.generationOutputTokenCount {
                            // Backend-measured values; the estimates below divide
                            // characters by wall-clock time including prefill.
                            if let promptTokenCount = message.generationPromptTokenCount {
                                DeveloperStatRow(label: String(localized: "Prompt tokens", bundle: .appLocalized, locale: locale), value: "\(promptTokenCount)")
                            }
                            if message.generationBackend == ModelBackendBridge.Backend.foundationModels.displayName {
                                DeveloperStatRow(label: String(localized: "Context window", bundle: .appLocalized, locale: locale), value: "\(ModelBackendBridge.foundationModelsContextSize)")
                            }
                            if let cachedPromptTokenCount = message.generationCachedPromptTokenCount,
                               cachedPromptTokenCount > 0 {
                                DeveloperStatRow(label: String(localized: "Cached prompt tokens", bundle: .appLocalized, locale: locale), value: "\(cachedPromptTokenCount)")
                            }
                            if let promptTokensPerSecond = message.promptTokensPerSecond {
                                DeveloperStatRow(label: String(localized: "Prompt tokens/sec", bundle: .appLocalized, locale: locale), value: String(format: "%.2f", promptTokensPerSecond))
                            }
                            if let timeToFirstToken = message.generationTimeToFirstToken {
                                DeveloperStatRow(label: String(localized: "Time to first token", bundle: .appLocalized, locale: locale), value: String(format: "%.2fs", timeToFirstToken))
                            }
                            DeveloperStatRow(label: String(localized: "Output tokens", bundle: .appLocalized, locale: locale), value: "\(outputTokenCount)")
                            DeveloperStatRow(label: String(localized: "Decode tokens/sec", bundle: .appLocalized, locale: locale), value: String(format: "%.2f", decodeTokensPerSecond))
                        } else {
                            if let estimatedOutputTokenCount = message.estimatedOutputTokenCount {
                                DeveloperStatRow(label: String(localized: "Est. output tokens", bundle: .appLocalized, locale: locale), value: "\(estimatedOutputTokenCount)")
                            }

                            if let estimatedTokensPerSecond = message.estimatedTokensPerSecond {
                                DeveloperStatRow(label: String(localized: "Est. tokens/sec", bundle: .appLocalized, locale: locale), value: String(format: "%.2f", estimatedTokensPerSecond))
                            }
                        }

                        DeveloperStatRow(label: String(localized: "Raw chars", bundle: .appLocalized, locale: locale), value: "\(message.developerRawText.count)")
                        DeveloperStatRow(label: String(localized: "Visible chars", bundle: .appLocalized, locale: locale), value: "\(message.displayText.count)")
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Raw Output")
                            .font(.headline)

                        Text(rawText)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous)
                                    .fill(Color.primary.opacity(0.06))
                            )
                    }
                }
                .padding()
            }
            .navigationTitle("Developer")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.fraction(0.5), .large])
        .presentationDragIndicator(.visible)
    }
}

private struct DeveloperStatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .monospaced))
        }
    }
}
