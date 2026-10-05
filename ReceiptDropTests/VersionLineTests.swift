import XCTest
@testable import ReceiptDrop

/// Settings' last line is how anyone checks which build a device runs, so
/// it must be the bundle's real version and build, never a placeholder.
final class VersionLineTests: XCTestCase {
    func testVersionLineShowsTheBundlesVersionAndBuild() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let version = try XCTUnwrap(info["CFBundleShortVersionString"] as? String)
        let build = try XCTUnwrap(info["CFBundleVersion"] as? String)
        XCTAssertEqual(SettingsView.versionLine, "Receipts4Tax \(version) (\(build))")
        XCTAssertFalse(SettingsView.versionLine.contains("?"))
    }
}
