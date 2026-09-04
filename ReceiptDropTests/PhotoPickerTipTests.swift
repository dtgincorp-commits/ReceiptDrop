import XCTest
@testable import ReceiptDrop

/// Covers the one-time photo-picker tip's shown-once rule.
///
/// Unlike the camera priming screen — which is one-time by construction,
/// since the system permission state can only be `.notDetermined` once — this
/// has nothing but its own flag to stop it reappearing. A bug here means
/// either a tip on every single import, or a first-time user who never sees
/// it at all.
final class PhotoPickerTipTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // A throwaway suite, so the test can't disturb the real one.
        defaults = UserDefaults(suiteName: "PhotoPickerTipTests")!
        defaults.removePersistentDomain(forName: "PhotoPickerTipTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "PhotoPickerTipTests")
        super.tearDown()
    }

    func testShownOnAFreshInstall() {
        XCTAssertTrue(shouldShowPhotoPickerTip(defaults: defaults))
    }

    func testNotShownAgainOnceSeen() {
        markPhotoPickerTipSeen(defaults: defaults)
        XCTAssertFalse(shouldShowPhotoPickerTip(defaults: defaults))
    }

    func testStaysSeenAcrossRepeatedChecks() {
        // Guards against a read that clears or toggles the flag — the tip
        // reappearing on every library import would be worse than never
        // showing it.
        markPhotoPickerTipSeen(defaults: defaults)
        for _ in 0..<3 {
            XCTAssertFalse(shouldShowPhotoPickerTip(defaults: defaults))
        }
    }

    func testMarkingSeenIsIdempotent() {
        markPhotoPickerTipSeen(defaults: defaults)
        markPhotoPickerTipSeen(defaults: defaults)
        XCTAssertFalse(shouldShowPhotoPickerTip(defaults: defaults))
    }
}
