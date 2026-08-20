import XCTest
@testable import ReceiptDrop

/// Tests for `ExtractionFailureClass.classify` — the pure `Error ->
/// connectivity | other` decision `ReceiptSubmitView` uses to tell "AI was
/// unreachable, the receipt is fine" (offer the on-device fallback) apart
/// from "AI was reached and something else went wrong" (still queue for
/// retry). No UI, no network — every error here is constructed directly.
final class ExtractionFailureClassTests: XCTestCase {

    // MARK: - Connectivity-class

    func testOfflineModeBlockedIsConnectivityClass() {
        // The local Offline-mode guard, not even a network attempt — but
        // from the user's point of view it's the same situation: AI is
        // unreachable right now, nothing is wrong with the receipt.
        let error = OfflineModeError.cloudProviderBlocked(.claude)
        XCTAssertEqual(ExtractionFailureClass.classify(error), .connectivity)
    }

    func testNotConnectedToInternetIsConnectivityClass() {
        let error = URLError(.notConnectedToInternet)
        XCTAssertEqual(ExtractionFailureClass.classify(error), .connectivity)
    }

    func testNetworkConnectionLostIsConnectivityClass() {
        let error = URLError(.networkConnectionLost)
        XCTAssertEqual(ExtractionFailureClass.classify(error), .connectivity)
    }

    func testCannotFindHostIsConnectivityClass() {
        let error = URLError(.cannotFindHost)
        XCTAssertEqual(ExtractionFailureClass.classify(error), .connectivity)
    }

    func testCannotConnectToHostIsConnectivityClass() {
        let error = URLError(.cannotConnectToHost)
        XCTAssertEqual(ExtractionFailureClass.classify(error), .connectivity)
    }

    func testTimedOutIsConnectivityClass() {
        let error = URLError(.timedOut)
        XCTAssertEqual(ExtractionFailureClass.classify(error), .connectivity)
    }

    func testDataNotAllowedIsConnectivityClass() {
        let error = URLError(.dataNotAllowed)
        XCTAssertEqual(ExtractionFailureClass.classify(error), .connectivity)
    }

    func testInternationalRoamingOffIsConnectivityClass() {
        let error = URLError(.internationalRoamingOff)
        XCTAssertEqual(ExtractionFailureClass.classify(error), .connectivity)
    }

    // MARK: - Not connectivity-class — the request reached the provider

    func testBadServerResponseIsNotConnectivityClass() {
        // The request got *a* response, just not a valid/parseable one —
        // different from never getting a response at all.
        let error = URLError(.badServerResponse)
        XCTAssertEqual(ExtractionFailureClass.classify(error), .other)
    }

    func testUserAuthenticationRequiredIsNotConnectivityClass() {
        // Stand-in for "the request reached the provider and it rejected
        // the credentials" — a bad/expired API key. Retrying on-device
        // would hide a problem the user actually needs to see and fix.
        let error = URLError(.userAuthenticationRequired)
        XCTAssertEqual(ExtractionFailureClass.classify(error), .other)
    }

    func testGenericNSErrorIsNotConnectivityClass() {
        // A provider-side error surfaced as a plain NSError (e.g. a decoded
        // 429 or 500 from Claude/OpenAI/Gemini's own error-response
        // parsing) — reached the network, got an answer, the answer just
        // wasn't success. Should still queue, not silently fall back.
        let error = NSError(domain: "ClaudeService", code: 429,
                             userInfo: [NSLocalizedDescriptionKey: "Rate limited"])
        XCTAssertEqual(ExtractionFailureClass.classify(error), .other)
    }

    func testCancelledIsNotConnectivityClass() {
        // The user (or the system) cancelled the request — not the network
        // failing to reach the provider, so shouldn't be treated the same
        // as "AI unreachable."
        let error = URLError(.cancelled)
        XCTAssertEqual(ExtractionFailureClass.classify(error), .other)
    }
}
