import Foundation
import Vision
#if canImport(UIKit)
import UIKit
#endif
import PDFKit
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Apple on-device (Foundation Models) extraction backend
//
// Reads a receipt entirely on-device with Apple Intelligence — no API key,
// no network. It conforms to the same `ReceiptExtractor` protocol as
// ClaudeService/OpenAIService/GeminiService, so nothing downstream (the
// pipeline, HITL flagging, history) changes when this backend is selected.
//
// Architecture: the receipt image/PDF is OCR'd on-device with Vision (the app
// already ships `VisionOCRService`), then the recognized text is handed to the
// on-device language model, which returns structured fields via *guided
// generation* (@Generable) — Apple's equivalent of Claude's forced tool call.
//
// iOS 27 multimodal: on iOS 27+ (when the on-device model reports the
// `.vision` capability) the receipt image is attached directly to the prompt
// via `Attachment`, skipping OCR entirely — the model sees the real two-column
// layout instead of flattened text, which fixes merged line items and
// misfiled totals. The OCR-text path below remains as the iOS 26 fallback
// (and the safety net if the image read fails for any reason).
//
// This file compiles behind `canImport(FoundationModels)` so the project still
// builds on toolchains without the framework; on those, selecting the provider
// throws a clear "unavailable" error instead of failing to compile.

enum FoundationModelsError: LocalizedError {
    case frameworkUnavailable
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .frameworkUnavailable:
            return "Apple On-Device extraction needs iOS 26+ and a build with the Foundation Models framework."
        case .modelUnavailable(let detail):
            return "Apple Intelligence isn't available: \(detail). Enable Apple Intelligence in Settings, or pick a different provider."
        }
    }
}

#if canImport(FoundationModels)

/// The structured result the on-device model must produce. Mirrors the
/// `record_receipt` tool schema used by the cloud providers. Kept all-strings
/// (plus the two confidence flags) so it maps 1:1 onto `ExtractedReceipt.build`.
@available(iOS 26.0, *)
@Generable
struct ReceiptDraft {
    @Guide(description: "The contractor or vendor / business name on the receipt. Empty string if not present.")
    var vendor: String

    @Guide(description: "The primary date on the receipt, copied exactly as printed (e.g. \"07/24/26\", \"March 3, 2026\" — whatever format is shown, do not convert or reformat it yourself). Empty string if none is clearly shown — never guess or invent one.")
    var workDate: String

    @Guide(description: "The GRAND TOTAL at the very bottom of the receipt — the final amount owed, appearing AFTER the subtotal and tax lines, usually labeled 'Total', 'Grand Total', or 'Amount Due'. NEVER use an individual line-item food or drink price, no matter how large. Plain number, no currency symbol, e.g. 142.51. Empty string if the bottom-of-receipt total is not found.")
    var amount: String

    @Guide(description: "A short, specific note about what was purchased or the receipt's purpose.")
    var comments: String

    @Guide(description: "Exactly one vendor-type token from the allowed list given in the prompt, or an empty string if none clearly fits. Do not invent new tokens.")
    var vendorType: String

    @Guide(description: "true if you are not confident the extracted values are correct (noisy text, ambiguous total, unclear date).")
    var lowConfidence: Bool

    @Guide(description: "A short reason when lowConfidence is true; otherwise an empty string.")
    var reviewReason: String
}

/// One line item for on-device bill itemization ("Check a Bill"). Mirrors
/// the item schema the cloud providers use in `BillItemizationService`.
@available(iOS 26.0, *)
@Generable
struct BillItemDraft {
    @Guide(description: "The item name as printed.")
    var name: String

    @Guide(description: "Whole-number quantity as a string, e.g. \"1\", \"2\". Use \"1\" if none shown.")
    var quantity: String

    @Guide(description: "This line's printed total price, plain number string, no currency symbol — the price for the whole line, already reflecting quantity, not a per-unit price.")
    var price: String
}

/// Items-only result for on-device bill itemization. Totals (subtotal, tax,
/// grand total) are extracted separately via BillTotalsParser — asking the
/// model to find "the grand total" on a complex receipt causes it to confuse
/// line-item prices with totals. Separating the two concerns fixes that.
@available(iOS 26.0, *)
@Generable
struct BillItemsDraft {
    @Guide(description: "Vendor/business name. Empty string if not present.")
    var vendor: String

    @Guide(description: "Every individual purchased line item (food, drink, product) printed on the bill, in printed order. Do NOT include subtotal, tax, service charge, tip, or total rows — only purchased items.")
    var items: [BillItemDraft]

    @Guide(description: "Count of lines that were present but genuinely illegible and omitted from items, as a string. \"0\" if none.")
    var unreadableLineCount: String
}

/// Binary item/skip label for each candidate line. The model only classifies
/// text that deterministic extraction already found — zero hallucination risk.
@available(iOS 26.0, *)
@Generable
struct ReceiptLineClassification {
    @Guide(description: "Exactly one label per input line, in the same order. 'item' = a specific purchased product or service with its own individual price. 'skip' = anything else: subtotals, discount subtotals, taxes, tip suggestions (e.g. '20% is $X'), service charges, timestamps, payment methods, room charges, coupon lines, or any receipt metadata that is not a purchased item.")
    var labels: [String]
}

/// On-device receipt extractor backed by Apple's Foundation Models framework.
@available(iOS 26.0, *)
struct FoundationModelsService: ReceiptExtractor {

    /// Image/PDF entry point. On iOS 27+ with a vision-capable model, hands
    /// the model the actual image; otherwise OCRs on-device and reasons over
    /// the text (iOS 26 path).
    func extract(data: Data, kind: ReceiptKind, categoryContext: String = "") async throws -> ExtractedReceipt {
        let imageData: Data
        switch kind {
        case .image:
            imageData = data
        case .pdf:
            // Both paths want raster image data; render the first PDF page.
            guard let rendered = Self.renderPDFPageToPNG(data) else {
                // Fall back to an empty read → HITL flags it for manual review
                // rather than throwing the submission away.
                return try await extract(ocrText: "", categoryContext: categoryContext)
            }
            imageData = rendered
        }

        #if canImport(UIKit)
        // iOS 27 multimodal: the model reads the real image, preserving the
        // two-column layout that OCR flattening destroys. `try?` so any
        // image-path failure falls through to the OCR path rather than
        // losing the submission.
        if #available(iOS 27.0, *), Self.supportsImageInput, let image = UIImage(data: imageData),
           let extracted = try? await extractFromImage(image, categoryContext: categoryContext) {
            return extracted
        }
        #endif

        let ocrText = (try? await VisionOCRService.recognizeText(in: imageData)) ?? ""
        return try await extract(ocrText: ocrText, categoryContext: categoryContext)
    }

    #if canImport(UIKit)
    /// iOS 27 image path: same instructions/output shape as the text path,
    /// minus the OCR-noise framing — the model is looking at the real photo.
    @available(iOS 27.0, *)
    private func extractFromImage(_ image: UIImage, categoryContext: String) async throws -> ExtractedReceipt {
        try Self.ensureModelAvailable()

        let vocabulary = VendorTypeToken.allValidValues.joined(separator: ", ")
        let preamble = ExtractionPrompt.preamble(categoryContext: categoryContext)

        let instructions = """
        You extract structured data from a photo of a receipt, invoice, or \
        bill. Return only what the image supports; never invent values. \
        Allowed vendor-type tokens: \(vocabulary). \
        The 'amount' must be the grand total at the very bottom of the receipt \
        (labeled 'Total' or 'Grand Total', appearing after the subtotal and tax), \
        never an individual line-item price.
        """

        let session = LanguageModelSession(instructions: instructions)
        let draft: ReceiptDraft
        do {
            let response = try await session.respond(generating: ReceiptDraft.self) {
                """
                \(preamble)

                Here is a photo of a receipt. Extract the receipt's details.
                """
                Attachment(image)
            }
            draft = response.content
        } catch {
            throw FoundationModelsError.modelUnavailable(error.localizedDescription)
        }

        return ExtractedReceipt.build(
            vendor: draft.vendor.trimmingCharacters(in: .whitespacesAndNewlines),
            rawWorkDate: draft.workDate.trimmingCharacters(in: .whitespacesAndNewlines),
            amount: draft.amount.trimmingCharacters(in: .whitespacesAndNewlines),
            comments: draft.comments.trimmingCharacters(in: .whitespacesAndNewlines),
            rawVendorType: draft.vendorType,
            modelReportedLowConfidence: draft.lowConfidence,
            modelReason: draft.reviewReason)
    }
    #endif

    /// Whether the on-device model accepts image input in prompts (varies by
    /// device/model generation, so check the capability, not just the OS).
    @available(iOS 27.0, *)
    static var supportsImageInput: Bool {
        SystemLanguageModel.default.capabilities.contains(.vision)
    }

    /// Text entry point — used directly by the Live Text "Scan Text" flow, and
    /// by the image path above after on-device OCR.
    func extract(ocrText: String, categoryContext: String = "") async throws -> ExtractedReceipt {
        try Self.ensureModelAvailable()

        let vocabulary = VendorTypeToken.allValidValues.joined(separator: ", ")
        let preamble = ExtractionPrompt.preamble(categoryContext: categoryContext)

        let instructions = """
        You extract structured data from noisy, on-device-OCR text of a receipt, \
        invoice, or bill. Return only what the text supports; never invent values. \
        Allowed vendor-type tokens: \(vocabulary). \
        On restaurant and bar receipts, ordered items (food, drinks) appear first, \
        each with an individual price; the subtotal, tax, optional service charge, \
        and GRAND TOTAL appear at the very bottom — often after a blank line or \
        dashed separator. Some receipts have a mid-receipt 'NOTE:' section listing \
        corrections or additions; those are still line items, not totals. The \
        'amount' field must always be the bottom-of-receipt grand total — never an \
        individual item price, no matter how large.
        """

        let prompt = """
        \(preamble)

        Here is text recognized from a photo of a receipt via on-device OCR. It \
        may contain recognition noise (misread characters, garbled spacing). \
        Extract the receipt's details.

        ---
        \(ocrText)
        ---
        """

        let session = LanguageModelSession(instructions: instructions)
        let draft: ReceiptDraft
        do {
            let response = try await session.respond(to: prompt, generating: ReceiptDraft.self)
            draft = response.content
        } catch {
            throw FoundationModelsError.modelUnavailable(error.localizedDescription)
        }

        // Hand off to the same model-agnostic HITL safety net every provider
        // uses — it re-checks empty vendor/amount and implausible dates.
        return ExtractedReceipt.build(
            vendor: draft.vendor.trimmingCharacters(in: .whitespacesAndNewlines),
            rawWorkDate: draft.workDate.trimmingCharacters(in: .whitespacesAndNewlines),
            amount: draft.amount.trimmingCharacters(in: .whitespacesAndNewlines),
            comments: draft.comments.trimmingCharacters(in: .whitespacesAndNewlines),
            rawVendorType: draft.vendorType,
            modelReportedLowConfidence: draft.lowConfidence,
            modelReason: draft.reviewReason)
    }

    // MARK: - Bill itemization ("Check a Bill")

    /// Bill itemization for "Check a Bill" — deterministic extraction:
    ///
    /// Items come directly from RecognizeDocumentsRequest table cells (left = name,
    /// right = price). Zero hallucination risk because the small on-device model is
    /// NOT used for item enumeration — it has a 4,096-token context window and no
    /// receipt-specific training, causing hallucination on complex receipts.
    ///
    /// Vendor name is the only scalar delegated to the on-device model, which
    /// handles single-value extraction reliably.
    ///
    /// NOTE: Private Cloud Compute (Apple server-side AI, 32K context, stronger
    /// reasoning) is wired in as Tier 1 but disabled until the
    /// com.apple.developer.private-cloud-compute entitlement is provisioned.
    /// Instantiating PrivateCloudComputeLanguageModel without that entitlement
    /// crashes the process — it does not throw a catchable Swift error.
    static func itemizeBill(data: Data) async throws -> ExtractedBill {
        try ensureModelAvailable()

        // Tier 1: RecognizeDocumentsRequest — understands formal document tables.
        // Returns paired (name, price) rows when Vision detects a structured table.
        let structuredRows = (try? await VisionLayoutService.recognizeRows(in: data)) ?? []
        let hasStructuredItems = structuredRows.contains { !$0.leftText.isEmpty && !$0.rightText.isEmpty }

        let rows: [VisionLayoutService.LayoutRow]
        if hasStructuredItems {
            rows = structuredRows
        } else {
            // Tier 2 (bounding-box) and Tier 3 (flat OCR text) run in parallel.
            //
            // Tier 2: groups VNRecognizeTextRequest observations by Y-coordinate
            // into visual rows and pairs names with trailing prices. Best for
            // thermal-printer receipts where name and price are separate observations.
            //
            // Tier 3: applies the price-suffix regex directly to flat OCR text,
            // one line at a time. Works universally — Apple Store receipts, printed
            // email receipts, any format where name+price are one merged observation.
            //
            // We use whichever tier finds more item rows (both leftText and rightText
            // populated), since a receipt format that defeats one will often work for
            // the other.
            async let tier2Task = VisionLayoutService.recognizeRowsViaRawOCR(in: data)
            async let tier3Task = VisionOCRService.recognizeText(in: data)

            let bbRows = (try? await tier2Task) ?? []
            let ocrText = (try? await tier3Task) ?? ""
            let ocrRows = VisionLayoutService.recognizeRowsFromOCRText(ocrText)

            let bbItemCount = bbRows.filter { !$0.leftText.isEmpty && !$0.rightText.isEmpty }.count
            let ocrItemCount = ocrRows.filter { !$0.leftText.isEmpty && !$0.rightText.isEmpty }.count

            rows = ocrItemCount > bbItemCount ? ocrRows : bbRows
        }

        let layoutText = VisionLayoutService.layoutString(from: rows)

        // Use layoutText for totals — each row is already "Label    Amount" on one
        // line so BillTotalsParser can pair the keyword with its trailing number.
        let totals = BillTotalsParser.extractTotals(from: layoutText)

        return try await itemizeBillDeterministically(
            rows: rows, layoutText: layoutText, totals: totals)
    }

    /// Final classification pass: the on-device model sees each candidate line
    /// we already extracted and answers one binary question — "item or skip?" —
    /// with no ability to invent new lines. Handles semantic edge cases that no
    /// keyword list can anticipate: discount subtotals ("Disc Sub Total"), tip
    /// suggestion lines ("20% is $16.60"), timestamps paired with totals ("3:03
    /// PM"), room charges, military discounts, etc.
    ///
    /// Failure mode: if the model call fails, all candidates are returned
    /// unchanged — better to show a false positive than silently drop real items.
    private static func filterCandidatesViaModel(
        _ candidates: [(name: String, quantity: String, price: String)]
    ) async -> [(name: String, quantity: String, price: String)] {
        guard !candidates.isEmpty else { return candidates }

        let lineList = candidates.enumerated()
            .map { "\($0.offset + 1). \($0.element.name)    \($0.element.price)" }
            .joined(separator: "\n")

        let session = LanguageModelSession(instructions: """
            You classify lines from a restaurant or retail receipt. For each \
            numbered line, output 'item' if it is a specific purchased product \
            or service with its own individual price. Output 'skip' for anything \
            else: subtotals, discount subtotals, taxes, tip/gratuity suggestions, \
            service charges, timestamps, payment method lines, room charges, \
            discount lines, coupons, or any other receipt metadata. Return exactly \
            one label per line in the same order.
            """)

        guard let response = try? await session.respond(
            to: "Classify these \(candidates.count) receipt lines:\n\(lineList)",
            generating: ReceiptLineClassification.self
        ) else {
            return candidates
        }

        let labels = response.content.labels
        return candidates.enumerated().compactMap { i, candidate in
            guard i < labels.count else { return candidate }
            return labels[i].lowercased().trimmingCharacters(in: .whitespaces) == "item" ? candidate : nil
        }
    }

    private static func itemizeBillDeterministically(
        rows: [VisionLayoutService.LayoutRow],
        layoutText: String,
        totals: BillTotalsParser.Totals
    ) async throws -> ExtractedBill {
        // Fast deterministic pre-filter — catches obvious non-items without a
        // model call. The model filter below handles semantic edge cases.
        let skipPrefixes = [
            "subtotal", "sub total", "tax", "service", "gratuity", "tip",
            "total", "grand total", "amount due", "change", "cash",
            "credit", "visa", "mastercard", "amex", "balance due",
            "thank", "welcome", "order", "server", "table", "guests",
            "check #", "receipt", "date", "time",
            "disc",         // "Disc Sub Total", "Discount"
            "discount",
            "room",         // "Room Charge", "Room Number"
            "coupon", "promo", "reward", "military", "senior", "adjustment",
            "please", "print", "sign", "authorization", "approved",
            "payment", "card", "discover", "aid ",
        ]
        // Substring markers: a line containing any of these is a total-section row
        // regardless of what comes before it (e.g. "Disc Sub Total", "Your Subtotal").
        let totalSubstrings = ["subtotal", "sub total", "sub-total"]

        let candidates: [(name: String, quantity: String, price: String)] = rows.compactMap { row in
            guard !row.leftText.isEmpty, !row.rightText.isEmpty else { return nil }
            let nameLower = row.leftText.lowercased().trimmingCharacters(in: .whitespaces)

            // Prefix skip
            guard !skipPrefixes.contains(where: { nameLower.hasPrefix($0) }) else { return nil }
            // Substring skip (catches "Disc Sub Total", "Happy Hour Sub Total", etc.)
            guard !totalSubstrings.contains(where: { nameLower.contains($0) }) else { return nil }
            // Merged total line: dollar amount embedded in the name
            guard row.leftText.range(of: #"\$\d"#, options: .regularExpression) == nil else { return nil }
            // Timestamp in name: "3:03 PM", "6:03 PM", etc.
            guard row.leftText.range(of: #"^\d{1,2}:\d{2}"#, options: .regularExpression) == nil else { return nil }
            // Tip/percentage suggestion: "20% is", "15% tip", "18%", etc.
            guard row.leftText.range(of: #"^\d+(\.\d+)?\s*%"#, options: .regularExpression) == nil else { return nil }

            let price = row.rightText
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "$", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard Double(price) != nil else { return nil }
            return (name: row.leftText.trimmingCharacters(in: .whitespacesAndNewlines),
                    quantity: "1",
                    price: price)
        }

        // Model classification — the semantic safety net. Classifies each candidate
        // as "item" or "skip" without being able to invent new entries.
        let finalItems = await filterCandidatesViaModel(candidates)

        // Vendor name: small model handles a single scalar from the top of
        // the receipt reliably.
        let vendor: String
        if !layoutText.isEmpty {
            let topLines = layoutText.components(separatedBy: "\n").prefix(6).joined(separator: "\n")
            let session = LanguageModelSession(instructions: "Extract the restaurant or store name from the top of this receipt text. Reply with only the business name, nothing else.")
            let resp = try? await session.respond(to: topLines)
            vendor = resp?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } else {
            vendor = ""
        }

        let unreadable = finalItems.isEmpty && !layoutText.isEmpty ? "1" : "0"
        return ExtractedBill.build(
            vendor: vendor,
            rawItems: finalItems,
            subtotal: totals.subtotal, tax: totals.tax,
            serviceCharge: totals.serviceCharge, total: totals.total,
            unreadableLineCount: unreadable)
    }

    // MARK: - Availability

    /// Whether the on-device model is usable right now (device eligible +
    /// Apple Intelligence enabled + model downloaded).
    static var isModelReady: Bool {
        switch SystemLanguageModel.default.availability {
        case .available: return true
        default: return false
        }
    }

    private static func ensureModelAvailable() throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw FoundationModelsError.modelUnavailable(String(describing: reason))
        @unknown default:
            throw FoundationModelsError.modelUnavailable("unknown status")
        }
    }

    // MARK: - PDF → image

    /// Renders a PDF's first page to PNG data at ~2x for legible OCR.
    static func renderPDFPageToPNG(_ data: Data) -> Data? {
        #if canImport(UIKit)
        guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { return nil }
        let pageRect = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.white.set()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
        return image.pngData()
        #else
        return nil
        #endif
    }
}

// MARK: - On-device search query parsing

/// The structured search filter the on-device model produces. Uses a -1
/// sentinel for "no bound" rather than optionals, so it maps cleanly onto
/// `QueryParseResult` (which does use optionals) without depending on optional
/// support in guided generation.
@available(iOS 26.0, *)
@Generable
struct QueryFilterDraft {
    @Guide(description: "The business/vendor type the query is asking about, taken from the allowed list in the prompt. Empty string if the query mentions no business type — do not force one.")
    var vendorType: String

    @Guide(description: "Minimum amount if the query implies a lower bound (e.g. 'over 100', 'at least 50'). Use -1 if none.")
    var amountMin: Double

    @Guide(description: "Maximum amount if the query implies an upper bound (e.g. 'under 20', 'below 50'). Use -1 if none.")
    var amountMax: Double
}

@available(iOS 26.0, *)
extension SemanticSearchService {
    /// Parses a free-form receipt search phrase into a structured filter,
    /// entirely on-device with Apple Intelligence — no API key. Mirrors the
    /// cloud parsers (`parseQueryViaClaude`/`Gemini`) but via guided generation.
    static func parseQueryOnDevice(_ text: String) async throws -> QueryParseResult {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw FoundationModelsError.modelUnavailable(String(describing: reason))
        @unknown default:
            throw FoundationModelsError.modelUnavailable("unknown status")
        }

        let vocabulary = VendorTypeToken.allValidValues.joined(separator: ", ")
        let instructions = """
        You turn a natural-language receipt search phrase into a structured \
        filter. Allowed vendor-type tokens: \(vocabulary). Map any mentioned \
        business type onto the closest token; leave it empty if none is \
        mentioned. Never invent tokens.
        """
        let prompt = "Parse this receipt search query: \"\(text)\""

        let session = LanguageModelSession(instructions: instructions)
        let draft: QueryFilterDraft
        do {
            draft = try await session.respond(to: prompt, generating: QueryFilterDraft.self).content
        } catch {
            throw SemanticSearchError.parsing(error.localizedDescription)
        }

        return QueryParseResult(
            vendorType: VendorTypeToken.resolve(draft.vendorType),
            amountMin: draft.amountMin < 0 ? nil : draft.amountMin,
            amountMax: draft.amountMax < 0 ? nil : draft.amountMax)
    }
}

// MARK: - On-device vendor-type classification ("Classify Untyped Receipts")

/// One type per vendor, same order as the input list — mirrors the cloud
/// providers' `vendor_types` array in `VendorTypeClassificationService`.
@available(iOS 26.0, *)
@Generable
struct VendorClassificationDraft {
    @Guide(description: "One vendor-type token per vendor, in the same order as the numbered list, from the allowed list given in the instructions.")
    var vendorTypes: [String]
}

@available(iOS 26.0, *)
extension VendorTypeClassificationService {
    /// On-device counterpart to `classify(vendorNames:)`'s cloud paths — used
    /// instead of silently sending vendor names to a cloud provider when
    /// Apple On-Device is selected (or Offline Mode requires it).
    static func classifyOnDevice(_ vendorNames: [String]) async throws -> [String: String] {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw FoundationModelsError.modelUnavailable(String(describing: reason))
        @unknown default:
            throw FoundationModelsError.modelUnavailable("unknown status")
        }

        let vocabulary = VendorTypeToken.allValidValues.joined(separator: ", ")
        let instructions = """
        You classify business names by type. Allowed vendor-type tokens: \
        \(vocabulary). Map each name onto the closest token based on what the \
        name itself suggests; use "other" only if truly nothing fits. Never \
        invent new tokens. Return exactly one token per name, in the same order \
        as the numbered list.
        """

        let session = LanguageModelSession(instructions: instructions)
        let draft: VendorClassificationDraft
        do {
            draft = try await session.respond(to: prompt(for: vendorNames), generating: VendorClassificationDraft.self).content
        } catch {
            throw VendorTypeClassificationError.api(error.localizedDescription)
        }

        return zip(vendorNames, with: draft.vendorTypes)
    }
}

#endif
