import SwiftUI

enum SettingsDataAction {
    case deleteAll, deleteAllExceptCurrent, export
}

struct PrivacySettingsView: View {
    @Binding var settings: AppSettingsDraft
    let hasChats: Bool
    let canDeleteAllExceptCurrent: Bool
    let onDeleteAll: () -> Void
    let onDeleteAllExceptCurrent: () -> Void
    let onExportChats: () -> Void
    @State private var deletion: SettingsDataAction?
    @State private var showingDeletionConfirmation = false

    static let retentionDayOptions = [7, 14, 30, 60, 90]

    /// The retention choices, plus a stored period that isn't one of them, so the picker
    /// never shows an empty selection while auto-delete keeps using that period.
    static func retentionDayOptions(including storedDays: Int) -> [Int] {
        guard storedDays > 0, !retentionDayOptions.contains(storedDays) else {
            return retentionDayOptions
        }
        return (retentionDayOptions + [storedDays]).sorted()
    }

    var body: some View {
        Form {
            Section {
                Toggle("Auto-Delete Chats", isOn: $settings.autoDeleteOldChats)
                    .accessibilityIdentifier("settings.autoDelete")
                if settings.autoDeleteOldChats {
                    Picker("Delete After", selection: $settings.autoDeleteDays) {
                        ForEach(Self.retentionDayOptions(including: settings.autoDeleteDays), id: \.self) { days in
                            Text("\(days) days").tag(days)
                        }
                    }
                    .accessibilityIdentifier("settings.retention")
                }
            } footer: {
                Text("Automatically remove conversations older than the selected period. Deleted chats cannot be recovered.")
            }
            Section {
                Button(action: onExportChats) {
                    Label("Export All Chats", systemImage: "square.and.arrow.up")
                        .foregroundStyle(hasChats ? Color.accentColor : Color(uiColor: .tertiaryLabel))
                }
                .disabled(!hasChats)
                .accessibilityIdentifier("settings.exportChats")
            } footer: {
                Text("Export a copy of your conversations to keep or share.")
            }
            Section {
                Button("Delete All Except Current", role: .destructive) {
                    deletion = .deleteAllExceptCurrent
                    showingDeletionConfirmation = true
                }
                .disabled(!canDeleteAllExceptCurrent)
                .accessibilityIdentifier("settings.deleteOtherChats")
                Button("Delete All Chats", role: .destructive) {
                    deletion = .deleteAll
                    showingDeletionConfirmation = true
                }
                .disabled(!hasChats)
                .accessibilityIdentifier("settings.deleteAllChats")
            } footer: {
                Text("Permanently delete conversations and their attachments from this device.")
            }
        }
        .navigationTitle("Privacy & Data")
        .navigationBarTitleDisplayMode(.inline)
        .alert(deletion == .deleteAll ? String(localized: "Delete All Chats?", bundle: .appLocalized) : String(localized: "Delete Other Chats?", bundle: .appLocalized),
               isPresented: $showingDeletionConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if deletion == .deleteAll { onDeleteAll() } else { onDeleteAllExceptCurrent() }
            }
        } message: {
            Text(deletion == .deleteAll
                 ? String(localized: "All conversations and their attachments will be permanently deleted. This cannot be undone.", bundle: .appLocalized)
                 : String(localized: "All conversations except the current one will be permanently deleted. If no chat is selected, the most recent chat is kept. This cannot be undone.", bundle: .appLocalized))
        }
    }
}
