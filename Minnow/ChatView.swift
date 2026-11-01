//
//  ChatView.swift
//  Minnow
//
//  Created by Nevio on 10/24/25.
//

import SwiftUI
import UniformTypeIdentifiers
import UIKit
import PhotosUI
import OSLog
import ImageIO

nonisolated private let chatViewLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Minnow", category: "ChatView")

struct ChatView: View {
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject var viewModel: ChatViewModel
    var onNewChat: (() -> Void)? = nil

    @State private var inputText: String = ""
    @State private var composerFocusRequest = 0
    @State private var editingSession: MessageEditingSession?
    @State private var shareText: String = ""
    @State private var isSharePresented: Bool = false

    // Search toggle state
    @State private var forceSearch: Bool = false
    @AppStorage(AppSettingsKeys.disableToolCalls) private var disableToolCallsPreference: Bool = false

    // Backend bridge for checking reasoning availability
    @ObservedObject private var modelBackendBridge = ModelBackendBridge.shared

    // Camera state
    @State private var showCameraCapture = false

    // Network monitoring
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @State private var isFileImporterPresented = false

    // Image attachment state
    @State private var showImagePicker = false
    @State private var selectedImage: UIImage?
    @State private var selectedImageToken = UUID()
    @State private var selectedPhotoItem: PhotosPickerItem?

    // Error handling states
    @State private var errorAlert: ErrorAlert?

    // Scroll state
    @State private var hasAppeared = false
    @State private var isReaderNearBottom = true
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    // In-app browser state
    @State private var activeURL: URL?

    /// How long a context-menu action waits before changing the chat. Changing focus or
    /// presenting a sheet while UIKit is still dismissing the menu loses the change.
    private static let menuDismissalDelay: Duration = .milliseconds(150)

    // Pure computed property — no side effects, no @State mutations during body evaluation.
    // Read once per body pass; the message list skips re-rendering when its IDs are unchanged.
    private var sortedMessages: [Message] {
        let messages = viewModel.conversation.messages
            .filter { $0.role != .system }
            .sortedByOrder

        guard let editingSession else {
            return messages
        }
        return messages.filter { $0.order < editingSession.messageOrder }
    }

    private var imageInputAvailable: Bool {
        modelBackendBridge.nativeImageInputAvailable
    }

    private var webSearchToggleAvailable: Bool {
        networkMonitor.isConnected &&
        selectedImage == nil &&
        modelBackendBridge.toolCallsAvailableForCurrentBackend &&
        viewModel.searchService != nil
    }

    /// Why the Web Search toggle is off limits, shown under it. Nil while tool
    /// calls are disabled, since that toggle sits right above it.
    /// Forced search turns off whenever web search can't run for the next message.
    private var forceSearchMustReset: Bool {
        !webSearchToggleAvailable || effectiveDisableToolCalls
    }

    private var webSearchUnavailableReason: String? {
        guard !webSearchToggleAvailable, !effectiveDisableToolCalls else { return nil }
        if !networkMonitor.isConnected {
            return String(localized: "Web search needs an internet connection.", bundle: .appLocalized, locale: locale)
        }
        if selectedImage != nil {
            return String(localized: "Web search isn't available while an image is attached.", bundle: .appLocalized, locale: locale)
        }
        if viewModel.searchService == nil {
            return String(localized: "Add a Tavily API key in Settings to search the web.", bundle: .appLocalized, locale: locale)
        }
        return nil
    }

    private var toolCallsLockedDisabled: Bool {
        !modelBackendBridge.toolCallsAvailableForCurrentBackend
    }

    private var effectiveDisableToolCalls: Bool {
        toolCallsLockedDisabled || disableToolCallsPreference
    }

    private var disableToolCallsBinding: Binding<Bool> {
        Binding(
            get: { effectiveDisableToolCalls },
            set: { disableToolCallsPreference = $0 }
        )
    }

    // Error handling helper
    private struct ErrorAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let retry: (() -> Void)?
    }

    private struct MessageEditingSession {
        let messageID: UUID
        let messageOrder: Int
        let previousInputText: String
    }

    struct ScrollFollowState: Equatable {
        static let nearBottomThreshold: CGFloat = 60

        let contentHeight: CGFloat
        let visibleHeight: CGFloat
        let distanceFromBottom: CGFloat

        var isNearBottom: Bool { distanceFromBottom <= Self.nearBottomThreshold }

        /// Re-pin to the bottom when a size change (not the reader's own scrolling) moved the
        /// bottom out of view while the reader was there. Any hidden overflow counts, not just
        /// overflow past the near-bottom threshold: a keyboard covering the last 40 points would
        /// otherwise leave the reply's action row hidden behind the composer.
        func shouldFollow(from old: ScrollFollowState) -> Bool {
            let sizeChanged = contentHeight != old.contentHeight || visibleHeight != old.visibleHeight
            return sizeChanged && old.isNearBottom && distanceFromBottom > 0.5
        }
    }

    private struct MessageEditingCommit {
        let messageID: UUID?
        let requiresTitleRegeneration: Bool
    }

    /// What the composer held before a send cleared it.
    private struct ComposerRestoreState {
        let text: String
        let image: UIImage?
        let forceSearch: Bool
        let editingSession: MessageEditingSession?
    }

    static func shouldPresentInAppBrowser(for url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }

        return scheme == "http" || scheme == "https"
    }

    var body: some View {
        let messages = sortedMessages
        VStack(spacing: 0) {
            ScrollView {
                ChatMessageList(
                    messages: messages,
                    viewModel: viewModel,
                    pendingReplyActivity: pendingReplyActivity(in: messages),
                    onEdit: beginEditing,
                    onShare: { text in
                        // Defer to allow context menu to dismiss cleanly
                        menuSafe {
                            shareText = text
                            isSharePresented = true
                        }
                    }
                )
                // Typing in the composer re-renders ChatView; the list only needs to when
                // its messages or the pending-reply indicator change.
                .equatable()
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollPosition($scrollPosition)
            .overlay(alignment: .bottom) {
                // The animation stays on the button, so the list's own updates in the same
                // transaction (a streaming reply, the follow scroll) aren't animated with it.
                ZStack {
                    jumpToLatestButton(hasMessages: !messages.isEmpty)
                }
                .animation(.easeInOut(duration: 0.2), value: isReaderNearBottom)
            }
            // Short chats sit at the top edge; longer ones open at the latest message.
            // Edge-based scrolling (unlike scrolling a message to the bottom anchor) never
            // pushes short content past the top.
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Follow a growing reply (or a shrinking viewport) only while the reader is already
            // at the bottom; someone who scrolled up to read earlier messages stays put.
            .onScrollGeometryChange(for: ScrollFollowState.self) { geometry in
                // visibleRect spans the insets (navigation bar, composer, keyboard), so
                // measure against the inset-free container and the inset content bottom.
                ScrollFollowState(
                    contentHeight: geometry.contentSize.height,
                    visibleHeight: geometry.containerSize.height,
                    distanceFromBottom: geometry.contentSize.height + geometry.contentInsets.bottom
                        - geometry.visibleRect.maxY
                )
            } action: { old, new in
                if isReaderNearBottom != new.isNearBottom {
                    isReaderNearBottom = new.isNearBottom
                }
                if new.shouldFollow(from: old) {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }
            .task {
                // Cancelled with the view. Settles the bottom once lazily measured rows have
                // replaced their estimates, which the initial-offset anchor alone can miss.
                hasAppeared = true
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                scrollToBottom(animated: false)
            }
            // Scroll when streaming message changes
            .onChange(of: viewModel.streamingMessageID) { _, newID in
                guard let id = newID,
                      sortedMessages.contains(where: { $0.id == id }) else { return }
                scrollToBottom(animated: true)
            }
            // Scroll when the last message ID changes (more precise than count)
            .onChange(of: messages.last?.id) { _, _ in
                scrollToBottom(animated: true)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: restoreComposerDraft)
        .onChange(of: inputText) { _, text in
            viewModel.composerDraft.recordText(text, preEditText: editingSession?.previousInputText)
        }
        .onChange(of: selectedImageToken) {
            viewModel.composerDraft.image = selectedImage
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Not sortedMessages: editing the first message hides every message,
                // which must not unlock the model mid-conversation.
                NavigationTitleView(
                    hasMessages: canStartNewChat,
                    modelBackendBridge: modelBackendBridge
                )
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    onNewChat?()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(canStartNewChat ? .primary : .secondary)
                }
                .disabled(!canStartNewChat)
                .accessibilityLabel("New Chat")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                // Image preview (if image is attached)
                if let image = selectedImage {
                    HStack(spacing: 12) {
                        // Thumbnail. Decorative: the label beside it says an image is attached.
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 50, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityHidden(true)

                        Text("Image attached")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Spacer()

                        // Remove button
                        Button {
                            withAnimation {
                                clearSelectedImage()
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Remove Image")
                    }
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                composer
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            .background(Color.clear)
        }
        .sheet(isPresented: $isSharePresented, onDismiss: {
            shareText = ""
        }) {
            ActivityView(activityItems: [shareText as Any])
                // Match the system share sheet instead of a mostly empty full-height sheet.
                .presentationDetents([.medium, .large])
        }
        .photosPicker(
            isPresented: $showImagePicker,
            selection: $selectedPhotoItem,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                let image = await loadAttachmentImage(from: newItem)
                selectedPhotoItem = nil
                guard let image else {
                    chatViewLogger.error("Failed to load image from picker item")
                    presentError(ImageError.invalidFormat, title: String(localized: "Photo Import Failed", bundle: .appLocalized))
                    return
                }
                setSelectedImage(image)
            }
        }
        .alert(item: $errorAlert) { alert in
            if let retry = alert.retry {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("Retry"), action: retry),
                    secondaryButton: .cancel()
                )
            } else {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            Task {
                do {
                    try await handleFileImporterResult(result)
                } catch {
                    presentError(error, title: String(localized: "File Import Failed", bundle: .appLocalized))
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Someone who scrolled up to read keeps their place when they come back.
            if phase == .active, hasAppeared, isReaderNearBottom {
                scrollToBottom(animated: false)
            }
        }
        // Covers losing the network, attaching an image, a backend without tool calls,
        // a missing search key and turning tool calls off.
        .onChange(of: forceSearchMustReset) { _, mustReset in
            if mustReset && forceSearch {
                forceSearch = false
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if Self.shouldPresentInAppBrowser(for: url) {
                activeURL = url
                return .handled
            }

            return .systemAction(url)
        })
        .sheet(item: $activeURL) { url in
            SafariView(url: url)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showCameraCapture) {
            CameraCapturePicker(isPresented: $showCameraCapture) { image in
                setSelectedImage(image)
            }
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var composer: some View {
        SimpleTextComposer(
            text: $inputText,
            placeholder: String(localized: "Ask anything", bundle: .appLocalized, locale: locale),
            focusRequest: composerFocusRequest,
            isEditing: editingSession != nil,
            onSend: {
                Task { await sendIfPossible() }
            },
            onStop: {
                viewModel.cancelGeneration()
            },
            onCancelEditing: cancelEditing,
            canSend: !viewModel.isBusy
                && (selectedImage != nil || !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
            isGenerating: viewModel.isGenerating,
            onCamera: {
                showCameraCapture = true
            },
            onPhotosPicker: {
                showImagePicker = true
            },
            onFileImporter: {
                isFileImporterPresented = true
            },
            imageInputAvailable: imageInputAvailable,
            forceSearch: $forceSearch,
            searchAvailable: webSearchToggleAvailable,
            searchUnavailableReason: webSearchUnavailableReason,
            disableToolCalls: disableToolCallsBinding,
            toolCallsLockedDisabled: toolCallsLockedDisabled,
            isReasoningEnabled: Binding(
                get: { viewModel.conversation.reasoningMode },
                set: { viewModel.setReasoningMode($0) }
            ),
            isSmartReasoningEnabled: Binding(
                get: { viewModel.conversation.smartReasoningMode },
                set: { viewModel.setSmartReasoningMode($0) }
            ),
            reasoningAvailable: modelBackendBridge.reasoningAvailable,
            reasoningRequired: modelBackendBridge.reasoningRequired
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message composer")
    }

    /// Shown once the reader scrolls away from the latest message, so a long chat
    /// or a reply that keeps growing below them is one tap from the bottom.
    @ViewBuilder
    private func jumpToLatestButton(hasMessages: Bool) -> some View {
        if !isReaderNearBottom && hasMessages {
            Button {
                scrollToBottom(animated: true)
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Scroll to Latest Message")
            .accessibilityIdentifier("chat.scrollToLatest")
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }

    // MARK: - Computed State

    /// True when the current conversation has at least one non-system message.
    /// Used to gray out the New Chat button when already on an empty chat.
    private var canStartNewChat: Bool {
        viewModel.conversation.messages.contains { $0.role != .system }
    }

    /// The activity shown under the list while a reply is starting and has no message yet.
    private func pendingReplyActivity(in messages: [Message]) -> StreamingActivity? {
        guard viewModel.isGenerating,
              let streamingID = viewModel.streamingMessageID,
              !messages.contains(where: { $0.id == streamingID }) else {
            return nil
        }
        return viewModel.streamingActivity
    }

    // MARK: - Helper Methods

    private func beginEditing(_ message: Message) {
        menuSafe {
            guard !viewModel.isBusy else { return }

            let previousInputText = editingSession?.previousInputText ?? inputText
            editingSession = MessageEditingSession(
                messageID: message.id,
                messageOrder: message.order,
                previousInputText: previousInputText
            )
            inputText = message.text
            composerFocusRequest += 1
        }
    }

    private func sendIfPossible() async {
        // A regeneration that is still unwinding refuses new messages too.
        guard !viewModel.isBusy else { return }
        let textToSend = inputText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if we have an image to send
        if let image = selectedImage {
            // An image picked before switching to a text-only model stays in
            // the composer; that model would answer without seeing it.
            guard imageInputAvailable else {
                presentError(
                    ImageError.unsupportedByModel,
                    title: String(localized: "Can't Send Image", bundle: .appLocalized)
                )
                return
            }

            let replacementText = textToSend.isEmpty ? ChatViewModel.defaultImagePrompt : textToSend
            let draft = ComposerRestoreState(
                text: inputText,
                image: image,
                forceSearch: forceSearch,
                editingSession: editingSession
            )
            guard let editingCommit = commitEditingIfNeeded(replacementText: replacementText) else { return }

            // Clear immediately for snappy feel, then send
            inputText = ""
            clearSelectedImage()

            let sent = await viewModel.trySendWithImage(
                text: replacementText,
                image: image,
                regenerateTitle: editingCommit.requiresTitleRegeneration,
                editedUserMessageID: editingCommit.messageID
            )
            if !sent {
                restoreComposer(draft, afterCommit: editingCommit)
            }
            return
        }

        // Normal text-only message
        guard !textToSend.isEmpty else { return }
        let draft = ComposerRestoreState(
            text: inputText,
            image: nil,
            forceSearch: forceSearch,
            editingSession: editingSession
        )
        guard let editingCommit = commitEditingIfNeeded(replacementText: textToSend) else { return }

        let shouldSearch = forceSearch
        let shouldDisableToolCalls = effectiveDisableToolCalls

        // Clear input immediately for snappy feel, then send
        inputText = ""
        forceSearch = false

        let sent = await viewModel.trySend(
            userText: textToSend,
            forceSearch: shouldSearch,
            disableToolCalls: shouldDisableToolCalls,
            regenerateTitle: editingCommit.requiresTitleRegeneration,
            editedUserMessageID: editingCommit.messageID
        )
        if !sent {
            restoreComposer(draft, afterCommit: editingCommit)
        }
    }

    /// Gives a refused message back to the composer, so the user doesn't lose what they typed.
    /// An edit that was already committed stays an edit of the same message.
    private func restoreComposer(_ draft: ComposerRestoreState, afterCommit commit: MessageEditingCommit) {
        // Something typed while the refused send was waiting wins over the old draft.
        if inputText.isEmpty {
            inputText = draft.text
        }
        if selectedImage == nil, let image = draft.image {
            setSelectedImage(image)
        }
        if draft.forceSearch && !forceSearchMustReset {
            forceSearch = true
        }
        if editingSession == nil,
           let previous = draft.editingSession,
           let messageID = commit.messageID,
           let message = viewModel.conversation.messages.first(where: { $0.id == messageID }) {
            editingSession = MessageEditingSession(
                messageID: messageID,
                messageOrder: message.order,
                previousInputText: previous.previousInputText
            )
        }
        chatViewLogger.notice("Message was not sent; restored it to the composer")
    }

    private func cancelEditing() {
        guard let editingSession else { return }
        inputText = editingSession.previousInputText
        self.editingSession = nil
        composerFocusRequest += 1
    }

    private func commitEditingIfNeeded(replacementText: String) -> MessageEditingCommit? {
        guard let editingSession else {
            return MessageEditingCommit(messageID: nil, requiresTitleRegeneration: false)
        }
        guard let rewind = viewModel.rewindForEditingUserMessage(
            messageID: editingSession.messageID,
            replacementText: replacementText
        ) else {
            return nil
        }

        self.editingSession = nil
        return MessageEditingCommit(
            messageID: rewind.messageID,
            requiresTitleRegeneration: rewind.requiresTitleRegeneration
        )
    }

    private func scrollToBottom(animated: Bool) {
        guard !sortedMessages.isEmpty else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) {
                scrollPosition.scrollTo(edge: .bottom)
            }
        } else {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    private func presentError(_ error: Error, title: String, retry: (() -> Void)? = nil) {
        // Image and file errors describe the failure, never the user's content.
        chatViewLogger.error("Error in ChatView: \(error.localizedDescription, privacy: .public)")

        let message: String
        if let localizedError = error as? LocalizedError {
            message = localizedError.errorDescription ?? error.localizedDescription
        } else {
            message = error.localizedDescription
        }

        errorAlert = ErrorAlert(
            title: title,
            message: message,
            retry: retry
        )
    }

    // MARK: - Image and File Handling

    private func handleFileImporterResult(_ result: Result<[URL], Error>) async throws {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                throw ImageError.noData
            }
            guard url.startAccessingSecurityScopedResource() else {
                throw ImageError.accessDenied
            }
            defer { url.stopAccessingSecurityScopedResource() }

            // Reading a file (possibly from iCloud) and decoding it stays off the main actor.
            guard let image = await AttachmentImageDecoder.thumbnail(from: url) else {
                throw ImageError.invalidFormat
            }
            setSelectedImage(image)
        case .failure(let error):
            chatViewLogger.error("File importer failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Brings back an unsent draft after this view was rebuilt for the same conversation.
    private func restoreComposerDraft() {
        let draft = viewModel.composerDraft
        if inputText.isEmpty, !draft.text.isEmpty {
            inputText = draft.text
        }
        if selectedImage == nil, let image = draft.image {
            setSelectedImage(image)
        }
    }

    private func setSelectedImage(_ image: UIImage) {
        selectedImage = image
        selectedImageToken = UUID()
        forceSearch = false
    }

    private func clearSelectedImage() {
        selectedImage = nil
        selectedImageToken = UUID()
    }

    // MARK: - Error Types

    private enum ImageError: LocalizedError {
        case noData
        case invalidFormat
        case accessDenied
        case unsupportedByModel

        var errorDescription: String? {
            switch self {
            case .noData:
                return String(localized: "Could not load the selected image.", bundle: .appLocalized)
            case .invalidFormat:
                return String(localized: "The selected file is not a valid image.", bundle: .appLocalized)
            case .accessDenied:
                return String(localized: "Access to the file was denied.", bundle: .appLocalized)
            case .unsupportedByModel:
                return String(localized: "The selected model can't read images. Remove the image or switch to a model that supports images.", bundle: .appLocalized)
            }
        }
    }

    // Small helper: run UI mutations after menus have time to dismiss
    private func menuSafe(_ action: @escaping () -> Void) {
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: Self.menuDismissalDelay)
            action()
        }
    }

    // MARK: - Image Loading

    /// Loads a picked photo at the attachment budget. The original can be tens of
    /// megabytes, so decoding happens off the main actor.
    private func loadAttachmentImage(from item: PhotosPickerItem) async -> UIImage? {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            return nil
        }
        return await AttachmentImageDecoder.thumbnail(from: data)
    }
}

// MARK: - Message List

/// The conversation's messages. Equatable on what it lays out, so composer keystrokes,
/// which re-render ChatView, don't rebuild and re-diff every cell. Cells observe their
/// own message and the view model's `streamingState`, so they still update while a reply streams.
private struct ChatMessageList: View, Equatable {
    let messages: [Message]
    let viewModel: ChatViewModel
    /// Shown under the list while a reply is starting and has no message yet.
    let pendingReplyActivity: StreamingActivity?
    let onEdit: (Message) -> Void
    let onShare: (String) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.viewModel === rhs.viewModel
            && lhs.pendingReplyActivity == rhs.pendingReplyActivity
            && lhs.messages.map(\.id) == rhs.messages.map(\.id)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            // Use ForEach with stable IDs for better performance
            ForEach(messages, id: \.id) { msg in
                MessageCellView(
                    message: msg,
                    viewModel: viewModel,
                    onEdit: onEdit,
                    onShare: onShare
                )
            }

            if let pendingReplyActivity {
                StreamingActivityIndicator(activity: pendingReplyActivity)
                    .padding(.vertical, 8)
            }
        }
        .padding()
    }
}

// MARK: - Attachment Image Decoding

/// Decodes picked photos and files into bounded attachment images away from the main actor.
nonisolated enum AttachmentImageDecoder {
    /// Longest side of an attached image, in pixels. Matches the size ImageStore saves
    /// attachments at, so a larger decode would only be downscaled again on save.
    static let pixelBudget = 1_200

    @concurrent
    static func thumbnail(from data: Data, maxPixelSize: Int = pixelBudget) async -> UIImage? {
        // Bridging shares Data's buffer; copying it into a new CFData would double the
        // memory of a large original.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return thumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    @concurrent
    static func thumbnail(from url: URL, maxPixelSize: Int = pixelBudget) async -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return thumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    private static func thumbnail(from source: CGImageSource, maxPixelSize: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Camera Capture Picker

private struct CameraCapturePicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onCapture: @MainActor (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCapturePicker
        init(_ parent: CameraCapturePicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else {
                parent.isPresented = false
                return
            }
            parent.isPresented = false

            // UIImagePickerController only exposes a UIImage for camera stills.
            // Prepare a bounded thumbnail before handing it to chat state, so
            // the original capture is never retained by the SwiftUI view tree.
            Task { @MainActor in
                let pixelWidth = image.size.width * image.scale
                let pixelHeight = image.size.height * image.scale
                let maxSide = max(pixelWidth, pixelHeight)
                let budget = CGFloat(AttachmentImageDecoder.pixelBudget)
                guard maxSide > budget else {
                    parent.onCapture(image)
                    return
                }
                let ratio = budget / maxSide
                let targetSize = CGSize(
                    width: (pixelWidth * ratio).rounded(),
                    height: (pixelHeight * ratio).rounded()
                )
                let thumbnail = await image.byPreparingThumbnail(ofSize: targetSize)
                parent.onCapture(thumbnail ?? image)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
        }
    }
}
