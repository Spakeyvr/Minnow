//
//  MarkdownBlocksView.swift
//  ChatLLM
//
//  Native SwiftUI rendering for parsed Markdown blocks.
//
//  This is the path almost every assistant message takes. It lays out with the
//  rest of the chat, so there is no height round-trip, no reload when the
//  transcript recycles a bubble off screen, and no per-token IPC while a model
//  is streaming. Only math falls back to the bundled KaTeX WebView.
//

import SwiftUI

struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    let fontSize: Double
    var tone: RichMarkdownView.TextTone = .primary

    /// Plain prose hugs its text, the way a short chat bubble always has.
    /// Structured content — headings, lists, quotes, code, tables, rules — fills
    /// the bubble instead, matching how those blocks used to lay out.
    private var wantsFullWidth: Bool {
        blocks.contains { block in
            if case .paragraph = block { return false }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { offset, block in
                MarkdownBlockView(block: block, fontSize: fontSize, tone: tone, depth: 0)
                    .padding(.top, offset == 0 ? 0 : topSpacing(before: block))
            }
        }
        .frame(maxWidth: wantsFullWidth ? .infinity : nil, alignment: .leading)
    }

    private func topSpacing(before block: MarkdownBlock) -> CGFloat {
        switch block {
        case .heading:
            return fontSize * 1.05
        case .thematicBreak:
            return fontSize * 0.9
        default:
            return fontSize * 0.75
        }
    }
}

// MARK: - Single block

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let fontSize: Double
    let tone: RichMarkdownView.TextTone
    let depth: Int

    var body: some View {
        switch block {
        case let .heading(level, text):
            MarkdownInlineText(markdown: text, fontSize: fontSize * MarkdownTypography.headingScale(level), tone: tone)
                .fontWeight(.bold)
                .fixedSize(horizontal: false, vertical: true)

        case let .paragraph(text):
            MarkdownInlineText(markdown: text, fontSize: fontSize, tone: tone)
                .fixedSize(horizontal: false, vertical: true)

        case let .codeBlock(language, code):
            MarkdownCodeBlockView(language: language, code: code, fontSize: fontSize)

        case let .blockQuote(inner):
            MarkdownBlockQuoteView(blocks: inner, fontSize: fontSize, tone: tone, depth: depth)

        case let .list(list):
            MarkdownListView(list: list, fontSize: fontSize, tone: tone, depth: depth)

        case let .table(table):
            MarkdownTableView(table: table, fontSize: fontSize, tone: tone)

        case .thematicBreak:
            Rectangle()
                .fill(MarkdownPalette.separator)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Code

private struct MarkdownCodeBlockView: View {
    let language: String?
    let code: String
    let fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: fontSize * 0.9, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, fontSize * 0.9)
                    .padding(.bottom, fontSize * 0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(MarkdownPalette.codeBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(MarkdownPalette.codeBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Long-pressing a reply opens the message menu, so this is the only way to
    /// copy just the code rather than the whole reply.
    private var header: some View {
        HStack(spacing: 8) {
            if let language, !language.isEmpty {
                Text(verbatim: language)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            CopyFeedbackButton(text: code, accessibilityLabel: { $0 ? "Copied" : "Copy Code" }) { isShowingFeedback in
                Label(isShowingFeedback ? "Copied" : "Copy", systemImage: isShowingFeedback ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("markdown.copyCode")
        }
        .font(.system(size: fontSize * 0.75, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.leading, fontSize * 0.9)
        .padding(.trailing, fontSize * 0.4)
    }
}

// MARK: - Copy button

/// Copies `text` and briefly shows a checkmark. Shared by code blocks and the
/// message actions bar so both give the same feedback.
struct CopyFeedbackButton<Content: View>: View {
    let text: String
    let accessibilityLabel: (Bool) -> LocalizedStringKey
    @ViewBuilder let label: (Bool) -> Content
    @State private var copyFeedback: Task<Void, Never>?

    var body: some View {
        let isShowingFeedback = copyFeedback != nil
        Button(action: copy) {
            label(isShowingFeedback)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(isShowingFeedback))
    }

    private func copy() {
        UIPasteboard.general.string = text
        AppHaptics.impact(.light)
        copyFeedback?.cancel()
        copyFeedback = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copyFeedback = nil
        }
    }
}

// MARK: - Block quote

private struct MarkdownBlockQuoteView: View {
    let blocks: [MarkdownBlock]
    let fontSize: Double
    let tone: RichMarkdownView.TextTone
    let depth: Int

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(MarkdownPalette.quoteBorder)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { offset, block in
                    MarkdownBlockView(block: block, fontSize: fontSize, tone: tone, depth: depth + 1)
                        .padding(.top, offset == 0 ? 0 : fontSize * 0.7)
                }
            }
            .padding(.horizontal, fontSize * 0.9)
            .padding(.vertical, fontSize * 0.75)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 10,
                topTrailingRadius: 10,
                style: .continuous
            )
            .fill(MarkdownPalette.quoteBackground)
        }
    }
}

// MARK: - Lists

private struct MarkdownListView: View {
    let list: MarkdownList
    let fontSize: Double
    let tone: RichMarkdownView.TextTone
    let depth: Int

    private var itemSpacing: CGFloat { list.isLoose ? fontSize * 0.7 : fontSize * 0.3 }

    var body: some View {
        VStack(alignment: .leading, spacing: itemSpacing) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { offset, item in
                HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.4) {
                    Text(marker(at: offset))
                        .font(.system(size: fontSize))
                        .foregroundStyle(tone == .secondary ? .secondary : .primary)
                        .monospacedDigit()
                        .frame(minWidth: markerWidth, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(item.blocks.enumerated()), id: \.offset) { innerOffset, block in
                            MarkdownBlockView(block: block, fontSize: fontSize, tone: tone, depth: depth + 1)
                                .padding(.top, innerOffset == 0 ? 0 : fontSize * 0.5)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.leading, depth == 0 ? 0 : fontSize * 0.5)
    }

    private var markerWidth: CGFloat {
        list.isOrdered ? fontSize * 1.35 : fontSize * 0.55
    }

    private func marker(at offset: Int) -> String {
        guard list.isOrdered else {
            switch depth % 3 {
            case 0: return "•"
            case 1: return "◦"
            default: return "▪"
            }
        }
        return "\(list.start + offset)."
    }
}

// MARK: - Tables

private struct MarkdownTableView: View {
    let table: MarkdownTable
    let fontSize: Double
    let tone: RichMarkdownView.TextTone

    private var cellFontSize: Double { fontSize * 0.96 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.headers.enumerated()), id: \.offset) { offset, header in
                        cell(header, column: offset, isHeader: true)
                    }
                }
                .background(MarkdownPalette.codeBackground)

                ForEach(Array(table.rows.enumerated()), id: \.offset) { rowOffset, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { offset, value in
                            cell(value, column: offset, isHeader: false)
                        }
                    }
                    .background(rowOffset.isMultiple(of: 2) ? Color.clear : MarkdownPalette.tableStripe)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(MarkdownPalette.separator, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(1)
        }
    }

    @ViewBuilder
    private func cell(_ value: String, column: Int, isHeader: Bool) -> some View {
        let alignment = table.alignments.indices.contains(column) ? table.alignments[column] : .leading
        MarkdownInlineText(markdown: value, fontSize: cellFontSize, tone: tone)
            .fontWeight(isHeader ? .semibold : .regular)
            .multilineTextAlignment(textAlignment(alignment))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, cellFontSize * 0.7)
            .padding(.vertical, cellFontSize * 0.55)
            // Fill the column, so backgrounds and borders line up with the widest cell.
            .frame(minWidth: cellFontSize * 3, maxWidth: .infinity, alignment: frameAlignment(alignment))
            .overlay(alignment: .trailing) {
                Rectangle().fill(MarkdownPalette.separator).frame(width: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(MarkdownPalette.separator).frame(height: 1)
            }
    }

    private func textAlignment(_ alignment: MarkdownTable.ColumnAlignment) -> TextAlignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func frameAlignment(_ alignment: MarkdownTable.ColumnAlignment) -> Alignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

// MARK: - Inline text

/// Renders one block's inline Markdown. Images are reduced to their alt text and
/// non-web links are stripped before the string ever reaches SwiftUI, so model
/// output can never trigger a network load or open a custom scheme.
struct MarkdownInlineText: View {
    let markdown: String
    let fontSize: Double
    var tone: RichMarkdownView.TextTone = .primary
    @Environment(\.isMarkdownStreaming) private var isStreaming

    var body: some View {
        Text(MarkdownInlineRenderer.attributed(markdown, fontSize: fontSize, caching: !isStreaming))
            .font(.system(size: fontSize))
            .foregroundStyle(tone == .secondary ? .secondary : .primary)
    }
}

enum MarkdownInlineRenderer {

    private nonisolated struct CacheKey: Hashable, Sendable {
        let markdown: String
        let fontSize: Double
    }

    /// Whole-tree invalidations (appearance, Dynamic Type, the message size
    /// setting, a math bubble swapping in its fallback) re-run every inline
    /// body, so finished blocks keep their attributed strings here.
    private static let cache = BoundedCache<CacheKey, AttributedString>(limit: 256)

    /// Like `attributed(_:fontSize:)`, memoised unless `caching` is false. A
    /// streaming block is a new key on every token, so it is never stored.
    static func attributed(_ markdown: String, fontSize: Double, caching: Bool) -> AttributedString {
        guard caching else { return attributed(markdown, fontSize: fontSize) }
        return cache.value(for: CacheKey(markdown: markdown, fontSize: fontSize)) {
            attributed(markdown, fontSize: fontSize)
        }
    }

    static func attributed(_ markdown: String, fontSize: Double) -> AttributedString {
        let source = sanitizedSource(markdown)
        guard !source.isEmpty else { return AttributedString() }
        guard var parsed = NativeMarkdownParser.attributedString(from: source) else {
            return AttributedString(source)
        }
        stripUnsafeLinks(&parsed)
        styleInlineCode(&parsed, fontSize: fontSize)
        return parsed
    }

    /// Removes image syntax and link reference definitions, which the inline-only
    /// parser would otherwise surface as literal text.
    static func sanitizedSource(_ markdown: String) -> String {
        var text = markdown
        if text.contains("![") {
            text = SharedRegexes.markdownInlineImage.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: "$1"
            )
            text = SharedRegexes.markdownReferenceImage.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: "$1"
            )
        }
        guard text.contains("]:") else { return text }
        let kept = text.components(separatedBy: "\n").filter { line in
            SharedRegexes.markdownLinkReferenceDefinition.firstMatch(
                in: line,
                range: NSRange(line.startIndex..., in: line)
            ) == nil
        }
        return kept.joined(separator: "\n")
    }

    private static func stripUnsafeLinks(_ text: inout AttributedString) {
        for run in text.runs where run.link != nil {
            let scheme = run.link?.scheme?.lowercased()
            if scheme != "http" && scheme != "https" {
                text[run.range].link = nil
            }
        }
    }

    private static func styleInlineCode(_ text: inout AttributedString, fontSize: Double) {
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            text[run.range].font = .system(size: fontSize * 0.92, design: .monospaced)
            text[run.range].foregroundColor = MarkdownColorToken.inlineCode.color
        }
    }
}

// MARK: - Design tokens

/// Heading sizes, shared by the native renderer and the math document's CSS.
nonisolated enum MarkdownTypography {
    /// Font-size multipliers for heading levels 1 through 4; deeper levels use body size.
    static let headingScales: [Double] = [1.65, 1.45, 1.25, 1.12]

    static func headingScale(_ level: Int) -> Double {
        headingScales.indices.contains(level - 1) ? headingScales[level - 1] : 1.0
    }

    /// The same scale as CSS rules for the math document.
    static var headingCSS: String {
        let sized = headingScales.enumerated().map { "h\($0.offset + 1) { font-size: \($0.element)em; }" }
        return (sized + ["h5, h6 { font-size: 1em; }"]).joined(separator: "\n")
    }
}

/// The Markdown colours, shared by the native `MarkdownPalette` and the math
/// document's `RichTextPalette`, so a change applies to both renderers.
enum MarkdownColorToken {
    case codeBackground
    case codeBorder
    case quoteBorder
    case quoteBackground
    case separator
    case tableStripe
    case inlineCode

    private var base: UIColor {
        switch self {
        case .codeBackground, .tableStripe: .secondarySystemBackground
        case .codeBorder, .separator: .separator
        case .quoteBorder: .systemBlue
        case .quoteBackground: .tertiarySystemBackground
        case .inlineCode: .secondaryLabel
        }
    }

    /// Multiplies the base colour's own alpha, like SwiftUI's `opacity`.
    private var opacity: CGFloat {
        switch self {
        case .codeBackground, .inlineCode: 1
        case .codeBorder, .tableStripe: 0.45
        case .quoteBorder: 0.5
        case .quoteBackground: 0.7
        case .separator: 0.35
        }
    }

    var color: Color {
        Color(uiColor: base).opacity(opacity)
    }

    func resolvedColor(with traits: UITraitCollection) -> UIColor {
        let resolved = base.resolvedColor(with: traits)
        guard opacity < 1 else { return resolved }
        var alpha: CGFloat = 0
        resolved.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        return resolved.withAlphaComponent(alpha * opacity)
    }
}

enum MarkdownPalette {
    static let codeBackground = MarkdownColorToken.codeBackground.color
    static let codeBorder = MarkdownColorToken.codeBorder.color
    static let quoteBorder = MarkdownColorToken.quoteBorder.color
    static let quoteBackground = MarkdownColorToken.quoteBackground.color
    static let separator = MarkdownColorToken.separator.color
    static let tableStripe = MarkdownColorToken.tableStripe.color
}
