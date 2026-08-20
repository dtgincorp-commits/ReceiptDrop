import XCTest
@testable import ReceiptDrop

/// Tests for `ExtractionSettings.extractor(for:)` — the pure
/// `ExtractionProvider -> ReceiptExtractor` resolution that
/// `SubmissionPipeline.run(forcedProvider:)` uses to run extraction with a
/// specific provider *without* touching the persisted, App-Group-shared
/// `ExtractionSettings.provider` setting. This is what lets
/// `ReceiptSubmitView`'s "Use Apple Intelligence" fallback force the
/// on-device model for one submission while leaving the user's actually
/// configured provider (Claude, Gemini, ...) untouched.
///
/// Deliberately does not read or write `ExtractionSettings.provider` itself
/// — every case here passes the provider in explicitly, so these tests can't
/// leak state into (or pick up state from) any other test or the app's real
/// persisted setting.
final class ExtractionSettingsOverrideTests: XCTestCase {

    func testExtractorForClaudeReturnsClaudeService() {
        XCTAssertTrue(ExtractionSettings.extractor(for: .claude) is ClaudeService)
    }

    func testExtractorForGeminiReturnsGeminiService() {
        XCTAssertTrue(ExtractionSettings.extractor(for: .gemini) is GeminiService)
    }

    func testExtractorForOpenAIReturnsOpenAIService() {
        XCTAssertTrue(ExtractionSettings.extractor(for: .openAI) is OpenAIService)
    }

    func testExtractorForPerplexityReturnsPerplexityService() {
        XCTAssertTrue(ExtractionSettings.extractor(for: .perplexity) is PerplexityService)
    }

    func testExtractorForAzureReturnsAzureDocumentIntelligenceService() {
        XCTAssertTrue(ExtractionSettings.extractor(for: .azureDocumentIntelligence) is AzureDocumentIntelligenceService)
    }

    /// The case this whole override exists for: asking for `.appleOnDevice`
    /// explicitly returns the on-device extractor regardless of whatever
    /// `ExtractionSettings.provider` is actually set to — proven here by
    /// never reading `.provider` at all, only ever passing the provider in.
    func testExtractorForAppleOnDeviceReturnsOnDeviceExtractorOnSupportedOS() {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            XCTAssertTrue(ExtractionSettings.extractor(for: .appleOnDevice) is FoundationModelsService)
            return
        }
        #endif
        // Pre-iOS 26 / no FoundationModels framework: falls back to Gemini
        // rather than crashing or returning nil — still a valid
        // ReceiptExtractor, just not the on-device one.
        XCTAssertTrue(ExtractionSettings.extractor(for: .appleOnDevice) is GeminiService)
    }

    /// `currentExtractor()` (no argument) must still resolve from the
    /// persisted `provider` — this override adds a new entry point, it
    /// doesn't change the existing one. Reads the default rather than
    /// mutating `.provider`, since other tests may run in the same process
    /// and `.provider` is a shared App Group default.
    func testCurrentExtractorMatchesExtractorForPersistedProvider() {
        let persisted = ExtractionSettings.provider
        XCTAssertTrue(type(of: ExtractionSettings.currentExtractor()) == type(of: ExtractionSettings.extractor(for: persisted)))
    }

    /// `appleOnDeviceReady` depends on real device/OS state
    /// (`SystemLanguageModel.default.availability`, which reflects hardware
    /// eligibility, whether Apple Intelligence is enabled, and whether the
    /// model has finished downloading) — none of that is controllable from
    /// a unit test, so there's no meaningful assertion to make beyond "it
    /// doesn't crash to call it." Not tested further here.

    // MARK: - assertProviderAllowed(_:) — the Offline-mode guard

    /// With Offline mode on, `.appleOnDevice` is always allowed — nothing
    /// about it needs the network, so the guard must not block it regardless
    /// of what the persisted `provider` setting happens to be (this call
    /// passes the provider explicitly and never reads `.provider`).
    func testAppleOnDevicePassesOfflineGuardWhenOfflineModeOn() {
        let originalOfflineOnly = ExtractionSettings.offlineOnly
        defer { ExtractionSettings.offlineOnly = originalOfflineOnly }
        ExtractionSettings.offlineOnly = true

        XCTAssertNoThrow(try ExtractionSettings.assertProviderAllowed(.appleOnDevice))
    }

    /// This is the exact hazard the parameterized check exists to close: a
    /// caller about to run extraction with a cloud provider — whether that's
    /// the persisted setting or a one-shot `forcedProvider` override — must
    /// still be blocked while Offline mode is on. Regression test for
    /// `SubmissionPipeline.extractWithFallback`, which used to skip this
    /// guard entirely on the `forcedProvider` path.
    func testCloudProviderFailsOfflineGuardWhenOfflineModeOn() {
        let originalOfflineOnly = ExtractionSettings.offlineOnly
        defer { ExtractionSettings.offlineOnly = originalOfflineOnly }
        ExtractionSettings.offlineOnly = true

        XCTAssertThrowsError(try ExtractionSettings.assertProviderAllowed(.claude)) { error in
            guard case OfflineModeError.cloudProviderBlocked(let blocked) = error else {
                XCTFail("Expected OfflineModeError.cloudProviderBlocked, got \(error)")
                return
            }
            XCTAssertEqual(blocked, .claude)
        }
    }

    /// With Offline mode off, every provider is allowed — the guard only
    /// ever activates because of the mode, not the provider on its own.
    func testCloudProviderPassesGuardWhenOfflineModeOff() {
        let originalOfflineOnly = ExtractionSettings.offlineOnly
        defer { ExtractionSettings.offlineOnly = originalOfflineOnly }
        ExtractionSettings.offlineOnly = false

        XCTAssertNoThrow(try ExtractionSettings.assertProviderAllowed(.claude))
    }
}
