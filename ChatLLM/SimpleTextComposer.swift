//
//  SimpleTextComposer.swift
//  ChatLLM
//
//  Created by Nevio on 10/26/25.
//

import SwiftUI
import UIKit

enum ComposerReturnKeyBehaviorAction: Equatable {
    case send
    case insertNewline
}

enum ComposerReturnKeyBehavior {
    static func action(
        sendOnReturn: Bool,
        canSend: Bool,
        isGenerating: Bool,
        replacementText: String
    ) -> ComposerReturnKeyBehaviorAction {
        guard replacementText == "\n" else {
            return .insertNewline
        }

        guard sendOnReturn, canSend, !isGenerating else {
            return .insertNewline
        }

        return .send
    }
}

struct SimpleTextComposer: View {
    @Binding var text: String
    var placeholder: String
    var focusRequest: Int
    var isEditing: Bool
    var onSend: () -> Void
    var onStop: () -> Void
    var onCancelEditing: () -> Void
    var canSend: Bool
    var isGenerating: Bool
    var onCamera: (() -> Void)?
    var onPhotosPicker: (() -> Void)?
    var onFileImporter: (() -> Void)?
    var imageInputAvailable: Bool = true
    @Binding var forceSearch: Bool
    var searchAvailable: Bool = true
    var searchUnavailableReason: String?
    @Binding var disableToolCalls: Bool
    var toolCallsLockedDisabled: Bool = false
    @Binding var isReasoningEnabled: Bool
    @Binding var isSmartReasoningEnabled: Bool
    var reasoningAvailable: Bool = false
    var reasoningRequired: Bool = false

    @AppStorage(AppSettingsKeys.sendOnReturn) private var sendOnReturn = false

    @State private var isTextViewFocused = false
    @State private var showAddSheet = false

    private let circleSize: CGFloat = 44
    private let pillMinHeight: CGFloat = 44
    /// Half the minimum height, so a one-line composer is a capsule; taller
    /// composers keep the same radius.
    private let pillCornerRadius: CGFloat = 22
    private let pillHorizontalPadding: CGFloat = 10
    private let maxTextViewHeight: CGFloat = 112

    var body: some View {
        GlassEffectContainer(spacing: 10.0) {
            VStack(spacing: 0) {
                // Text field area
                ZStack(alignment: .topLeading) {
                    // Sizes itself from the proposed width (see `sizeThatFits`).
                    ComposerTextView(
                        text: $text,
                        isFocused: $isTextViewFocused,
                        sendOnReturn: sendOnReturn,
                        canSend: canSend,
                        isGenerating: isGenerating,
                        maxHeight: maxTextViewHeight,
                        onSend: onSend
                    )

                    // Same font as the text view, so typing doesn't shrink the text. Hide it
                    // as soon as anything is typed, or it would overlap a leading newline.
                    if text.isEmpty {
                        Text(placeholder)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, pillHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // Bottom row: + button on left, send button on right
                HStack {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(forceSearch && searchAvailable ? Color.blue : Color.primary)
                            .frame(width: circleSize, height: circleSize)
                            .contentShape(Circle())
                    }
                    .buttonStyle(SubtleGlassButtonStyle())
                    .accessibilityLabel("Add attachment or web search")
                    .sheet(isPresented: $showAddSheet) {
                        AddOptionsSheet(
                            onCamera: { showAddSheet = false; onCamera?() },
                            onPhotoLibrary: { showAddSheet = false; onPhotosPicker?() },
                            onFile: { showAddSheet = false; onFileImporter?() },
                            imageInputAvailable: imageInputAvailable,
                            forceSearch: $forceSearch,
                            searchAvailable: searchAvailable,
                            searchUnavailableReason: searchUnavailableReason,
                            disableToolCalls: $disableToolCalls,
                            toolCallsLockedDisabled: toolCallsLockedDisabled,
                            isReasoningEnabled: $isReasoningEnabled,
                            isSmartReasoningEnabled: $isSmartReasoningEnabled,
                            reasoningAvailable: reasoningAvailable,
                            reasoningRequired: reasoningRequired
                        )
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                    }

                    if isEditing {
                        Button("Cancel edit", action: onCancelEditing)
                            .font(.subheadline.weight(.semibold))
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(.red)
                            .accessibilityIdentifier("chat.edit.cancel")
                    }

                    Spacer()

                    Button {
                        AppHaptics.impact(.light)

                        if isGenerating {
                            onStop()
                        } else if canSend {
                            onSend()
                        }
                    } label: {
                        Group {
                            if isGenerating {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.red)
                            } else {
                                // An explicit style overrides the disabled dimming.
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(canSend ? .primary : .tertiary)
                            }
                        }
                        .frame(width: circleSize, height: circleSize)
                        .contentShape(Circle())
                    }
                    .disabled(!isGenerating && !canSend)
                    .buttonStyle(SubtleGlassButtonStyle())
                    .accessibilityLabel(isGenerating ? String(localized: "Stop", bundle: .appLocalized) : String(localized: "Send", bundle: .appLocalized))
                    .accessibilityAddTraits(.isButton)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(maxWidth: .infinity, minHeight: pillMinHeight)
            .glassEffect(
                .regular.interactive(),
                in: .rect(cornerRadius: pillCornerRadius)
            )
            .clipShape(RoundedRectangle(cornerRadius: pillCornerRadius, style: .continuous))
        }
        .onChange(of: focusRequest) {
            isTextViewFocused = true
        }
    }
}

private struct SubtleGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .glassEffect(
                configuration.isPressed ? .regular : .identity,
                in: .circle
            )
    }
}

private struct AddOptionsSheet: View {
    var onCamera: () -> Void
    var onPhotoLibrary: () -> Void
    var onFile: () -> Void
    var imageInputAvailable: Bool
    @Binding var forceSearch: Bool
    var searchAvailable: Bool
    var searchUnavailableReason: String?
    @Binding var disableToolCalls: Bool
    var toolCallsLockedDisabled: Bool
    @Binding var isReasoningEnabled: Bool
    @Binding var isSmartReasoningEnabled: Bool
    var reasoningAvailable: Bool
    var reasoningRequired: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss

    private var reasoningUnavailableReason: LocalizedStringKey? {
        if reasoningRequired { return "This model always reasons before answering." }
        if !reasoningAvailable { return "Reasoning needs a downloaded model that supports it." }
        return nil
    }

    var body: some View {
        // Three tiles side by side truncate their labels at accessibility sizes.
        let tileLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        NavigationStack {
            // Scrolls once large text sizes outgrow the medium detent.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Every attach option imports an image, so all of them depend
                    // on the model reading images itself. Unavailable options stay
                    // visible but grayed out, so the row keeps the same layout.
                    tileLayout {
                        AttachTile(icon: "camera", label: "Camera", action: onCamera)
                            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                        AttachTile(icon: "photo.on.rectangle", label: "Photos", action: onPhotoLibrary)
                        AttachTile(icon: "doc.badge.arrow.up", label: "Files", action: onFile)
                    }
                    .disabled(!imageInputAvailable)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, imageInputAvailable ? 24 : 8)

                    if !imageInputAvailable {
                        Text("This model can't read images.")
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 16)
                    }

                    Divider()
                        .padding(.horizontal, 20)

                    VStack(spacing: 0) {
                        Toggle(isOn: $disableToolCalls) {
                            Label {
                                Text("Disable Tool Calls")
                                    .font(.body)
                            } icon: {
                                Image(systemName: "wrench.and.screwdriver")
                                    .font(.body)
                                    .frame(width: 28)
                            }
                        }
                        .tint(.orange)
                        .disabled(toolCallsLockedDisabled)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .onChange(of: disableToolCalls) { _, isDisabled in
                            if isDisabled {
                                forceSearch = false
                            }
                        }

                        Toggle(isOn: $forceSearch) {
                            Label {
                                Text("Web Search")
                                    .font(.body)
                            } icon: {
                                Image(systemName: "globe")
                                    .font(.body)
                                    .frame(width: 28)
                            }
                        }
                        .disabled(!searchAvailable || disableToolCalls)
                        .tint(.blue)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)

                        if let searchUnavailableReason {
                            Text(searchUnavailableReason)
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 8)
                                .accessibilityIdentifier("composer.webSearchUnavailableReason")
                        }

                        Divider()
                            .padding(.horizontal, 20)

                        // Off while unavailable, since the reply won't reason; the stored
                        // choice returns once a model that can reason is selected.
                        Toggle(isOn: Binding(
                            get: { reasoningRequired || (reasoningAvailable && isReasoningEnabled) },
                            set: { newValue in
                                if newValue { isSmartReasoningEnabled = false }
                                isReasoningEnabled = newValue
                            }
                        )) {
                            Label {
                                Text("Always Reason")
                                    .font(.body)
                            } icon: {
                                Image(systemName: "brain.head.profile")
                                    .font(.body)
                                    .frame(width: 28)
                                    .foregroundStyle(.blue)
                            }
                        }
                        .disabled(reasoningRequired || !reasoningAvailable || isSmartReasoningEnabled)
                        .tint(.blue)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)

                        Toggle(isOn: Binding(
                            get: { !reasoningRequired && reasoningAvailable && isSmartReasoningEnabled },
                            set: { newValue in
                                if newValue { isReasoningEnabled = false }
                                isSmartReasoningEnabled = newValue
                            }
                        )) {
                            Label {
                                Text("Smart Reasoning")
                                    .font(.body)
                            } icon: {
                                Image(systemName: "sparkles")
                                    .font(.body)
                                    .frame(width: 28)
                                    .foregroundStyle(.purple)
                            }
                        }
                        .disabled(reasoningRequired || !reasoningAvailable || isReasoningEnabled)
                        .tint(.purple)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)

                        // Like Web Search, say why the switches above can't be changed.
                        if let reasoningUnavailableReason {
                            Text(reasoningUnavailableReason)
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 8)
                                .accessibilityIdentifier("composer.reasoningUnavailableReason")
                        }

                        Divider()
                            .padding(.horizontal, 20)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("Add to Chat")
            .navigationBarTitleDisplayMode(.inline)
            // The switches apply right away; this only closes the sheet.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("sheet.close")
                }
            }
        }
    }
}

private struct AttachTile: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let icon: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        let isAccessibilitySize = dynamicTypeSize.isAccessibilitySize
        let contentLayout = isAccessibilitySize
            ? AnyLayout(HStackLayout(spacing: 16))
            : AnyLayout(VStackLayout(spacing: 10))
        Button(action: action) {
            contentLayout {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .regular))
                Text(label)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity, alignment: isAccessibilitySize ? .leading : .center)
            .padding(.horizontal, isAccessibilitySize ? 20 : 0)
            .frame(minHeight: isAccessibilitySize ? 72 : 100)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? .primary : .tertiary)
    }
}

struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    let sendOnReturn: Bool
    let canSend: Bool
    let isGenerating: Bool
    let maxHeight: CGFloat
    let onSend: () -> Void

    private var returnKeyType: UIReturnKeyType { sendOnReturn ? .send : .default }

    /// The smallest height, one line of body text.
    static let minimumHeight: CGFloat = 24

    /// The height for `text` laid out at `width`, capped at `maxHeight`, and
    /// whether the text overflows that cap and must scroll.
    static func fittingHeight(of textView: UITextView, width: CGFloat, maxHeight: CGFloat) -> (height: CGFloat, scrolls: Bool) {
        let fitting = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = max(minimumHeight, ceil(fitting.height))
        return (min(height, maxHeight), height > maxHeight)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = KeyboardSendingTextView()
        let coordinator = context.coordinator
        textView.onCommandReturn = { [weak coordinator] in coordinator?.sendFromKeyboard() }
        textView.backgroundColor = .clear
        textView.delegate = context.coordinator
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.tintColor = .systemBlue
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.autocapitalizationType = .sentences
        textView.autocorrectionType = .default
        textView.keyboardDismissMode = .interactive
        textView.returnKeyType = returnKeyType
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.text = text
        textView.onShiftReturn = { [weak coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.insertLineBreak(in: textView)
        }
        return textView
    }

    /// Measured against the width SwiftUI proposes, so the first layout of a
    /// restored draft, a rotation, or a split-view resize all get the right
    /// height in the same pass, without a zero-width measurement or a deferred
    /// state write.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let fit = Self.fittingHeight(of: uiView, width: width, maxHeight: maxHeight)
        if uiView.isScrollEnabled != fit.scrolls {
            uiView.isScrollEnabled = fit.scrolls
        }
        return CGSize(width: width, height: fit.height)
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self

        if uiView.text != text {
            uiView.text = text
        }

        // The key's label should say what pressing it does.
        if uiView.returnKeyType != returnKeyType {
            uiView.returnKeyType = returnKeyType
            if uiView.isFirstResponder { uiView.reloadInputViews() }
        }

        if isFocused, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFocused, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        /// Set while Shift-Return inserts a line break, which must never send.
        private var isInsertingLineBreak = false

        init(parent: ComposerTextView) {
            self.parent = parent
        }

        // updateUIView changes the first responder to match isFocused, and UIKit
        // reports that back synchronously; writing the same value again would
        // modify state during the view update.
        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }

        func textViewDidChange(_ textView: UITextView) {
            // The new text re-renders the composer, and SwiftUI re-measures it
            // through `sizeThatFits`.
            parent.text = textView.text
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            guard !isInsertingLineBreak else { return true }
            switch ComposerReturnKeyBehavior.action(
                sendOnReturn: parent.sendOnReturn,
                canSend: parent.canSend,
                isGenerating: parent.isGenerating,
                replacementText: text
            ) {
            case .send:
                parent.onSend()
                return false
            case .insertNewline:
                return true
            }
        }

        /// Command-Return sends whatever Return is set to do, and never stops a reply.
        func sendFromKeyboard() {
            guard parent.canSend, !parent.isGenerating else { return }
            parent.onSend()
        }

        /// Shift-Return always starts a new line, so a hardware keyboard can
        /// still write one when Return is set to send.
        func insertLineBreak(in textView: UITextView) {
            isInsertingLineBreak = true
            defer { isInsertingLineBreak = false }
            textView.insertText("\n")
        }
    }
}

/// Sends on Command-Return from a hardware keyboard. The key command asks for priority
/// over the text view's own Return handling, which would otherwise insert a line break
/// before a menu shortcut or a button's shortcut could see the key. Shift-Return
/// likewise always inserts a line break, even when Return sends.
final class KeyboardSendingTextView: UITextView {
    var onCommandReturn: (() -> Void)?
    var onShiftReturn: (() -> Void)?

    /// Built once; UIKit asks for key commands often while validating the responder chain.
    private lazy var composerKeyCommands: [UIKeyCommand] = {
        let send = UIKeyCommand(
            title: String(localized: "Send Message", bundle: .appLocalized),
            action: #selector(sendFromKeyboard),
            input: "\r",
            modifierFlags: .command
        )
        send.wantsPriorityOverSystemBehavior = true
        let lineBreak = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(insertLineBreakFromKeyboard))
        lineBreak.wantsPriorityOverSystemBehavior = true
        return [send, lineBreak]
    }()

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + composerKeyCommands
    }

    @objc private func sendFromKeyboard() {
        onCommandReturn?()
    }

    @objc private func insertLineBreakFromKeyboard() {
        onShiftReturn?()
    }
}
