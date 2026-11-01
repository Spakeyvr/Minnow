import SwiftUI

/// Ranges and starting values for the on-device model settings. The stored preferences
/// are clamped to the same limits, so keep the two in step.
nonisolated enum MLXTuningLimits {
    static let minimumContextWindowTokens = 512
    static let contextWindowStep = 512
    static let outputTokenRange = 512...1024
    static let outputTokenStep = 32
    /// Where Maximum Output starts when Unlimited Output is turned off.
    static let defaultCappedOutputTokens = 1024
    /// 1.0 means no penalty, which the Reduce Repetition toggle represents as off.
    static let noRepetitionPenalty = 1.0
    static let repetitionPenaltyRange = 1.05...1.5
    static let repetitionPenaltyStep = 0.05
    /// Where the penalty starts when Reduce Repetition is turned on.
    static let defaultRepetitionPenalty = 1.1
}

struct AdvancedSettingsView: View {
    @Binding var settings: AppSettingsDraft
    @State private var showingResetConfirmation = false

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    MLXSettingsView(settings: $settings)
                } label: {
                    Label("On-Device Models", systemImage: "cpu")
                }
                .accessibilityIdentifier("settings.mlx")
                NavigationLink {
                    DeveloperSettingsView(settings: $settings)
                } label: {
                    Label("Developer", systemImage: "hammer")
                }
                .accessibilityIdentifier("settings.developer")
            } footer: {
                Text("Fine-tune local models and diagnostics. The defaults are recommended for most people.")
            }
            Section {
                Button("Reset All Settings", role: .destructive) { showingResetConfirmation = true }
                    .accessibilityIdentifier("settings.reset")
            } footer: {
                Text("Restore default preferences and remove the saved web search key. Chats and downloaded models are kept.")
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Reset All Settings?", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { settings.resetToDefaults() }
        } message: {
            Text("This restores all preferences, clears response preferences, and removes the saved web search key. Chats and downloaded models will not be deleted.")
        }
    }
}

private struct MLXSettingsView: View {
    @Binding var settings: AppSettingsDraft
    @Environment(\.locale) private var locale

    private enum RotorQuantCopy {
        static var infoMessage: String { String(localized: "Enabled by default for persistent MLX text and image chats, RotorQuant uses IsoQuant block rotations with 4-bit keys, 4-bit values, exact prefill buffering, and per-layer deterministic rotation parameters to reduce memory use. Tool and low-memory turns use safer uncompressed or bounded caches.", bundle: .appLocalized) }
        static var accessibilityHint: String { String(localized: "Enabled by default for supported persistent MLX text and image chats. Tool and low-memory turns use safer cache modes.", bundle: .appLocalized) }
        static var experimentalTitle: String { String(localized: "RotorQuant Experimental", bundle: .appLocalized) }
        static var experimentalMessage: String { String(localized: "RotorQuant is very early and in beta. It can reduce KV-cache memory, but speed and stability are still being tuned.", bundle: .appLocalized) }
    }

    @ObservedObject private var modelBackendBridge = ModelBackendBridge.shared

    private var selectedModel: MLXModelManager.MLXModelInfo? { modelBackendBridge.selectedLocalModel }
    private var deviceMaximum: Int {
        MLXDeviceSupportProfile.current.contextWindowSettingMaximum(selectedModel: selectedModel)
    }
    private var sliderMaximum: Int {
        settings.overrideContextWindowLimit
            ? max(deviceMaximum, UserDefaults.mlxDeveloperContextWindowMaximum)
            : deviceMaximum
    }
    private var contextTokens: Binding<Double> {
        Binding(
            get: {
                Double(settings.mlxContextWindowTokens <= 0
                       ? deviceMaximum
                       : min(max(settings.mlxContextWindowTokens, MLXTuningLimits.minimumContextWindowTokens), sliderMaximum))
            },
            set: { settings.mlxContextWindowTokens = Int($0.rounded()) }
        )
    }
    private var outputTokens: Binding<Double> {
        Binding(get: { Double(max(MLXTuningLimits.outputTokenRange.lowerBound, settings.mlxMaxOutputTokens)) },
                set: { settings.mlxMaxOutputTokens = Int($0.rounded()) })
    }
    private var outputTokenSliderRange: ClosedRange<Double> {
        Double(MLXTuningLimits.outputTokenRange.lowerBound)...Double(MLXTuningLimits.outputTokenRange.upperBound)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Context Window", value: String(localized: "\(Int(contextTokens.wrappedValue)) tokens", bundle: .appLocalized, locale: locale))
                Slider(
                    value: contextTokens,
                    in: Double(MLXTuningLimits.minimumContextWindowTokens)...Double(sliderMaximum),
                    step: Double(MLXTuningLimits.contextWindowStep)
                ) {
                    Text("Context Window")
                }
                .accessibilityValue("\(Int(contextTokens.wrappedValue)) tokens")
            } footer: {
                if let selectedModel {
                    Text("How much conversation a local MLX model can use. On this device, \(selectedModel.displayName) supports up to \(deviceMaximum) tokens.")
                } else {
                    Text("How much conversation a local MLX model can use. This device supports up to \(deviceMaximum) tokens.")
                }
            }

            Section {
                Toggle("Unlimited Output", isOn: Binding(
                    get: { settings.mlxMaxOutputTokens == 0 },
                    set: { settings.mlxMaxOutputTokens = $0 ? 0 : MLXTuningLimits.defaultCappedOutputTokens }
                ))
                .accessibilityIdentifier("settings.unlimitedOutput")
                if settings.mlxMaxOutputTokens != 0 {
                    LabeledContent("Maximum Output", value: String(localized: "\(settings.mlxMaxOutputTokens) tokens", bundle: .appLocalized, locale: locale))
                    Slider(value: outputTokens, in: outputTokenSliderRange, step: Double(MLXTuningLimits.outputTokenStep)) {
                        Text("Maximum Output")
                    }
                    .accessibilityValue("\(settings.mlxMaxOutputTokens) tokens")
                }
            } footer: {
                Text("Shorter responses usually use less memory and finish sooner. Unlimited removes the output cap.")
            }

            Section {
                Toggle("Reduce Repetition", isOn: Binding(
                    get: { settings.mlxRepetitionPenalty > MLXTuningLimits.noRepetitionPenalty },
                    set: {
                        settings.mlxRepetitionPenalty = $0
                            ? MLXTuningLimits.defaultRepetitionPenalty
                            : MLXTuningLimits.noRepetitionPenalty
                    }
                ))
                .accessibilityIdentifier("settings.reduceRepetition")
                if settings.mlxRepetitionPenalty > MLXTuningLimits.noRepetitionPenalty {
                    LabeledContent("Penalty", value: settings.mlxRepetitionPenalty.formatted(.number.precision(.fractionLength(2))))
                    Slider(
                        value: $settings.mlxRepetitionPenalty,
                        in: MLXTuningLimits.repetitionPenaltyRange,
                        step: MLXTuningLimits.repetitionPenaltyStep
                    ) {
                        Text("Repetition Penalty")
                    }
                }
            } footer: {
                Text("Discourage repeated words and phrases. Increase gradually if a model loops or echoes itself.")
            }

            Section {
                Toggle("RotorQuant", isOn: $settings.mlxEnableRotorQuant)
                    .accessibilityHint(RotorQuantCopy.accessibilityHint)
                    .accessibilityIdentifier("settings.rotorQuant")
                NavigationLink("About RotorQuant") {
                    Form {
                        Section {
                            Text(RotorQuantCopy.experimentalMessage)
                        } header: {
                            Text(RotorQuantCopy.experimentalTitle)
                        }
                        Section("How It Works") {
                            Text(RotorQuantCopy.infoMessage)
                        }
                    }
                    .navigationTitle("RotorQuant")
                    .navigationBarTitleDisplayMode(.inline)
                }
            } header: {
                Text("Experimental")
            } footer: {
                Text("Compresses the MLX conversation cache to reduce memory use. This is an early beta; speed and stability may vary.")
            }
        }
        .navigationTitle("On-Device Models")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DeveloperSettingsView: View {
    @Environment(\.locale) private var locale
    @Binding var settings: AppSettingsDraft
    @State private var showingMemoryWarning = false

    var body: some View {
        Form {
            Section {
                Toggle("Show Output Stats", isOn: $settings.developerModeEnabled)
                    .accessibilityIdentifier("settings.outputStats")
            } footer: {
                Text("Add an action beneath assistant messages to view raw output and generation diagnostics.")
            }
            Section {
                Toggle("Disable RAM Precautions", isOn: Binding(
                    get: { settings.disableRAMPrecautions },
                    set: { enabled in
                        if enabled { showingMemoryWarning = true }
                        else { settings.disableRAMPrecautions = false }
                    }
                ))
                .accessibilityIdentifier("settings.disableRAMPrecautions")
            } footer: {
                Text("Allow models and tool calls that exceed this device’s memory limits. This can cause crashes or severe slowdowns.")
            }
            Section {
                Toggle("Raise Context Window Limit", isOn: $settings.overrideContextWindowLimit)
                    .accessibilityIdentifier("settings.overrideContextWindowLimit")
            } footer: {
                Text("Let the On-Device Models context window go up to \(UserDefaults.mlxDeveloperContextWindowMaximum.formatted(.number.locale(locale))) tokens, past this device’s limit. Large contexts can run out of memory and crash the app.")
            }
            Section {
                Toggle("Keep Full KV Cache", isOn: $settings.forcePersistentKVCache)
                    .accessibilityIdentifier("settings.forcePersistentKVCache")
            } footer: {
                Text("On devices with less than 12 GB of RAM, keep the whole conversation in the model cache instead of a sliding window. RotorQuant applies when it’s on. Long chats can run out of memory.")
            }
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Disable RAM Precautions?", isPresented: $showingMemoryWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Disable", role: .destructive) { settings.disableRAMPrecautions = true }
        } message: {
            Text("Models that need more memory than your device has can crash the app or make it extremely slow. Only disable these safeguards if you understand the risks.")
        }
    }
}
