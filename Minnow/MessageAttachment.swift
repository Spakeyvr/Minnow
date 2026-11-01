//
//  Attachment.swift
//  Minnow
//
//  Created by Nevio on 10/24/25.
//
//  CRITICAL: Image Persistence Strategy
//  =====================================
//  This model stores image attachments with RELATIVE PATHS instead of absolute URLs.
//
//  Why? iOS app containers can move between launches, especially during:
//  - App updates
//  - Device restores
//  - iOS updates
//
//  If we stored absolute URLs (e.g., /var/mobile/.../Documents/Attachments/image.jpg),
//  they would become invalid when the container path changes, resulting in
//  "Image unavailable" errors after app restarts.
//
//  Solution: Store only the filename in `relativePath`, then reconstruct the full
//  path dynamically using FileManager when accessing `fileURL`.
//

import Foundation
import SwiftData
import UIKit
import OSLog

nonisolated private let attachmentLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Minnow", category: "MessageAttachment")

enum AttachmentType: String, Codable, Sendable {
    case image
    case file
}

@Model
final class MessageAttachment {
    @Attribute(.unique) var id: UUID
    var type: AttachmentType
    
    // Store the file URL - but we'll normalize it to be relative-path-based
    var fileURL: URL
    var createdAt: Date
    var fileName: String
    
    @Relationship var message: Message?
    
    init(
        id: UUID = UUID(),
        type: AttachmentType,
        fileURL: URL,
        fileName: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        // Store a relative URL with just the filename so it stays container-agnostic.
        let storedName = fileURL.lastPathComponent
        self.fileURL = URL(string: storedName)
            ?? URL(string: storedName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")
            ?? Self.attachmentsDirectory.appending(path: storedName, directoryHint: .notDirectory)
        self.fileName = fileName
        self.createdAt = createdAt
    }

    /// `Documents/Attachments` in the current app container. The container path
    /// does not change while the app runs, so it is resolved once.
    nonisolated static let attachmentsDirectory = URL.documentsDirectory
        .appending(path: "Attachments", directoryHint: .isDirectory)

    /// Get the actual file URL in the current app container
    var actualFileURL: URL {
        // Rows saved by early builds hold an absolute path; use it while it still exists.
        if fileURL.path.hasPrefix("/") && FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        return Self.attachmentsDirectory.appending(path: fileURL.lastPathComponent, directoryHint: .notDirectory)
    }
    
    /// Load the image from disk
    func loadImage() async -> UIImage? {
        guard type == .image else { return nil }
        
        // Use actualFileURL which handles both old absolute paths and new relative paths
        let imageURL = actualFileURL

        if let image = await DiskBackedImageLoader.loadImage(at: imageURL) {
            return image
        }

        attachmentLogger.warning("Failed to load attachment image \(imageURL.lastPathComponent, privacy: .public); file exists: \(FileManager.default.fileExists(atPath: imageURL.path), privacy: .public)")
        return nil
    }
}

extension MessageAttachment {
    /// Files still used by saved chats, as URLs in the current Attachments directory.
    /// The store filters attachment rows by their chat, so neither messages nor
    /// conversations are faulted in; only each row's stored file name is read.
    static func referencedFileURLs(
        in context: ModelContext,
        excludingConversationIDs excludedConversationIDs: Set<UUID> = []
    ) throws -> Set<URL> {
        let excludedIDs = Array(excludedConversationIDs)
        let predicate = #Predicate<MessageAttachment> { attachment in
            if let conversation = attachment.message?.conversation {
                !excludedIDs.contains(conversation.id)
            } else {
                false
            }
        }
        let attachments = try context.fetch(FetchDescriptor(predicate: predicate))
        return Set(attachments.map { attachment in
            attachmentsDirectory.appending(path: attachment.fileURL.lastPathComponent, directoryHint: .notDirectory)
        })
    }
}
