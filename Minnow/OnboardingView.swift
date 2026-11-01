//
//  OnboardingView.swift
//  Minnow
//
//  First-launch onboarding flow for new users.
//

import SwiftUI

struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case intro
        case tavily
        case mlx

        var title: LocalizedStringKey {
            switch self {
            case .intro:
                return "Welcome to Minnow"
            case .tavily:
                return "Web Search"
            case .mlx:
                return "Local Models"
            }
        }
    }

    let onFinish: () -> Void

    @ObservedObject private var modelBackendBridge = ModelBackendBridge.shared

    @Environment(\.locale) private var locale
    @State private var step: Step = .intro
    /// Read from the Keychain once, on appear. A State initial value would repeat the
    /// Keychain read on every parent render.
    @State private var tavilyKey: String = ""
    @State private var hasLoadedTavilyKey = false
    @State private var tavilyKeySaveFailed = false
    @State private var selectedModelID: String?

    private var modelManager: MLXModelManager? { modelBackendBridge.modelManager }

    private var selectedModel: MLXModelManager.MLXModelInfo? {
        guard let selectedModelID else { return modelManager?.availableModels.first }
        return modelManager?.model(withID: selectedModelID) ?? modelManager?.availableModels.first
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                ScrollView {
                    VStack(spacing: 24) {
                        header
                        progressDots
                        content
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Longer translations can scroll while navigation stays reachable.
                // Each step starts at the top without resetting onboarding state.
                .id(step)
                footer
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(backgroundGradient)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") {
                        finishOnboarding()
                    }
                    .accessibilityIdentifier("onboarding.skip")
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityIdentifier("onboarding.root")
        }
        .alert("Couldn't Save API Key", isPresented: $tavilyKeySaveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The Tavily API key couldn't be stored in the Keychain. Try again.")
        }
        .onAppear {
            if !hasLoadedTavilyKey {
                hasLoadedTavilyKey = true
                tavilyKey = TavilyAPIKeyStore.currentKey() ?? ""
            }
            if selectedModelID == nil {
                selectedModelID = modelManager?.availableModels.first?.id
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(step.title)
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
                .accessibilityIdentifier(headerTitleIdentifier)

            Text(stepSubtitle)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.rawValue) { currentStep in
                Capsule()
                    .fill(currentStep == step ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(width: currentStep == step ? 28 : 10, height: 10)
                    .animation(.easeInOut(duration: 0.2), value: step)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
        .accessibilityIdentifier("onboarding.progress")
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .intro:
            introStep
        case .tavily:
            tavilyStep
        case .mlx:
            mlxStep
        }
    }

    private var introStep: some View {
        VStack(alignment: .leading, spacing: 18) {

            onboardingCard(
                title: "Start instantly",
                systemImage: "apple.logo",
                description: "The app works right away with Apple Foundation Models when your device supports them."
            )

            onboardingCard(
                title: "Run bigger local models",
                systemImage: "square.stack.3d.down.forward",
                description: "You can optionally download MLX models for fully local chats, reasoning, and native image support."
            )

            onboardingCard(
                title: "Search when needed",
                systemImage: "magnifyingglass.circle",
                description: "Add a Tavily API key if you want the assistant to search the web for current information."
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tavilyStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Tavily is optional")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Paste a Tavily API key if you want web search. You can also skip this and use the rest of the app normally.")
                .foregroundStyle(.secondary)

            SecureField("Enter your Tavily API key", text: $tavilyKey)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.continue)
                .onSubmit(advance)
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityIdentifier("onboarding.tavily.key")

            Link(destination: URL(string: "https://app.tavily.com/")!) {
                Label("Get a Tavily API key", systemImage: "arrow.up.right")
            }
            .font(.subheadline.weight(.semibold))

            Label("Your key is stored in Keychain and sent to Tavily only to authenticate web searches.", systemImage: "lock.shield")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mlxStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Download a local model")
                .font(.title2)
                .fontWeight(.semibold)

            Text("You can finish now and keep using the app while the download runs in the background.")
                .foregroundStyle(.secondary)

            if let modelManager {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(modelManager.availableModels) { model in
                            modelRow(for: model, modelManager: modelManager)
                        }
                    }
                }
                .frame(maxHeight: 300)

                if let selectedModel {
                    // Observes the manager itself: the bridge doesn't forward download progress.
                    OnboardingDownloadStatusView(model: selectedModel, modelManager: modelManager)
                }
            } else {
                LoadingIndicator()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modelRow(
        for model: MLXModelManager.MLXModelInfo,
        modelManager: MLXModelManager
    ) -> some View {
        Button {
            selectedModelID = model.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                modelSelectionIcon(for: model)
                modelDescription(for: model, modelManager: modelManager)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedModelID == model.id ? .isSelected : [])
        .accessibilityIdentifier("onboarding.mlx.model.\(model.id)")
    }

    private func modelSelectionIcon(for model: MLXModelManager.MLXModelInfo) -> some View {
        Image(systemName: selectedModelID == model.id ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(selectedModelID == model.id ? Color.accentColor : Color.secondary)
    }

    private func modelDescription(
        for model: MLXModelManager.MLXModelInfo,
        modelManager: MLXModelManager
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text(model.downloadSize(locale: locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(model.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if model.isAvailable {
                Label("Already downloaded", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if let issue = modelManager.availabilityIssue(for: model) {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    enum DownloadStatus: Equatable {
        case downloading
        case installed
        case unavailable(String)
        /// Offers the download, with the last attempt's error when it failed.
        case download(previousError: String?)
    }

    static func downloadStatus(
        hasActiveDownload: Bool,
        isInstalled: Bool,
        availabilityIssue: String?,
        downloadError: String?
    ) -> DownloadStatus {
        if hasActiveDownload { return .downloading }
        if isInstalled { return .installed }
        if let availabilityIssue { return .unavailable(availabilityIssue) }
        return .download(previousError: downloadError)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step != .intro {
                Button("Back") {
                    previousStep()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("onboarding.back")
            }

            Spacer()

            Button(primaryButtonTitle) {
                advance()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(primaryButtonIdentifier)
        }
    }

    private func onboardingCard(title: LocalizedStringKey, systemImage: String, description: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Text(description)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(uiColor: .systemBackground),
                Color.accentColor.opacity(0.08),
                Color(uiColor: .secondarySystemBackground)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var stepSubtitle: LocalizedStringKey {
        switch step {
        case .intro:
            return "A quick look at what the app can do."
        case .tavily:
            return "Optional setup for web search."
        case .mlx:
            return "Optional setup for larger fully local models."
        }
    }

    private var primaryButtonTitle: LocalizedStringKey {
        switch step {
        case .intro:
            return "Continue"
        case .tavily:
            return "Continue"
        case .mlx:
            return "Finish"
        }
    }

    private var primaryButtonIdentifier: String {
        switch step {
        case .intro:
            return "onboarding.intro.continue"
        case .tavily:
            return "onboarding.tavily.continue"
        case .mlx:
            return "onboarding.finish"
        }
    }

    private var headerTitleIdentifier: String {
        switch step {
        case .intro:
            return "onboarding.intro.title"
        case .tavily:
            return "onboarding.tavily.title"
        case .mlx:
            return "onboarding.mlx.title"
        }
    }

    private func previousStep() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private func advance() {
        switch step {
        case .intro:
            step = .tavily
        case .tavily:
            // Trims the key; an empty key clears the stored key.
            guard saveTavilyKey() else { return }
            step = .mlx
        case .mlx:
            finishOnboarding()
        }
    }

    private func finishOnboarding() {
        // Skip is always visible, so a key typed on the web search step is kept
        // rather than dropped just because Continue wasn't tapped first.
        if step == .tavily {
            guard saveTavilyKey() else { return }
        }
        onFinish()
    }

    /// Stores the typed key. On failure the user stays on this step and is told, rather
    /// than leaving onboarding believing web search is set up.
    private func saveTavilyKey() -> Bool {
        guard TavilyAPIKeyStore.save(tavilyKey) else {
            tavilyKeySaveFailed = true
            return false
        }
        return true
    }
}

// MARK: - Download Status

/// The selected model's download state. It observes the model manager directly, so
/// progress updates re-render only this view, not the whole onboarding flow.
private struct OnboardingDownloadStatusView: View {
    let model: MLXModelManager.MLXModelInfo
    @ObservedObject var modelManager: MLXModelManager
    @Environment(\.locale) private var locale

    var body: some View {
        let status = OnboardingView.downloadStatus(
            hasActiveDownload: modelManager.activeDownloadModel != nil,
            isInstalled: model.isAvailable,
            availabilityIssue: modelManager.availabilityIssue(for: model),
            downloadError: modelManager.downloadError(for: model.id)
        )
        switch status {
        case .downloading:
            if let activeDownloadModel = modelManager.activeDownloadModel {
                VStack(alignment: .leading, spacing: 8) {
                    Text(activeDownloadModel.id == model.id ? "Downloading \(activeDownloadModel.displayName)" : "\(activeDownloadModel.displayName) is downloading")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    ProgressView(value: modelManager.downloadProgress)
                    Text(modelManager.downloadProgress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("You can finish onboarding now and keep using the app while this continues.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("onboarding.mlx.progress.\(activeDownloadModel.id)")
            }
        case .installed:
            Label("MLX model is installed.", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
        case .unavailable(let issue):
            Text(issue)
                .font(.caption)
                .foregroundStyle(.orange)
        case .download(let previousError):
            // A failed download keeps its button, so the user can try again right here.
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    modelManager.startDownload(for: model)
                } label: {
                    Label("Download \(model.downloadSize(locale: locale))", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(modelManager.hasActiveDownload(excluding: model.id))
                .accessibilityIdentifier("onboarding.mlx.download")

                if let previousError {
                    Text(previousError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("onboarding.mlx.downloadError")
                }
            }
        }
    }
}
