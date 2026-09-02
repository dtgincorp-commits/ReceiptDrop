import XCTest
@testable import ReceiptDrop

/// Covers the "Save for Later" queue state — receipts the share extension
/// parked to be read overnight rather than on next app open.
///
/// The risk this guards against is a receipt that is never read at all: held
/// entries are deliberately skipped by the foreground path, so if the grace
/// period or the decoding default were wrong, a user's receipts would sit in
/// the queue indefinitely with nothing surfacing the problem.
final class HeldSubmissionTests: XCTestCase {

    private func entry(isPending: Bool, isHeld: Bool, ageInHours: Double) -> QueueEntry {
        QueueEntry(category: "BUSINESS EXPENSES",
                   filename: "x.jpg",
                   kind: .image,
                   error: "",
                   timestamp: Date().addingTimeInterval(-ageInHours * 3600),
                   isPending: isPending,
                   isHeld: isHeld)
    }

    func testAFreshlyHeldEntryIsLeftForTheOvernightRun() {
        XCTAssertFalse(entry(isPending: true, isHeld: true, ageInHours: 1).heldLongEnoughToForce)
    }

    func testAHeldEntryIsForcedOnceTheGracePeriodPasses() {
        // The safety net. iOS may never grant background time — the user can
        // force-quit the app, never charge overnight, or the system can skip
        // for days — so "later" must eventually become "now" rather than
        // "never".
        XCTAssertTrue(entry(isPending: true, isHeld: true, ageInHours: 25).heldLongEnoughToForce)
    }

    func testTheGracePeriodBoundaryIsInclusive() {
        XCTAssertTrue(entry(isPending: true, isHeld: true, ageInHours: 24).heldLongEnoughToForce)
    }

    func testAnUnheldEntryIsNeverForced() {
        // heldLongEnoughToForce is only meaningful for held entries; an
        // ordinary pending entry is processed on foreground anyway, and a
        // genuine failure must never be swept up by this path.
        XCTAssertFalse(entry(isPending: true, isHeld: false, ageInHours: 99).heldLongEnoughToForce)
        XCTAssertFalse(entry(isPending: false, isHeld: false, ageInHours: 99).heldLongEnoughToForce)
    }

    func testEntriesPersistedBeforeIsHeldExistedDecodeAsNotHeld() throws {
        // Real payload shape from the App Group defaults before this field
        // existed. Defaulting to held would strand every queued receipt
        // already on a user's phone.
        let json = """
        {"id":"\(UUID().uuidString)","category":"BUSINESS EXPENSES","filename":"a.jpg",
         "kind":"image","error":"","timestamp":0,"isPending":true}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(QueueEntry.self, from: json)
        XCTAssertTrue(decoded.isPending)
        XCTAssertFalse(decoded.isHeld, "A queue entry from before this field existed was never held.")
    }

    func testHeldSurvivesAnEncodeDecodeRoundTrip() throws {
        let original = entry(isPending: true, isHeld: true, ageInHours: 2)
        let decoded = try JSONDecoder().decode(
            QueueEntry.self, from: JSONEncoder().encode(original))
        XCTAssertTrue(decoded.isHeld)
        XCTAssertTrue(decoded.isPending)
    }

    // MARK: - Scheduling

    func testTheQuietWindowIsTonightWhenItIsStillEvening() {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 2
        components.hour = 21; components.minute = 30
        let evening = Calendar.current.date(from: components)!

        let scheduled = OvernightProcessingService.nextQuietWindow(from: evening)
        let hour = Calendar.current.component(.hour, from: scheduled)
        XCTAssertEqual(hour, 2)
        XCTAssertGreaterThan(scheduled, evening)
        // Tomorrow's 2am, not a week away.
        XCTAssertLessThan(scheduled.timeIntervalSince(evening), 24 * 3600)
    }

    func testTheQuietWindowIsLaterTodayWhenItIsPastMidnight() {
        // 00:30 — 2am has not happened yet today, so waiting a full day
        // would be an unnecessary 24-hour delay.
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 2
        components.hour = 0; components.minute = 30
        let afterMidnight = Calendar.current.date(from: components)!

        let scheduled = OvernightProcessingService.nextQuietWindow(from: afterMidnight)
        XCTAssertEqual(Calendar.current.component(.hour, from: scheduled), 2)
        XCTAssertEqual(scheduled.timeIntervalSince(afterMidnight), 1.5 * 3600, accuracy: 1)
    }
}
