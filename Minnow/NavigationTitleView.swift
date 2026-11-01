//
//  NavigationTitleView.swift
//  Minnow
//
//  Created by Nevio on 10/24/25.
//

import SwiftUI

// MARK: - Navigation title component

/// The chat's model name in the navigation bar. Before the first message it is a menu
/// for choosing the model; afterwards the model is locked and the title is plain.
struct NavigationTitleView: View {
    @Environment(\.locale) private var locale
    let hasMessages: Bool

    @ObservedObject var modelBackendBridge: ModelBackendBridge

    @State private var showModelManagement = false

    private var modelManager: MLXModelManager? { modelBackendBridge.modelManager }

    private var isLoading: Bool {
        modelBackendBridge.modelManager?.isLoading ?? false
    }

    private var displayName: String {
        if modelBackendBridge.selectedBackend == .foundationModels {
            return ModelBackendBridge.Backend.foundationModels.displayName
        } else if let current = modelBackendBridge.currentModelDisplayName {
            return current
        } else {
            return String(localized: "Select Model", bundle: .appLocalized, locale: locale)
        }
    }

    var body: some View {
        if hasMessages {
            // Mid-conversation: model is locked, show non-interactive capsule
            modelCapsule(interactive: false)
        } else {
            // No messages yet: allow model selection
            Menu {
                // Apple Intelligence
                if modelBackendBridge.foundationModelsAvailable {
                    Button {
                        modelBackendBridge.selectBackend(.foundationModels, source: "chat-input.foundation")
                    } label: {
                        HStack {
                            Text(ModelBackendBridge.Backend.foundationModels.displayName)
                            if modelBackendBridge.selectedBackend == .foundationModels {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                // MLX Models (only downloaded, compatible ones; the rest live in Manage Models)
                ForEach(modelManager?.installedModels ?? [], id: \.id) { model in
                    Button {
                        modelBackendBridge.switchToMLXModel(model.id, source: "chat-input.model")
                    } label: {
                        HStack {
                            Text(model.displayName)
                            if modelBackendBridge.selectedBackend == .mlx && modelBackendBridge.selectedModelID == model.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                Divider()

                Button {
                    showModelManagement = true
                } label: {
                    Label("Manage Models", systemImage: "square.stack.3d.down.forward")
                }
            } label: {
                modelCapsule(interactive: true)
            }
            .accessibilityHint(Text("Choose the model for this chat."))
            .menuOrder(.fixed)
            .sheet(isPresented: $showModelManagement) {
                ModelSelectionView()
            }
        }
    }

    private var isSwitching: Bool {
        isLoading && (modelBackendBridge.modelManager?.pendingModelToLoad != nil)
    }

    @ViewBuilder
    private func modelCapsule(interactive: Bool) -> some View {
        HStack(spacing: 4) {
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
            }

            if isSwitching {
                LoadingDotsLabel(font: .headline)
            } else {
                Text(displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            if interactive {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
        }
    }
}
