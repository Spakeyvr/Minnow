//
//  ChatLLMUITests.swift
//  ChatLLMUITests
//
//  Created by Nevio on 10/24/25.
//

import XCTest
import CoreGraphics
import UIKit

final class ChatLLMUITests: XCTestCase {
    /// Launch-time measurements take several cold launches, so they only run on request.
    static var runsPerformanceTests: Bool {
        ProcessInfo.processInfo.environment["CHATLLM_RUN_PERFORMANCE_TESTS"] == "1"
    }

    private let firstMLXModelID = "qwen3.5-4b-4bit-hybrid"
    private let secondMLXModelID = "qwen3.5-2b-4bit"

    @MainActor
    func testMarkdownRendersDuringAndAfterStreamingInBothBubbleTypes() throws {
        for reasoning in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-markdown"]
            if reasoning { app.launchArguments.append("-ui-test-markdown-reasoning") }
            app.launch()

            // Each paragraph is its own element now, and a soft break stays inside one.
            let firstParagraph = app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS %@", "First bold word"))
                .firstMatch
            XCTAssertTrue(firstParagraph.waitForExistence(timeout: 5))
            XCTAssertTrue(firstParagraph.label.contains("Next line."))
            XCTAssertFalse(firstParagraph.label.contains("Second paragraph"))

            let secondParagraph = app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS %@", "Second paragraph with italic text"))
                .firstMatch
            XCTAssertTrue(secondParagraph.exists)
            XCTAssertTrue(secondParagraph.label.contains("first_name"))
            assertLabel(of: app.staticTexts["markdown.status"], becomes: "Streaming")
            captureSettingsScreenshot("markdown-\(reasoning ? "reasoning" : "standard")-paragraphs", in: app)

            app.buttons["markdown.advance"].tap()
            // Headings, lists and code are laid out natively — no WebView involved.
            XCTAssertTrue(app.staticTexts["Live heading"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["First item"].exists)
            XCTAssertTrue(app.staticTexts["Second item"].exists)
            XCTAssertTrue(app.staticTexts["let first_name = 1"].exists)
            XCTAssertFalse(app.webViews.firstMatch.exists)
            assertLabel(of: app.staticTexts["markdown.status"], becomes: "Streaming")
            captureSettingsScreenshot("markdown-\(reasoning ? "reasoning" : "standard")-streaming", in: app)

            app.buttons["markdown.advance"].tap()
            XCTAssertTrue(app.staticTexts["Last paragraph."].waitForExistence(timeout: 5))
            assertLabel(of: app.staticTexts["markdown.status"], becomes: "Finished")
            XCTAssertTrue(app.staticTexts["First item"].exists)
            XCTAssertFalse(app.webViews.firstMatch.exists)
            captureSettingsScreenshot("markdown-\(reasoning ? "reasoning" : "standard")-finished", in: app)
            app.terminate()
        }
    }

    @MainActor
    func testCodeBlockOffersItsOwnCopyButton() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-markdown"]
        app.launch()
        XCTAssertTrue(app.buttons["markdown.advance"].waitForExistence(timeout: 5))
        app.buttons["markdown.advance"].tap()
        XCTAssertTrue(app.staticTexts["let first_name = 1"].waitForExistence(timeout: 5))

        // Long-pressing opens the whole message's menu, so code gets a button of its own.
        XCTAssertTrue(app.staticTexts["swift"].exists)
        let copy = app.buttons["markdown.copyCode"]
        XCTAssertTrue(copy.exists)
        XCTAssertGreaterThanOrEqual(copy.frame.height, 44)
        XCTAssertEqual(copy.label, "Copy Code")
        copy.tap()
        assertLabel(of: copy, becomes: "Copied")
        let restored = expectation(for: NSPredicate(format: "label == %@", "Copy Code"), evaluatedWith: copy)
        wait(for: [restored], timeout: 4)
    }

    @MainActor
    func testFinishedReplyOffersCopyFirstInItsActionsRow() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ui-test-reset-app-state",
            "-ui-test-web-search-demo",
            "-ui-test-web-search-without-reasoning"
        ]
        app.launch()

        let sources = app.buttons["message.sources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        let copy = app.buttons["message.copy"]
        XCTAssertTrue(copy.exists)
        XCTAssertGreaterThanOrEqual(copy.frame.height, 44)
        XCTAssertLessThan(copy.frame.minX, app.buttons["Regenerate"].frame.minX)
        XCTAssertLessThan(copy.frame.minX, sources.frame.minX)

        XCTAssertEqual(copy.label, "Copy")
        copy.tap()
        assertLabel(of: copy, becomes: "Copied")
        let restored = expectation(for: NSPredicate(format: "label == %@", "Copy"), evaluatedWith: copy)
        wait(for: [restored], timeout: 4)
    }

    @MainActor
    func testTableCellsFillTheirColumn() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-markdown"]
        app.launch()
        XCTAssertTrue(app.buttons["markdown.advance"].waitForExistence(timeout: 5))
        app.buttons["markdown.advance"].tap()

        let header = app.staticTexts["Fruit"]
        let shortCell = app.staticTexts["Fig"]
        let longCell = app.staticTexts["Strawberry"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertTrue(shortCell.exists)
        XCTAssertTrue(longCell.exists)
        // Short cells used to hug their text, so the header shading stopped short of
        // the column edge. Past "Fruit", under the end of "Strawberry", it must match
        // the shading at the start of the header cell.
        let screenshot = app.screenshot().image
        let insideHeader = CGPoint(x: header.frame.minX - 4, y: header.frame.midY)
        let pastShortHeader = CGPoint(x: longCell.frame.maxX - 2, y: header.frame.midY)
        let insideFirstRow = CGPoint(x: longCell.frame.maxX - 2, y: shortCell.frame.midY)
        XCTAssertGreaterThan(longCell.frame.maxX - 2, header.frame.maxX + 20)
        XCTAssertEqual(brightness(of: screenshot, at: pastShortHeader), brightness(of: screenshot, at: insideHeader), accuracy: 0.01)
        XCTAssertNotEqual(brightness(of: screenshot, at: pastShortHeader), brightness(of: screenshot, at: insideFirstRow), accuracy: 0.01)
    }

    private func brightness(of image: UIImage, at point: CGPoint) -> CGFloat {
        guard let cgImage = image.cgImage else { return -1 }
        let scale = CGFloat(cgImage.width) / image.size.width
        var pixel: [UInt8] = [0, 0, 0, 0]
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(cgImage, in: CGRect(
            x: -point.x * scale, y: -(CGFloat(cgImage.height) - point.y * scale),
            width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)
        ))
        return (CGFloat(pixel[0]) + CGFloat(pixel[1]) + CGFloat(pixel[2])) / (3 * 255)
    }

    @MainActor
    func testMathStillRendersThroughTheBundledDocument() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-markdown", "-ui-test-markdown-math"]
        app.launch()

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 10))
        captureSettingsScreenshot("markdown-math", in: app)
        app.terminate()
    }

    /// `fastFakeDownloads` finishes fake downloads at once, for tests that wait for
    /// a download to complete rather than look at its progress.
    @MainActor
    private func launchApp(
        resetAppState: Bool = true,
        fakeMLXDownloads: Bool = false,
        fastFakeDownloads: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        if resetAppState {
            app.launchArguments.append("-ui-test-reset-app-state")
        }
        if fakeMLXDownloads {
            app.launchArguments.append("-ui-test-fake-mlx-downloads")
        }
        if fastFakeDownloads {
            app.launchArguments.append("-ui-test-fast-fake-mlx-downloads")
        }
        app.launch()
        return app
    }

    @MainActor
    private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFreshLaunchShowsOnboarding() throws {
        let app = launchApp()

        XCTAssertTrue(app.otherElements["onboarding.root"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["onboarding.intro.title"].exists)
        XCTAssertFalse(app.otherElements["content.root"].exists)
    }

    @MainActor
    func testSkippingOnboardingPersistsCompletionAcrossLaunches() throws {
        let app = launchApp()

        app.buttons["onboarding.skip"].tap()
        XCTAssertTrue(app.otherElements["content.root"].waitForExistence(timeout: 5))

        app.terminate()

        let relaunchedApp = launchApp(resetAppState: false)
        XCTAssertTrue(relaunchedApp.otherElements["content.root"].waitForExistence(timeout: 5))
        XCTAssertFalse(relaunchedApp.otherElements["onboarding.root"].exists)
    }

    @MainActor
    func testTavilyKeyEntryDoesNotShowOnboardingAgain() throws {
        let app = launchApp()

        app.buttons["onboarding.intro.continue"].tap()

        let keyField = app.secureTextFields["onboarding.tavily.key"]
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        keyField.tap()
        keyField.typeText("tvly-test-key")

        app.buttons["onboarding.tavily.continue"].tap()
        app.buttons["onboarding.finish"].tap()
        XCTAssertTrue(app.otherElements["content.root"].waitForExistence(timeout: 5))

        app.terminate()

        let relaunchedApp = launchApp(resetAppState: false)
        XCTAssertTrue(relaunchedApp.otherElements["content.root"].waitForExistence(timeout: 5))
        XCTAssertFalse(relaunchedApp.otherElements["onboarding.root"].exists)
    }

    @MainActor
    func testSkippingAfterTypingATavilyKeyKeepsTheKey() throws {
        let app = launchApp()
        assertLabel(of: element(in: app, identifier: "onboarding.progress"), becomes: "Step 1 of 3")

        app.buttons["onboarding.intro.continue"].tap()
        let keyField = app.secureTextFields["onboarding.tavily.key"]
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        assertLabel(of: element(in: app, identifier: "onboarding.progress"), becomes: "Step 2 of 3")
        keyField.tap()
        keyField.typeText("tvly-test-key")

        app.buttons["onboarding.skip"].tap()
        XCTAssertTrue(app.otherElements["content.root"].waitForExistence(timeout: 5))
        app.buttons["Add attachment or web search"].tap()
        XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["composer.webSearchUnavailableReason"].exists)
    }

    @MainActor
    func testStartingMLXDownloadAllowsFinishingOnboarding() throws {
        let app = launchApp(fakeMLXDownloads: true)

        app.buttons["onboarding.intro.continue"].tap()
        app.buttons["onboarding.tavily.continue"].tap()

        let downloadButton = app.buttons["onboarding.mlx.download"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 5))
        downloadButton.tap()

        XCTAssertTrue(element(in: app, identifier: "onboarding.mlx.progress.\(firstMLXModelID)").waitForExistence(timeout: 5))

        app.buttons["onboarding.finish"].tap()
        XCTAssertTrue(app.otherElements["content.root"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testChangingSelectedModelDoesNotMoveActiveDownloadProgress() throws {
        let app = launchApp(fakeMLXDownloads: true)

        app.buttons["onboarding.intro.continue"].tap()
        app.buttons["onboarding.tavily.continue"].tap()

        let downloadButton = app.buttons["onboarding.mlx.download"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 5))
        downloadButton.tap()

        let firstProgress = element(in: app, identifier: "onboarding.mlx.progress.\(firstMLXModelID)")
        XCTAssertTrue(firstProgress.waitForExistence(timeout: 5))

        let secondModelButton = app.buttons["onboarding.mlx.model.\(secondMLXModelID)"]
        XCTAssertTrue(secondModelButton.waitForExistence(timeout: 5))
        secondModelButton.tap()

        XCTAssertTrue(firstProgress.waitForExistence(timeout: 2))
        XCTAssertFalse(element(in: app, identifier: "onboarding.mlx.progress.\(secondMLXModelID)").exists)
    }

    @MainActor
    func testDownloadedModelIsMarkedAndNamedPlainlyInTheMenu() throws {
        let app = launchApp(fakeMLXDownloads: true, fastFakeDownloads: true)
        XCTAssertTrue(app.buttons["onboarding.skip"].waitForExistence(timeout: 5))
        app.buttons["onboarding.skip"].tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))

        app.navigationBars.staticTexts["Apple Intelligence"].firstMatch.tap()
        app.buttons["Manage Models"].tap()
        let download = app.buttons["modelSelection.download.qwen3.5-0.8b-4bit"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        download.tap()
        XCTAssertTrue(element(in: app, identifier: "modelSelection.downloaded.qwen3.5-0.8b-4bit").waitForExistence(timeout: 5))
        // The icon-only row buttons are named for VoiceOver.
        XCTAssertTrue(app.buttons["Delete"].exists)
        XCTAssertTrue(app.buttons["Model Information"].firstMatch.exists)
        app.buttons["Done"].tap()

        app.navigationBars.staticTexts["Apple Intelligence"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Qwen 3.5 0.8B (4-bit)"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testSearchOnlyResponseShowsSourcesWithoutThoughtSummary() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ui-test-reset-app-state",
            "-ui-test-web-search-demo",
            "-ui-test-web-search-without-reasoning"
        ]
        app.launch()

        XCTAssertTrue(app.buttons["message.sources"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["message.thought"].exists)
    }

    @MainActor
    func testReasonedResponseShowsTappableThoughtDuration() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ui-test-reset-app-state",
            "-ui-test-web-search-demo"
        ]
        app.launch()

        let thoughtSummary = app.buttons["message.thought"]
        XCTAssertTrue(thoughtSummary.waitForExistence(timeout: 5))
        XCTAssertEqual(thoughtSummary.label, "Thought for 1 minute and 8 seconds")
        XCTAssertTrue(app.buttons["message.sources"].exists)

        thoughtSummary.tap()
        XCTAssertTrue(app.navigationBars["Reasoning"].waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "</think>")).count,
            0
        )
    }

    @MainActor
    func testDeletingTheSelectedModelLeavesItUnselected() throws {
        let app = launchApp(fakeMLXDownloads: true, fastFakeDownloads: true)
        XCTAssertTrue(app.buttons["onboarding.skip"].waitForExistence(timeout: 5))
        app.buttons["onboarding.skip"].tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))

        app.navigationBars.staticTexts["Apple Intelligence"].firstMatch.tap()
        app.buttons["Manage Models"].tap()
        let download = app.buttons["modelSelection.download.qwen3.5-0.8b-4bit"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        download.tap()
        XCTAssertTrue(element(in: app, identifier: "modelSelection.downloaded.qwen3.5-0.8b-4bit").waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        app.navigationBars.staticTexts["Apple Intelligence"].firstMatch.tap()
        app.buttons["Qwen 3.5 0.8B (4-bit)"].tap()
        let qwenTitle = app.navigationBars.staticTexts["Qwen 3.5 0.8B (4-bit)"].firstMatch
        XCTAssertTrue(qwenTitle.waitForExistence(timeout: 3))

        // The fake download has no files, so the load failed; Manage Models reports it.
        qwenTitle.tap()
        app.buttons["Manage Models"].tap()
        let loadError = app.alerts["Model Error"]
        XCTAssertTrue(loadError.waitForExistence(timeout: 5))
        loadError.buttons["OK"].tap()
        XCTAssertTrue(loadError.waitForNonExistence(timeout: 3))

        app.buttons["Delete"].firstMatch.tap()
        let confirmDelete = app.alerts.buttons["Delete"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 3))
        confirmDelete.tap()
        app.buttons["Done"].tap()

        XCTAssertTrue(qwenTitle.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testShortChatStaysBelowTheTopEdgeAfterPresentingASheet() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ui-test-reset-app-state",
            "-ui-test-web-search-demo"
        ]
        app.launch()

        let question = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "What changed in SwiftUI web views"))
            .firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        XCTAssertTrue(question.isHittable)

        // Presenting and dismissing a sheet must not re-apply a scroll that hides the first message.
        let thoughtSummary = app.buttons["message.thought"]
        XCTAssertTrue(thoughtSummary.waitForExistence(timeout: 5))
        thoughtSummary.tap()
        let reasoningNavigationBar = app.navigationBars["Reasoning"]
        XCTAssertTrue(reasoningNavigationBar.waitForExistence(timeout: 5))
        let start = reasoningNavigationBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(reasoningNavigationBar.waitForNonExistence(timeout: 5))

        XCTAssertTrue(question.isHittable)
    }

    @MainActor
    func testLongChatOpensAtTheLatestMessage() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ui-test-reset-app-state",
            "-ui-test-web-search-demo",
            "-ui-test-long-chat"
        ]
        app.launch()

        XCTAssertTrue(app.buttons["message.sources"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["message.sources"].isHittable)
        XCTAssertFalse(app.staticTexts["Earlier message 1"].isHittable)
    }

    @MainActor
    func testScrollingUpOffersAWayBackToTheLatestMessage() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ui-test-reset-app-state",
            "-ui-test-web-search-demo",
            "-ui-test-long-chat"
        ]
        app.launch()

        let sources = app.buttons["message.sources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        let jump = app.buttons["chat.scrollToLatest"]
        XCTAssertFalse(jump.exists)

        app.scrollViews.firstMatch.swipeDown()
        XCTAssertTrue(jump.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(jump.frame.height, 44)

        jump.tap()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 3))
        XCTAssertTrue(sources.isHittable)
    }

    @MainActor
    func testReturningToTheAppKeepsTheReadersScrollPosition() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ui-test-reset-app-state",
            "-ui-test-web-search-demo",
            "-ui-test-long-chat"
        ]
        app.launch()

        XCTAssertTrue(app.buttons["message.sources"].waitForExistence(timeout: 5))
        let firstMessage = app.staticTexts["Earlier message 1"]
        for _ in 0..<6 where !firstMessage.isHittable {
            app.scrollViews.firstMatch.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(firstMessage.isHittable)

        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(app.staticTexts["Earlier message 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(firstMessage.isHittable)
        XCTAssertFalse(app.buttons["message.sources"].isHittable)
    }

    @MainActor
    func testReasoningSheetRendersContentExposedByExpansion() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ui-test-reset-app-state",
            "-ui-test-web-search-demo",
            "-ui-test-long-reasoning-demo"
        ]
        app.launch()

        let thoughtSummary = app.buttons["message.thought"]
        XCTAssertTrue(thoughtSummary.waitForExistence(timeout: 5))
        thoughtSummary.tap()

        let reasoningNavigationBar = app.navigationBars["Reasoning"]
        XCTAssertTrue(reasoningNavigationBar.waitForExistence(timeout: 5))
        let start = reasoningNavigationBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        start.press(forDuration: 0.1, thenDragTo: end)

        let newlyExposedText = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@",
                "This newly exposed reasoning must appear immediately when the sheet expands."
            )
        ).firstMatch
        XCTAssertTrue(newlyExposedText.waitForExistence(timeout: 5))
        XCTAssertTrue(newlyExposedText.isHittable)
    }

    @MainActor
    func testOpeningAnotherChatAfterReturningToListShowsIt() throws {
        let fixture = XCUIApplication()
        fixture.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo", "-ui-test-second-chat"]
        fixture.launch()
        XCTAssertTrue(fixture.buttons["message.sources"].waitForExistence(timeout: 5))
        fixture.terminate()

        // Relaunch without the demo selection so the app opens into a fresh chat.
        let app = launchApp(resetAppState: false)
        openSidebar(in: app)
        let secondChatRow = app.staticTexts["Second Chat"]
        XCTAssertTrue(secondChatRow.waitForExistence(timeout: 5))
        secondChatRow.tap()
        XCTAssertTrue(app.staticTexts["Second chat reply."].waitForExistence(timeout: 5))

        openSidebar(in: app)
        let demoChatRow = app.staticTexts["Web Search Preview"]
        XCTAssertTrue(demoChatRow.waitForExistence(timeout: 5))
        demoChatRow.tap()

        XCTAssertTrue(app.buttons["message.sources"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Preparing chat…"].exists)
    }

    @MainActor
    func testSelectingSearchResultClosesDrawerAndKeyboard() throws {
        let fixture = XCUIApplication()
        fixture.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo", "-ui-test-second-chat"]
        fixture.launch()
        XCTAssertTrue(fixture.buttons["message.sources"].waitForExistence(timeout: 5))
        fixture.terminate()

        let app = launchApp(resetAppState: false)
        openSidebar(in: app)
        app.buttons["Search"].firstMatch.tap()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.typeText("Second")

        let result = app.staticTexts["Second Chat"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()

        XCTAssertTrue(app.staticTexts["Second chat reply."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sidebar.dismiss"].exists)
        let keyboardGone = NSPredicate(format: "exists == false")
        expectation(for: keyboardGone, evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 3)
    }

    @MainActor
    func testRenamingAChatKeepsItsPlaceInTheSidebar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo", "-ui-test-second-chat"]
        app.launch()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))

        openSidebar(in: app)
        let olderRow = app.staticTexts["Web Search Preview"]
        XCTAssertTrue(olderRow.waitForExistence(timeout: 5))
        olderRow.press(forDuration: 1.0)
        let rename = app.buttons["Rename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 3))
        rename.tap()

        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        let existing = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + "Swift Notes")
        app.alerts.buttons["Save"].tap()

        let renamedRow = app.staticTexts["Swift Notes"]
        XCTAssertTrue(renamedRow.waitForExistence(timeout: 3))
        let newerRow = app.staticTexts["Second Chat"]
        XCTAssertLessThan(newerRow.frame.minY, renamedRow.frame.minY)
    }

    @MainActor
    func testRenameFieldCanBeClearedInOneTap() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo"]
        app.launch()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))

        openSidebar(in: app)
        let row = app.staticTexts["Web Search Preview"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1.0)
        app.buttons["Rename"].tap()

        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        app.alerts.buttons["Clear text"].tap()
        field.typeText("Web Notes\n")

        XCTAssertTrue(app.staticTexts["Web Notes"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    @MainActor
    func testDeletingTheOpenChatOpensABlankChat() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo", "-ui-test-second-chat"]
        app.launch()
        let demoMessage = app.staticTexts["What changed in SwiftUI web views this year?"]
        XCTAssertTrue(demoMessage.waitForExistence(timeout: 5))

        openSidebar(in: app)
        let demoChatRow = app.staticTexts["Web Search Preview"]
        XCTAssertTrue(demoChatRow.waitForExistence(timeout: 5))
        demoChatRow.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        // Deleting a chat asks first.
        let confirm = app.alerts["Delete Chat?"].buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Web Search Preview"].waitForNonExistence(timeout: 3))

        // The sidebar stays open for further edits while a blank chat takes the open chat's place.
        XCTAssertTrue(app.buttons["sidebar.dismiss"].exists)
        XCTAssertTrue(app.staticTexts["Second Chat"].exists)
        app.buttons["sidebar.dismiss"].tap()

        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(demoMessage.exists)
        XCTAssertFalse(app.staticTexts["Select a Conversation"].exists)
    }

    @MainActor
    func testDeletingAChatFromItsContextMenuAsksFirst() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo", "-ui-test-second-chat"]
        app.launch()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))

        openSidebar(in: app)
        let row = app.staticTexts["Second Chat"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let confirmation = app.alerts["Delete Chat?"]

        // Cancelling keeps the chat.
        row.press(forDuration: 1.0)
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 3))
        XCTAssertTrue(row.exists)

        // Confirming deletes it and leaves the other chats alone.
        row.press(forDuration: 1.0)
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.buttons["Delete"].tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Web Search Preview"].exists)
    }

    @MainActor
    func testSwipingToDeleteAChatAsksFirstEvenAfterAFullSwipe() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo", "-ui-test-second-chat"]
        app.launch()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))

        openSidebar(in: app)
        let row = app.staticTexts["Second Chat"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        // A swipe across the whole row only reveals the action; nothing is deleted yet.
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -app.frame.width, dy: 0)))
        let confirmation = app.alerts["Delete Chat?"]
        XCTAssertFalse(confirmation.exists)
        XCTAssertTrue(row.exists)

        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 3))
        XCTAssertTrue(row.exists)
    }

    @MainActor
    func testNewChatDoesNotInheritAnEditInProgress() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo"]
        app.launch()
        let messageText = "What changed in SwiftUI web views this year?"
        let message = app.staticTexts[messageText]
        XCTAssertTrue(message.waitForExistence(timeout: 5))

        message.press(forDuration: 1.0)
        app.buttons["Edit"].tap()
        let composer = app.textViews.firstMatch
        XCTAssertTrue(app.buttons["chat.edit.cancel"].waitForExistence(timeout: 3))
        assertValue(of: composer, becomes: messageText)

        openSidebar(in: app)
        app.buttons["New Chat"].firstMatch.tap()
        XCTAssertTrue(message.waitForNonExistence(timeout: 5))

        // The new chat's composer is empty and not editing the other chat's message.
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.edit.cancel"].exists)
        XCTAssertFalse((composer.value as? String ?? "").contains(messageText))
    }

    @MainActor
    func testComposerTextAndImageStayWithTheirChat() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-test-reset-app-state", "-ui-test-web-search-demo",
            "-ui-test-second-chat", "-ui-test-composer-image"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["message.sources"].waitForExistence(timeout: 5))
        let attachedImage = app.staticTexts["Image attached"]
        XCTAssertTrue(attachedImage.waitForExistence(timeout: 5))

        let draft = "Draft for the demo chat"
        let composer = app.textViews.firstMatch
        composer.tap()
        composer.typeText(draft)
        assertValue(of: composer, becomes: draft)

        openSidebar(in: app)
        let secondChatRow = app.staticTexts["Second Chat"]
        XCTAssertTrue(secondChatRow.waitForExistence(timeout: 5))
        secondChatRow.tap()
        XCTAssertTrue(app.staticTexts["Second chat reply."].waitForExistence(timeout: 5))

        // The other chat's composer starts empty: neither the text nor the image followed.
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertFalse((composer.value as? String ?? "").contains(draft))
        XCTAssertFalse(attachedImage.exists)
        XCTAssertFalse(app.buttons["Remove Image"].exists)
    }

    @MainActor
    func testDeletingAllChatsFromADraftKeepsTheComposer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["What changed in SwiftUI web views this year?"].waitForExistence(timeout: 5))

        // Open a blank draft, then delete every saved chat from Settings.
        openSidebar(in: app)
        app.buttons["New Chat"].firstMatch.tap()
        openSettings(in: app)
        app.buttons["settings.privacy"].tap()
        app.buttons["settings.deleteAllChats"].tap()
        let confirm = app.alerts.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()

        // The draft stays usable instead of being replaced by a dead placeholder.
        // Settings was opened from the sidebar, which is still open behind it.
        let dismissSidebar = app.buttons["sidebar.dismiss"]
        XCTAssertTrue(dismissSidebar.waitForExistence(timeout: 3))
        dismissSidebar.tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Start a New Chat"].exists)
    }

    @MainActor
    func testKeyboardShortcutsStartAChatAndOpenSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo"]
        app.launch()
        let message = app.staticTexts["What changed in SwiftUI web views this year?"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        // The simulator hands the first key press after launch to the system.
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(message.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.textViews.firstMatch.exists)

        // The menu command opens ChatLLM's settings, not the app's page in the Settings app.
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["settings.appearance"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testReplyActionsHaveFullSizeTapTargets() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo"]
        app.launch()
        let regenerate = app.buttons["Regenerate"].firstMatch
        XCTAssertTrue(regenerate.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.buttons["message.sources"].frame.height, 44)

        // The icon is about 20 points; a tap just below it should still open the menu.
        regenerate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: 16))
            .tap()
        XCTAssertTrue(app.buttons["Try again"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testSheetsHaveACloseButton() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo"]
        app.launch()
        XCTAssertTrue(app.buttons["message.sources"].waitForExistence(timeout: 5))

        app.buttons["message.sources"].tap()
        XCTAssertTrue(app.buttons["sources.query.0"].waitForExistence(timeout: 3))
        app.buttons["sheet.close"].tap()
        XCTAssertTrue(app.buttons["sources.query.0"].waitForNonExistence(timeout: 3))

        app.buttons["message.thought"].tap()
        XCTAssertTrue(app.navigationBars["Reasoning"].waitForExistence(timeout: 3))
        app.buttons["sheet.close"].tap()
        XCTAssertTrue(app.navigationBars["Reasoning"].waitForNonExistence(timeout: 3))

        app.buttons["Add attachment or web search"].tap()
        XCTAssertTrue(app.navigationBars["Add to Chat"].waitForExistence(timeout: 3))
        app.buttons["sheet.close"].tap()
        XCTAssertTrue(app.navigationBars["Add to Chat"].waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testUnavailableWebSearchExplainsWhy() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo"]
        app.launch()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))

        // No Tavily key is configured after a reset.
        app.buttons["Add attachment or web search"].tap()
        let reason = app.staticTexts["composer.webSearchUnavailableReason"]
        XCTAssertTrue(reason.waitForExistence(timeout: 3))
        XCTAssertTrue(reason.label.contains("Tavily"))
    }

    @MainActor
    func testEditingTheFirstMessageKeepsTheModelLocked() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo"]
        app.launch()
        let message = app.staticTexts["What changed in SwiftUI web views this year?"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Manage Models"].exists)

        message.press(forDuration: 1.0)
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.buttons["chat.edit.cancel"].waitForExistence(timeout: 3))

        // The title stays a plain label rather than the model menu. The tap returns
        // once the app is idle, so a menu would already be showing.
        app.navigationBars.staticTexts["Apple Intelligence"].firstMatch.tap()
        XCTAssertTrue(app.buttons["chat.edit.cancel"].exists)
        XCTAssertFalse(app.buttons["Manage Models"].exists)
    }

    @MainActor
    func testImageAttachmentOpensFullScreenAndCloses() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo", "-ui-test-image-message"]
        app.launch()
        let thumbnail = app.buttons["Attached image"]
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 5))

        thumbnail.tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3))

        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.textViews.firstMatch.exists)
    }

    @MainActor
    func testFullScreenImageCanBeShared() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo", "-ui-test-image-message"]
        app.launch()
        let thumbnail = app.buttons["Attached image"]
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 5))
        thumbnail.tap()

        // A photo taken with the in-app camera exists only in the chat.
        let share = app.buttons["imageViewer.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 3))
        share.tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDoubleTappingAFullScreenImageZoomsInAndOut() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo", "-ui-test-image-message"]
        app.launch()
        let thumbnail = app.buttons["Attached image"]
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 5))
        thumbnail.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 3))

        let viewer = app.scrollViews.firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 3))
        XCTAssertEqual(viewer.value as? String, "100%")
        viewer.doubleTap()
        expectation(for: NSPredicate(format: "value == %@", "250%"), evaluatedWith: viewer)
        waitForExpectations(timeout: 3)
        viewer.doubleTap()
        expectation(for: NSPredicate(format: "value == %@", "100%"), evaluatedWith: viewer)
        waitForExpectations(timeout: 3)

        // At normal size a downward swipe still dismisses the viewer.
        let start = viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 300)))
        XCTAssertTrue(app.buttons["Done"].waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testVoiceOverSkipsTheChatMessagesBehindTheOpenSidebar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo"]
        app.launch()
        XCTAssertTrue(app.buttons["message.sources"].waitForExistence(timeout: 5))

        openSidebar(in: app)
        XCTAssertTrue(app.buttons["message.sources"].waitForNonExistence(timeout: 3))
        app.buttons["sidebar.dismiss"].tap()
        XCTAssertTrue(app.buttons["message.sources"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testAttachedImageCanBeRemovedBeforeSending() throws {
        // The image is seeded into the composer as if just picked, so the test doesn't
        // depend on the simulator's sample photo library.
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo", "-ui-test-composer-image"]
        app.launch()
        XCTAssertTrue(app.buttons["message.sources"].waitForExistence(timeout: 5))

        let remove = app.buttons["Remove Image"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Image attached"].exists)
        remove.tap()
        XCTAssertTrue(app.staticTexts["Image attached"].waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testAttachOptionsStackAtAccessibilityTextSizes() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-test-reset-app-state", "-ui-test-web-search-demo",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["message.sources"].waitForExistence(timeout: 8))

        app.buttons["Add attachment or web search"].tap()
        let photos = app.buttons["Photos"]
        let files = app.buttons["Files"]
        XCTAssertTrue(photos.waitForExistence(timeout: 3))
        // Side by side, each label would be cut to a few letters.
        XCTAssertGreaterThanOrEqual(files.frame.minY, photos.frame.maxY)
        XCTAssertGreaterThan(photos.frame.width, app.frame.width * 0.6)
    }

    @MainActor
    func testUnavailableReasoningSwitchesExplainWhy() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo"]
        app.launch()
        XCTAssertTrue(app.buttons["message.sources"].waitForExistence(timeout: 5))

        // The demo chat uses Apple Intelligence, which has no reasoning mode.
        app.buttons["Add attachment or web search"].tap()
        let reason = app.staticTexts["composer.reasoningUnavailableReason"]
        XCTAssertTrue(reason.waitForExistence(timeout: 3))
        XCTAssertEqual(reason.label, "Reasoning needs a downloaded model that supports it.")
        // The demo chat was saved with reasoning on, but it can't apply here.
        let alwaysReason = app.switches.matching(NSPredicate(format: "label CONTAINS 'Always Reason'")).firstMatch
        XCTAssertEqual(alwaysReason.value as? String, "0")
    }

    @MainActor
    func testSwipingRightFromAMessageOpensTheSidebar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo"]
        app.launch()
        let userMessage = app.staticTexts["What changed in SwiftUI web views this year?"]
        XCTAssertTrue(userMessage.waitForExistence(timeout: 5))

        // Messages have no swipe actions, so a rightward swipe that starts on
        // one belongs to the sidebar drawer.
        let start = userMessage.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        let end = start.withOffset(CGVector(dx: app.frame.width * 0.7, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end)

        XCTAssertTrue(app.buttons["sidebar.dismiss"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testLongPressingAMessageOffersCopyAndShare() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo"]
        app.launch()
        let userMessage = app.staticTexts["What changed in SwiftUI web views this year?"]
        XCTAssertTrue(userMessage.waitForExistence(timeout: 5))

        userMessage.press(forDuration: 1.0)

        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Share"].exists)
        XCTAssertTrue(app.buttons["Edit"].exists)
    }

    /// Five or more cold launches; opt in with TEST_RUNNER_CHATLLM_RUN_PERFORMANCE_TESTS=1.
    @MainActor
    func testLaunchPerformance() throws {
        try XCTSkipUnless(Self.runsPerformanceTests, "Set TEST_RUNNER_CHATLLM_RUN_PERFORMANCE_TESTS=1 to measure launch time.")
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments.append("-ui-test-reset-app-state")
            app.launch()
        }
    }

    /// The drawer's sidebar and chat navigation bars stay in the hierarchy under the
    /// settings sheet, so target the system back button explicitly.
    @MainActor
    private func settingsBackButton(in app: XCUIApplication) -> XCUIElement {
        app.navigationBars.buttons.matching(identifier: "BackButton").firstMatch
    }

    /// On iPhone the chat list lives in a drawer behind the chat; slide it out.
    @MainActor
    private func openSidebar(in app: XCUIApplication) {
        let toggle = app.buttons["sidebar.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertTrue(app.buttons["sidebar.dismiss"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func openSettings(in app: XCUIApplication) {
        // Wait for whichever screen the launch shows instead of always waiting for onboarding.
        let skip = app.buttons["onboarding.skip"]
        let sidebarToggle = app.buttons["sidebar.toggle"]
        XCTAssertTrue(waitUntil { skip.exists || sidebarToggle.exists })
        if skip.exists { skip.tap() }
        if !app.buttons["sidebar.dismiss"].exists { openSidebar(in: app) }
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.buttons["settings.appearance"].waitForExistence(timeout: 5))
    }

    /// Polls `condition` until it holds or `timeout` passes, returning as soon as the
    /// app reaches the expected state instead of after a fixed wait.
    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return true
    }

    @MainActor
    private func assertLabel(
        of element: XCUIElement, becomes label: String, timeout: TimeInterval = 3,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let matched = waitUntil(timeout: timeout) { element.exists && element.label == label }
        XCTAssertTrue(matched, "Expected label \"\(label)\", found \"\(element.exists ? element.label : "no element")\"",
                      file: file, line: line)
    }

    @MainActor
    private func assertValue(
        of element: XCUIElement, becomes value: String, timeout: TimeInterval = 3,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let matched = waitUntil(timeout: timeout) { element.exists && element.value as? String == value }
        let found = element.exists ? String(describing: element.value ?? "nil") : "no element"
        XCTAssertTrue(matched, "Expected value \"\(value)\", found \"\(found)\"", file: file, line: line)
    }

    @MainActor
    private func toggle(_ element: XCUIElement) {
        // iOS 26 exposes the labeled SwiftUI row and the UISwitch separately.
        // Tapping the center of the outer row hits its label, not the switch.
        let control = element.switches.firstMatch
        if control.exists { control.tap() } else { element.tap() }
    }

    @MainActor
    private func captureSettingsScreenshot(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func settingsBackgroundBrightness(in app: XCUIApplication) throws -> Double {
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        // Sample the list background at its left edge, away from text and cards.
        let sample = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: image.height / 2, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Double(Int(bytes[0]) + Int(bytes[1]) + Int(bytes[2])) / 3
    }

    @MainActor
    func testSettingsSwipeDismissKeepsChanges() throws {
        let app = launchApp()
        openSettings(in: app)
        app.buttons["settings.chat"].tap()
        let sendOnReturn = app.switches["settings.sendOnReturn"]
        let original = sendOnReturn.value as? String
        toggle(sendOnReturn)
        settingsBackButton(in: app).tap()
        let navigationBar = app.navigationBars["Settings"]
        navigationBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        openSettings(in: app)
        app.buttons["settings.chat"].tap()
        let changed = app.switches["settings.sendOnReturn"]
        XCTAssertTrue(waitUntil(timeout: 3) { changed.exists && changed.value as? String != original })
    }

    @MainActor
    func testSendOnReturnLabelsTheKeyboardKeySend() throws {
        let app = launchApp()
        openSettings(in: app)
        app.buttons["settings.chat"].tap()
        toggle(app.switches["settings.sendOnReturn"])
        settingsBackButton(in: app).tap()
        app.buttons["settings.done"].tap()
        // Settings was opened from the sidebar, which is still open behind it.
        let dismissSidebar = app.buttons["sidebar.dismiss"]
        XCTAssertTrue(dismissSidebar.waitForExistence(timeout: 3))
        dismissSidebar.tap()

        let composer = app.textViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        let sendKey = app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] %@", "send")).firstMatch
        XCTAssertTrue(sendKey.waitForExistence(timeout: 5))
    }

    @MainActor
    func testInterfaceLanguageSwitchesImmediatelyAndPersists() throws {
        let app = launchApp()
        openSettings(in: app)
        app.buttons["settings.appearance"].tap()

        for (name, title, appearance, done) in [
            ("Deutsch", "Einstellungen", "Darstellung", "Fertig"),
            ("Español", "Ajustes", "Apariencia", "Listo"),
            ("English", "Settings", "Appearance", "Done")
        ] {
            app.buttons["settings.language"].tap()
            app.buttons[name].tap()
            XCTAssertTrue(app.navigationBars[appearance].waitForExistence(timeout: 5))
            captureSettingsScreenshot("appearance-\(name)", in: app)
            settingsBackButton(in: app).tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["settings.appearance"].label.contains(appearance))
            XCTAssertEqual(app.buttons["settings.done"].label, done)
            captureSettingsScreenshot("language-\(name)", in: app)
            app.buttons["settings.appearance"].tap()
        }

        app.buttons["settings.language"].tap()
        app.buttons["Español"].tap()
        settingsBackButton(in: app).tap()
        app.buttons["settings.done"].tap()
        app.terminate()
        let relaunched = launchApp(resetAppState: false)
        relaunched.buttons["sidebar.toggle"].tap()
        let settings = relaunched.buttons["Ajustes"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(relaunched.navigationBars["Ajustes"].waitForExistence(timeout: 5))
        XCTAssertEqual(relaunched.buttons["settings.done"].label, "Listo")
        relaunched.buttons["settings.appearance"].tap()
        XCTAssertTrue(relaunched.buttons["settings.language"].label.contains("Español"))
    }

    @MainActor
    func testLocalizedOnboardingAndModelSetup() throws {
        for (language, welcome, localModels) in [
            ("de", "Willkommen bei ChatLLM", "Lokale Modelle"),
            ("es", "Te damos la bienvenida a ChatLLM", "Modelos locales")
        ] {
            let app = XCUIApplication()
            app.launchArguments = [
                "-ui-test-reset-app-state", "-ui-test-fake-mlx-downloads",
                "-appLanguage", language
            ]
            app.launch()
            XCTAssertTrue(app.staticTexts[welcome].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["onboarding.intro.continue"].isHittable)
            captureSettingsScreenshot("onboarding-\(language)", in: app)
            app.scrollViews.firstMatch.swipeUp()
            let finalCard = language == "de"
                ? "Füge einen Tavily-API-Schlüssel hinzu, damit der Assistent im Web nach aktuellen Informationen suchen kann."
                : "Añade una clave de API de Tavily para que el asistente busque información actual en la web."
            XCTAssertTrue(app.staticTexts[finalCard].isHittable)
            XCTAssertTrue(app.buttons["onboarding.intro.continue"].isHittable)
            captureSettingsScreenshot("onboarding-scrolled-\(language)", in: app)
            app.buttons["onboarding.intro.continue"].tap()
            XCTAssertTrue(app.buttons["onboarding.tavily.continue"].waitForExistence(timeout: 5))
            app.buttons["onboarding.tavily.continue"].tap()
            XCTAssertTrue(app.staticTexts[localModels].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["onboarding.finish"].isHittable)
            captureSettingsScreenshot("models-\(language)", in: app)

            // Both languages put a space before the percent sign.
            app.buttons["onboarding.mlx.download"].tap()
            let percent = app.staticTexts
                .matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+[\u{00A0}\u{202F} ]%$"))
                .firstMatch
            XCTAssertTrue(percent.waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    func testSettingsAppearanceAndDetailNavigation() throws {
        let app = launchApp()
        openSettings(in: app)
        let systemBrightness = try settingsBackgroundBrightness(in: app)
        let oppositeAppearance = systemBrightness > 128 ? "Dark" : "Light"
        captureSettingsScreenshot("settings-light", in: app)
        app.buttons["settings.appearance"].tap()
        app.segmentedControls["settings.colorScheme"].buttons[oppositeAppearance].tap()
        captureSettingsScreenshot("appearance-dark", in: app)
        app.sliders["settings.messageTextSize"].adjust(toNormalizedSliderPosition: 1)
        assertValue(of: app.sliders["settings.messageTextSize"], becomes: "22 points")
        settingsBackButton(in: app).tap()
        XCTAssertTrue(app.buttons["settings.appearance"].label.contains(oppositeAppearance))
        XCTAssertGreaterThan(abs(try settingsBackgroundBrightness(in: app) - systemBrightness), 100)
        captureSettingsScreenshot("settings-dark", in: app)

        app.buttons["settings.appearance"].tap()
        app.segmentedControls["settings.colorScheme"].buttons["System"].tap()
        app.buttons["Reset Text Size"].tap()
        assertValue(of: app.sliders["settings.messageTextSize"], becomes: "16 points")
        captureSettingsScreenshot("appearance-light", in: app)
        settingsBackButton(in: app).tap()
        XCTAssertEqual(try settingsBackgroundBrightness(in: app), systemBrightness, accuracy: 5)

        for (id, title) in [("chat", "Chat"), ("webSearch", "Web Search"), ("privacy", "Privacy & Data"),
                            ("about", "About & Support"), ("advanced", "Advanced")] {
            app.buttons["settings.\(id)"].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3))
            captureSettingsScreenshot("settings-\(id)", in: app)
            settingsBackButton(in: app).tap()
        }
        app.buttons["settings.advanced"].tap()
        for (id, title) in [("mlx", "On-Device Models"), ("developer", "Developer")] {
            app.buttons["settings.\(id)"].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3))
            captureSettingsScreenshot("settings-\(id)", in: app)
            if id == "mlx" {
                app.buttons["About RotorQuant"].tap()
                XCTAssertTrue(app.navigationBars["RotorQuant"].waitForExistence(timeout: 3))
                captureSettingsScreenshot("settings-rotorQuant", in: app)
                settingsBackButton(in: app).tap()
            }
            settingsBackButton(in: app).tap()
        }
    }

    @MainActor
    func testSettingsPagesRemainScrollable() throws {
        let app = launchApp()
        openSettings(in: app)
        // Also run this flow with the simulator at its largest accessibility
        // text size; keep screenshots for checking wraps and control spacing.
        captureSettingsScreenshot("settings-scroll-root", in: app)
        for id in ["appearance", "chat"] {
            app.buttons["settings.\(id)"].tap()
            captureSettingsScreenshot("settings-scroll-\(id)", in: app)
            app.swipeUp()
            captureSettingsScreenshot("settings-scroll-\(id)-bottom", in: app)
            settingsBackButton(in: app).tap()
        }
        let about = app.buttons["settings.about"]
        for _ in 0..<4 where !about.isHittable { app.swipeUp() }
        XCTAssertTrue(about.isHittable)
        captureSettingsScreenshot("settings-scroll-root-bottom", in: app)
        about.tap()
        XCTAssertTrue(app.navigationBars["About & Support"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testSettingsCategoriesAndImmediatePersistence() throws {
        let app = launchApp()
        openSettings(in: app)
        for id in ["appearance", "chat", "webSearch", "privacy", "advanced", "about"] {
            XCTAssertTrue(app.buttons["settings.\(id)"].isHittable)
        }
        XCTAssertFalse(app.buttons["Save"].exists)
        XCTAssertFalse(app.buttons["Cancel"].exists)

        app.buttons["settings.chat"].tap()
        let sendOnReturn = app.switches["settings.sendOnReturn"]
        XCTAssertTrue(sendOnReturn.waitForExistence(timeout: 3))
        assertValue(of: sendOnReturn, becomes: "0")
        toggle(sendOnReturn)
        assertValue(of: sendOnReturn, becomes: "1")
        // Terminate without Done: the toggle must already be saved.
        app.terminate()
        let relaunched = launchApp(resetAppState: false)
        openSettings(in: relaunched)
        relaunched.buttons["settings.chat"].tap()
        assertValue(of: relaunched.switches["settings.sendOnReturn"], becomes: "1")
    }

    @MainActor
    func testSettingsResponsePreferencesSaveAndCancel() throws {
        let app = launchApp()
        openSettings(in: app)
        app.buttons["settings.chat"].tap()
        app.buttons["settings.responsePreferences"].tap()
        let editor = app.textViews["settings.preferencesEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText("Discard this draft")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["settings.responsePreferences"].label.contains("Not Set"))

        app.buttons["settings.responsePreferences"].tap()
        editor.tap()
        editor.typeText("Keep answers concise.")
        app.buttons["settings.savePreferences"].tap()
        XCTAssertTrue(app.buttons["settings.responsePreferences"].label.contains("Custom"))
        app.terminate()
        let relaunched = launchApp(resetAppState: false)
        openSettings(in: relaunched)
        relaunched.buttons["settings.chat"].tap()
        relaunched.buttons["settings.responsePreferences"].tap()
        XCTAssertEqual(relaunched.textViews["settings.preferencesEditor"].value as? String, "Keep answers concise.")
    }

    @MainActor
    func testSettingsAPIKeySaveCancelAndRemove() throws {
        let app = launchApp()
        openSettings(in: app)
        app.buttons["settings.webSearch"].tap()
        app.buttons["settings.editAPIKey"].tap()
        let key = app.secureTextFields["settings.apiKeyEditor"]
        XCTAssertTrue(key.waitForExistence(timeout: 3))
        key.tap()
        key.typeText("tvly-settings-test-key")
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.buttons["settings.testAPIKey"].exists)

        // The field is focused when the editor opens, and Return saves.
        app.buttons["settings.editAPIKey"].tap()
        XCTAssertTrue(key.waitForExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.typeText("tvly-settings-test-key\n")
        XCTAssertTrue(app.buttons["settings.testAPIKey"].waitForExistence(timeout: 3))
        app.terminate()
        let relaunched = launchApp(resetAppState: false)
        openSettings(in: relaunched)
        // A saved key hides the row's "Set Up" prompt.
        XCTAssertFalse(relaunched.buttons["settings.webSearch"].label.contains("Set Up"))
        relaunched.buttons["settings.webSearch"].tap()
        relaunched.buttons["settings.removeAPIKey"].tap()
        relaunched.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(relaunched.buttons["settings.testAPIKey"].exists)
        relaunched.buttons["settings.removeAPIKey"].tap()
        relaunched.alerts.buttons["Remove"].tap()
        XCTAssertFalse(relaunched.buttons["settings.testAPIKey"].exists)
    }

    @MainActor
    func testSettingsMemoryWarningAndResetRequireConfirmation() throws {
        let app = launchApp()
        openSettings(in: app)
        app.buttons["settings.advanced"].tap()
        app.buttons["settings.developer"].tap()
        let memory = app.switches["settings.disableRAMPrecautions"]
        toggle(memory)
        XCTAssertTrue(app.alerts["Disable RAM Precautions?"].waitForExistence(timeout: 3))
        app.alerts.buttons["Cancel"].tap()
        assertValue(of: memory, becomes: "0")
        toggle(memory)
        app.alerts.buttons["Disable"].tap()
        assertValue(of: memory, becomes: "1")
        let fullCache = app.switches["settings.forcePersistentKVCache"]
        assertValue(of: fullCache, becomes: "0")
        toggle(fullCache)
        assertValue(of: fullCache, becomes: "1")
        let contextLimit = app.switches["settings.overrideContextWindowLimit"]
        assertValue(of: contextLimit, becomes: "0")
        toggle(contextLimit)
        assertValue(of: contextLimit, becomes: "1")
        settingsBackButton(in: app).tap()
        app.buttons["settings.reset"].tap()
        app.alerts.buttons["Cancel"].tap()
        app.buttons["settings.developer"].tap()
        assertValue(of: memory, becomes: "1")
        settingsBackButton(in: app).tap()
        app.buttons["settings.reset"].tap()
        app.alerts.buttons["Reset"].tap()
        app.buttons["settings.developer"].tap()
        assertValue(of: memory, becomes: "0")
        assertValue(of: fullCache, becomes: "0")
        assertValue(of: contextLimit, becomes: "0")
    }

    @MainActor
    func testSettingsPrivacyEmptyStateAndRetentionPicker() throws {
        let app = launchApp()
        openSettings(in: app)
        app.buttons["settings.privacy"].tap()
        XCTAssertFalse(app.buttons["settings.exportChats"].isEnabled)
        XCTAssertFalse(app.buttons["settings.deleteAllChats"].isEnabled)
        XCTAssertFalse(app.buttons["settings.deleteOtherChats"].isEnabled)
        XCTAssertFalse(app.buttons["settings.retention"].exists)
        toggle(app.switches["settings.autoDelete"])
        XCTAssertTrue(app.buttons["settings.retention"].waitForExistence(timeout: 3))
        toggle(app.switches["settings.autoDelete"])
        XCTAssertFalse(app.buttons["settings.retention"].exists)
    }

    @MainActor
    func testAutoDeleteRemovesOldChatsWhenTheAppReturns() throws {
        let fixture = XCUIApplication()
        fixture.launchArguments = [
            "-ui-test-reset-app-state", "-ui-test-web-search-demo",
            "-ui-test-second-chat", "-ui-test-stale-second-chat"
        ]
        fixture.launch()
        XCTAssertTrue(fixture.buttons["message.sources"].waitForExistence(timeout: 5))
        fixture.terminate()

        let app = launchApp(resetAppState: false)
        openSidebar(in: app)
        XCTAssertTrue(app.staticTexts["Second Chat"].waitForExistence(timeout: 5))
        openSettings(in: app)
        app.buttons["settings.privacy"].tap()
        toggle(app.switches["settings.autoDelete"])
        XCTAssertTrue(app.buttons["settings.retention"].waitForExistence(timeout: 3))
        settingsBackButton(in: app).tap()
        app.buttons["settings.done"].tap()

        XCUIDevice.shared.press(.home)
        app.activate()

        if !app.buttons["sidebar.dismiss"].exists { openSidebar(in: app) }
        XCTAssertTrue(app.staticTexts["Web Search Preview"].waitForExistence(timeout: 5))
        let staleRow = app.staticTexts["Second Chat"]
        XCTAssertTrue(staleRow.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testSettingsDeletionCancelsThenDeletesWithoutASecondPrompt() throws {
        let fixture = XCUIApplication()
        fixture.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo"]
        fixture.launch()
        XCTAssertTrue(fixture.buttons["message.sources"].waitForExistence(timeout: 5))
        fixture.terminate()

        let app = launchApp(resetAppState: false)
        openSettings(in: app)
        app.buttons["settings.privacy"].tap()
        let delete = app.buttons["settings.deleteAllChats"]
        XCTAssertTrue(delete.isEnabled)
        delete.tap()
        XCTAssertTrue(app.alerts["Delete All Chats?"].waitForExistence(timeout: 3))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(delete.isEnabled)
        delete.tap()
        app.alerts.buttons["Delete"].tap()

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        openSettings(in: app)
        app.buttons["settings.privacy"].tap()
        XCTAssertFalse(app.buttons["settings.deleteAllChats"].isEnabled)
        XCTAssertFalse(app.buttons["settings.exportChats"].isEnabled)
    }

    @MainActor
    func testSettingsExportPresentsShareSheetAfterClosingSettings() throws {
        let fixture = XCUIApplication()
        fixture.launchArguments = ["-ui-test-reset-app-state", "-ui-test-web-search-demo"]
        fixture.launch()
        XCTAssertTrue(fixture.buttons["message.sources"].waitForExistence(timeout: 5))
        fixture.terminate()

        let app = launchApp(resetAppState: false)
        openSettings(in: app)
        app.buttons["settings.privacy"].tap()
        app.buttons["settings.exportChats"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "settings-export-share-sheet"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
