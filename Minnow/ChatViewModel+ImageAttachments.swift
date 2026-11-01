//
//  ChatViewModel+ImageAttachments.swift
//  Minnow
//
//  Images are sent only to models that read them directly. The composer
//  disables attachments for every other model.
//

import Foundation
import SwiftData
import UIKit
import OSLog

extension ChatViewModel {

    /// The message sent for an image without a question. It is shown as the user's
    /// message, so it follows the app language.
    static var defaultImagePrompt: String {
        String(localized: "Describe what you see", bundle: .appLocalized)
    }

    /// Send a user message with an image attachment.
    func sendWithImage(
        text: String,
        image: UIImage,
        regenerateTitle: Bool = false,
        editedUserMessageID: UUID? = nil
    ) async {
        _ = await trySendWithImage(
            text: text,
            image: image,
            regenerateTitle: regenerateTitle,
            editedUserMessageID: editedUserMessageID
        )
    }

    /// `sendWithImage`, returning false when the message was not sent (see `trySend`),
    /// so the caller can give the text and image back.
    func trySendWithImage(
        text: String,
        image: UIImage,
        regenerateTitle: Bool = false,
        editedUserMessageID: UUID? = nil
    ) async -> Bool {
        logger.debug("sendWithImage called")

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let userPrompt = trimmed.isEmpty ? Self.defaultImagePrompt : trimmed

        guard beginUserTurn() else { return false }
        return await runTurn { generationID in
            await self.sendImageTurn(
                userPrompt: userPrompt,
                image: image,
                generationID: generationID,
                regenerateTitle: regenerateTitle,
                editedUserMessageID: editedUserMessageID
            )
        }
    }

    private func sendImageTurn(
        userPrompt: String,
        image: UIImage,
        generationID: UUID,
        regenerateTitle: Bool,
        editedUserMessageID: UUID?
    ) async {
        let shouldUseReasoning = resolvedReasoningMode(for: userPrompt)

        guard isGenerationActive(generationID) else { return }

        guard let turn = prepareUserMessageForSend(
            userPrompt,
            forceAutoNaming: regenerateTitle,
            replacingMessageID: editedUserMessageID
        ) else { return }

        // The composer holds one image, so an image sent from an edit replaces the
        // message's old one rather than joining it.
        let replacedAttachments = editedUserMessageID == nil ? [] : turn.message.attachments

        // The placeholder below saves the attachment change together with the turn.
        let isAttached: Bool
        do {
            try await addImageAttachment(image, to: turn.message, savesImmediately: false)
            removeAttachments(replacedAttachments, from: turn.message)
            isAttached = true
        } catch {
            logger.error("Failed to attach image: \((error as NSError).localizedDescription, privacy: .public)")
            isAttached = false
        }
        guard isGenerationActive(generationID) else {
            // Keep what the edit already changed rather than leaving it unsaved.
            immediateSave()
            return
        }
        let assistantMsg = appendAssistantPlaceholder(isReasoningMode: shouldUseReasoning)

        if isAttached {
            _ = await streamAssistant(
                into: assistantMsg,
                basedOnHistoryUpTo: assistantMsg.order,
                additionalUserInstruction: nil,
                disableWebSearch: true,
                allowNativeImages: true,
                generationID: generationID
            )
        } else {
            // Answering without the image would read as if the model had seen it.
            assistantMsg.generationError = String(
                localized: "The image couldn't be saved, so it wasn't sent. Try attaching it again.",
                bundle: .appLocalized
            )
            assistantMsg.markAsComplete()
            conversation.lastUpdated = Date()
            immediateSave()
        }

        guard isGenerationActive(generationID) else { return }
        scheduleAutoNamingIfNeeded(turn.needsAutoNaming)
    }

    // MARK: - Private Helpers

    /// The files are left to the app's orphaned-attachment cleanup. The caller saves.
    private func removeAttachments(_ attachments: [MessageAttachment], from message: Message) {
        guard !attachments.isEmpty else { return }
        let ids = Set(attachments.map(\.id))
        message.attachments.removeAll { ids.contains($0.id) }
        for attachment in attachments {
            context.delete(attachment)
        }
    }

    /// Add image attachment (basic version). `savesImmediately: false` leaves the save to
    /// the caller when it saves the rest of the turn right after.
    @discardableResult
    func addImageAttachment(
        _ image: UIImage,
        to message: Message,
        savesImmediately: Bool = true
    ) async throws -> MessageAttachment {
        // Save image to disk
        let fileURL = try await ImageStore.shared.save(image: image)
        
        // Create attachment
        let attachment = MessageAttachment(
            type: .image,
            fileURL: fileURL,
            fileName: fileURL.lastPathComponent
        )
        
        // Add to message
        message.attachments.append(attachment)
        attachment.message = message
        
        conversation.lastUpdated = Date()
        if savesImmediately {
            immediateSave()
        }

        return attachment
    }
}
