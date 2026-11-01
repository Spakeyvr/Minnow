//
//  ContentView+Export.swift
//  Minnow
//

import SwiftUI
import OSLog

extension ContentView {

    struct ChatExport: Identifiable {
        let url: URL
        var id: URL { url }
    }

    func exportAllChats() {
        guard !conversations.isEmpty else { return }
        cleanupExportFile()

        // Only copying the stored values reads the SwiftData models; cleanup,
        // formatting, encoding and the protected file write run off the main actor.
        let snapshots = ChatExportFormatter.snapshots(of: conversations)
        let language = AppLanguage.current

        Task {
            do {
                let url = try await ChatExportFormatter.writeExportFile(for: snapshots, language: language)
                exportURL = url
                chatExport = ChatExport(url: url)
            } catch {
                contentLogger.error("Failed to write chat export: \((error as NSError).localizedDescription, privacy: .public)")
                errorMessage = String(localized: "Failed to export chats. Please try again.", bundle: .appLocalized)
            }
        }
    }

    func cleanupExportFile() {
        guard let exportURL else { return }
        try? FileManager.default.removeItem(at: exportURL)
        self.exportURL = nil
    }
}
