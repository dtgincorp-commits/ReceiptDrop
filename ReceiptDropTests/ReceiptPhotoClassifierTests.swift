import XCTest
@testable import ReceiptDrop

/// Covers `ReceiptPhotoClassifier`, the Phase 0 pre-filter for auto-import
/// (AUTO_IMPORT_RESEARCH.md). Pure text-in/score-out, so none of this needs a
/// photo library, Vision, or a device.
///
/// These tests pin the *ordering* the classifier has to get right — a till
/// receipt must outscore a bank statement, a dog photo, a business card —
/// rather than exact scores, which the eval screen exists to tune. Asserting
/// on specific numbers here would make every weight adjustment a test failure
/// for no gain in safety.
final class ReceiptPhotoClassifierTests: XCTestCase {

    private let receiptText = """
    MONTERAS CAFE
    123 Main Street
    07/16/2026  2:14 PM
    Flat White        4.50
    Sandwich          8.95
    SUBTOTAL         13.45
    SALES TAX         1.21
    TOTAL           $14.66
    VISA ****4821
    AUTH CODE 003914
    THANK YOU
    """

    private let dogPhotoText = "Nikon"

    private let bankStatementText = """
    FIRST NATIONAL BANK
    Account Summary
    Statement Period 06/01/2026 - 06/30/2026
    Opening Balance          1,240.18
    Closing Balance          1,902.44
    Minimum Payment             35.00
    """

    private let businessCardText = """
    Jane Okonkwo
    Principal Engineer
    www.linkedin.com/in/jokonkwo
    +1 555 0134
    """

    private let menuText = """
    DINNER MENU
    Appetizers
    Bruschetta        9.00
    Calamari         14.00
    Entrees
    Ribeye           38.00
    Wine List available on request
    """

    func testARealReceiptScoresAboveTheSuggestedThreshold() {
        let result = ReceiptPhotoClassifier.classify(text: receiptText)
        XCTAssertGreaterThanOrEqual(result.score, ReceiptPhotoClassifier.suggestedThreshold,
                                    "A plainly-a-receipt till roll must clear the default threshold.")
    }

    func testAReceiptOutscoresEveryExpectedFalsePositive() {
        let receipt = ReceiptPhotoClassifier.classify(text: receiptText).score
        for (name, text) in [("dog photo", dogPhotoText),
                             ("bank statement", bankStatementText),
                             ("business card", businessCardText),
                             ("menu", menuText)] {
            let other = ReceiptPhotoClassifier.classify(text: text).score
            XCTAssertGreaterThan(receipt, other,
                                 "A receipt must outscore a \(name) — that ordering is the whole feature.")
        }
    }

    func testAPhotoWithNoTextScoresZero() {
        // The most common thing in a camera roll, and the cheapest to reject.
        XCTAssertEqual(ReceiptPhotoClassifier.classify(text: "").score, 0)
        XCTAssertEqual(ReceiptPhotoClassifier.classify(text: dogPhotoText).score, 0)
    }

    func testStatementKeywordsPushABankStatementBelowTheThreshold() {
        // A statement has dates, many currency amounts and the word "balance"
        // — everything a receipt has. Only the negative keywords separate
        // them, so this is the test that actually guards the negative list.
        let result = ReceiptPhotoClassifier.classify(text: bankStatementText)
        XCTAssertLessThan(result.score, ReceiptPhotoClassifier.suggestedThreshold)
    }

    func testKeywordsDoNotMatchInsideLongerWords() {
        // "tax" inside "taxi", "total" inside "subtotal" — a substring match
        // would quietly inflate every score and make the weights meaningless.
        let taxi = ReceiptPhotoClassifier.classify(text: "Yellow taxi stand, gate 4")
        XCTAssertFalse(taxi.reason.contains("receipt words"),
                       "'taxi' must not count as the receipt word 'tax'.")
    }

    func testReasonNamesTheSignalsThatFired() {
        // The suggestions tray shows this string to the user, so it has to be
        // populated and human-readable, not an empty string.
        let result = ReceiptPhotoClassifier.classify(text: receiptText)
        XCTAssertFalse(result.reason.isEmpty)
        XCTAssertTrue(result.reason.contains("currency amounts"), result.reason)
    }

    func testNegativeKeywordsAlsoRespectWordBoundaries() {
        // Regression from the first eval run: a real payment-confirmation
        // receipt scored 0.00 because "menu" matched inside a longer word.
        // A negative hit is heavy enough to sink a photo alone, so a loose
        // match here is worse than anywhere else in the classifier.
        let payment = ReceiptPhotoClassifier.classify(
            text: "Money sent to Dimitri  $240.00  Feb 4, 2026  Payment complete")
        XCTAssertFalse(payment.reason.contains("not-a-receipt"), payment.reason)
        XCTAssertGreaterThan(payment.score, 0)

        // The word itself must still be caught when it really is a menu.
        let realMenu = ReceiptPhotoClassifier.classify(
            text: "DINNER MENU  Appetizers  Bruschetta 9.00  Entrees  Ribeye 38.00")
        XCTAssertTrue(realMenu.reason.contains("not-a-receipt"), realMenu.reason)
    }

    func testScoreIsClampedToZeroAndOne() {
        let piledUp = String(repeating: receiptText, count: 5)
        let result = ReceiptPhotoClassifier.classify(text: piledUp)
        XCTAssertLessThanOrEqual(result.score, 1.0)
        XCTAssertGreaterThanOrEqual(result.score, 0.0)
    }
}
