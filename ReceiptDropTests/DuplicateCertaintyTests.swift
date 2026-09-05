import XCTest
@testable import ReceiptDrop

/// Covers which duplicate check fired, which the UI now reports.
///
/// The distinction is not cosmetic: an identical file is proof the user has
/// already filed this exact photo, while matching category/date/amount is a
/// guess that a repeat coffee order or a flat fee charged twice trips
/// regularly. Telling the user the weaker reason for the stronger evidence
/// makes them second-guess a certainty, and vice versa.
final class DuplicateCertaintyTests: XCTestCase {

    private func entry(vendor: String = "Naan and Kabob") -> HistoryEntry {
        HistoryEntry(category: "DTG", vendor: vendor, workDate: "2026-09-03",
                     amount: "89.93", receiptLink: "a.jpg", timestamp: Date(),
                     verificationStatus: .verified)
    }

    func testTheErrorCarriesWhichCheckFired() {
        let identical = SubmissionError.duplicate(entry(), .identicalFile)
        let fields = SubmissionError.duplicate(entry(), .matchingFields)

        if case .duplicate(_, let certainty) = identical {
            XCTAssertEqual(certainty, .identicalFile)
        } else {
            XCTFail("Expected a duplicate error.")
        }
        if case .duplicate(_, let certainty) = fields {
            XCTAssertEqual(certainty, .matchingFields)
        } else {
            XCTFail("Expected a duplicate error.")
        }
    }

    func testTheDescriptionStillNamesTheExistingReceipt() {
        // Used where there is no room for the fuller explanation — the retry
        // queue's error line, for one — so it has to stay self-contained.
        let message = SubmissionError.duplicate(entry(), .identicalFile).errorDescription ?? ""
        XCTAssertTrue(message.contains("Naan and Kabob"), message)
        XCTAssertTrue(message.contains("89.93"), message)
    }

    func testAnEmptyVendorDoesNotProduceADanglingSentence() {
        let message = SubmissionError.duplicate(entry(vendor: ""), .matchingFields)
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("this vendor"), message)
        XCTAssertFalse(message.contains("as  on"), message)
    }
}
