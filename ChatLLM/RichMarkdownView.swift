//
//  RichMarkdownView.swift
//  ChatLLM
//

import OSLog
import SwiftUI
import WebKit

nonisolated private let mathDocumentLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ChatLLM",
    category: "MathDocument"
)

/// Renders assistant Markdown.
///
/// There are two rendering paths, and the split is math-based:
///
/// - **Native** (`MarkdownBlocksView` + `MarkdownBlockParser`): headings, lists,
///   quotes, fenced code, tables, hr, and inline emphasis. Used for every
///   message that contains no math. No WebView, no height round-trip, no reload
///   when the transcript recycles a bubble off screen.
/// - **Bundled WebView document** (`RichMarkdownWebViewRepresentable`): the only
///   remaining user of `RenderingAssets/` (`markdown-it.min.js`, `katex.min.js`,
///   `katex.min.css`). It renders the *whole* message with markdown-it, whose math
///   rules hand each formula to KaTeX. Chosen only when
///   `RichTextFeatureDetector.requiresAdvancedRendering` finds math outside code
///   spans. The native path covers the gap while the document loads or measures,
///   and replaces it if the document cannot recover from a failure.
///
/// Math web views come from `MathDocumentWebViewPool`, so a bubble recycled by
/// the transcript's `LazyVStack` reuses an already loaded document instead of
/// parsing and compiling ~820 KB of KaTeX again. Inside the document, only the
/// top-level blocks that changed are re-rendered, and each formula is typeset
/// once per document, so streaming does not re-typeset the whole message.
///
/// Do not delete the `RenderingAssets/` files: the native path cannot render
/// KaTeX, and the WebView document inlines all three of them (see
/// `MathDocument.makeHTML()`). All parser assets and WOFF2 fonts are required; a
/// missing asset triggers the existing native fallback. Fonts are embedded as
/// data URIs under the local CSP. `$…$`, `$$…$$`, `\(…\)`, `\[…\]` and bare KaTeX
/// environments (align, cases, pmatrix, …) share one delimiter list for detection
/// and Markdown tokenizing. Display math that starts a line may span blank lines.
///
/// Known limitations:
/// - Images are disabled in both paths: the native renderer reduces
///   `![alt](url)` to its alt text, while markdown-it's `image` rule is disabled
///   so the raw markup shows. Keep `RichMarkdownRenderingPolicy
///   .disabledMarkdownRules` in sync with `MarkdownInlineRenderer
///   .sanitizedSource` if that policy ever changes.
/// - Bare URLs are not linked in either path; only `[text](url)` and `<url>` are.
///
/// If you add a rendered feature, decide explicitly whether it belongs in
/// `MarkdownBlockParser` (native) or in the WebView document's JS, and keep the
/// detector in sync so math stays the only trigger for the WebView.
struct RichMarkdownView: View {
    let text: String
    let fontSize: Double
    var textTone: TextTone = .primary
    /// A streaming message changes on every token, so its intermediate prefixes
    /// are kept out of the shared caches, where they would evict finished messages.
    var isStreaming: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    /// Body text size under the current Dynamic Type setting (17 at the default size).
    @ScaledMetric(relativeTo: .body) private var bodyPointSize: CGFloat = 17

    enum TextTone: Hashable {
        case primary
        case secondary
    }

    /// The message size setting applies at the default text size; Dynamic Type scales
    /// it from there, so larger accessibility sizes enlarge messages like the rest of the app.
    static func scaledFontSize(_ fontSize: Double, bodyPointSize: CGFloat) -> Double {
        fontSize * Double(bodyPointSize) / 17
    }

    var body: some View {
        let fontSize = Self.scaledFontSize(fontSize, bodyPointSize: bodyPointSize)
        let plan = MarkdownBlockCache.plan(for: text, isStreaming: isStreaming)
        Group {
            if plan.needsMath {
                RichMarkdownWebView(
                    text: text,
                    fallbackBlocks: plan.blocks,
                    fontSize: fontSize,
                    palette: RichTextPalette.resolved(colorScheme: colorScheme, tone: textTone),
                    fallbackTone: textTone,
                    isStreaming: isStreaming
                )
            } else {
                MarkdownBlocksView(blocks: plan.blocks, fontSize: fontSize, tone: textTone)
            }
        }
        .environment(\.isMarkdownStreaming, isStreaming)
    }
}

extension EnvironmentValues {
    /// Whether the Markdown being rendered is still streaming. Inline renders of
    /// a streaming message skip the shared memo, since each token is a new key.
    @Entry var isMarkdownStreaming: Bool = false
}

enum NativeMarkdownParser {
    static func attributedString(from markdown: String) -> AttributedString? {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return try? AttributedString(markdown: markdown, options: options)
    }
}

// MARK: - Caches

/// A small thread-safe memo that evicts its least recently used entry. All
/// mutable state is read and written under `lock`.
nonisolated final class BoundedCache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private struct Entry {
        var value: Value
        var lastUse: UInt64
    }

    private let limit: Int
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    var count: Int {
        lock.withLock { entries.count }
    }

    /// Returns the cached value and marks it as recently used.
    func value(for key: Key) -> Value? {
        lock.withLock {
            guard let index = entries.index(forKey: key) else { return nil }
            clock &+= 1
            entries.values[index].lastUse = clock
            return entries.values[index].value
        }
    }

    func store(_ value: Value, for key: Key) {
        lock.withLock {
            clock &+= 1
            entries[key] = Entry(value: value, lastUse: clock)
            guard entries.count > limit,
                  let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key else { return }
            entries.removeValue(forKey: oldest)
        }
    }

    /// Returns the cached value, or computes it outside the lock and stores it.
    func value(for key: Key, orInsert makeValue: () -> Value) -> Value {
        if let cached = value(for: key) { return cached }
        let value = makeValue()
        store(value, for: key)
        return value
    }

    func removeAll() {
        lock.withLock { entries.removeAll() }
    }
}

/// How one message renders: whether it needs the math document, and its
/// native block tree (the primary path, and the math document's fallback).
nonisolated struct MarkdownRenderPlan: Equatable, Sendable {
    let needsMath: Bool
    let blocks: [MarkdownBlock]
}

/// Bounded memo for routing decisions and parsed block trees.
///
/// A streaming message is re-parsed once per token, which is cheap and expected.
/// The memo exists so that redundant `body` calls — an appearance change, a
/// parent re-render, a bubble scrolling back into view — do not repeat the work.
/// Streamed prefixes go into a single slot of their own: each token is a new
/// key, and caching them would evict every finished message.
nonisolated enum MarkdownBlockCache {
    /// Finished messages kept before the least recently used one is evicted.
    static let limit = 48
    private static let cache = BoundedCache<String, MarkdownRenderPlan>(limit: limit)
    private static let streamingLock = NSLock()
    /// Only read and written under `streamingLock`.
    nonisolated(unsafe) private static var streamingSlot: (text: String, plan: MarkdownRenderPlan)?

    static func plan(for text: String, isStreaming: Bool = false) -> MarkdownRenderPlan {
        guard isStreaming else {
            return cache.value(for: text) { makePlan(for: text) }
        }
        if let slot = streamingLock.withLock({ streamingSlot }), slot.text == text {
            return slot.plan
        }
        let plan = makePlan(for: text)
        streamingLock.withLock { streamingSlot = (text, plan) }
        return plan
    }

    static func blocks(for text: String) -> [MarkdownBlock] {
        plan(for: text).blocks
    }

    /// Number of finished messages held, for tests.
    static var cachedCount: Int { cache.count }

    static func removeAll() {
        cache.removeAll()
        streamingLock.withLock { streamingSlot = nil }
    }

    private static func makePlan(for text: String) -> MarkdownRenderPlan {
        MarkdownRenderPlan(
            needsMath: RichTextFeatureDetector.requiresAdvancedRendering(text),
            blocks: MarkdownBlockParser.parse(text)
        )
    }
}

/// Remembers the measured height of a rendered math document.
///
/// The transcript is a `LazyVStack`, so scrolling a math bubble off screen and
/// back hands its WebView back to the pool and reattaches a document later.
/// Without a cached height the bubble collapses to a single point and everything
/// below it jumps. Heights depend on the wrapping width, so each entry records
/// the width it was measured at, and a bubble at another width ignores it.
nonisolated enum MarkdownHeightCache {
    nonisolated struct Key: Hashable, Sendable {
        let text: String
        let fontSize: Double
    }

    nonisolated struct Entry: Equatable, Sendable {
        let height: CGFloat
        /// The document width the height was measured at, when known.
        let width: CGFloat?

        /// Whether this height still applies at `width`.
        func matches(width otherWidth: CGFloat) -> Bool {
            guard let width else { return true }
            return abs(width - otherWidth) <= 1
        }
    }

    private static let cache = BoundedCache<Key, Entry>(limit: 64)

    static func entry(for key: Key) -> Entry? {
        cache.value(for: key)
    }

    static func height(for key: Key) -> CGFloat? {
        entry(for: key)?.height
    }

    static func store(_ height: CGFloat, width: CGFloat? = nil, for key: Key) {
        guard height > 1 else { return }
        cache.store(Entry(height: height, width: width.map { $0.rounded() }), for: key)
    }

    static func removeAll() {
        cache.removeAll()
    }
}

// MARK: - Math detection

/// KaTeX's display environments, which models also write without `$$`. Keep
/// parsing and routing aligned. `$…$` is not listed: it has stricter rules so
/// prices stay text (see `RichTextFeatureDetector.mathPattern`).
nonisolated private enum RichMathDelimiters {
    static let environments = [
        "equation", "equation*", "align", "align*", "aligned", "alignat", "alignat*", "alignedat",
        "gather", "gather*", "gathered", "split", "CD",
        "cases", "dcases", "rcases", "drcases",
        "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix",
        "matrix*", "pmatrix*", "bmatrix*", "Bmatrix*", "vmatrix*", "Vmatrix*",
        "smallmatrix", "array", "darray", "subarray"
    ]
    static let json: String = {
        let delimiters: [[String: Any]] = [
            ["left": "$$", "right": "$$", "display": true],
            ["left": "\\[", "right": "\\]", "display": true],
            ["left": "\\(", "right": "\\)", "display": false]
        ] + environments.map {
            ["left": "\\begin{\($0)}", "right": "\\end{\($0)}", "display": true]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: delimiters),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }()
}

/// Decides whether a message needs the bundled KaTeX document.
///
/// Only math does. Headings, lists, quotes, code, tables and inline emphasis are
/// all rendered natively, so they no longer force a WebView.
nonisolated enum RichTextFeatureDetector {
    /// Every math form in one pass:
    /// - `\(…\)`, `\[…\]` and `$$…$$`, each with its closing delimiter;
    /// - `$x$` on one line. The opener needs a non-space after it, and the next `$`
    ///   closes only with a non-space before it and no digit after it, so
    ///   "$5 and $10" stays text. Mirrors the `$` branch of the document's math rule;
    /// - a bare KaTeX environment, only once its matching `\end{…}` has arrived,
    ///   like the other delimiters.
    private static let mathPattern: NSRegularExpression? = {
        let environments = RichMathDelimiters.environments
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        let pattern = [
            #"\\\(.+?\\\)"#,
            #"\\\[.+?\\\]"#,
            #"\$\$.+?\$\$"#,
            #"(?<![\\$])\$(?![\s$])[^$\n]*(?<![\s\\])\$(?![$\d])"#,
            #"\\begin\{("# + environments + #")\}.*?\\end\{\1\}"#
        ].joined(separator: "|")
        return try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    }()

    /// A code span: a backtick run closed by a run of the same length on the same line.
    private static let inlineCodeSpan = try? NSRegularExpression(
        pattern: #"(?<!`)(`+)(?!`).*?(?<!`)\1(?!`)"#,
        options: []
    )

    static func requiresAdvancedRendering(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        // Swift interpolation (`\(name)`) and TeX-looking strings inside code are
        // not math. Masking code first keeps a snippet from spawning a WebView.
        let searchable = textOutsideCode(text)
        guard !searchable.isEmpty, let mathPattern else { return false }
        let range = NSRange(searchable.startIndex..., in: searchable)
        return mathPattern.firstMatch(in: searchable, options: [], range: range) != nil
    }

    /// Returns `text` with fenced blocks and inline code spans removed. Fences
    /// follow `MarkdownBlockParser`'s rules, so exactly what renders as code is masked.
    static func textOutsideCode(_ text: String) -> String {
        guard text.contains("`") || text.contains("~~~") else { return text }

        var kept: [String] = []
        var openFence: MarkdownBlockParser.Fence?

        for line in text.components(separatedBy: "\n") {
            if let fence = openFence {
                if MarkdownBlockParser.isFenceClosing(line, fence: fence) {
                    openFence = nil
                }
                continue
            }
            if let fence = MarkdownBlockParser.fenceOpening(line) {
                openFence = fence
                continue
            }
            kept.append(line)
        }

        let withoutFences = kept.joined(separator: "\n")
        guard withoutFences.contains("`"), let inlineCodeSpan else { return withoutFences }
        return inlineCodeSpan.stringByReplacingMatches(
            in: withoutFences,
            range: NSRange(withoutFences.startIndex..., in: withoutFences),
            withTemplate: " "
        )
    }
}

nonisolated enum RichMarkdownRenderingPolicy {
    static let disabledMarkdownRules = ["image"]
    static let contentSecurityPolicy = "default-src 'none'; img-src data:; font-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; object-src 'none'; base-uri 'none'"

    static var disabledMarkdownRulesJSON: String {
        guard let data = try? JSONEncoder().encode(disabledMarkdownRules),
              let json = String(data: data, encoding: .utf8) else {
            return #"["image"]"#
        }
        return json
    }
}

// MARK: - Palette

struct RichTextPalette: Hashable {
    let text: String
    let link: String
    let codeBackground: String
    let codeBorder: String
    let quoteBorder: String
    let quoteBackground: String
    let separator: String
    let tableStripe: String
    let inlineCode: String

    var cssVariables: [String: String] {
        ["text": text, "link": link, "code-background": codeBackground,
         "code-border": codeBorder, "quote-border": quoteBorder,
         "quote-background": quoteBackground, "separator": separator,
         "table-stripe": tableStripe, "inline-code": inlineCode]
    }

    /// Uses the same colour tokens as the native `MarkdownPalette`, so both
    /// renderers draw code, quotes and tables alike.
    init(colorScheme: ColorScheme, tone: RichMarkdownView.TextTone) {
        let trait = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        let textColor = (tone == .secondary ? UIColor.secondaryLabel : UIColor.label).resolvedColor(with: trait)
        self.text = textColor.cssRGBA
        self.link = UIColor.systemBlue.resolvedColor(with: trait).cssRGBA
        self.codeBackground = MarkdownColorToken.codeBackground.resolvedColor(with: trait).cssRGBA
        self.codeBorder = MarkdownColorToken.codeBorder.resolvedColor(with: trait).cssRGBA
        self.quoteBorder = MarkdownColorToken.quoteBorder.resolvedColor(with: trait).cssRGBA
        self.quoteBackground = MarkdownColorToken.quoteBackground.resolvedColor(with: trait).cssRGBA
        self.separator = MarkdownColorToken.separator.resolvedColor(with: trait).cssRGBA
        self.tableStripe = MarkdownColorToken.tableStripe.resolvedColor(with: trait).cssRGBA
        self.inlineCode = MarkdownColorToken.inlineCode.resolvedColor(with: trait).cssRGBA
    }

    private struct Variant: Hashable {
        let isDark: Bool
        let tone: RichMarkdownView.TextTone
    }

    /// There are only four palettes, so each is resolved once rather than on
    /// every body evaluation of a math bubble.
    private static var resolvedPalettes: [Variant: RichTextPalette] = [:]

    static func resolved(colorScheme: ColorScheme, tone: RichMarkdownView.TextTone) -> RichTextPalette {
        let variant = Variant(isDark: colorScheme == .dark, tone: tone)
        if let palette = resolvedPalettes[variant] { return palette }
        let palette = RichTextPalette(colorScheme: colorScheme, tone: tone)
        resolvedPalettes[variant] = palette
        return palette
    }
}

private extension UIColor {
    var cssRGBA: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "rgba(%d,%d,%d,%.3f)",
            Int(round(red * 255)),
            Int(round(green * 255)),
            Int(round(blue * 255)),
            alpha
        )
    }
}

// MARK: - Math bubble

private struct RichMarkdownWebView: View {
    let text: String
    let fallbackBlocks: [MarkdownBlock]
    let fontSize: Double
    let palette: RichTextPalette
    let fallbackTone: RichMarkdownView.TextTone
    let isStreaming: Bool

    @State private var height: CGFloat
    /// The width the seeded height was measured at, until the bubble's own width is known.
    @State private var seededWidth: CGFloat?
    @State private var hasMeasuredHeight = false
    @State private var failedToLoad = false
    @Environment(\.openURL) private var openURL

    init(
        text: String,
        fallbackBlocks: [MarkdownBlock],
        fontSize: Double,
        palette: RichTextPalette,
        fallbackTone: RichMarkdownView.TextTone,
        isStreaming: Bool
    ) {
        self.text = text
        self.fallbackBlocks = fallbackBlocks
        self.fontSize = fontSize
        self.palette = palette
        self.fallbackTone = fallbackTone
        self.isStreaming = isStreaming
        // Seeding the last known height keeps the transcript from jumping when a
        // bubble is recycled back into view and its document has to re-render.
        // `hasMeasuredHeight` stays false so the native fallback still covers the
        // gap until KaTeX has actually painted.
        let cached = MarkdownHeightCache.entry(for: .init(text: text, fontSize: fontSize))
        _height = State(initialValue: cached?.height ?? 1)
        _seededWidth = State(initialValue: cached?.width)
    }

    var body: some View {
        Group {
            if failedToLoad {
                MarkdownBlocksView(blocks: fallbackBlocks, fontSize: fontSize, tone: fallbackTone)
            } else {
                ZStack(alignment: .topLeading) {
                    if !hasMeasuredHeight {
                        MarkdownBlocksView(blocks: fallbackBlocks, fontSize: fontSize, tone: fallbackTone)
                    }

                    RichMarkdownWebViewRepresentable(
                        text: text,
                        fontSize: fontSize,
                        palette: palette,
                        isStreaming: isStreaming,
                        dynamicHeight: $height,
                        hasMeasuredHeight: $hasMeasuredHeight,
                        failedToLoad: $failedToLoad,
                        openURL: openURL
                    )
                    .frame(height: max(height, 1))
                    .opacity(hasMeasuredHeight ? 1 : 0)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                        dropSeededHeightIfStale(atWidth: width)
                    }
                }
            }
        }
    }

    /// A height measured at another width (before a rotation or a split-view
    /// resize) would reserve the wrong space until KaTeX re-measures, so the
    /// native fallback sizes the bubble instead.
    private func dropSeededHeightIfStale(atWidth width: CGFloat) {
        guard let seededWidth else { return }
        self.seededWidth = nil
        let entry = MarkdownHeightCache.Entry(height: height, width: seededWidth)
        if !hasMeasuredHeight, !entry.matches(width: width) {
            height = 1
        }
    }
}

struct RichMarkdownWebViewRepresentable: UIViewRepresentable {
    let text: String
    let fontSize: Double
    let palette: RichTextPalette
    var isStreaming: Bool = false
    @Binding var dynamicHeight: CGFloat
    @Binding var hasMeasuredHeight: Bool
    @Binding var failedToLoad: Bool
    let openURL: OpenURLAction

    /// The math document, built on first use. Kept for tests and diagnostics;
    /// web views get it from `MathDocument` without blocking the main actor.
    static var rendererHTML: String? { MathDocument.html }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            dynamicHeight: $dynamicHeight,
            hasMeasuredHeight: $hasMeasuredHeight,
            failedToLoad: $failedToLoad,
            openURL: openURL
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.openURL = openURL
        context.coordinator.update(
            webView,
            text: text,
            fontSize: fontSize,
            palette: palette,
            isStreaming: isStreaming
        )
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.dismantle(webView)
    }

    final class Coordinator: NSObject, MathDocumentClient {
        @Binding var dynamicHeight: CGFloat
        @Binding var hasMeasuredHeight: Bool
        @Binding var failedToLoad: Bool
        /// Refreshed on every update, so a changed environment action is honoured.
        var openURL: OpenURLAction

        private struct Payload: Equatable {
            let text: String
            let fontSize: Double
            let palette: RichTextPalette
            let isStreaming: Bool
        }

        /// Reloads attempted since the last successful render. WebKit kills the
        /// content process under memory pressure, which MLX makes likely, so a
        /// terminated document reloads instead of dropping to raw TeX for good.
        private static let maximumRecoveryAttempts = 2

        private var latestPayload: Payload?
        private var appliedPayload: Payload?
        /// The payload each in-flight revision rendered, so a height is cached
        /// under the text that produced it rather than whichever text is newest.
        private var renderedPayloads: [Int: Payload] = [:]
        private var isRendering = false
        private var isDismantled = false
        private var revision = 0
        private var measuredRevision = 0
        private var recoveryAttempts = 0
        /// Bumped on every reload, so a render that was in flight when the
        /// document went away cannot act on the new one.
        private var documentGeneration = 0

        init(
            dynamicHeight: Binding<CGFloat>,
            hasMeasuredHeight: Binding<Bool>,
            failedToLoad: Binding<Bool>,
            openURL: OpenURLAction
        ) {
            self._dynamicHeight = dynamicHeight
            self._hasMeasuredHeight = hasMeasuredHeight
            self._failedToLoad = failedToLoad
            self.openURL = openURL
        }

        func makeWebView() -> WKWebView {
            let webView = MathDocumentWebViewPool.shared.dequeue()
            webView.client = self
            return webView
        }

        func update(
            _ webView: WKWebView,
            text: String,
            fontSize: Double,
            palette: RichTextPalette,
            isStreaming: Bool = false
        ) {
            guard !isDismantled, let webView = webView as? MathDocumentWebView else { return }
            latestPayload = Payload(text: text, fontSize: fontSize, palette: palette, isStreaming: isStreaming)
            switch webView.documentState {
            case .ready:
                renderLatest(in: webView)
            case .loading:
                break // `mathDocumentDidLoad` renders the latest payload.
            case .empty:
                webView.loadDocumentIfNeeded()
            }
        }

        private func renderLatest(in webView: MathDocumentWebView) {
            guard !isDismantled, webView.documentState == .ready, !isRendering,
                  let payload = latestPayload, payload != appliedPayload else { return }
            isRendering = true
            revision += 1
            let renderRevision = revision
            let generation = documentGeneration
            renderedPayloads[renderRevision] = payload
            webView.callAsyncJavaScript(
                "window.updateMarkdown(text, fontSize, palette, revision); return true;",
                arguments: ["text": payload.text, "fontSize": payload.fontSize,
                            "palette": payload.palette.cssVariables, "revision": renderRevision],
                in: nil,
                in: .page
            ) { [weak self, weak webView] result in
                guard let self, !self.isDismantled, generation == self.documentGeneration else { return }
                self.isRendering = false
                switch result {
                case .success:
                    self.appliedPayload = payload
                    self.recoveryAttempts = 0
                    // Coalesce tokens that arrived while JS was running, including
                    // the final update. Never debounce until generation stops.
                    if let webView { self.renderLatest(in: webView) }
                case .failure(let error):
                    mathDocumentLogger.error("Math render failed: \(error.localizedDescription, privacy: .public)")
                    if let webView { self.recover(webView, reason: "a failed render") }
                }
            }
        }

        /// Reloads the document a bounded number of times, then falls back to
        /// native text so a persistent failure cannot loop.
        private func recover(_ webView: MathDocumentWebView, reason: String) {
            guard !isDismantled else { return }
            documentGeneration += 1
            isRendering = false
            appliedPayload = nil
            renderedPayloads.removeAll()
            recoveryAttempts += 1
            guard recoveryAttempts <= Self.maximumRecoveryAttempts else {
                mathDocumentLogger.error("Math document did not recover after \(reason, privacy: .public); using native text")
                setFailedToLoad(true)
                return
            }
            mathDocumentLogger.notice("Reloading math document after \(reason, privacy: .public)")
            webView.reloadDocument()
        }

        func dismantle(_ webView: WKWebView) {
            isDismantled = true
            guard let webView = webView as? MathDocumentWebView else { return }
            if webView.client === self { webView.client = nil }
            MathDocumentWebViewPool.shared.recycle(webView)
        }

        /// Called from `updateUIView` paths as well, so the state change is
        /// deferred past the current view update.
        func setFailedToLoad(_ nextValue: Bool) {
            Task { @MainActor [weak self] in
                guard let self, !self.isDismantled, self.failedToLoad != nextValue else { return }
                self.failedToLoad = nextValue
            }
        }

        // MARK: MathDocumentClient

        func mathDocumentDidLoad(_ webView: MathDocumentWebView) {
            renderLatest(in: webView)
        }

        func mathDocument(_ webView: MathDocumentWebView, didFailWith failure: MathDocumentFailure) {
            switch failure {
            case .missingAssets:
                setFailedToLoad(true)
            case .navigationFailed:
                recover(webView, reason: "a failed load")
            case .processTerminated:
                recover(webView, reason: "the content process ended")
            }
        }

        func mathDocument(_ webView: MathDocumentWebView, didMeasureHeight nextHeight: CGFloat, revision nextRevision: Int) {
            // Accept completed renders while a newer token is queued. Requiring
            // the latest requested revision can starve height updates mid-stream,
            // but an older measurement must never overwrite a newer one.
            guard !isDismantled, nextRevision > 0, nextRevision <= revision,
                  nextRevision >= measuredRevision, nextHeight.isFinite, nextHeight > 0 else { return }
            measuredRevision = nextRevision
            if !hasMeasuredHeight { hasMeasuredHeight = true }
            if abs(dynamicHeight - nextHeight) >= 1 {
                dynamicHeight = nextHeight
            }
            for key in renderedPayloads.keys where key < nextRevision {
                renderedPayloads.removeValue(forKey: key)
            }
            // Streamed prefixes are never shown again, so only a finished text is cached.
            if let payload = renderedPayloads[nextRevision], !payload.isStreaming {
                MarkdownHeightCache.store(
                    nextHeight,
                    width: webView.bounds.width > 0 ? webView.bounds.width : nil,
                    for: .init(text: payload.text, fontSize: payload.fontSize)
                )
            }
        }

        func mathDocument(_ webView: MathDocumentWebView, open url: URL) {
            openURL(url)
        }
    }
}

// MARK: - Math document

/// Why a math document could not be shown.
enum MathDocumentFailure: Equatable {
    /// A bundled parser, stylesheet or font is missing; reloading cannot help.
    case missingAssets
    case navigationFailed
    case processTerminated
}

@MainActor
protocol MathDocumentClient: AnyObject {
    func mathDocumentDidLoad(_ webView: MathDocumentWebView)
    func mathDocument(_ webView: MathDocumentWebView, didFailWith failure: MathDocumentFailure)
    func mathDocument(_ webView: MathDocumentWebView, didMeasureHeight height: CGFloat, revision: Int)
    func mathDocument(_ webView: MathDocumentWebView, open url: URL)
}

/// A web view holding the math document, which moves between bubbles through
/// `MathDocumentWebViewPool`. Delegate callbacks go to whichever bubble's
/// coordinator currently owns it.
final class MathDocumentWebView: WKWebView {
    enum DocumentState: Equatable {
        case empty
        case loading
        case ready
    }

    private(set) var documentState: DocumentState = .empty
    var client: MathDocumentClient? {
        get { events.client }
        set { events.client = newValue }
    }

    private let events: MathDocumentEvents

    init() {
        let events = MathDocumentEvents()
        let config = WKWebViewConfiguration()
        // No explicit process pool: WebKit has shared content processes
        // between web views on its own since iOS 15, and `WKProcessPool` is
        // deprecated precisely because setting one no longer does anything.
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // The content controller keeps the forwarder alive; the forwarder only
        // holds the web view and its client weakly, so nothing forms a cycle.
        config.userContentController.add(events, name: MathDocument.heightHandlerName)
        self.events = events
        super.init(frame: .zero, configuration: config)
        events.webView = self

        isOpaque = false
        backgroundColor = .clear
        scrollView.backgroundColor = .clear
        scrollView.isScrollEnabled = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        navigationDelegate = events
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Loads the document once. The HTML is assembled off the main actor the
    /// first time it is needed; the native fallback covers the wait.
    func loadDocumentIfNeeded() {
        guard documentState == .empty else { return }
        documentState = .loading
        if let built = MathDocument.builtHTML {
            load(built)
            return
        }
        Task { [weak self] in
            let html = await MathDocument.prepare()
            guard let self, self.documentState == .loading else { return }
            self.load(html)
        }
    }

    /// Starts the document over, for a terminated content process or a failed render.
    func reloadDocument() {
        guard documentState != .loading else { return }
        documentState = .empty
        loadDocumentIfNeeded()
    }

    /// Clears the rendered message so the view can serve another bubble. Reports
    /// false when the document is not in its pristine, reusable state.
    func resetForReuse() async -> Bool {
        guard documentState == .ready else { return false }
        let result = try? await callAsyncJavaScript(
            "return window.resetMarkdown?.() === true;",
            contentWorld: .page
        )
        return documentState == .ready && (result as? Bool) == true
    }

    private func load(_ html: String?) {
        guard let html else {
            documentState = .empty
            client?.mathDocument(self, didFailWith: .missingAssets)
            return
        }
        loadHTMLString(html, baseURL: nil)
    }

    fileprivate func documentDidFinishLoading() {
        guard documentState == .loading else { return }
        documentState = .ready
        client?.mathDocumentDidLoad(self)
    }

    fileprivate func documentDidFail(_ failure: MathDocumentFailure) {
        documentState = .empty
        client?.mathDocument(self, didFailWith: failure)
    }
}

/// Receives WebKit callbacks for one `MathDocumentWebView`.
private final class MathDocumentEvents: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var webView: MathDocumentWebView?
    weak var client: MathDocumentClient?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == MathDocument.heightHandlerName,
              let webView,
              let body = message.body as? [String: Any],
              let number = body["height"] as? NSNumber,
              let revision = body["revision"] as? Int else { return }
        client?.mathDocument(webView, didMeasureHeight: CGFloat(truncating: number), revision: revision)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.webView?.documentDidFinishLoading()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportNavigationFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        mathDocumentLogger.notice("Math document content process terminated")
        self.webView?.documentDidFail(.processTerminated)
    }

    private func reportNavigationFailure(_ error: Error) {
        // A load replaced by a newer one is not a failure of the document.
        if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorCancelled { return }
        mathDocumentLogger.error("Math document failed to load: \(error.localizedDescription, privacy: .public)")
        webView?.documentDidFail(.navigationFailed)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let isMainFrameInitialLoad = navigationAction.targetFrame?.isMainFrame == true && url.scheme == "about"
        guard !isMainFrameInitialLoad else {
            decisionHandler(.allow)
            return
        }

        if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let mathWebView = self.webView {
            client?.mathDocument(mathWebView, open: url)
        }
        decisionHandler(.cancel)
    }
}

/// Keeps a few loaded math documents for reuse.
///
/// The transcript is a `LazyVStack`, so a math bubble's web view is dismantled
/// whenever it scrolls away. Handing that view back here, with its document still
/// loaded and its compiled scripts and typeset formulas intact, lets the next math
/// bubble render straight away instead of parsing ~820 KB of KaTeX again.
@MainActor
final class MathDocumentWebViewPool {
    static let shared = MathDocumentWebViewPool()

    /// Idle documents kept warm. Each holds its own JS heap, so the pool stays small.
    let idleLimit: Int
    private var idle: [MathDocumentWebView] = []
    private var memoryWarnings: Task<Void, Never>?

    init(idleLimit: Int = 3) {
        self.idleLimit = idleLimit
        memoryWarnings = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didReceiveMemoryWarningNotification) {
                self?.drain()
            }
        }
    }

    var idleCount: Int { idle.count }

    /// Recycled views still resetting their document before the pool decides
    /// whether to keep them.
    private(set) var pendingRecycleCount = 0

    /// A loaded document when one is idle, otherwise a new view that starts loading.
    func dequeue() -> MathDocumentWebView {
        while let webView = idle.popLast() {
            if webView.documentState == .ready { return webView }
        }
        let webView = MathDocumentWebView()
        webView.loadDocumentIfNeeded()
        return webView
    }

    /// Takes back a view whose bubble went away. Only a cleanly reset document
    /// is kept; anything else is released.
    func recycle(_ webView: MathDocumentWebView) {
        webView.client = nil
        guard webView.documentState == .ready, idle.count < idleLimit else {
            discard(webView)
            return
        }
        pendingRecycleCount += 1
        Task { [weak self, weak webView] in
            defer { self?.pendingRecycleCount -= 1 }
            guard let webView else { return }
            let isReusable = await webView.resetForReuse()
            guard let self, isReusable, webView.client == nil, self.idle.count < self.idleLimit,
                  !self.idle.contains(where: { $0 === webView }) else {
                if webView.client == nil { self?.discard(webView) }
                return
            }
            webView.removeFromSuperview()
            self.idle.append(webView)
        }
    }

    func drain() {
        let views = idle
        idle.removeAll()
        views.forEach(discard)
    }

    private func discard(_ webView: MathDocumentWebView) {
        webView.stopLoading()
        webView.removeFromSuperview()
    }
}

/// Builds the self-contained KaTeX document.
nonisolated enum MathDocument {
    static let heightHandlerName = "richTextHeight"

    private static let lock = NSLock()
    /// `nil` until built; then the document, or `.some(nil)` when an asset is missing.
    /// Only read and written under `lock`.
    nonisolated(unsafe) private static var storage: String??

    /// The document if it has been built, without building it.
    static var builtHTML: String?? {
        lock.withLock { storage }
    }

    /// The document, built synchronously on first access.
    static var html: String? {
        if let built = builtHTML { return built }
        let built = makeHTML()
        return lock.withLock {
            if storage == nil { storage = .some(built) }
            return storage ?? nil
        }
    }

    /// Builds the document off the main actor: it reads 23 bundled files and
    /// base64-encodes the fonts, which would otherwise stall the first math render.
    @concurrent static func prepare() async -> String? {
        html
    }

    private static func makeHTML() -> String? {
        let markdownItJS = bundledTextResource(named: "markdown-it.min", extension: "js")?.escapedInlineScript
        let katexJS = bundledTextResource(named: "katex.min", extension: "js")?.escapedInlineScript
        let katexCSS = bundledMathCSS()?.escapedInlineStyle
        guard let markdownItJS, let katexCSS, let katexJS else {
            mathDocumentLogger.error("Math document assets are missing from the bundle; math renders as text")
            return nil
        }
        let disabledMarkdownRules = RichMarkdownRenderingPolicy.disabledMarkdownRulesJSON

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
          <meta http-equiv="Content-Security-Policy" content="\(RichMarkdownRenderingPolicy.contentSecurityPolicy)">
          <style>
          \(katexCSS)
          </style>
          <style>
            :root {
              color-scheme: light dark;
            }
            html, body {
              margin: 0;
              padding: 0;
              background: transparent;
              overflow: hidden;
            }
            body {
              color: var(--text);
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
              font-size: var(--font-size, 16px);
              line-height: 1.45;
              -webkit-font-smoothing: antialiased;
              word-wrap: break-word;
              overflow-wrap: anywhere;
              user-select: text;
              -webkit-user-select: text;
            }
            #content { display: flow-root; }
            #content > :first-child { margin-top: 0; }
            #content > :last-child { margin-bottom: 0; }
            p, ul, ol, blockquote, pre, table, hr {
              margin: 0 0 0.85em;
            }
            h1, h2, h3, h4, h5, h6 {
              margin: 0 0 0.55em;
              line-height: 1.2;
              font-weight: 700;
            }
            \(MarkdownTypography.headingCSS)
            ul, ol {
              padding-left: 1.35em;
            }
            li + li {
              margin-top: 0.25em;
            }
            a {
              color: var(--link);
              text-decoration: none;
            }
            pre, code {
              font-family: "SF Mono", "Menlo", "Consolas", monospace;
            }
            code {
              color: var(--inline-code);
              background: var(--code-background);
              border: 1px solid var(--code-border);
              border-radius: 6px;
              padding: 0.12em 0.35em;
              font-size: 0.92em;
            }
            pre {
              background: var(--code-background);
              border: 1px solid var(--code-border);
              border-radius: 10px;
              padding: 0.8em 0.9em;
              overflow-x: auto;
            }
            pre code {
              background: transparent;
              border: 0;
              color: inherit;
              padding: 0;
              font-size: 0.9em;
              white-space: pre;
              overflow-wrap: normal;
            }
            blockquote {
              border-left: 3px solid var(--quote-border);
              background: var(--quote-background);
              padding: 0.75em 0.9em;
              border-radius: 0 10px 10px 0;
            }
            hr {
              border: 0;
              border-top: 1px solid var(--separator);
            }
            table {
              width: 100%;
              border-collapse: collapse;
              font-size: 0.96em;
            }
            th, td {
              border: 1px solid var(--separator);
              padding: 0.55em 0.7em;
              text-align: left;
              vertical-align: top;
            }
            thead th {
              background: var(--code-background);
            }
            tbody tr:nth-child(even) {
              background: var(--table-stripe);
            }
            .katex-display {
              overflow-x: auto;
              overflow-y: hidden;
              padding: 0.25em 0;
            }
          </style>
        </head>
        <body>
          <div id="content"></div>
          <script>
          \(markdownItJS)
          </script>
          <script>
          \(katexJS)
          </script>
          <script>
            const root = document.getElementById('content');
            // Bare URLs stay text, as they do in the native renderer.
            const md = window.markdownit({
              html: false,
              linkify: false,
              typographer: false,
              breaks: true
            });
            md.disable(\(disabledMarkdownRules));
            // Math is tokenized here and rendered by KaTeX directly, so Markdown's
            // escape/emphasis rules never see it (they would strip \\( and \\[),
            // and code spans or fences are never mistaken for math.
            const mathDelimiters = \(RichMathDelimiters.json);
            const isSpace = (character) => character === undefined || /\\s/.test(character);
            const isEnvironment = (delimiter) => delimiter.left.startsWith('\\\\begin');
            // Index of the delimiter that closes one opened before `from`. A nested
            // environment of the same name (an array in an array) closes first.
            const closingIndex = (src, from, delimiter) => {
              if (!isEnvironment(delimiter)) return src.indexOf(delimiter.right, from);
              let depth = 1;
              let pos = from;
              for (;;) {
                const close = src.indexOf(delimiter.right, pos);
                if (close < 0) return -1;
                const open = src.indexOf(delimiter.left, pos);
                if (open >= 0 && open < close) {
                  depth += 1;
                  pos = open + delimiter.left.length;
                  continue;
                }
                depth -= 1;
                if (depth === 0) return close;
                pos = close + delimiter.right.length;
              }
            };
            // Environments go to KaTeX whole; other delimiters only wrap the TeX.
            const mathToken = (state, type, source, delimiter) => {
              const token = state.push(type, '', 0);
              token.content = isEnvironment(delimiter)
                ? source
                : source.slice(delimiter.left.length, source.length - delimiter.right.length);
              token.meta = {display: delimiter.display, source};
              return token;
            };
            md.inline.ruler.before('escape', 'math', (state, silent) => {
              const src = state.src;
              const pos = state.pos;
              for (const delimiter of mathDelimiters) {
                if (!src.startsWith(delimiter.left, pos)) continue;
                const end = closingIndex(src, pos + delimiter.left.length, delimiter);
                if (end < 0) return false;
                const next = end + delimiter.right.length;
                if (!silent) mathToken(state, 'math', src.slice(pos, next), delimiter);
                state.pos = next;
                return true;
              }
              // $x$: same rules as RichTextFeatureDetector's inline-dollar branch,
              // including no `$` right before the opener, so "$$x$" stays text.
              if (src[pos] !== '$' || src[pos + 1] === '$' || isSpace(src[pos + 1])) return false;
              if (pos > 0 && (src[pos - 1] === '$' || src[pos - 1] === '\\\\')) return false;
              const end = src.indexOf('$', pos + 1);
              if (end < 0 || isSpace(src[end - 1]) || src[end - 1] === '\\\\'
                  || /[\\d$]/.test(src[end + 1] ?? '') || src.slice(pos, end).includes('\\n')) return false;
              if (!silent) mathToken(state, 'math', src.slice(pos, end + 1), {left: '$', right: '$', display: false});
              state.pos = end + 1;
              return true;
            });
            // A display block that starts a line may contain blank lines, which
            // would otherwise split it into separate paragraphs.
            md.block.ruler.before('paragraph', 'math_block', (state, startLine, endLine, silent) => {
              if (state.sCount[startLine] - state.blkIndent >= 4) return false;
              const lineText = (line) => state.src.slice(state.bMarks[line] + state.tShift[line], state.eMarks[line]);
              const first = lineText(startLine);
              const delimiter = mathDelimiters.find(({left, display}) => display && first.startsWith(left));
              if (!delimiter) return false;
              let source = first;
              for (let line = startLine; line < endLine; line++) {
                if (line > startLine) {
                  const text = lineText(line);
                  if (text && state.sCount[line] < state.blkIndent) return false;
                  source += '\\n' + text;
                }
                const end = closingIndex(source, delimiter.left.length, delimiter);
                if (end < 0) continue;
                const next = end + delimiter.right.length;
                if (source.slice(next).trim()) return false;
                if (!silent) {
                  mathToken(state, 'math_block', source.slice(0, next), delimiter).map = [startLine, line + 1];
                }
                state.line = line + 1;
                return true;
              }
              return false;
            }, {alt: ['paragraph', 'reference', 'blockquote', 'list']});
            // Each formula is typeset once per document. Streaming re-renders the
            // message on every token, and KaTeX is by far the most expensive part.
            const typesetFormulas = new Map();
            const renderMath = (token) => {
              const key = (token.meta.display ? 'D' : 'I') + token.content;
              const cached = typesetFormulas.get(key);
              if (cached !== undefined) return cached;
              let html;
              try {
                html = katex.renderToString(token.content, {
                  displayMode: token.meta.display,
                  throwOnError: false,
                  strict: 'ignore'
                });
              } catch {
                html = md.utils.escapeHtml(token.meta.source);
              }
              if (typesetFormulas.size >= 512) typesetFormulas.clear();
              typesetFormulas.set(key, html);
              return html;
            };
            md.renderer.rules.math = (tokens, index) => renderMath(tokens[index]);
            md.renderer.rules.math_block = (tokens, index) => '<p>' + renderMath(tokens[index]) + '</p>\\n';
            let revision = 0;
            let appliedStyle = '';
            // The DOM nodes and HTML of each top-level block, in order. Only blocks
            // from the first changed one onward are replaced, so a streamed token
            // leaves earlier formulas, selections and scroll positions alone.
            let renderedBlocks = [];

            const topLevelBlocks = (tokens) => {
              const blocks = [];
              let start = 0;
              let depth = 0;
              for (let index = 0; index < tokens.length; index++) {
                depth += tokens[index].nesting;
                if (depth === 0) {
                  blocks.push(tokens.slice(start, index + 1));
                  start = index + 1;
                }
              }
              if (start < tokens.length) blocks.push(tokens.slice(start));
              return blocks;
            };

            const render = (source) => {
              const env = {};
              const html = topLevelBlocks(md.parse(source, env))
                .map((block) => md.renderer.render(block, md.options, env));
              let kept = 0;
              while (kept < html.length && kept < renderedBlocks.length && renderedBlocks[kept].html === html[kept]) {
                kept += 1;
              }
              for (const block of renderedBlocks.slice(kept)) {
                for (const node of block.nodes) node.remove();
              }
              const next = renderedBlocks.slice(0, kept);
              for (const blockHTML of html.slice(kept)) {
                const template = document.createElement('template');
                template.innerHTML = blockHTML;
                const nodes = Array.from(template.content.childNodes);
                root.append(template.content);
                next.push({html: blockHTML, nodes});
              }
              renderedBlocks = next;
            };

            const postHeight = () => {
              if (!revision) return;
              // Document scrollHeight is at least the viewport height, which
              // prevents a previously tall bubble from ever shrinking.
              const height = Math.max(1, Math.ceil(root.getBoundingClientRect().height));
              window.webkit?.messageHandlers?.\(heightHandlerName)?.postMessage({height, revision});
            };

            const updateMarkdown = (source, fontSize, palette, nextRevision) => {
              revision = nextRevision;
              const style = JSON.stringify([fontSize, palette]);
              if (style !== appliedStyle) {
                appliedStyle = style;
                document.documentElement.style.setProperty('--font-size', fontSize + 'px');
                for (const [key, value] of Object.entries(palette)) {
                  document.documentElement.style.setProperty('--' + key, value);
                }
              }
              render(source);
              postHeight();
              requestAnimationFrame(postHeight);
            };
            window.updateMarkdown = updateMarkdown;

            // Clears the message so the pool can hand the document to another
            // bubble. Refuses when the renderer was replaced, so a modified
            // document is never reused.
            window.resetMarkdown = () => {
              if (window.updateMarkdown !== updateMarkdown) return false;
              revision = 0;
              renderedBlocks = [];
              root.replaceChildren();
              return true;
            };

            if (window.ResizeObserver) {
              const observer = new ResizeObserver(postHeight);
              observer.observe(root);
            }
            window.addEventListener('resize', postHeight);
            if (document.fonts && document.fonts.ready) {
              document.fonts.ready.then(postHeight);
            }
          </script>
        </body>
        </html>
        """
    }

    /// Use only the bundled WOFF2 source; other formats would leave dangling
    /// relative URLs in a document loaded from an HTML string.
    private static func bundledMathCSS() -> String? {
        guard var css = bundledTextResource(named: "katex.min", extension: "css"),
              let sources = try? NSRegularExpression(pattern: #"src:url\(fonts/(KaTeX_[^)]+)\.woff2\)[^;}]+"#) else { return nil }
        let matches = sources.matches(in: css, range: NSRange(css.startIndex..., in: css))
        guard !matches.isEmpty else { return nil }
        for match in matches.reversed() {
            guard let nameRange = Range(match.range(at: 1), in: css),
                  let sourceRange = Range(match.range, in: css) else { return nil }
            let name = String(css[nameRange])
            let url = Bundle.main.url(forResource: name, withExtension: "woff2")
                ?? Bundle.main.url(forResource: name, withExtension: "woff2", subdirectory: "RenderingAssets/Fonts")
                ?? Bundle.main.url(forResource: name, withExtension: "woff2", subdirectory: "Fonts")
            guard let url, let data = try? Data(contentsOf: url) else {
                mathDocumentLogger.error("Missing KaTeX font \(name, privacy: .public)")
                return nil
            }
            css.replaceSubrange(sourceRange, with: "src:url(data:font/woff2;base64,\(data.base64EncodedString())) format(\"woff2\")")
        }
        return css
    }

    private static func bundledTextResource(named name: String, extension fileExtension: String) -> String? {
        let candidateURLs = [
            Bundle.main.url(forResource: name, withExtension: fileExtension),
            Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: "RenderingAssets")
        ]

        for url in candidateURLs.compactMap({ $0 }) {
            if let contents = try? String(contentsOf: url, encoding: .utf8) {
                return contents
            }
        }

        mathDocumentLogger.error("Missing rendering asset \(name, privacy: .public).\(fileExtension, privacy: .public)")
        return nil
    }
}

nonisolated private extension String {
    var escapedInlineScript: String {
        replacingOccurrences(of: "</script", with: "<\\/script")
    }

    var escapedInlineStyle: String {
        replacingOccurrences(of: "</style", with: "<\\/style")
    }
}
