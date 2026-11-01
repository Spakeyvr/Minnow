//
//  SettingsSheetContainer.swift
//  Minnow
//

import SwiftUI

// Owns the live settings snapshot. Each binding edit persists only changed fields;
// dedicated editors keep API keys and response preferences local until Save.
private struct SettingsSheetContainer: View {
    let hasChats: Bool
    let canDeleteAllExceptCurrent: Bool
    let onDeleteAll: () -> Void
    let onDeleteAllExceptCurrent: () -> Void
    let onExportChats: () -> Void
    let onDismiss: () -> Void

    /// Loaded once when the sheet appears. A State initial value would read the Keychain
    /// again on every parent render while the sheet is up, only to be thrown away.
    @State private var draft: AppSettingsDraft?
    @State private var tavilyKeySaveFailed = false

    var body: some View {
        NavigationStack {
            if let loadedDraft = draft {
                SettingsSheet(
                    settings: Binding(
                        get: { draft ?? loadedDraft },
                        set: { updated in
                            let previous = draft ?? loadedDraft
                            if updated.persist(comparedTo: previous) {
                                draft = updated
                            } else {
                                draft = updated.revertingTavilyKey(to: previous)
                                tavilyKeySaveFailed = true
                            }
                        }
                    ),
                    hasChats: hasChats,
                    canDeleteAllExceptCurrent: canDeleteAllExceptCurrent,
                    onDeleteAll: onDeleteAll,
                    onDeleteAllExceptCurrent: onDeleteAllExceptCurrent,
                    onExportChats: onExportChats
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            onDismiss()
                        }
                        .accessibilityIdentifier("settings.done")
                    }
                }
                .alert("Couldn't Save API Key", isPresented: $tavilyKeySaveFailed) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("The Tavily API key couldn't be stored in the Keychain. Try again.")
                }
            }
        }
        .environment(\.locale, (draft.map { AppLanguage.resolve($0.appLanguage) } ?? .current).locale)
        .onAppear {
            if draft == nil {
                draft = AppSettingsDraft.load()
            }
        }
    }
}

// MARK: - Presentation

extension View {
    func settingsCover(
        isPresented: Binding<Bool>,
        hasChats: Bool,
        canDeleteAllExceptCurrent: Bool,
        onDeleteAll: @escaping () -> Void,
        onDeleteAllExceptCurrent: @escaping () -> Void,
        onExportChats: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            SettingsSheetContainer(
                hasChats: hasChats,
                canDeleteAllExceptCurrent: canDeleteAllExceptCurrent,
                onDeleteAll: onDeleteAll,
                onDeleteAllExceptCurrent: onDeleteAllExceptCurrent,
                onExportChats: onExportChats,
                onDismiss: { isPresented.wrappedValue = false }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }
}
