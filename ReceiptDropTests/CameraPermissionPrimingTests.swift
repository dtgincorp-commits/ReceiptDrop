import AVFoundation
import XCTest
@testable import ReceiptDrop

/// Tests for `shouldPrimeCameraPermission(for:)` — the pure decision behind
/// whether `NewReceiptView` and `BillCaptureView` show the "why we need
/// your camera" screen before triggering the system dialog. Everything
/// else about priming (presenting the screen, wiring `onContinue` to the
/// real trigger) depends on live device/OS permission state and can't be
/// meaningfully unit tested, but this decision is plain data in, bool out.
final class CameraPermissionPrimingTests: XCTestCase {

    func testPrimesWhenNotDetermined() {
        XCTAssertTrue(shouldPrimeCameraPermission(for: .notDetermined))
    }

    func testDoesNotPrimeWhenAuthorized() {
        // Already granted — the system dialog won't fire again, so showing
        // priming here would just be an extra, pointless tap.
        XCTAssertFalse(shouldPrimeCameraPermission(for: .authorized))
    }

    func testDoesNotPrimeWhenDenied() {
        // Already resolved (the other way) — priming now can't change what
        // happens next, since only Settings can flip this back.
        XCTAssertFalse(shouldPrimeCameraPermission(for: .denied))
    }

    func testDoesNotPrimeWhenRestricted() {
        // e.g. Screen Time / MDM restriction — no dialog will ever fire,
        // priming would be dead air.
        XCTAssertFalse(shouldPrimeCameraPermission(for: .restricted))
    }
}
