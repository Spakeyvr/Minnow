//
//  ContentView.swift
//  ChatLLM
//
//  Created by Nevio on 10/24/25.
//

import SwiftUI
import SwiftData
import FoundationModels
import UIKit
import OSLog

nonisolated let contentLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ChatLLM", category: "ContentView")

struct ContentView: View {
    @Environment(\.modelContext) var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Query(sort: \Conversation.lastUpdated, order: .reverse)
    var conversations: [Conversation]

    @State var selection: Conversation?
    @State var currentViewModel: ChatViewModel?
    @State var draftConversation: Conversation? = nil
    @State private var isSidebarOpen = false

    @State private var searchText: String = ""
    @State private var debouncedSearchText: String = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var sidebarSectionsCache = SidebarSectionsCache()
    @State private var showSettings: Bool = false
    @State private var pendingSettingsAction: SettingsDataAction?
    @State var errorMessage: String?
    @State private var isErrorAlertPresented: Bool = false

    @State var chatExport: ChatExport?
    @State var exportURL: URL?
    @State private var isSearchPresented: Bool = false
    @State var attachmentCleanupTask: Task<Void, Never>?
    @State var isPerformingAutoDelete = false
    @Environment(\.scenePhase) private var scenePhase

    // App-wide preferences
    @AppStorage(AppSettingsKeys.chatPreferences) private var chatPreferences: String = ""
    @AppStorage(AppSettingsKeys.appAppearance) private var appAppearance: String = "system" // system | light | dark
    @AppStorage(AppSettingsKeys.appLanguage) private var appLanguage: String = AppLanguage.systemDefault.rawValue // en | de | es
    @AppStorage(AppSettingsKeys.reasoningModeDefault) private var reasoningModeDefault: Bool = false
    @AppStorage(AppSettingsKeys.autoDeleteOldChats) var autoDeleteOldChats: Bool = false
    @AppStorage(AppSettingsKeys.autoDeleteDays) var autoDeleteDays: Int = 30
    @AppStorage(AppSettingsKeys.hasCompletedOnboarding) private var hasCompletedOnboarding: Bool = false

    private var storedChatPreferences: String {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: AppSettingsKeys.chatPreferences) != nil {
            return chatPreferences
        }
        return defaults.string(forKey: AppSettingsKeys.legacyDefaultSystemPrompt) ?? ""
    }

    @State private var showsStoreRecoveryAlert = PersistentStoreRecovery.openFailed

    var body: some View {
        rootContent
            .alert("Chats Can't Be Saved", isPresented: $showsStoreRecoveryAlert) {
                Button("Keep Existing Chats", role: .cancel) {}
                Button("Start Fresh", role: .destructive) {
                    PersistentStoreRecovery.discardUnreadableStore()
                }
            } message: {
                Text("ChatLLM couldn't open your saved chats. New messages in this session won't be saved. Keep your existing chats to try again on the next launch, or start fresh with an empty history. A backup copy has been kept either way.")
            }
            // Apply selected language to entire UI
            .environment(\.locale, AppLanguage.resolve(appLanguage).locale)
            .background {
                AppAppearanceOverride(appearance: appAppearance)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        if hasCompletedOnboarding {
            mainExperience
                .overlay(alignment: .topLeading) {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("content.root")
                }
        } else {
            OnboardingView {
                hasCompletedOnboarding = true
            }
        }
    }

    private var mainExperience: some View {
        navigationRoot
            .focusedSceneValue(\.windowCommandActions, WindowCommandActions(
                newChat: { startDraftChat() },
                showSettings: { showSettings = true }
            ))
            .onAppear(perform: handleOnAppear)
            .onChange(of: selection, handleSelectionChange)
            .onChange(of: conversations, handleConversationsChange)
            .onChange(of: errorMessage, handleErrorMessageChange)
            .onChange(of: scenePhase) { _, phase in
                // The app can stay suspended for days, so retention can't wait for a cold launch.
                if phase == .active { performAutoDeleteIfNeeded() }
            }
            .errorAlert(
                isPresented: $isErrorAlertPresented,
                message: errorMessage ?? String(localized: "An unknown error occurred.", bundle: .appLocalized),
                onDismiss: { 
                    isErrorAlertPresented = false
                    errorMessage = nil
                }
            )
            .settingsCover(
                isPresented: $showSettings,
                hasChats: !conversations.isEmpty,
                canDeleteAllExceptCurrent: ChatNavigationRules.canDeleteAllExceptCurrent(
                    conversationIDs: conversations.map(\.id),
                    selectionID: selection?.id,
                    draftID: draftConversation?.id
                ),
                onDeleteAll: { queueSettingsAction(.deleteAll) },
                onDeleteAllExceptCurrent: { queueSettingsAction(.deleteAllExceptCurrent) },
                onExportChats: { queueSettingsAction(.export) },
                onDismiss: performPendingSettingsAction
            )
            .sheet(item: $chatExport, onDismiss: cleanupExportFile) { export in
                ActivityView(activityItems: [export.url])
                    // Match the system share sheet instead of a mostly empty full-height sheet.
                    .presentationDetents([.medium, .large])
            }
    }

    @ViewBuilder
    private var navigationRoot: some View {
        if horizontalSizeClass == .compact {
            drawerView
        } else {
            splitView
        }
    }

    // iPhone: the chat fills the screen and slides aside to reveal the sidebar.
    private var drawerView: some View {
        SidebarDrawer(isOpen: $isSidebarOpen) {
            NavigationStack {
                sidebar
            }
        } content: {
            NavigationStack {
                detailContent
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                                    isSidebarOpen.toggle()
                                }
                            } label: {
                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 17, weight: .semibold))
                            }
                            .accessibilityLabel("Show Chats")
                            .accessibilityIdentifier("sidebar.toggle")
                        }
                    }
                    // The drawer's accessibilityHidden stops at the NavigationStack boundary,
                    // so the covered chat's messages hide themselves from VoiceOver here.
                    .accessibilityHidden(isSidebarOpen)
            }
        }
    }

    // Regular width only: compact width uses the drawer, so this split view never collapses.
    private var splitView: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailContent
        }
    }

    // MARK: - Lifecycle handlers (split out for type-checking simplicity)

    private func handleOnAppear() {
        #if DEBUG
        if let demoConversation = seedWebSearchDemoIfNeeded() {
            selection = demoConversation
            return
        }
        #endif

        // Clean up old chats if auto-delete is enabled
        performAutoDeleteIfNeeded()
        scheduleAttachmentStorageCleanup()
        
        // iPhone opens straight into a fresh chat; the sidebar slides out on demand.
        if horizontalSizeClass == .compact, selection == nil, draftConversation == nil {
            startDraftChat(withHaptics: false)
            return
        }

        // Only auto-select on regular width (split view visible).
        if horizontalSizeClass == .regular,
           selection == nil,
           let first = conversations.first {
            selection = first
        }
    }

    private func handleSelectionChange(_ oldSelection: Conversation?, _ newSelection: Conversation?) {
        let newID = newSelection?.id
        // Entering draft mode: selection becomes nil but we want to keep the draft vm alive.
        if newID == nil && draftConversation != nil {
            ModelBackendBridge.shared.bindConversation(draftConversation)
            return
        }
        // Navigating to a real conversation discards any open draft.
        if newID != nil { draftConversation = nil }
        if let currentVM = currentViewModel, currentVM.conversation.id != newID {
            currentVM.deactivate()
            currentViewModel = nil
        }
        ModelBackendBridge.shared.bindConversation(newSelection)
        // Build the chat as soon as it is selected, so the detail column never waits
        // on the "Preparing chat…" placeholder.
        if let newSelection {
            openViewModel(for: newSelection)
        }
    }

    private func handleConversationsChange(_ oldConversations: [Conversation], _ newConversations: [Conversation]) {
        let change = ChatNavigationRules.listChange(
            from: oldConversations.map(\.id),
            to: newConversations.map(\.id),
            selectionID: selection?.id,
            draftID: draftConversation?.id,
            isRegularWidth: horizontalSizeClass == .regular
        )
        switch change {
        case .promoteDraft:
            // The draft's first message was saved, inserting it into the context.
            guard let draft = draftConversation else { return }
            draftConversation = nil
            selection = draft
        case .replaceDeletedSelection:
            // The open chat was deleted; retire its view model if that hasn't happened yet.
            if let currentVM = currentViewModel, currentVM.conversation.id == selection?.id {
                currentVM.deactivate()
                currentViewModel = nil
            }
            openDraftChat()
        case .select(let id):
            selection = newConversations.first { $0.id == id }
        case .none:
            break
        }
    }
    
    private func handleErrorMessageChange(_ old: String?, _ new: String?) {
        isErrorAlertPresented = (new != nil)
    }

    private var activeChatViewModel: ChatViewModel? {
        guard let vm = currentViewModel else { return nil }

        if let draft = draftConversation, vm.conversation.id == draft.id {
            return vm
        }

        if let convo = selection, vm.conversation.id == convo.id {
            return vm
        }

        return nil
    }

    // Extracted to reduce complexity in body
    @ViewBuilder
    private var detailContent: some View {
        if let vm = activeChatViewModel {
            ChatView(viewModel: vm, onNewChat: { startDraftChat() })
                // One chat screen per conversation: composer text, an attached image or an
                // in-progress edit must never carry over into another chat.
                .id(vm.conversation.id)
        } else if let convo = selection {
            VStack(spacing: 16) {
                ProgressView()
                Text("Preparing chat…")
                    .foregroundStyle(.secondary)
            }
            .task(id: convo.id) {
                // A fallback only: selecting a chat already builds its view model.
                guard selection?.id == convo.id else { return }
                openViewModel(for: convo)
            }
        } else if conversations.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "plus.bubble.right")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Start a New Chat")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Tap the + button to create your first conversation")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("New Chat") {
                    startDraftChat()
                }
                .buttonStyle(.glassProminent)
                .padding(.top)
            }
            .padding()
        } else {
            VStack(spacing: 16) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Select a Conversation")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Choose a chat from the sidebar to continue")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }

    private var searchTerms: [String] {
        debouncedSearchText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }

    @ViewBuilder
    private var sidebar: some View {
        ConversationSidebar(
            // Cached: ContentView renders several times a second while a reply streams,
            // and the search filter reads every message of every chat.
            sections: sidebarSectionsCache.sections(for: conversations, searchTerms: searchTerms),
            hasConversations: !conversations.isEmpty,
            selectedID: selection?.id,
            selection: $selection,
            searchText: $searchText,
            isSearchPresented: $isSearchPresented,
            onSubmitSearch: {
                // Immediate search on submit
                searchDebounceTask?.cancel()
                debouncedSearchText = searchText
            },
            onSelect: closeSidebar,
            onNewChat: {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    startDraftChat()
                }
            },
            onShowSettings: { showSettings = true },
            onRename: rename,
            // The sidebar has already asked the user to confirm.
            onDelete: delete
        )
        .equatable()
        .onChange(of: searchText) { _, newValue in
            // Debounce search input to avoid excessive filtering
            searchDebounceTask?.cancel()
            if newValue.isEmpty {
                debouncedSearchText = ""
                return
            }
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                debouncedSearchText = newValue
            }
        }
    }

    private func makeViewModel(for conversation: Conversation) -> ChatViewModel {
        let viewModel = ChatViewModel(generator: OnDeviceLLMGenerator(), context: modelContext, conversation: conversation)
        #if DEBUG
        seedComposerImageIfNeeded(into: viewModel)
        #endif
        return viewModel
    }

    /// Opens a saved chat's view model, retiring the previous chat's. Keeps the current
    /// one when it already belongs to this chat.
    private func openViewModel(for conversation: Conversation) {
        guard currentViewModel?.conversation.id != conversation.id else { return }
        currentViewModel?.deactivate()
        currentViewModel = makeViewModel(for: conversation)
    }

    private func closeSidebar() {
        guard isSidebarOpen else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            isSidebarOpen = false
        }
    }

    private func startDraftChat(withHaptics: Bool = true) {
        // Only one draft at a time — the button is disabled when a draft is already open.
        // From the sidebar, New Chat just reveals the draft that is already open. This runs
        // synchronously, so a second tap always sees the first tap's draft.
        guard ChatNavigationRules.newChatCreatesDraft(draftID: draftConversation?.id) else {
            closeSidebar()
            return
        }
        if withHaptics {
            AppHaptics.impact(.medium)
        }
        openDraftChat()
        closeSidebar()
        if !searchText.isEmpty {
            clearSearch()
        }
    }

    func openDraftChat() {
        currentViewModel?.deactivate()
        let convo = Conversation(
            title: String(localized: "New Chat", bundle: .appLocalized),
            chatPreferences: storedChatPreferences.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        convo.reasoningMode = reasoningModeDefault
        let backendBridge = ModelBackendBridge.shared
        convo.preferredBackendRawValue = backendBridge.selectedBackend.rawValue
        convo.preferredModelID = backendBridge.selectedModelID
        // Set draft BEFORE clearing selection so handleSelectionChange preserves this vm.
        draftConversation = convo
        currentViewModel = makeViewModel(for: convo)
        backendBridge.bindConversation(convo)
        selection = nil
    }

    private func clearSearch() {
        searchDebounceTask?.cancel()
        searchText = ""
        debouncedSearchText = ""
        isSearchPresented = false
    }


    // Wait for the cover to dismiss before exporting or showing action errors.
    // Deletion has already been confirmed inside Settings.
    private func queueSettingsAction(_ action: SettingsDataAction) {
        pendingSettingsAction = action
        showSettings = false
    }

    private func performPendingSettingsAction() {
        let action = pendingSettingsAction
        pendingSettingsAction = nil
        switch action {
        case .deleteAll: deleteAllChats()
        case .deleteAllExceptCurrent: deleteAllExceptCurrent()
        case .export: exportAllChats()
        case nil: break
        }
    }
}

#Preview {
    let schema = Schema([Conversation.self, Message.self, MessageAttachment.self])
    let container: ModelContainer
    do {
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    } catch {
        fatalError("Failed to create ModelContainer for preview: \(error)")
    }

    return ContentView()
        .modelContainer(container)
}

// MARK: - Lightweight View helpers to reduce body complexity

private extension View {
    func errorAlert(
        isPresented: Binding<Bool>,
        message: String,
        onDismiss: @escaping () -> Void
    ) -> some View {
        alert("Error", isPresented: isPresented) {
            Button("OK") {
                onDismiss()
            }
        } message: {
            Text(message)
        }
    }
}
