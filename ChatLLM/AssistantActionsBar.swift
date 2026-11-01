//
//  AssistantActionsBar.swift
//  ChatLLM
//

import SwiftUI

// MARK: - Enhanced Assistant Actions Bar

struct AssistantActionsBar: View {
    @Environment(\.locale) private var locale
    var copyText: String
    var canAct: Bool
    var sourceInvocations: [SearchInvocation]
    var onTryAgain: () -> Void
    var onConcise: () -> Void
    var onFormal: () -> Void
    var developerModeEnabled: Bool
    var onDeveloper: () -> Void

    @State private var showSources = false

    var body: some View {
        HStack(spacing: 22) {
            // Stop button removed from here; lives in the composer now.

            MessageCopyButton(text: copyText)

            Group {
                Menu {
                    Button(action: onTryAgain) {
                        Label("Try again", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button(action: onConcise) {
                        Label("More concise", systemImage: "text.justify.leading")
                    }
                    Button(action: onFormal) {
                        Label("More formal", systemImage: "textformat.abc")
                    }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                // A 44-point target around the small icon, without moving it.
                .padding(-12)
                // Removed .menuStyle(.borderlessButton) – flaky in scrollable cells
                .disabled(!canAct)
                .accessibilityLabel("Regenerate")
            }

            if developerModeEnabled {
                Button(action: onDeveloper) {
                    Image(systemName: "hammer")
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .disabled(!canAct)
                .accessibilityLabel("Developer")
            }

            if !sourceInvocations.isEmpty {
                SourcesButton(showSources: $showSources, invocations: sourceInvocations)
                    .sheet(isPresented: $showSources) {
                        SourcesSheetView(
                            invocations: sourceInvocations,
                            title: String(localized: "Sources", bundle: .appLocalized, locale: locale)
                        )
                    }
            }

            Spacer()
        }
        // Fixed row height keeps the gap below the reply the same whether or not
        // the (taller) Sources button is present.
        .frame(minHeight: 36)
        .font(.body)
        .foregroundStyle(.primary)
    }
}

// MARK: - Copy button for the actions bar

/// Copies the whole reply in one tap, without opening the long-press menu.
private struct MessageCopyButton: View {
    let text: String

    var body: some View {
        CopyFeedbackButton(text: text, accessibilityLabel: { $0 ? "Copied" : "Copy" }) { isShowingFeedback in
            Image(systemName: isShowingFeedback ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        // A 44-point target around the small icon, without moving it.
        .padding(-12)
        .accessibilityIdentifier("message.copy")
    }
}
