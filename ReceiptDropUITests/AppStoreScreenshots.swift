import XCTest

/// Captures the App Store screenshots: launches the app with fictional demo
/// receipts (`-ScreenshotDemoData`, see ScreenshotDemoData.swift), visits each
/// screen, and saves a PNG per screen.
///
/// Run with the ReceiptDropScreenshots scheme on the iPhone Pro Max and iPad Pro 13" simulators — the sizes App Store
/// Connect requires — with the status bar overridden to a clean 9:41. Files go
/// to $SCREENSHOT_DIR (pass TEST_RUNNER_SCREENSHOT_DIR to xcodebuild), and are
/// also attached to the test result.
///
/// Not a correctness test: it asserts only what it needs to reach each screen.
final class AppStoreScreenshots: XCTestCase {
    private var app: XCUIApplication!
    private var outputDirectory: URL!
    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        outputDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SCREENSHOT_DIR"]
                              ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments = ["-ScreenshotDemoData"]
        app.launch()
    }

    private func capture(_ name: String) throws {
        sleep(2)   // let animations and async loads settle
        let shot = XCUIScreen.main.screenshot()
        try shot.pngRepresentation.write(to: outputDirectory.appendingPathComponent("\(device)-\(name).png"))
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "\(device)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tab(_ name: String) -> XCUIElement {
        let inTabBar = app.tabBars.buttons[name]
        return inTabBar.exists ? inTabBar : app.buttons[name].firstMatch
    }

    func testCaptureAppStoreScreenshots() throws {
        // 1. The receipt list, with the running total.
        XCTAssertTrue(app.staticTexts["Harbor Lane Bistro"].waitForExistence(timeout: 20))
        try capture("1-Receipts")

        // 2. A receipt opened to its photo. Tap the row's button: tapping its
        // text alone doesn't open it.
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Riverbend Hardware'")).firstMatch.tap()
        // The photo viewer can take well over 10 s to appear in the Simulator.
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 30))
        sleep(8)   // QuickLook draws the photo out of process, after Done appears
        try capture("2-Receipt")
        app.buttons["Done"].tap()

        // 3. Insights. Captured before search: on iPad the search screen hides
        // the tabs and has no Cancel, so search goes last.
        // iPad draws the tabs at the top; tap the tab bar's own button there.
        tab("Insights").tap()
        XCTAssertTrue(app.staticTexts["Receipt Insights"].waitForExistence(timeout: 10))
        try capture("4-Insights")
        tab("Receipts").tap()

        // 4. Search by amount. The trailing return submits the search, which
        // closes the keyboard so it doesn't cover the results.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText(">100\n")
        let parsing = app.staticTexts["Understanding your search…"]
        XCTAssertTrue(parsing.waitForNonExistence(timeout: 30))
        try capture("3-Search")
    }
}
