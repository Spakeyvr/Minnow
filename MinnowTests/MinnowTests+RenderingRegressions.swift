//
//  MinnowTests+RenderingRegressions
//  MinnowTests
//
//  Regression coverage for message rendering: the Markdown parser, math
//  routing, the render caches, the pooled math document, reasoning bubbles
//  and the composer. Part of the single @Suite(.serialized) MinnowTests suite.
//

import Testing
import Foundation
import SwiftUI
import SwiftData
import WebKit
import UIKit
@testable import Minnow

// MARK: - Markdown parser

extension MinnowTests {
    @Test func parserLetsATableInterruptAParagraph() {
        #expect(MarkdownBlockParser.parse("Here is a comparison:\n| A | B |\n|---|---|\n| 1 | 2 |") == [
            .paragraph("Here is a comparison:"),
            .table(MarkdownTable(headers: ["A", "B"], alignments: [.leading, .leading], rows: [["1", "2"]]))
        ])
        // Pipes without a delimiter row below them are still prose.
        #expect(MarkdownBlockParser.parse("Use a | b\nor c | d") == [.paragraph("Use a | b\nor c | d")])
        // A delimiter row with a different column count does not start a table.
        #expect(MarkdownBlockParser.parse("Intro\n| A | B |\n|---|") == [.paragraph("Intro\n| A | B |\n|---|")])
    }

    @Test func parserKeepsHashesThatEndAHeadingWord() {
        #expect(MarkdownBlockParser.parse("## Learning C#") == [.heading(level: 2, text: "Learning C#")])
        #expect(MarkdownBlockParser.parse("# F# tips") == [.heading(level: 1, text: "F# tips")])
        // A closing sequence after whitespace is still decorative.
        #expect(MarkdownBlockParser.parse("### Heading ###") == [.heading(level: 3, text: "Heading")])
        #expect(MarkdownBlockParser.parse("## C# ##") == [.heading(level: 2, text: "C#")])
        #expect(MarkdownBlockParser.parse("# #") == [.heading(level: 1, text: "")])
    }

    @Test func streamedListAfterParagraphNeverFlashesAsHeading() {
        let source = "Intro:\n- First item\n- Second item"
        for length in 1...source.count {
            let blocks = MarkdownBlockParser.parse(String(source.prefix(length)))
            let hasHeading = blocks.contains { if case .heading = $0 { return true } else { return false } }
            #expect(!hasHeading, "prefix \(length) parsed as a heading")
        }
        #expect(MarkdownBlockParser.parse(source) == [
            .paragraph("Intro:"),
            .list(MarkdownList(isOrdered: false, start: 1, isLoose: false, items: [
                MarkdownListItem(blocks: [.paragraph("First item")]),
                MarkdownListItem(blocks: [.paragraph("Second item")])
            ]))
        ])
        // Underlines that are already decided stay setext headings.
        #expect(MarkdownBlockParser.parse("Title\n---") == [.heading(level: 2, text: "Title")])
        #expect(MarkdownBlockParser.parse("Title\n=") == [.heading(level: 1, text: "Title")])
        #expect(MarkdownBlockParser.parse("Title\n-\nMore") == [.heading(level: 2, text: "Title"), .paragraph("More")])
    }
}

// MARK: - Math routing

extension MinnowTests {
    @Test func mathDetectorMasksCodeExactlyLikeTheParser() {
        // A line starting "```make```" is a code span, not a fence that swallows the rest.
        #expect(RichTextFeatureDetector.requiresAdvancedRendering("```make``` runs it.\n\nThen $$x^2$$ holds."))
        // A fence indented four spaces is indented code, not a fence.
        #expect(RichTextFeatureDetector.requiresAdvancedRendering("    ```\n\n$$x^2$$"))
        // A stray backtick does not mask text in a later paragraph.
        #expect(RichTextFeatureDetector.requiresAdvancedRendering("Press ` to open.\n\nThen $$x^2$$ and a ` later."))
        // A double-backtick span may hold single backticks and still masks its TeX.
        #expect(!RichTextFeatureDetector.requiresAdvancedRendering("Use ``a` $$x$$ `b`` here."))
        // A real fence still masks everything until it closes.
        #expect(!RichTextFeatureDetector.requiresAdvancedRendering("```\n$$x^2$$\n```"))
    }

    @Test func mathDetectorWaitsForTheClosingEnvironment() {
        #expect(!RichTextFeatureDetector.requiresAdvancedRendering(#"\begin{align} x &= 1"#))
        #expect(!RichTextFeatureDetector.requiresAdvancedRendering(#"\begin{align} x \end{equation}"#))
        #expect(RichTextFeatureDetector.requiresAdvancedRendering("\\begin{align}\nx &= 1\n\\end{align}"))
        #expect(RichTextFeatureDetector.requiresAdvancedRendering(#"\begin{pmatrix*} 1 \end{pmatrix*}"#))
    }

    @Test func renderPlanRoutesMathAndKeepsTheFallbackBlocks() {
        MarkdownBlockCache.removeAll()
        let plan = MarkdownBlockCache.plan(for: "## Area\n\n$$\\pi r^2$$")
        #expect(plan.needsMath)
        #expect(plan.blocks == MarkdownBlockParser.parse("## Area\n\n$$\\pi r^2$$"))
        #expect(!MarkdownBlockCache.plan(for: "## Plain").needsMath)
    }
}

// MARK: - Caches

extension MinnowTests {
    @Test func boundedCacheEvictsTheLeastRecentlyUsedEntry() {
        let cache = BoundedCache<String, Int>(limit: 2)
        cache.store(1, for: "a")
        cache.store(2, for: "b")
        #expect(cache.value(for: "a") == 1)
        cache.store(3, for: "c")
        // "b" was the least recently used; "a" was just read.
        #expect(cache.value(for: "b") == nil)
        #expect(cache.value(for: "a") == 1)
        #expect(cache.value(for: "c") == 3)
        #expect(cache.count == 2)
    }

    @Test func streamedPrefixesDoNotEvictFinishedMessages() {
        MarkdownBlockCache.removeAll()
        let finished = "## Finished\n\n- First\n- Second"
        _ = MarkdownBlockCache.plan(for: finished)
        let reply = String(repeating: "Streaming word ", count: 200)
        for length in stride(from: 1, through: reply.count, by: 3) {
            _ = MarkdownBlockCache.plan(for: String(reply.prefix(length)), isStreaming: true)
        }
        #expect(MarkdownBlockCache.cachedCount == 1)
        #expect(MarkdownBlockCache.plan(for: finished).blocks == MarkdownBlockParser.parse(finished))
    }

    @Test func heightCacheRemembersTheMeasuredWidth() {
        MarkdownHeightCache.removeAll()
        let key = MarkdownHeightCache.Key(text: "$$x$$", fontSize: 16)
        MarkdownHeightCache.store(120, width: 320.4, for: key)
        let entry = MarkdownHeightCache.entry(for: key)
        #expect(entry?.height == 120)
        #expect(entry?.width == 320)
        #expect(entry?.matches(width: 320.8) == true)
        // A different width, after a rotation or split-view resize, needs its own measurement.
        #expect(entry?.matches(width: 480) == false)
        // A height stored without a width applies at any width.
        MarkdownHeightCache.store(90, for: key)
        #expect(MarkdownHeightCache.entry(for: key)?.matches(width: 480) == true)
    }

    @Test func inlineRendererMemoMatchesAFreshRender() {
        let source = "Some **bold** and `code` text."
        let fresh = MarkdownInlineRenderer.attributed(source, fontSize: 16)
        #expect(MarkdownInlineRenderer.attributed(source, fontSize: 16, caching: true) == fresh)
        #expect(MarkdownInlineRenderer.attributed(source, fontSize: 16, caching: true) == fresh)
        #expect(MarkdownInlineRenderer.attributed(source, fontSize: 16, caching: false) == fresh)
    }
}

// MARK: - Math document

extension MinnowTests {
    @Test func mathHeightIsCachedUnderTheTextThatProducedIt() async throws {
        MarkdownHeightCache.removeAll()
        let renderer = MarkdownWebTestHarness()
        defer { renderer.close() }
        renderer.update("$$a^2$$")
        try await renderer.waitFor("document.querySelector('.katex') !== null")
        let firstKey = MarkdownHeightCache.Key(text: "$$a^2$$", fontSize: 16)
        let firstHeight = try #require(MarkdownHeightCache.height(for: firstKey))

        // The height message arrives before the render call completes, which is
        // exactly when the previous text used to be taken as its key.
        _ = try await renderer.webView.evaluateJavaScript("""
        window.updateMarkdown = (source, fontSize, palette, revision) => {
          window.webkit.messageHandlers.richTextHeight.postMessage({height: 77, revision});
        };
        true;
        """)
        renderer.update("$$b^2$$")
        let secondKey = MarkdownHeightCache.Key(text: "$$b^2$$", fontSize: 16)
        try await waitUntil { MarkdownHeightCache.height(for: secondKey) != nil }
        #expect(MarkdownHeightCache.height(for: secondKey) == 77)
        #expect(MarkdownHeightCache.height(for: firstKey) == firstHeight)
    }

    @Test func streamingMathHeightsAreCachedOnlyOnceFinished() async throws {
        MarkdownHeightCache.removeAll()
        let renderer = MarkdownWebTestHarness()
        defer { renderer.close() }
        let palette = RichTextPalette(colorScheme: .light, tone: .primary)
        let key = MarkdownHeightCache.Key(text: "$$c^2$$", fontSize: 16)
        renderer.coordinator.update(renderer.webView, text: "$$c^2$$", fontSize: 16, palette: palette, isStreaming: true)
        try await renderer.waitFor("document.querySelector('.katex') !== null")
        #expect(MarkdownHeightCache.height(for: key) == nil)

        renderer.coordinator.update(renderer.webView, text: "$$c^2$$", fontSize: 16, palette: palette, isStreaming: false)
        try await waitUntil { MarkdownHeightCache.height(for: key) != nil }
        #expect(MarkdownHeightCache.entry(for: key)?.width == 320)
    }

    @Test func mathDocumentReloadsAfterItsContentProcessTerminates() async throws {
        let renderer = MarkdownWebTestHarness()
        defer { renderer.close() }
        renderer.update("$$x^2 + y^2$$")
        try await renderer.waitFor("document.querySelector('.katex') !== null")
        _ = try await renderer.webView.evaluateJavaScript("window.beforeTermination = true; true;")

        renderer.webView.navigationDelegate?.webViewWebContentProcessDidTerminate?(renderer.webView)

        // A fresh document, re-rendered with the same text, rather than raw TeX.
        try await renderer.waitFor("window.beforeTermination === undefined && document.querySelector('.katex') !== null")
        #expect(!renderer.failedToLoad)
    }

    @Test func mathDocumentFallsBackToNativeTextAfterRepeatedFailures() async throws {
        let renderer = MarkdownWebTestHarness()
        defer { renderer.close() }
        renderer.update("$$x^2$$")
        try await renderer.waitFor("document.querySelector('.katex') !== null")

        for _ in 0..<3 {
            renderer.webView.navigationDelegate?.webViewWebContentProcessDidTerminate?(renderer.webView)
        }
        try await waitUntil { renderer.failedToLoad }
        #expect(renderer.failedToLoad)
    }

    /// The policy method must keep matching WebKit's Swift 6 signature (a
    /// `@MainActor @Sendable` handler); a near miss would never be called and
    /// links in math documents would load inside the bubble.
    @Test func mathDocumentHandsWebLinksOffInsteadOfLoadingThem() {
        let renderer = MarkdownWebTestHarness()
        defer { renderer.close() }
        let recorder = NavigationPolicyRecorder()

        let handled: Void? = renderer.webView.navigationDelegate?.webView?(
            renderer.webView,
            decidePolicyFor: StubNavigationAction(url: URL(string: "https://example.com/page")!),
            decisionHandler: { policy in recorder.policy = policy }
        )

        #expect(handled != nil)
        #expect(recorder.policy == .cancel)
    }

    @Test func recycledMathWebViewKeepsItsLoadedDocument() async throws {
        // Earlier tests may have filled the pool; start from an empty one.
        MathDocumentWebViewPool.shared.drain()
        let first = MarkdownWebTestHarness()
        first.update("$$e^{i\\pi}$$")
        try await first.waitFor("document.querySelector('.katex') !== null")
        _ = try await first.webView.evaluateJavaScript("window.documentIdentity = 'pooled'; true;")
        let pooledView = first.webView
        let idleBefore = MathDocumentWebViewPool.shared.idleCount
        first.close()
        try await waitUntil { MathDocumentWebViewPool.shared.idleCount > idleBefore }

        let second = MarkdownWebTestHarness()
        defer { second.close() }
        #expect(second.webView === pooledView)
        // The same loaded document, emptied of the previous message.
        #expect(try await second.webView.evaluateJavaScript("window.documentIdentity") as? String == "pooled")
        #expect(try await second.webView.evaluateJavaScript("document.getElementById('content').childNodes.length") as? Int == 0)
        second.update("$$1 + 1$$")
        try await second.waitFor("document.querySelectorAll('.katex').length === 1")
        #expect(!second.failedToLoad)
    }

    @Test func modifiedMathDocumentIsNotReused() async throws {
        let first = MarkdownWebTestHarness()
        first.update("$$z$$")
        try await first.waitFor("document.querySelector('.katex') !== null")
        _ = try await first.webView.evaluateJavaScript("window.updateMarkdown = () => {}; true;")
        let modifiedView = first.webView
        first.close()
        // Wait for the pool to decide about the view instead of for a fixed time.
        try await waitUntil { MathDocumentWebViewPool.shared.pendingRecycleCount == 0 }

        let second = MarkdownWebTestHarness()
        defer { second.close() }
        #expect(second.webView !== modifiedView)
    }

    @Test func streamedMathKeepsEarlierBlocksInPlace() async throws {
        let renderer = MarkdownWebTestHarness()
        defer { renderer.close() }
        renderer.update("$$a^2 + b^2$$\n\nFirst")
        try await renderer.waitFor("document.querySelector('.katex-display') !== null")
        _ = try await renderer.webView.evaluateJavaScript("document.querySelector('.katex-display').dataset.marker = 'kept'; true;")

        renderer.update("$$a^2 + b^2$$\n\nFirst and **more**")
        try await renderer.waitFor("document.querySelector('strong')?.textContent === 'more'")
        // The unchanged formula was neither re-typeset nor replaced.
        #expect(try await renderer.webView.evaluateJavaScript("document.querySelector('.katex-display').dataset.marker") as? String == "kept")
        #expect(try await renderer.webView.evaluateJavaScript("document.querySelectorAll('#content > p').length") as? Int == 2)

        renderer.update("Rewritten $x$")
        try await renderer.waitFor("document.querySelectorAll('.katex-display').length === 0")
        #expect(try await renderer.webView.evaluateJavaScript("document.querySelectorAll('.katex').length") as? Int == 1)
    }

    @Test func mathDocumentClosesNestedEnvironmentsAndRejectsDoubledDollars() async throws {
        let renderer = MarkdownWebTestHarness()
        defer { renderer.close() }
        renderer.update(#"""
        Nested: \begin{array}{c} \begin{array}{c} 1 \\ 2 \end{array} \end{array}

        Price $$5$ and \(y\).

        See https://example.com for more.
        """#)
        try await renderer.waitFor("document.querySelectorAll('.katex').length === 2")
        #expect(try await renderer.webView.evaluateJavaScript("document.querySelectorAll('.katex-error').length") as? Int == 0)
        let text = try #require(try await renderer.webView.evaluateJavaScript("""
        (() => { const clone = document.getElementById('content').cloneNode(true);
          clone.querySelectorAll('.katex').forEach(e => e.remove()); return clone.textContent; })()
        """) as? String)
        #expect(text.contains("$$5$"))
        #expect(!text.contains(#"\end{array}"#))
        // Bare URLs stay text, like in the native renderer.
        #expect(try await renderer.webView.evaluateJavaScript("document.querySelectorAll('a').length") as? Int == 0)
    }

    @Test func mathDocumentUsesTheNativeHeadingScale() throws {
        let html = try #require(RichMarkdownWebViewRepresentable.rendererHTML)
        for (index, scale) in MarkdownTypography.headingScales.enumerated() {
            #expect(html.contains("h\(index + 1) { font-size: \(scale)em; }"))
        }
        #expect(MarkdownTypography.headingScale(2) == 1.45)
        #expect(MarkdownTypography.headingScale(6) == 1)
        #expect(RichTextPalette.resolved(colorScheme: .dark, tone: .secondary)
                == RichTextPalette(colorScheme: .dark, tone: .secondary))
    }
}

// MARK: - Message bubbles

extension MinnowTests {
    @Test func reasoningTagsAreRecognisedInAnyCase() {
        #expect(Message(role: .assistant, text: "<think>Plan", order: 0).containsReasoningTags)
        #expect(Message(role: .assistant, text: "<Thinking>Plan</Thinking>Done", order: 0).containsReasoningTags)
        #expect(!Message(role: .assistant, text: "No tags here.", order: 0).containsReasoningTags)

        let tagged = Message(role: .assistant, text: "<Think>Let me look", order: 0, isFinal: false)
        // A tagged reply routes to the reasoning bubble, which shows its own search label.
        #expect(!MessageCellView.showsSearchingBelowText(message: tagged, isStreaming: true, activity: .searching))
    }

    @Test func replyThatOnlyMentionsAReasoningTagStaysAPlainAnswer() {
        let text = "Qwen wraps its reasoning in `<think>` tags before the answer."
        let message = Message(role: .assistant, text: text, order: 0)
        #expect(!message.containsReasoningTags)
        #expect(ReasoningTagParser.parse(text) == nil)
        // Leading whitespace before a real tag still counts as a tagged reply.
        #expect(ReasoningTagParser.parse("\n  <think>Plan</think>Answer") ==
                .init(reasoning: "Plan", finalAnswer: "Answer"))
    }

    @Test func unclosedReasoningTagIsReasoningNotTheAnswer() {
        #expect(ReasoningTagParser.parse("<thinking>Step 1, then step 2") ==
                .init(reasoning: "Step 1, then step 2", finalAnswer: ""))
        #expect(ReasoningTagParser.parse("<think>") == .init(reasoning: nil, finalAnswer: ""))
        #expect(ReasoningTagParser.parse("<THINK>Weigh it</THINK>\n\nFinal answer: 42") ==
                .init(reasoning: "Weigh it", finalAnswer: "42"))
        #expect(ReasoningTagParser.parse("Just an answer.") == nil)
        // Streaming parses skip the memo but agree with it.
        #expect(ReasoningTagParser.parse("<think>a</think>b", caching: false) ==
                ReasoningTagParser.parse("<think>a</think>b"))
    }

    @Test func sourcesSplitMatchesUserVisibleText() {
        for text in ["Plain answer.\n", "<sources>1. https://a.example</sources>\n\nAnswer.", "  "] {
            let message = Message(role: .assistant, text: text, order: 0)
            #expect(MessageSourcesSplit.visibleText(message.displayText) == message.userVisibleText)
        }
        let split = MessageSourcesSplit.split("A<sources>one</sources>B")
        #expect(split == .init(visible: "AB", sources: "one"))
    }
}

// MARK: - Reasoning sheet

extension MinnowTests {
    @Test func reasoningStepsKeepFencedCodeAndDisplayMathWhole() {
        let reasoning = """
        Step one.

        ```swift
        let a = 1

        let b = 2
        ```

        $$
        x = 1

        y = 2
        $$

        1. First

           Continued item.

        Step two.
        """
        let segments = ReasoningStepSegmenter.segments(from: reasoning)
        #expect(segments.map(\.text) == [
            "Step one.",
            "```swift\nlet a = 1\n\nlet b = 2\n```",
            "$$\nx = 1\n\ny = 2\n$$",
            "1. First\n\n   Continued item.",
            "Step two."
        ])
        #expect(segments.map(\.pieces) == [0...0, 1...2, 3...4, 5...6, 7...7])
        #expect(ReasoningStepSegmenter.segments(from: "").isEmpty)
        #expect(ReasoningStepSegmenter.segments(from: #"\begin{align} a \end{align}"#).count == 1)
    }

    @Test func reasoningSearchesFollowTheStepHoldingTheirAnchor() {
        let reasoning = "Step one.\n\n```\na\n\nb\n```\n\nStep two."
        let leading = SearchInvocation(query: "first", results: "", anchorStepNumber: 0)
        // Anchored after the second blank-line piece, which sits inside the fence.
        let insideFence = SearchInvocation(query: "middle", results: "", anchorStepNumber: 2)
        let trailing = SearchInvocation(query: "last", results: "", anchorStepNumber: 9)
        let items = StepByStepReasoningSheet.makeTimeline(
            reasoning: reasoning,
            searchInvocations: [trailing, insideFence, leading]
        )
        #expect(items.map(\.id) == [
            "search-\(leading.id.uuidString)",
            "reasoning-0",
            "reasoning-1",
            "search-\(insideFence.id.uuidString)",
            "reasoning-3",
            "search-\(trailing.id.uuidString)"
        ])
        #expect(StepByStepReasoningSheet.makeTimeline(reasoning: "", searchInvocations: nil).isEmpty)
    }
}

// MARK: - Composer and small views

extension MinnowTests {
    @Test func composerHeightFollowsTheProposedWidth() {
        let textView = UITextView()
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.text = String(repeating: "A restored draft that wraps. ", count: 3)

        let wide = ComposerTextView.fittingHeight(of: textView, width: 600, maxHeight: 112)
        let narrow = ComposerTextView.fittingHeight(of: textView, width: 160, maxHeight: 112)
        #expect(wide.height >= ComposerTextView.minimumHeight)
        #expect(narrow.height > wide.height)
        #expect(!wide.scrolls)

        textView.text = String(repeating: "Line\n", count: 20)
        let tall = ComposerTextView.fittingHeight(of: textView, width: 300, maxHeight: 112)
        #expect(tall.height == 112)
        #expect(tall.scrolls)

        textView.text = ""
        #expect(ComposerTextView.fittingHeight(of: textView, width: 300, maxHeight: 112).height == ComposerTextView.minimumHeight)
    }

    @Test func shiftReturnInsertsALineBreakEvenWhenReturnSends() throws {
        let textView = KeyboardSendingTextView()
        var lineBreaks = 0
        textView.onShiftReturn = { lineBreaks += 1 }
        let command = try #require(textView.keyCommands?.first {
            $0.input == "\r" && $0.modifierFlags == .shift
        })
        #expect(command.wantsPriorityOverSystemBehavior)
        let action = try #require(command.action)
        textView.perform(action)
        #expect(lineBreaks == 1)
        // Key commands are built once, not on every query.
        #expect(textView.keyCommands?.last === textView.keyCommands?.last)

        var sends = 0
        let coordinator = ComposerTextView(
            text: .constant("Hello"),
            isFocused: .constant(true),
            sendOnReturn: true,
            canSend: true,
            isGenerating: false,
            maxHeight: 120,
            onSend: { sends += 1 }
        ).makeCoordinator()
        let field = UITextView()
        field.text = "Hello"
        field.selectedRange = NSRange(location: 5, length: 0)
        field.delegate = coordinator
        coordinator.insertLineBreak(in: field)
        #expect(field.text == "Hello\n")
        #expect(sends == 0)
    }

    @Test func loadingDotsCycleWithTheClock() {
        let interval = LoadingDotsLabel.dotInterval
        let counts = (0..<6).map {
            LoadingDotsLabel.dotCount(at: Date(timeIntervalSinceReferenceDate: 3_000 * interval + Double($0) * interval))
        }
        #expect(counts == [1, 2, 3, 1, 2, 3])
        // A timeline entry a hair early does not repeat the previous count.
        let early = LoadingDotsLabel.dotCount(at: Date(timeIntervalSinceReferenceDate: 3_001 * interval - 0.000_01))
        #expect(early == counts[1])
    }

    @Test func fullscreenDismissDragOnlyMovesTheImageDown() {
        #expect(FullscreenImageView.dismissDragOffset(for: CGSize(width: 12, height: 40)) == CGSize(width: 0, height: 40))
        // Dragging back above the start returns the page to rest.
        #expect(FullscreenImageView.dismissDragOffset(for: CGSize(width: 0, height: -30)) == .zero)
    }

    #if DEBUG
    @Test func mathPreviewFixtureKeepsItsMathThroughEveryStage() {
        for stage in 0...2 {
            #expect(RichTextFeatureDetector.requiresAdvancedRendering(MarkdownRenderingPreview.text(forStage: stage, math: true)))
        }
        #expect(MarkdownRenderingPreview.text(forStage: 2, math: true).hasSuffix("Last **paragraph**."))
        #expect(!RichTextFeatureDetector.requiresAdvancedRendering(MarkdownRenderingPreview.text(forStage: 1, math: false)))
    }
    #endif
}

// MARK: - Navigation policy stubs

@MainActor
private final class NavigationPolicyRecorder {
    var policy: WKNavigationActionPolicy?
}

/// A link activation in a subframe-less document, with only the request WebKit
/// would report.
private final class StubNavigationAction: WKNavigationAction {
    private let stubRequest: URLRequest

    init(url: URL) {
        stubRequest = URLRequest(url: url)
        super.init()
    }

    override var request: URLRequest { stubRequest }
    override var targetFrame: WKFrameInfo? { nil }
}
