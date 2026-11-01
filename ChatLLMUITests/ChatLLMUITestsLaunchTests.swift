//
//  ChatLLMUITestsLaunchTests.swift
//  ChatLLMUITests
//
//  Created by Nevio on 10/24/25.
//

import XCTest

/// Launch screenshots in every appearance and orientation. The normal run already
/// checks the launch screen (testFreshLaunchShowsOnboarding), so these repeated
/// launches run only with TEST_RUNNER_CHATLLM_RUN_PERFORMANCE_TESTS=1.
final class ChatLLMUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        ChatLLMUITests.runsPerformanceTests
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        try XCTSkipUnless(ChatLLMUITests.runsPerformanceTests, "Set TEST_RUNNER_CHATLLM_RUN_PERFORMANCE_TESTS=1 for launch screenshots.")
        let app = XCUIApplication()
        app.launchArguments.append("-ui-test-reset-app-state")
        app.launch()

        XCTAssertTrue(app.otherElements["onboarding.root"].waitForExistence(timeout: 5))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
