import XCTest
import AppKit

@MainActor final class JobTrackerUITests: XCTestCase {
    private enum LaunchFailure: Error { case missingInterface }

    private func launchApp(language: String, file: StaticString = #filePath, line: UInt = #line) async throws -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Do not restore a previous test's empty or closed window set.
        // Argument-domain defaults apply only to this launched process.
        app.launchArguments = ["--uitesting", "-ApplePersistenceIgnoreState", "YES",
                               "-NSQuitAlwaysKeepsWindows", "NO", "-AppleLanguages", "(\(language))", "-language", language]
        app.launch()
        app.activate()
        guard app.wait(for: .runningForeground, timeout: 10) else {
            try fail("JobTracker did not become the foreground application.", app: app, file: file, line: line)
        }
        // XCTest starts the process, but activation alone does not reproduce a
        // Dock/Finder open request. Send that request to this exact running app.
        guard let running = NSWorkspace.shared.frontmostApplication,
              running.bundleIdentifier == "local.JobTracker",
              let bundleURL = running.bundleURL else {
            try fail("Cannot identify the launched JobTracker instance for the system open request.", app: app, file: file, line: line)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        let reopened: NSRunningApplication
        do {
            reopened = try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
        } catch {
            try fail("The system could not open the running JobTracker application: \(error.localizedDescription)", app: app, file: file, line: line)
        }
        guard reopened.processIdentifier == running.processIdentifier else {
            try fail("The system open request created a different JobTracker process.", app: app, file: file, line: line)
        }
        _ = try require(app.windows.firstMatch, app: app, message: "JobTracker launched without a main window.", timeout: 10, file: file, line: line)
        let startupError = app.descendants(matching: .any).matching(identifier: "startupError").firstMatch
        if startupError.exists {
            try fail("JobTracker displayed its data-store startup error instead of the main interface.", app: app, file: file, line: line)
        }
        return app
    }

    private func require(_ element: XCUIElement, app: XCUIApplication, message: String,
                         timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        guard element.waitForExistence(timeout: timeout) else {
            try fail(message, app: app, file: file, line: line)
        }
        return element
    }

    private func requireDisappearance(_ element: XCUIElement, app: XCUIApplication,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        guard XCTWaiter.wait(for: [expectation], timeout: 5) == .completed else {
            try fail("The application form did not dismiss.", app: app, file: file, line: line)
        }
    }

    private func fail(_ message: String, app: XCUIApplication, file: StaticString, line: UInt) throws -> Never {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "JobTracker accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        if app.windows.firstMatch.exists {
            let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            screenshot.name = "JobTracker window at failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTFail(message, file: file, line: line)
        throw LaunchFailure.missingInterface
    }

    func testCreateSearchEditAndCancel() async throws {
        let app = try await launchApp(language: "en")
        try require(app.buttons["newApplicationButton"], app: app, message: "The main window has no New Application toolbar button.").click()
        let company = try require(app.textFields["companyField"], app: app, message: "The new application form did not open.")
        company.typeText("Test Company")
        app.textFields["jobTitleField"].click(); app.textFields["jobTitleField"].typeText("macOS Developer")
        app.buttons["saveApplicationButton"].click()
        try requireDisappearance(company, app: app)
        XCTAssertTrue(app.staticTexts["Test Company"].firstMatch.waitForExistence(timeout: 5))
        app.typeKey("n", modifierFlags: .command)
        try require(app.textFields["companyField"], app: app, message: "Cmd+N did not open the application form.").typeText("Cancelled Company")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        try requireDisappearance(company, app: app)
        XCTAssertFalse(app.staticTexts["Cancelled Company"].exists)
        try require(app.buttons["editApplicationButton"], app: app, message: "The selected application has no Edit button.").click()
        let editedCompany = try require(app.textFields["companyField"], app: app, message: "The edit application form did not open.")
        editedCompany.click(); app.typeKey("a", modifierFlags: .command)
        editedCompany.typeText("Updated Company")
        app.buttons["saveApplicationButton"].click()
        try requireDisappearance(editedCompany, app: app)
        XCTAssertTrue(app.staticTexts["Updated Company"].firstMatch.waitForExistence(timeout: 5))
        let search = try require(app.searchFields.firstMatch, app: app, message: "The application search field is unavailable.")
        search.click(); search.typeText("does not exist")
        XCTAssertTrue(app.staticTexts["No matching applications"].waitForExistence(timeout: 5))
    }
    func testValidationAndPolishInterface() async throws {
        let app = try await launchApp(language: "pl")
        try require(app.buttons["newApplicationButton"], app: app, message: "The main window has no New Application toolbar button.").click()
        _ = try require(app.textFields["companyField"], app: app, message: "The Polish application form did not open.")
        try require(app.buttons["saveApplicationButton"], app: app, message: "The application form has no Save button.").click()
        XCTAssertTrue(app.staticTexts["formError"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Podaj nazwę firmy."].exists)
    }
}
