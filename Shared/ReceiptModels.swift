import Foundation

/// The kind of receipt file we handle. Kept in Shared (not the extension's
/// SharedAttachment) so the submission pipeline, Drive upload, and Claude
/// extraction — all in Shared — can reason about the file without importing
/// UIKit or the extension's view types.
enum ReceiptKind: String, Codable {
    case image
    case pdf

    /// File extension used when naming the uploaded Drive file / queued file.
    var fileExtension: String { self == .image ? "jpg" : "pdf" }

    /// MIME type sent to Drive and as the Claude content-block media_type.
    /// Image attachments are always re-encoded to JPEG before submission,
    /// so this is safe to hard-code.
    var mimeType: String { self == .image ? "image/jpeg" : "application/pdf" }
}

/// The fixed business-type vocabulary used for vendor classification, shared
/// by every call site that needs it: receipt extraction (classify once at
/// save time), the search query parser (map a phrase like "restaurants" onto
/// the same token), and the one-time backfill for pre-existing receipts.
/// Deliberately a single source of truth — schema `enum` arrays for all
/// three AI providers, in both extraction and search, are built from
/// `VendorType.allCases` rather than retyped as prose in six separate
/// prompts, so the vocabulary can't silently drift between call sites.
///
/// Near-synonym categories are deliberately merged into one bucket (e.g.
/// hardware store and home improvement store share one case) — if the
/// vocabulary offered both, a vendor like Home Depot could be filed under
/// either one, and a search for one term would silently miss receipts
/// classified under the other. One bucket per real-world concept avoids that.
enum VendorType: String, CaseIterable, Codable {
    case restaurant
    case gasStation = "gas_station"
    case grocery
    case hardwareHomeImprovement = "hardware_home_improvement"
    case retail
    case autoRepair = "auto_repair"
    case lodging
    case medical
    case professionalServices = "professional_services"
    case entertainment
    case utilities
    case other

    var displayName: String {
        switch self {
        case .restaurant: return "Restaurant"
        case .gasStation: return "Gas Station"
        case .grocery: return "Grocery"
        case .hardwareHomeImprovement: return "Hardware / Home Improvement"
        case .retail: return "Retail"
        case .autoRepair: return "Auto Repair"
        case .lodging: return "Lodging"
        case .medical: return "Medical"
        case .professionalServices: return "Professional Services"
        case .entertainment: return "Entertainment"
        case .utilities: return "Utilities"
        case .other: return "Other"
        }
    }

    static var allRawValues: [String] { allCases.map(\.rawValue) }

    /// nil for anything not exactly matching a known token — callers should
    /// treat that as "unrecognized," not silently coerce to `.other`.
    static func from(_ raw: String?) -> VendorType? {
        guard let raw else { return nil }
        return VendorType(rawValue: raw.lowercased().trimmingCharacters(in: .whitespaces))
    }
}

/// User-added vendor types beyond the fixed built-in vocabulary (e.g. "Tiki
/// Bar") — deliberately human-curated, not AI-invented: the user types it
/// once via Edit Receipt's "Add Custom Type…", it's saved here, and every
/// future receipt (and search) can reuse that exact same token. This is the
/// same reasoning that makes user-added Categories safe (CategoryStore) —
/// a small, deliberately-grown list stays consistent, whereas letting the
/// model freely invent new labels per receipt was the exact problem the
/// fixed VendorType vocabulary was built to avoid.
enum CustomVendorTypeStore {
    private static let defaults = UserDefaults(suiteName: AppConstants.appGroupID)!
    private static let key = "customVendorTypes"

    static var customTypes: [String] {
        get { defaults.stringArray(forKey: key) ?? [] }
        set { defaults.set(newValue, forKey: key) }
    }

    /// Adds a new custom type if it's non-empty and doesn't collide
    /// (case-insensitively) with a built-in type or an existing custom one.
    /// Returns the canonical stored string to select immediately — either
    /// the newly-added one, or the existing match if it already existed.
    @discardableResult
    static func add(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if VendorType.allRawValues.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return nil
        }
        if let existing = customTypes.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        var updated = customTypes
        updated.append(trimmed)
        customTypes = updated
        return trimmed
    }

    /// Removes a custom type from the pickable list. Any receipt already
    /// tagged with it keeps that string as-is (same behavior as deleting a
    /// Category) — it just stops being offered for future receipts.
    static func remove(at offsets: IndexSet) {
        var updated = customTypes
        updated.remove(atOffsets: offsets)
        customTypes = updated
    }
}

/// Resolves a vendor-type token against *everything* currently valid — the
/// fixed `VendorType` vocabulary plus whatever custom types the user has
/// added — used everywhere a model's output (extraction, search-query
/// parsing, backfill classification) needs validating against the full set,
/// not just the built-in enum. Kept separate from `VendorType` itself since
/// custom types have no corresponding enum case (Swift enums are static).
enum VendorTypeToken {
    /// Every string an AI schema `enum` should currently allow.
    static var allValidValues: [String] { VendorType.allRawValues + CustomVendorTypeStore.customTypes }

    /// The canonical stored form of `raw` if it matches a built-in or custom
    /// type (case-insensitive), or nil if it matches neither.
    static func resolve(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let builtin = VendorType(rawValue: trimmed.lowercased()) { return builtin.rawValue }
        return CustomVendorTypeStore.customTypes.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Display label for any valid vendor-type token, built-in or custom.
    static func displayName(for raw: String) -> String {
        if let builtin = VendorType(rawValue: raw) { return builtin.displayName }
        return raw
    }
}

/// Structured data Claude reads off a receipt. All fields are strings so they
/// round-trip cleanly into a spreadsheet row.
struct ExtractedReceipt {
    let vendor: String
    let workDate: String   // normalized to yyyy-MM-dd
    let amount: String     // plain number, no currency symbol
    let comments: String
    /// A `VendorType` raw value, or empty string if the model couldn't
    /// confidently place it (treated the same as "unclassified" —
    /// searchable later via the backfill action, never blocks saving).
    let vendorType: String
    /// True if the extraction backend reported low confidence, or a heuristic
    /// safety net (empty vendor/amount, unparseable date) caught a likely-bad
    /// read. Model-agnostic by design: whatever fills these in — Claude today,
    /// an on-device model later — the HITL flow downstream is the same.
    let needsReview: Bool
    let reviewReason: String

    /// Heuristic safety net shared by every `ReceiptExtractor` — independent
    /// of whatever confidence the model itself reports, catches empty
    /// vendor/amount, an unparseable date (which `ClaudeService.normalizeDate`
    /// silently defaults to today), or an implausible-but-well-formed date.
    /// Keeping this in one place means Claude, OpenAI, and Gemini all get
    /// identical HITL flagging behavior.
    ///
    /// `sourceText`, when available (the OCR'd receipt text), is cross-checked
    /// against the model's reported date via `ReceiptDateDetector` — a
    /// deterministic second opinion that catches a model reporting a date
    /// that doesn't actually appear on the receipt (confirmed real failure:
    /// a model that correctly wrote "Ordered at 8/8/26" into Comments while
    /// reporting a *different* date as workDate — it recognized the date
    /// fine, it just populated the wrong field). `nil` (full-image paths that
    /// never OCR) skips this check entirely — behavior identical to before.
    static func build(vendor: String, rawWorkDate: String, amount: String, comments: String,
                      rawVendorType: String, modelReportedLowConfidence: Bool, modelReason: String,
                      sourceText: String? = nil) -> ExtractedReceipt {
        var needsReview = modelReportedLowConfidence
        var reason = modelReason
        if vendor.isEmpty {
            needsReview = true
            if reason.isEmpty { reason = "Vendor name missing" }
        }
        if amount.isEmpty || Double(amount) == nil || Double(amount) == 0 {
            needsReview = true
            if reason.isEmpty { reason = "Amount missing or unreadable" }
        } else if let sourceText, let amountValue = Double(amount) {
            // Cross-check against what's actually printed — a model asked
            // for a grand total that's blank on the receipt (tip line never
            // filled in, no total written) can fabricate a plausible-looking
            // number rather than returning empty, the same failure mode
            // ReceiptDateDetector catches for dates. Confirmed real case: a
            // receipt with a blank TOTAL AMOUNT line and only "$66.23"
            // printed came back with $142.51 saved.
            //
            // Unlike the date check, this never auto-corrects: a receipt has
            // many numbers (line items, subtotal, tax, tip, card digits),
            // so guessing which one is "the" total risks writing a
            // different wrong figure into a tax record. Flag only.
            //
            // An empty detector result means "this receipt's amount format
            // wasn't recognized," not "the model invented it" — same
            // reasoning as the date guardrail's empty-detector case.
            let printed = ReceiptAmountDetector.amounts(in: sourceText)
            let normalizedAmount = String(format: "%.2f", amountValue)
            if !printed.isEmpty && !printed.contains(normalizedAmount) {
                needsReview = true
                if reason.isEmpty {
                    reason = "Amount $\(amount) isn't printed on this receipt — please check it."
                }
            }
        }
        // Accept any format receipts actually use (M/d/yy, MM/dd/yyyy, …), not
        // just yyyy-MM-dd — otherwise a correctly-read date in the receipt's
        // own format would be treated as "unreadable" and dropped for today.
        var resolvedWorkDate = ClaudeService.normalizeDate(rawWorkDate)
        if let parsed = ClaudeService.flexibleDate(rawWorkDate) {
            // Well-formed but implausible: a model working from noisy OCR
            // text (no visual layout to anchor on) can hallucinate a
            // plausible-looking date rather than admitting none was found —
            // this catches that even though it passes the parse check above.
            let calendar = Calendar.current
            if parsed > calendar.date(byAdding: .day, value: 1, to: Date())! {
                needsReview = true
                if reason.isEmpty { reason = "Date is in the future" }
            } else if parsed < calendar.date(byAdding: .month, value: -15, to: Date())! {
                needsReview = true
                if reason.isEmpty { reason = "Date is over a year old — please confirm" }
            }

            if let sourceText {
                let printed = ReceiptDateDetector.dates(in: sourceText)
                let parsedDay = calendar.startOfDay(for: parsed)
                // Empty means the receipt's date format isn't one
                // NSDataDetector recognizes — NOT that the model invented
                // its answer. Acting on an empty result would punish
                // correct reads on unusual receipts, so we only judge when
                // the detector actually found something.
                if !printed.isEmpty && !printed.contains(parsedDay) {
                    needsReview = true
                    if printed.count == 1 {
                        // Unambiguous: the receipt shows exactly one date
                        // and it isn't the one the model reported.
                        // Deterministic text beats model inference here —
                        // take the printed date. Still flagged, so the
                        // correction is visible, but the *stored* value is
                        // right even if the user never looks.
                        let formatter = DateFormatter()
                        formatter.locale = Locale(identifier: "en_US_POSIX")
                        formatter.dateFormat = AppConstants.sheetDateFormat
                        resolvedWorkDate = formatter.string(from: printed[0])
                        if reason.isEmpty {
                            reason = "Date corrected to \(resolvedWorkDate) — the receipt shows that, not \(rawWorkDate). Please confirm."
                        }
                    } else if reason.isEmpty {
                        // Genuine ambiguity (multiple dates on the receipt,
                        // model's answer matches none) — flag, don't guess.
                        reason = "Date \(rawWorkDate) doesn't appear on this receipt. Please confirm."
                    }
                }
            }
        } else {
            needsReview = true
            // Include the actual string the AI returned (when there was one)
            // so a future "why didn't this parse?" is answerable by reading
            // the review reason instead of re-scanning and guessing. Both
            // branches end in "defaulted to today" — callers that need to
            // detect this case (the "set the date" prompt) match on that
            // suffix rather than the exact string, so this stays compatible.
            if reason.isEmpty {
                reason = rawWorkDate.isEmpty
                    ? "Date unreadable, defaulted to today"
                    : "Couldn't parse date: \"\(rawWorkDate)\" — defaulted to today"
            }
        }
        // Only ever store a recognized token (built-in or custom) or empty —
        // never let a model's free-text deviation into the vocabulary
        // silently corrupt it.
        let resolvedVendorType = VendorTypeToken.resolve(rawVendorType) ?? ""
        return ExtractedReceipt(
            vendor: vendor,
            workDate: resolvedWorkDate,
            amount: amount,
            comments: comments,
            vendorType: resolvedVendorType,
            needsReview: needsReview,
            reviewReason: reason)
    }
}

/// Shared prompt preamble every `ReceiptExtractor` prepends to its request —
/// keeping this in one place means Claude/OpenAI/Gemini give the model
/// identical grounding. Two things an LLM has no way to know on its own:
/// today's date (so it can judge "is this date plausible?" instead of
/// guessing blind) and what this category is actually for (so it can write
/// better Comments and sanity-check whether the receipt looks like it
/// belongs), if the user bothered to write one.
enum ExtractionPrompt {
    /// `modelNormalizesDate` controls who converts the receipt's printed date
    /// into `yyyy-MM-dd`. The cloud models (Claude/OpenAI/Gemini/Perplexity)
    /// do it themselves reliably, so they get today's date for plausibility
    /// grounding plus an explicit format instruction.
    ///
    /// Apple's small on-device model passes `false`, for a confirmed reason:
    /// asking it to both *find* the date and *reformat* it is two tasks, and
    /// when it couldn't manage the conversion it fell back to copying the one
    /// correctly-formatted yyyy-MM-dd string in its context — today's date,
    /// handed to it by this very preamble. That produced a well-formed but
    /// wrong date that passed every downstream plausibility check silently
    /// (real case: a receipt printed "Ordered: 8/8/26 2:29 PM" saved as
    /// today's date, while the model's own Comments correctly quoted
    /// "8/8/26"). So for that model this omits today's date entirely — no
    /// copyable target — and asks only for the date exactly as printed,
    /// leaving normalization to `ClaudeService.flexibleDate`, which handles
    /// the receipt formats deterministically.
    static func preamble(categoryContext: String, modelNormalizesDate: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = AppConstants.sheetDateFormat

        let dateGrounding = modelNormalizesDate
            ? "Today's date is \(formatter.string(from: Date())), given only so you can judge whether a date you find is plausible — never output today's date as the receipt's date unless the receipt itself clearly shows that date. "
            : ""
        let formatInstruction = modelNormalizesDate
            ? "Output it as yyyy-MM-dd, expanding a 2-digit year to 20YY (so 3/20/24 becomes 2024-03-20). "
            : "Copy the date exactly as it is printed on the receipt — do not convert, reformat, or reorder it, and never substitute a date from anywhere else. "

        var lines = [dateGrounding + "The transaction date can appear near the top (often beside a check or order number) or in the payment / card-approval block near the bottom — check both. Look for labels like \"Date\", \"Ordered\", \"Order Date\", \"Transaction Date\", \"Sale Date\", or \"Served\" (e.g. a line like \"Date: 3/20/24\" or \"Ordered: 8/8/26\"). " + formatInstruction + "Only if there is genuinely no date anywhere, return an empty string — never guess or invent one."]
        if !categoryContext.isEmpty {
            lines.append("This receipt is being filed under a category described by the user as: \"\(categoryContext)\". Use this to write more specific Comments, and lower your confidence if the receipt looks unrelated to this description.")
        }
        return lines.joined(separator: " ")
    }
}

/// A backend that can turn a receipt (image/PDF bytes, or text already OCR'd
/// on-device) into structured fields. `ClaudeService` was the first and only
/// implementation; `OpenAIService`/`GeminiService` conform the same way, and
/// a future on-device Apple Intelligence backend would too — nothing
/// downstream (HITL flagging, HistoryEntry, the pipeline) needs to change
/// when the engine changes, since they all speak `ExtractedReceipt`.
protocol ReceiptExtractor {
    /// `categoryContext` is the user-written description of the category
    /// this receipt is being filed under (e.g. "Expenses for my IT company",
    /// "Rental property — Monteras St"), if one was set — gives the model
    /// real signal for writing better Comments and judging whether a receipt
    /// looks like it belongs. Empty string if the category has no description.
    func extract(data: Data, kind: ReceiptKind, categoryContext: String) async throws -> ExtractedReceipt
    func extract(ocrText: String, categoryContext: String) async throws -> ExtractedReceipt
}

/// Which AI backend performs extraction. Stored in App Group UserDefaults so
/// the share extension honors the same choice as the main app.
enum ExtractionProvider: String, Codable, CaseIterable, Identifiable {
    case claude
    case openAI
    case gemini
    case perplexity
    case azureDocumentIntelligence
    case appleOnDevice

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .openAI: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .perplexity: return "Perplexity"
        case .azureDocumentIntelligence: return "Microsoft Document Intelligence"
        case .appleOnDevice: return "Apple On-Device"
        }
    }

    /// Apple On-Device requires iOS 26 + the Foundation Models framework.
    /// Selectable on iOS 26+; whether the model is actually ready on this
    /// specific device (eligible hardware + Apple Intelligence enabled) is
    /// checked at extraction time, surfacing a clear error if not.
    var isAvailable: Bool {
        guard self == .appleOnDevice else { return true }
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// Whether this provider produces bill itemization good enough to put in
    /// front of a user. Every provider *can* run `BillItemizationService`,
    /// but Apple's small on-device model isn't accurate enough on real bills
    /// to be worth offering — it has a 4,096-token context and no
    /// receipt-specific training, so complex multi-item bills come back
    /// unreliable (the same limitation documented in
    /// `FoundationModelsService.itemizeBill`). Rather than let someone hit
    /// that and conclude the feature is broken, the Check a Bill entry point
    /// is hidden entirely while this provider is selected.
    ///
    /// Deliberately keyed off the provider, not the device: a recent iPhone
    /// that *can* run Apple On-Device hits the same accuracy problem, and an
    /// older iPhone can't select it in the first place.
    var supportsBillItemization: Bool {
        self != .appleOnDevice
    }
}

/// Whether extraction sends the full image/PDF, or on-device OCR text only
/// (cheaper/faster, with an automatic full-image retry if the result looks
/// unreliable — see `SubmissionPipeline`).
enum ExtractionMode: String, Codable, CaseIterable, Identifiable {
    case fullImage
    case onDeviceOCR

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fullImage: return "Full Image"
        case .onDeviceOCR: return "On-Device OCR Text"
        }
    }
}

/// Raised when Offline mode is on but a network-dependent provider is chosen.
enum OfflineModeError: LocalizedError {
    case cloudProviderBlocked(ExtractionProvider)

    var errorDescription: String? {
        switch self {
        case .cloudProviderBlocked(let provider):
            return "Offline mode is on, so \(provider.displayName) (which needs the internet) is blocked. Switch the AI Provider to Apple On-Device in Settings, or turn off Offline mode."
        }
    }
}

/// Classifies an extraction failure as "the AI genuinely couldn't be
/// reached, but nothing is wrong with the receipt itself" vs. a real
/// failure worth queuing for retry.
///
/// This distinction matters because `ReceiptSubmitView` has a perfectly
/// good deterministic fallback (Vision OCR + `ManualEntryOCRPrefill`)
/// sitting unused — when the only problem is connectivity, the user should
/// be offered that path immediately instead of having the receipt dumped
/// into the Retry Queue with nothing extracted.
///
/// Deliberately narrow. Two categories count:
///   - `OfflineModeError.cloudProviderBlocked` — Offline mode is on and the
///     selected provider needs the network. This isn't even a network
///     *attempt*, just a local guard, but it's the same situation from the
///     user's point of view: "AI is unreachable right now, the receipt is
///     fine."
///   - A `URLError` in the "not connected" family: `.notConnectedToInternet`,
///     `.networkConnectionLost`, `.cannotFindHost`, `.cannotConnectToHost`,
///     `.timedOut`, `.dataNotAllowed`, `.internationalRoamingOff`. These are
///     all "the request never got a response from the provider" — no signal
///     at all about whether the receipt, the API key, or the request itself
///     was valid.
///
/// Deliberately NOT included: any error that reached the provider and got
/// an answer back, even an unhappy one. A bad/expired API key, a 429 rate
/// limit, a 500 from the provider, a malformed-response parse failure —
/// these all mean the network worked and something else is actually wrong,
/// so "just try again on-device" would silently hide a problem (like an
/// expired key) that the user needs to see and fix. Those still queue.
enum ExtractionFailureClass {
    case connectivity
    case other

    static func classify(_ error: Error) -> ExtractionFailureClass {
        if case OfflineModeError.cloudProviderBlocked = error {
            return .connectivity
        }
        if let urlError = error as? URLError {
            let connectivityCodes: Set<URLError.Code> = [
                .notConnectedToInternet,
                .networkConnectionLost,
                .cannotFindHost,
                .cannotConnectToHost,
                .timedOut,
                .dataNotAllowed,
                .internationalRoamingOff,
            ]
            if connectivityCodes.contains(urlError.code) {
                return .connectivity
            }
        }
        return .other
    }
}

/// Reads/writes the extraction provider + mode from App Group UserDefaults
/// (not `@AppStorage`, which defaults to `UserDefaults.standard` — the share
/// extension runs in a different sandbox and wouldn't see the same value).
enum ExtractionSettings {
    private static let defaults = UserDefaults(suiteName: AppConstants.appGroupID)!

    static var provider: ExtractionProvider {
        get {
            // Gemini is the default: it has a genuine free tier (no card,
            // no per-user cost), unlike Claude/OpenAI which always bill.
            guard let raw = defaults.string(forKey: AppConstants.DefaultsKeys.extractionProvider),
                  let value = ExtractionProvider(rawValue: raw) else { return .gemini }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: AppConstants.DefaultsKeys.extractionProvider) }
    }

    static var mode: ExtractionMode {
        get {
            guard let raw = defaults.string(forKey: AppConstants.DefaultsKeys.extractionMode),
                  let value = ExtractionMode(rawValue: raw) else { return .fullImage }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: AppConstants.DefaultsKeys.extractionMode) }
    }

    /// When true, the app refuses the cloud providers (Claude/OpenAI/Gemini)
    /// and works only with Apple's on-device model — nothing leaves the phone.
    /// Stored in the App Group so the share extension honors it too.
    static var offlineOnly: Bool {
        get { defaults.bool(forKey: AppConstants.DefaultsKeys.offlineOnly) }
        set { defaults.set(newValue, forKey: AppConstants.DefaultsKeys.offlineOnly) }
    }

    /// Throws if Offline mode is on but `provider` is a cloud provider —
    /// parameterized so a caller that's about to run extraction with some
    /// provider *other* than the persisted `ExtractionSettings.provider`
    /// (e.g. a one-shot `forcedProvider` override) can still have the
    /// Offline mode guarantee enforced against what it's actually about to
    /// use, not what happens to be saved in settings. Offline mode is a
    /// user-facing privacy commitment ("nothing leaves the phone"), so this
    /// must hold for the effective provider on every call path, not just the
    /// persisted one — the invariant needs to be structural, not something
    /// every future caller has to remember to check themselves.
    static func assertProviderAllowed(_ provider: ExtractionProvider) throws {
        if offlineOnly && provider != .appleOnDevice {
            throw OfflineModeError.cloudProviderBlocked(provider)
        }
    }

    /// Throws if Offline mode is on but the currently *selected* provider is
    /// a cloud provider. Call at the start of any extraction or search so
    /// the block is enforced everywhere (main app *and* share extension),
    /// not just hidden in the UI.
    static func assertProviderAllowed() throws {
        try assertProviderAllowed(provider)
    }

    /// True when the currently selected provider can actually run right now —
    /// either it needs no key (Apple On-Device, and only when the model is
    /// actually ready on this device) or its key/credentials are saved.
    /// Lives here (not just in the app target) because the capture fallback
    /// in `ReceiptSubmitView`/`SubmissionPipeline` needs it too, and those
    /// compile into the share extension as well.
    static var aiConfigured: Bool {
        switch provider {
        case .appleOnDevice:
            return appleOnDeviceReady
        case .claude:
            return KeychainHelper.get(AppConstants.KeychainKeys.anthropicAPIKey) != nil
        case .openAI:
            return KeychainHelper.get(AppConstants.KeychainKeys.openAIAPIKey) != nil
        case .gemini:
            return KeychainHelper.get(AppConstants.KeychainKeys.geminiAPIKey) != nil
        case .perplexity:
            return KeychainHelper.get(AppConstants.KeychainKeys.perplexityAPIKey) != nil
        case .azureDocumentIntelligence:
            return KeychainHelper.get(AppConstants.KeychainKeys.azureDocIntelKey) != nil
                && KeychainHelper.get(AppConstants.KeychainKeys.azureDocIntelEndpoint) != nil
        }
    }

    /// Whether Apple's on-device model is usable on this device *right now*,
    /// independent of whether it's the currently-configured provider. Mirrors
    /// the availability dance `aiConfigured` does for the `.appleOnDevice`
    /// case, but exposed standalone so callers can ask "could I fall back to
    /// on-device AI?" without switching `provider` first — e.g.
    /// `ReceiptSubmitView` offering it as a one-shot override when the
    /// user's actually-configured provider (Claude, Gemini, ...) can't be
    /// reached. `SystemLanguageModel.default.availability` reflects device
    /// eligibility + Apple Intelligence being enabled + the model being
    /// downloaded, none of which this app can query cheaply outside
    /// `FoundationModelsService`, so the check has to be gated the same way
    /// that file is (iOS 26+ and the framework actually importable — the
    /// share extension and older toolchains still need to compile this).
    static var appleOnDeviceReady: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return FoundationModelsService.isModelReady }
        #endif
        return false
    }

    /// The extractor instance for a given provider — factored out of
    /// `currentExtractor()` so a caller can resolve the extractor for a
    /// provider *other* than the persisted setting (a one-shot override)
    /// without touching `provider` itself, which is a shared App Group
    /// setting the share extension also reads.
    static func extractor(for provider: ExtractionProvider) -> ReceiptExtractor {
        switch provider {
        case .claude: return ClaudeService()
        case .openAI: return OpenAIService()
        case .gemini: return GeminiService()
        case .perplexity: return PerplexityService()
        case .azureDocumentIntelligence: return AzureDocumentIntelligenceService()
        case .appleOnDevice:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) { return FoundationModelsService() }
            #endif
            return GeminiService() // fallback on older OS / toolchains
        }
    }

    /// The extractor instance for the currently selected provider.
    static func currentExtractor() -> ReceiptExtractor {
        extractor(for: provider)
    }
}

// MARK: - Archive & Backup

enum BackupReminderFrequency: String, Codable, CaseIterable, Identifiable {
    case off, weekly, monthly

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .off: return "Off"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }
    var intervalDays: Int? {
        switch self {
        case .off: return nil
        case .weekly: return 7
        case .monthly: return 30
        }
    }
}

/// Backup stamp + reminder preference, in App Group defaults.
enum BackupSettings {
    private static let defaults = UserDefaults(suiteName: AppConstants.appGroupID)!

    static var lastBackupDate: Date? {
        get { defaults.object(forKey: AppConstants.DefaultsKeys.lastBackupDate) as? Date }
        set { defaults.set(newValue, forKey: AppConstants.DefaultsKeys.lastBackupDate) }
    }

    static var reminderFrequency: BackupReminderFrequency {
        get {
            // Defaults to Weekly, not Off — `AutoBackupService` relies on
            // this being on so backups actually happen without anyone
            // having to find and flip the setting first (see the 2025
            // restore incident this was built to prevent). Still
            // one-line-overridable from Settings for anyone who wants Off.
            guard let raw = defaults.string(forKey: AppConstants.DefaultsKeys.backupReminderFrequency),
                  let value = BackupReminderFrequency(rawValue: raw) else { return .weekly }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: AppConstants.DefaultsKeys.backupReminderFrequency) }
    }


    /// True if a *reminder alert* is due: frequency isn't Off, at least one
    /// backup has ever been made (no nagging a user who's never backed up
    /// once — that's a decision to surface once, on the Archive & Backup
    /// screen itself, not a repeated interruption), and enough days have
    /// passed.
    static func isReminderDue() -> Bool {
        guard let days = reminderFrequency.intervalDays, let lastBackupDate else { return false }
        return Date().timeIntervalSince(lastBackupDate) >= Double(days) * 86400
    }

    /// True if an *automatic, silent* backup should run (see
    /// `AutoBackupService`). Deliberately looser than `isReminderDue()` in
    /// exactly one case: a user who has never backed up.
    ///
    /// The "never nag someone who's never backed up" rule above is right for
    /// an alert, but applying it to the silent backup created a trap — with
    /// no `lastBackupDate`, no auto-backup ran, which meant `lastBackupDate`
    /// stayed nil forever. Auto-backup could never bootstrap itself, so
    /// anyone who didn't manually find "Backup Now" had *zero* backups
    /// indefinitely, while receipts are (by default) excluded from iCloud —
    /// i.e. a lost phone lost everything. Nothing is nagged here because
    /// there's no UI at all, so the reasoning simply doesn't transfer.
    ///
    /// Still gated on actually having receipts, preserving the original
    /// intent of not spending a backup slot on an empty app.
    static func isAutoBackupDue() -> Bool {
        guard reminderFrequency.intervalDays != nil else { return false }
        guard lastBackupDate != nil else { return !SubmissionStore.loadHistory().isEmpty }
        return isReminderDue()
    }
}

enum ArchiveBackupError: LocalizedError {
    case noReceipts

    var errorDescription: String? {
        "No receipts found for that period."
    }
}

/// Builds Archive (period-scoped) and Backup (everything) zip exports.
/// "Period" is defined by each receipt's work date, falling back to its scan
/// date when the work date is missing/unparseable — mirroring the Receipts
/// screen's own grouping logic, so an archive matches what you'd see there.
enum ArchiveBackupService {
    static func periodDate(for entry: HistoryEntry) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = AppConstants.sheetDateFormat
        if !entry.workDate.isEmpty, let parsed = formatter.date(from: entry.workDate) {
            return parsed
        }
        return entry.timestamp
    }

    static func availableYears() -> [Int] {
        let years = SubmissionStore.loadHistory().map { Calendar.current.component(.year, from: periodDate(for: $0)) }
        return Array(Set(years)).sorted(by: >)
    }

    static func availableMonths(inYear year: Int) -> [Int] {
        let months = entries(inYear: year).map { Calendar.current.component(.month, from: periodDate(for: $0)) }
        return Array(Set(months)).sorted()
    }

    static func entries(inYear year: Int) -> [HistoryEntry] {
        SubmissionStore.loadHistory().filter { Calendar.current.component(.year, from: periodDate(for: $0)) == year }
    }

    static func entries(inYear year: Int, month: Int) -> [HistoryEntry] {
        SubmissionStore.loadHistory().filter {
            let date = periodDate(for: $0)
            let calendar = Calendar.current
            return calendar.component(.year, from: date) == year && calendar.component(.month, from: date) == month
        }
    }

    static func entries(from start: Date, to end: Date) -> [HistoryEntry] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: start)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
        return SubmissionStore.loadHistory().filter {
            let date = periodDate(for: $0)
            return date >= startOfDay && date < endOfDay
        }
    }

    /// Builds a period archive: per-category folders (hard-linked photos +
    /// extras, never copies — zero extra disk space) plus a CSV filtered
    /// from the real on-disk logs so Comments survive. `includeEverything`
    /// (used by `buildFullBackup`) also writes manifest.json + history.json
    /// at the zip root — never Keychain/API keys, which must never leave
    /// the device in a file that could be AirDropped or emailed.
    static func buildArchive(label: String, entries: [HistoryEntry], includeEverything: Bool = false) throws -> URL {
        guard !entries.isEmpty else { throw ArchiveBackupError.noReceipts }

        // The label-named folder goes *inside* a throwaway UUID parent:
        // `.forUploading` zips include the zipped folder itself as the zip's
        // top-level entry, so this is the name users see when they unzip the
        // backup in the Files app (and the folder Restore expects to find).
        let tempParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReceiptDropArchive_\(UUID().uuidString)", isDirectory: true)
        let tempRoot = tempParent.appendingPathComponent(label, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempParent) }

        let byCategory = Dictionary(grouping: entries, by: { $0.category })
        for (category, categoryEntries) in byCategory {
            let categoryFolder = tempRoot.appendingPathComponent(category, isDirectory: true)
            try FileManager.default.createDirectory(at: categoryFolder, withIntermediateDirectories: true)

            for entry in categoryEntries {
                for filename in [entry.receiptLink] + entry.extraFiles {
                    guard !filename.isEmpty, !SubmissionPipeline.isPlaceholderLabel(filename),
                          let source = LocalReceiptStore.existingFileURL(category: category, filename: filename) else { continue }
                    let dest = categoryFolder.appendingPathComponent(filename)
                    guard !FileManager.default.fileExists(atPath: dest.path) else { continue }
                    // Hard link (zero extra bytes on APFS); fall back to a
                    // copy if linking fails for any reason.
                    if (try? FileManager.default.linkItem(at: source, to: dest)) == nil {
                        try? FileManager.default.copyItem(at: source, to: dest)
                    }
                }
            }

            let csvContent = LocalReceiptStore.filteredCSV(category: category, entries: categoryEntries)
            try csvContent.write(to: categoryFolder.appendingPathComponent("\(category)_log.csv"), atomically: true, encoding: .utf8)
        }

        if includeEverything {
            let manifest: [String: Any] = [
                "categories": CategoryStore.shared.categories,
                "categoryDescriptions": CategoryStore.shared.descriptions,
                "extractionProvider": ExtractionSettings.provider.rawValue,
                "extractionMode": ExtractionSettings.mode.rawValue,
                "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                "backupDate": ISO8601DateFormatter().string(from: Date()),
            ]
            if let manifestData = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
                try manifestData.write(to: tempRoot.appendingPathComponent("manifest.json"))
            }
            let historyEncoder = JSONEncoder()
            historyEncoder.dateEncodingStrategy = .iso8601
            historyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let historyData = try? historyEncoder.encode(SubmissionStore.loadHistory()) {
                try historyData.write(to: tempRoot.appendingPathComponent("history.json"))
            }
        }

        return try LocalReceiptStore.zipFolder(at: tempRoot, name: label)
    }

    /// Everything: all receipts, drained first so nothing the share
    /// extension wrote since the app was last opened gets missed. Moves the
    /// finished zip into the on-device backup library (Documents/Backups)
    /// rather than leaving it in tmp — that's what lets Restore list past
    /// backups by date instead of requiring the document picker every time.
    /// Prunes to the 3 most recent afterward, since each retained backup
    /// costs roughly the full size of your photos.
    @discardableResult
    static func buildFullBackup() throws -> URL {
        LocalReceiptStore.drainSpoolIntoDocuments()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let label = "ReceiptDrop_Backup_\(formatter.string(from: Date()))"
        let tempZipURL = try buildArchive(label: label, entries: SubmissionStore.loadHistory(), includeEverything: true)

        guard let backupsFolder = LocalReceiptStore.backupsFolderURL() else {
            return tempZipURL
        }
        let finalURL = backupsFolder.appendingPathComponent(tempZipURL.lastPathComponent)
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: tempZipURL, to: finalURL)
        LocalReceiptStore.pruneBackups(keeping: 3)
        return finalURL
    }
}

enum RestoreError: LocalizedError {
    case notAFullBackup

    var errorDescription: String? {
        "This is an Archive export, not a full backup — Restore needs a zip made with \"Backup Now\"."
    }
}

struct RestoreSummary {
    var receiptsRestored = 0
    var receiptsSkipped = 0
    /// Suspected duplicates found across every category this restore
    /// touched (whichever categories the restored receipts actually landed
    /// in — the original ones, or the single target category) — not just
    /// among the newly-restored entries, since a duplicate could be one
    /// already on this phone matching one just restored. Never
    /// auto-resolved — see `DuplicateReviewView`.
    var duplicatePairs: [DuplicateDetectionService.Pair] = []
    /// Photos reattached to receipts that were already in the list — the
    /// device-restore case, where iCloud brought back the ledger (App Group
    /// history isn't excluded from backup) but not the (deliberately
    /// excluded) image files. Distinct from `receiptsRestored`, which only
    /// counts entries new to history.
    var photosReattached = 0
    /// Category names newly created by this restore — from the backup's
    /// manifest, or backfilled from the restored entries themselves when the
    /// manifest didn't list one. Worth surfacing on its own: a category can
    /// appear here with zero of its receipts actually landing in
    /// `receiptsRestored` (every entry that would have used it turned out to
    /// already be present), which would otherwise look like nothing happened
    /// even though a new, empty category now sits in the list with no
    /// explanation for why.
    var categoriesAdded: [String] = []
}

/// Restores a full backup zip (from `ArchiveBackupService.buildFullBackup`).
/// Strictly additive: never overwrites or deletes anything already on this
/// phone — only adds what's missing, matched by `HistoryEntry.id`. Safe to
/// run on the same zip twice (second run reports everything as skipped) and
/// safe to run into a phone that already has receipts (a merge, not a wipe).
enum RestoreService {
    /// Cheap pre-check ("does this zip even have the files Restore needs?")
    /// so a picked file can be rejected the instant it's chosen, with the
    /// exact same message `restore(zipURL:)` would eventually throw — rather
    /// than only discovering the problem after the user has also chosen a
    /// target category and tapped Restore. Reads only the zip's central
    /// directory (via `MinimalZipReader.listEntryNames`), never extracts or
    /// decompresses anything.
    static func isFullBackup(zipURL: URL) -> Bool {
        guard let names = try? MinimalZipReader.listEntryNames(zipURL: zipURL) else { return false }
        // `.forUploading` zips wrap everything in one label-named folder, so
        // these files sit one path segment down rather than at the zip
        // root — matched the same way `restore(zipURL:)` itself accepts
        // either layout.
        let hasHistory = names.contains { $0 == "history.json" || $0.hasSuffix("/history.json") }
        let hasManifest = names.contains { $0 == "manifest.json" || $0.hasSuffix("/manifest.json") }
        return hasHistory && hasManifest
    }

    /// `targetCategory`, if given, redirects every restored receipt into
    /// that one category regardless of what category it was under on the
    /// source phone — useful for importing another iPhone's backup as a
    /// visibly separate batch (e.g. two phones both having a "DTG" category
    /// that mean different things) rather than silently merging into
    /// same-named categories here. `nil` keeps today's behavior: each
    /// receipt stays under its original category name, creating any that
    /// don't already exist on this phone.
    static func restore(zipURL: URL, targetCategory: String? = nil) throws -> RestoreSummary {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReceiptDropRestore_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try MinimalZipReader.extract(zipURL: zipURL, to: tempRoot)

        // `.forUploading`-created zips contain the zipped folder itself as
        // their top-level entry, so the backup's files usually sit one
        // directory down from the extraction root. Accept either layout:
        // top-level, or nested in a single subfolder.
        var contentRoot = tempRoot
        if !FileManager.default.fileExists(atPath: contentRoot.appendingPathComponent("history.json").path) {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: contentRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            let subdirs = children.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            if subdirs.count == 1 { contentRoot = subdirs[0] }
        }

        let historyURL = contentRoot.appendingPathComponent("history.json")
        let manifestURL = contentRoot.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: historyURL.path),
              FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw RestoreError.notAFullBackup
        }

        // Importing into one target category shouldn't also silently create
        // every category name the source phone happened to have — only the
        // one category actually being used should show up here.
        var categoriesAdded: [String] = []
        if targetCategory == nil {
            categoriesAdded += restoreManifest(at: manifestURL, isFreshInstall: SubmissionStore.loadHistory().isEmpty)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var backupEntries = try decoder.decode([HistoryEntry].self, from: Data(contentsOf: historyURL))

        // The file/CSV each entry needs to pull from inside the extracted
        // zip lives under its *original* category folder — remembered here
        // before any remap below, since `entry.category` itself is about to
        // become the (possibly different) destination category.
        let sourceCategories = Dictionary(uniqueKeysWithValues: backupEntries.map { ($0.id, $0.category) })

        if let targetCategory {
            CategoryStore.shared.add(targetCategory)
            backupEntries = backupEntries.map { entry in
                HistoryEntry(
                    id: entry.id, category: targetCategory, vendor: entry.vendor,
                    workDate: entry.workDate, amount: entry.amount,
                    receiptLink: entry.receiptLink, timestamp: entry.timestamp,
                    verificationStatus: entry.verificationStatus, reviewReason: entry.reviewReason,
                    extraFiles: entry.extraFiles, vendorType: entry.vendorType)
            }
        }

        // Backfill the category list from the entries themselves, not just
        // the manifest. `restoreManifest` covers the normal case, but it's
        // skipped entirely for a targeted import, and a hand-edited or
        // older-format zip can carry entries whose category never appears in
        // `manifest["categories"]` at all. Either way the receipts would
        // land in history with no matching filter pill — visible under "All"
        // and nowhere else. `add` is a no-op for anything already present
        // (case-insensitively), so this only ever fills real gaps.
        for category in Set(backupEntries.map(\.category)) where !category.isEmpty {
            if CategoryStore.shared.add(category) { categoriesAdded.append(category) }
        }

        let existingEntries = SubmissionStore.loadHistory()
        let existingByID = Dictionary(uniqueKeysWithValues: existingEntries.map { ($0.id, $0) })
        let existingIDs = Set(existingByID.keys)
        let newEntries = backupEntries.filter { !existingIDs.contains($0.id) }

        // Copy files for EVERY entry in the backup, not just new ones — an
        // entry can already be in history (its metadata rode along in an
        // iCloud device backup, since only the receipt image folders are
        // excluded from that, not the App Group history list) while its
        // photo is still missing (the excluded folder came back empty).
        // `importFile` no-ops when the destination already exists, so this
        // is safe: receipts that still have their photo are untouched, and
        // this only ever fills in what's actually missing.
        //
        // For an entry that already exists on this phone, which filenames
        // count as "still missing, please restore" comes from the LIVE
        // entry, not the backup's own copy of it. A backup taken before the
        // user deliberately deleted a photo (EditReceiptView's Delete
        // Photo, or removing an extra attachment) still has the real
        // filename in its snapshot — `mergeHistory` never overwrites an
        // existing entry, so the deletion stays correct in the visible
        // list, but without this the file itself would get silently copied
        // back onto disk as an orphan nothing points to, and
        // `photosReattached` would claim a recovery that didn't actually
        // happen from the user's point of view.
        var photosReattached = 0
        for entry in backupEntries {
            let sourceCategory = sourceCategories[entry.id] ?? entry.category
            let liveEntry = existingByID[entry.id]
            let isReattach = liveEntry != nil
            let expectedFilenames = liveEntry.map { [$0.receiptLink] + $0.extraFiles } ?? ([entry.receiptLink] + entry.extraFiles)
            // Destination category comes from the LIVE entry too, not the
            // backup's snapshot — same reasoning as `expectedFilenames`
            // above. A receipt renamed/merged into a different category
            // *after* the backup was taken still says the OLD category in
            // that snapshot; using it here would silently copy the file
            // into a folder the entry no longer lives in, creating an
            // orphaned duplicate with the same filename — which then
            // collides the next time something tries to move a real file
            // into that category (`moveFile`'s destination check fails on
            // "an item with the same name already exists").
            let destinationCategory = liveEntry?.category ?? entry.category
            for filename in expectedFilenames {
                guard !filename.isEmpty, !SubmissionPipeline.isPlaceholderLabel(filename) else { continue }
                let sourceURL = contentRoot.appendingPathComponent(sourceCategory).appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }
                let copied = (try? LocalReceiptStore.importFile(from: sourceURL, category: destinationCategory, filename: filename)) ?? false
                if copied && isReattach { photosReattached += 1 }
            }
        }

        for sourceCategory in Set(sourceCategories.values) {
            let backupCSVURL = contentRoot.appendingPathComponent(sourceCategory).appendingPathComponent("\(sourceCategory)_log.csv")
            guard let backupCSVText = try? String(contentsOf: backupCSVURL, encoding: .utf8) else { continue }
            try? LocalReceiptStore.mergeCSVRows(category: targetCategory ?? sourceCategory, csvText: backupCSVText)
        }

        let restoredCount = SubmissionStore.mergeHistory(backupEntries)

        // Scan every category this restore actually touched — not just the
        // newly-restored entries — since a duplicate could be an entry
        // already on this phone matching one just restored.
        let touchedCategories = Set(backupEntries.map(\.category))
        let duplicatePairs = touchedCategories.flatMap { category in
            DuplicateDetectionService.findPairs(in: SubmissionStore.loadHistory().filter { $0.category == category })
        }

        return RestoreSummary(
            receiptsRestored: restoredCount, receiptsSkipped: backupEntries.count - restoredCount,
            duplicatePairs: duplicatePairs, photosReattached: photosReattached,
            categoriesAdded: categoriesAdded)
    }

    /// Categories/descriptions merge in regardless (additive, never clobbers
    /// an existing description). Extraction provider/mode are only applied
    /// on a fresh install — restoring into an already-configured phone
    /// should never silently change live settings. Returns the category
    /// names actually newly created (not already present, case-insensitively)
    /// so the caller can tell the user a category appeared, rather than it
    /// showing up in the list with no explanation — this matters especially
    /// when that category ends up with zero receipts actually restored into
    /// it (e.g. every entry that would have used it was already present).
    private static func restoreManifest(at url: URL, isFreshInstall: Bool) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var added: [String] = []
        if let categories = manifest["categories"] as? [String] {
            for category in categories where CategoryStore.shared.add(category) {
                added.append(category)
            }
        }
        if let descriptions = manifest["categoryDescriptions"] as? [String: String] {
            for (category, description) in descriptions
            where CategoryStore.shared.description(for: category).isEmpty {
                CategoryStore.shared.setDescription(description, for: category)
            }
        }
        guard isFreshInstall else { return added }
        if let providerRaw = manifest["extractionProvider"] as? String,
           let provider = ExtractionProvider(rawValue: providerRaw), provider.isAvailable {
            ExtractionSettings.provider = provider
        }
        if let modeRaw = manifest["extractionMode"] as? String,
           let mode = ExtractionMode(rawValue: modeRaw) {
            ExtractionSettings.mode = mode
        }
        return added
    }
}

/// Human-in-the-loop status of a saved receipt, surfaced in the Receipts list.
enum VerificationStatus: String, Codable {
    case none         // no review needed, never flagged
    case needsReview  // low confidence or heuristic trigger — unreviewed
    case verified     // a human has saved this entry via Edit
}

/// A successful submission, appended to the App Group history (newest first).
struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    let category: String
    let vendor: String
    let workDate: String
    let amount: String
    let receiptLink: String
    let timestamp: Date
    var verificationStatus: VerificationStatus = .none
    var reviewReason: String = ""
    /// Extra photos/PDFs attached after the fact (e.g. a second page or a
    /// warranty slip), beyond the primary `receiptLink`. Purely supplemental —
    /// never sent to Claude, never written to the CSV. Filenames live in the
    /// same category folder as the primary file.
    var extraFiles: [String] = []
    /// A `VendorType` raw value, classified once at save time (or later via
    /// the backfill action) and never re-derived at search time. Empty
    /// string means unclassified — manual entries, entries from before this
    /// field existed, or anything the model couldn't confidently place.
    var vendorType: String = ""

    init(id: UUID = UUID(), category: String, vendor: String, workDate: String, amount: String,
         receiptLink: String, timestamp: Date,
         verificationStatus: VerificationStatus = .none, reviewReason: String = "",
         extraFiles: [String] = [], vendorType: String = "") {
        self.id = id
        self.category = category
        self.vendor = vendor
        self.workDate = workDate
        self.amount = amount
        self.receiptLink = receiptLink
        self.timestamp = timestamp
        self.verificationStatus = verificationStatus
        self.reviewReason = reviewReason
        self.extraFiles = extraFiles
        self.vendorType = vendorType
    }

    // Custom Decodable so history persisted before these fields existed
    // (App Group UserDefaults) still decodes, defaulting to `.none`/empty.
    private enum CodingKeys: String, CodingKey {
        case id, category, vendor, workDate, amount, receiptLink, timestamp
        case verificationStatus, reviewReason, extraFiles, vendorType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        category = try container.decode(String.self, forKey: .category)
        vendor = try container.decode(String.self, forKey: .vendor)
        workDate = try container.decode(String.self, forKey: .workDate)
        amount = try container.decode(String.self, forKey: .amount)
        receiptLink = try container.decode(String.self, forKey: .receiptLink)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        verificationStatus = try container.decodeIfPresent(VerificationStatus.self, forKey: .verificationStatus) ?? .none
        reviewReason = try container.decodeIfPresent(String.self, forKey: .reviewReason) ?? ""
        extraFiles = try container.decodeIfPresent([String].self, forKey: .extraFiles) ?? []
        vendorType = try container.decodeIfPresent(String.self, forKey: .vendorType) ?? ""
    }
}

/// A submission whose bytes are parked in the App Group container
/// (<container>/PendingReceipts) for the main app to run through
/// `SubmissionPipeline` later — either because it already failed once
/// (`isPending == false`, `error` explains why, shown in the Retry Queue's
/// "Why it failed" section) or because it hasn't been attempted yet
/// (`isPending == true` — e.g. a multi-photo share extension batch, which
/// can't safely run the AI round-trip inside the extension's short process
/// lifetime; see `SubmissionStore.enqueuePending` and
/// `PendingSubmissionProcessor`). Keeping these distinct means an unstarted
/// batch item never gets mislabeled as a failure in the UI.
struct QueueEntry: Codable, Identifiable {
    var id = UUID()
    let category: String
    let filename: String   // file under <container>/PendingReceipts
    let kind: ReceiptKind
    let error: String
    let timestamp: Date
    var isPending: Bool = false

    init(id: UUID = UUID(), category: String, filename: String, kind: ReceiptKind,
         error: String, timestamp: Date, isPending: Bool = false) {
        self.id = id
        self.category = category
        self.filename = filename
        self.kind = kind
        self.error = error
        self.timestamp = timestamp
        self.isPending = isPending
    }

    // Custom Decodable so queue entries persisted before `isPending` existed
    // (App Group UserDefaults) still decode, defaulting to `false` — i.e.
    // "genuine failure", which is what every existing entry actually is.
    private enum CodingKeys: String, CodingKey {
        case id, category, filename, kind, error, timestamp, isPending
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        category = try container.decode(String.self, forKey: .category)
        filename = try container.decode(String.self, forKey: .filename)
        kind = try container.decode(ReceiptKind.self, forKey: .kind)
        error = try container.decode(String.self, forKey: .error)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isPending = try container.decodeIfPresent(Bool.self, forKey: .isPending) ?? false
    }
}

/// One-time (re-runnable) maintenance action: classifies every history entry
/// still missing a `vendorType` — manual entries (never touched by any AI),
/// receipts saved before this field existed, or entries whose vendor was
/// renamed since (which resets the type, see `SubmissionPipeline.updateEntry`).
/// Safe to run anytime; only entries still empty get touched, and unique
/// vendor names are classified once each even if they appear on many receipts.
enum VendorTypeBackfillService {
    @discardableResult
    static func classifyUnclassified() async throws -> Int {
        let history = SubmissionStore.loadHistory()
        let unclassifiedVendors = Array(Set(
            history.filter { $0.vendorType.isEmpty && !$0.vendor.isEmpty }.map(\.vendor)))
        guard !unclassifiedVendors.isEmpty else { return 0 }

        let classifications = try await VendorTypeClassificationService.classify(vendorNames: unclassifiedVendors)
        guard !classifications.isEmpty else { return 0 }

        var updates: [HistoryEntry] = []
        for entry in history where entry.vendorType.isEmpty {
            guard let type = classifications[entry.vendor] else { continue }
            var updated = entry
            updated.vendorType = type
            updates.append(updated)
        }
        return SubmissionStore.updateHistoryEntries(updates)
    }
}

/// Extracts the summary totals from a receipt's OCR/layout text by scanning
/// for labeled keyword lines (Subtotal, Tax, Total, etc.). Deterministic and
/// more reliable than asking a language model to find "the grand total" on a
/// complex receipt where line-item prices are easily confused with totals.
enum BillTotalsParser {
    struct Totals {
        var subtotal: String = ""
        var tax: String = ""
        var serviceCharge: String = ""
        var total: String = ""
    }

    static func extractTotals(from text: String) -> Totals {
        var result = Totals()
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            let lower = t.lowercased()
            if result.subtotal.isEmpty,
               lower.hasPrefix("subtotal") || lower.hasPrefix("sub total") {
                result.subtotal = trailingAmount(t) ?? ""
            } else if result.tax.isEmpty,
                      lower.hasPrefix("tax") || lower.hasPrefix("sales tax") || lower.hasPrefix("state tax") {
                result.tax = trailingAmount(t) ?? ""
            } else if result.serviceCharge.isEmpty,
                      lower.hasPrefix("service") || lower.hasPrefix("gratuity") || lower.hasPrefix("grat") {
                result.serviceCharge = trailingAmount(t) ?? ""
            }
            // Keep overwriting so the LAST "Total" line wins — the grand total
            // is always the last occurrence on a restaurant check.
            if lower.hasPrefix("total") || lower.hasPrefix("grand total") ||
               lower.hasPrefix("total due") || lower.hasPrefix("amount due") ||
               lower.hasPrefix("balance due") {
                if let amt = trailingAmount(t) { result.total = amt }
            }
        }
        return result
    }

    /// Extracts the rightmost dollar amount from a line, e.g. "Total    142.51" → "142.51".
    private static func trailingAmount(_ line: String) -> String? {
        let pattern = #"(?:^|\s)\$?\s*(\d{1,6}(?:\.\d{1,2})?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        let val = String(line[range])
        return val.isEmpty ? nil : val
    }
}
