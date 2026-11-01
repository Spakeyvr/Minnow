//
//  SourcesSheetView.swift
//  ChatLLM
//

import SwiftUI

// MARK: - Compact Sources button

struct SourcesButton: View {
    @Binding var showSources: Bool
    let invocations: [SearchInvocation]

    @ScaledMetric(relativeTo: .subheadline) private var faviconSize: CGFloat = 20
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var previewSources: [WebSearchSource] {
        var seenDomains: Set<String> = []
        var sources: [WebSearchSource] = []

        for source in invocations.flatMap(\.displaySources) {
            guard seenDomains.insert(source.domainName).inserted else { continue }
            sources.append(source)
            if sources.count == 3 { break }
        }

        return sources
    }

    private var totalSourceCount: Int {
        invocations.reduce(0) { $0 + $1.sourceCount }
    }

    var body: some View {
        // Computed once: it flattens and de-duplicates every invocation's sources.
        let previews = previewSources
        Button {
            showSources = true
        } label: {
            HStack(spacing: 10) {
                // The favicons are decoration; at accessibility sizes the row needs
                // their room so the label doesn't break mid-word.
                if !previews.isEmpty, !dynamicTypeSize.isAccessibilitySize {
                    faviconStack(previews)
                        .offset(x: -6)
                        .padding(.trailing, 2)
                }

                Text("Sources")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(.primary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A 44-point target without making the actions row taller.
        .padding(.vertical, -12)
        .accessibilityLabel("Sources")
        .accessibilityValue("\(totalSourceCount) sources")
        .accessibilityHint("Shows the sources used for this response")
        .accessibilityIdentifier("message.sources")
    }

    private func faviconStack(_ previews: [WebSearchSource]) -> some View {
        let overlapOffset = faviconSize * 0.62

        return ZStack(alignment: .leading) {
            ForEach(Array(previews.enumerated()), id: \.element.id) { index, source in
                SourceButtonFavicon(source: source, size: faviconSize)
                    .offset(x: CGFloat(index) * overlapOffset)
                    .zIndex(Double(index))
            }
        }
        .frame(
            width: faviconSize + CGFloat(max(0, previews.count - 1)) * overlapOffset,
            height: faviconSize
        )
        .accessibilityHidden(true)
    }
}

private struct SourceButtonFavicon: View {
    let source: WebSearchSource
    let size: CGFloat

    var body: some View {
        FaviconImage(source: source, size: size, initialScale: 0.46)
            .background(.background, in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
            }
            .compositingGroup()
            .clipShape(Circle())
    }
}

/// A source's favicon, or its domain's initial while it loads or when it has none.
/// The callers add their own shape and border.
private struct FaviconImage: View {
    let source: WebSearchSource
    let size: CGFloat
    /// The initial's size relative to `size`.
    let initialScale: CGFloat

    var body: some View {
        Group {
            if let faviconURL = source.faviconURL.flatMap(URL.init(string:)) {
                AsyncImage(url: faviconURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    initial
                }
            } else {
                initial
            }
        }
        .frame(width: size, height: size)
    }

    private var initial: some View {
        Text(String(source.domainName.prefix(1)).uppercased())
            .font(.system(size: size * initialScale, weight: .bold))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Structured web sources

struct SourcesSheetView: View {
    let invocations: [SearchInvocation]
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var selectedInvocationID: UUID?
    @State private var activeURL: URL?
    @State private var selectedDetent: PresentationDetent = .large

    private var availableInvocations: [SearchInvocation] {
        invocations.filter { !$0.displaySources.isEmpty }
    }

    private var selectedInvocation: SearchInvocation? {
        availableInvocations.first(where: { $0.id == selectedInvocationID }) ?? availableInvocations.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if availableInvocations.count > 1 {
                        queryPicker
                    }

                    if let selectedInvocation {
                        queryCard(selectedInvocation)
                        SourceListView(sources: selectedInvocation.displaySources) { source in
                            activeURL = source.resolvedURL
                        }
                    } else {
                        ContentUnavailableView(
                            "No Sources",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("This search did not return a readable source.")
                        )
                    }
                }
                .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // Swiping down isn't available to every input method.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("sheet.close")
                }
            }
        }
        .foregroundStyle(.primary)
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .onAppear { selectDefaults() }
        .sheet(item: $activeURL) { url in
            SafariView(url: url)
                .ignoresSafeArea()
        }
    }

    private var queryPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(availableInvocations.enumerated()), id: \.element.id) { index, invocation in
                    Button {
                        selectedInvocationID = invocation.id
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "magnifyingglass")
                            Text(invocation.query)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 190, alignment: .leading)
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            selectedInvocationID == invocation.id
                                ? Color.accentColor.opacity(0.16)
                                : Color.secondary.opacity(0.08),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(invocation.query)
                    .accessibilityAddTraits(selectedInvocationID == invocation.id ? .isSelected : [])
                    .accessibilityIdentifier("sources.query.\(index)")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func queryCard(_ invocation: SearchInvocation) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Search query", systemImage: "text.magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(invocation.query)
                .font(.body.weight(.medium))
                .textSelection(.enabled)
            Text("\(invocation.sourceCount) sources")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium))
    }

    private func selectDefaults() {
        guard selectedInvocationID == nil else { return }
        selectedInvocationID = availableInvocations.first?.id
    }
}

private struct SourceListView: View {
    let sources: [WebSearchSource]
    let onOpen: (WebSearchSource) -> Void

    private var lastSourceID: UUID? { sources.last?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sources")
                .font(.headline)

            LazyVStack(spacing: 0) {
                ForEach(sources) { source in
                    VStack(spacing: 0) {
                        SourceListRow(source: source) {
                            onOpen(source)
                        }

                        if source.id != lastSourceID {
                            Divider()
                                .padding(.leading, 52)
                        }
                    }
                }
            }
            .background(
                Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.1))
            }
        }
    }
}

private struct SourceListRow: View {
    let source: WebSearchSource
    let onOpen: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Two lines hold only a word or two at accessibility sizes.
        let isAccessibilitySize = dynamicTypeSize.isAccessibilitySize
        Button(action: onOpen) {
            HStack(spacing: 12) {
                SourceIcon(source: source, size: 30)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(source.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(isAccessibilitySize ? 6 : 2)
                        .multilineTextAlignment(.leading)

                    Text(source.domainName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(isAccessibilitySize ? 3 : 1)
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(source.resolvedURL == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(source.title), \(source.domainName)")
        .accessibilityHint("Opens the website")
    }
}

private struct SourceIcon: View {
    let source: WebSearchSource
    let size: CGFloat

    var body: some View {
        FaviconImage(source: source, size: size, initialScale: 0.48)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: size * 0.25))
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: size * 0.25))
    }
}
