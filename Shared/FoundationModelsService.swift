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

    @Guide(description: "The receipt total as a plain number with no currency symbol or thousands separators, e.g. 42.10. Empty string if unreadable.")
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

/// The structured result for on-device bill itemization. Mirrors the
/// `record_bill` schema used by the cloud providers in
/// `BillItemizationService`, kept all-strings so it maps 1:1 onto
/// `ExtractedBill.build`.
@available(iOS 26.0, *)
@Generable
struct BillDraft {
    @Guide(description: "Vendor/business name. Empty string if not present.")
    var vendor: String

    @Guide(description: "Every line item printed on the bill, in printed order.")
    var items: [BillItemDraft]

    @Guide(description: "Printed subtotal, empty string if not shown.")
    var subtotal: String

    @Guide(description: "Printed tax amount, empty string if not shown.")
    var tax: String

    @Guide(description: "Printed service charge/tip, empty string if not shown.")
    var serviceCharge: String

    @Guide(description: "Printed grand total, empty string if not shown.")
    var total: String

    @Guide(description: "Count of lines that were present but genuinely illegible and omitted from items, as a string. \"0\" if none.")
    var unreadableLineCount: String
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
        Allowed vendor-type tokens: \(vocabulary).
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
        Allowed vendor-type tokens: \(vocabulary).
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

    /// On-device counterpart to `BillItemizationService`'s cloud-provider
    /// paths — same OCR-first architecture as `extract(data:kind:)` above,
    /// but asking for an itemized breakdown instead of just vendor/date/
    /// total. Kept in this file (not `BillItemizationService`) since it
    /// needs the same `@available`/`canImport(FoundationModels)` gating as
    /// the rest of the on-device backend.
    static func itemizeBill(data: Data) async throws -> ExtractedBill {
        try ensureModelAvailable()

        #if canImport(UIKit)
        // iOS 27 multimodal: itemization is where OCR flattening hurt most
        // (merged line items, footers read as items, totals misfiled) — the
        // model reading the actual photo keeps each item's name and price
        // visually paired. Falls through to the OCR path on any failure.
        if #available(iOS 27.0, *), supportsImageInput, let image = UIImage(data: data),
           let bill = try? await itemizeBillFromImage(image) {
            return bill
        }
        #endif

        let ocrText = (try? await VisionOCRService.recognizeText(in: data)) ?? ""

        let instructions = """
        You extract an itemized breakdown from noisy, on-device-OCR text of a \
        restaurant or store bill. Return only what the text supports; never \
        invent values or line items.
        """

        let prompt = """
        Here is text recognized from a photo of a bill via on-device OCR. It may \
        contain recognition noise (misread characters, garbled spacing). List \
        every line item printed on it — one entry per item, in the order \
        printed. For each: the item name as printed, the quantity (a whole \
        number; use 1 if none is shown), and the line's printed total price as a \
        plain number string with no currency symbol (the price for that whole \
        line, already reflecting the quantity — not a per-unit price). If a \
        line is present but genuinely illegible, do not guess its name or \
        price — omit it from the items list and count it in \
        unreadable_line_count instead. Also read the subtotal, tax, service \
        charge/tip (if separately printed), and grand total as plain number \
        strings; use an empty string for any of these that aren't printed. \
        Never invent a value that isn't actually shown.

        ---
        \(ocrText)
        ---
        """

        let session = LanguageModelSession(instructions: instructions)
        let draft: BillDraft
        do {
            let response = try await session.respond(to: prompt, generating: BillDraft.self)
            draft = response.content
        } catch {
            throw FoundationModelsError.modelUnavailable(error.localizedDescription)
        }

        let rawItems = draft.items.map { (name: $0.name, quantity: $0.quantity, price: $0.price) }
        return ExtractedBill.build(
            vendor: draft.vendor.trimmingCharacters(in: .whitespacesAndNewlines),
            rawItems: rawItems,
            subtotal: draft.subtotal, tax: draft.tax,
            serviceCharge: draft.serviceCharge, total: draft.total,
            unreadableLineCount: draft.unreadableLineCount)
    }

    #if canImport(UIKit)
    /// iOS 27 image path for itemization — same `BillDraft` output shape,
    /// prompt reframed for a photo instead of noisy OCR text.
    @available(iOS 27.0, *)
    private static func itemizeBillFromImage(_ image: UIImage) async throws -> ExtractedBill {
        let instructions = """
        You extract an itemized breakdown from a photo of a restaurant or \
        store bill. Return only what the image supports; never invent values \
        or line items.
        """

        let session = LanguageModelSession(instructions: instructions)
        let draft: BillDraft
        do {
            let response = try await session.respond(generating: BillDraft.self) {
                """
                Here is a photo of a bill. List every line item printed on \
                it — one entry per item, in the order printed. For each: the \
                item name as printed, the quantity (a whole number; use 1 if \
                none is shown), and the line's printed total price as a plain \
                number string with no currency symbol (the price for that \
                whole line, already reflecting the quantity — not a per-unit \
                price). Item names and prices are visually paired on the same \
                printed line — never merge two items or attach a price to the \
                wrong item. Marketing text, slogans, or loyalty-club footers \
                are not line items. If a line is present but genuinely \
                illegible, do not guess its name or price — omit it from the \
                items list and count it in unreadable_line_count instead. \
                Also read the subtotal, tax, service charge/tip (if \
                separately printed), and grand total as plain number strings; \
                use an empty string for any of these that aren't printed. \
                Never invent a value that isn't actually shown.
                """
                Attachment(image)
            }
            draft = response.content
        } catch {
            throw FoundationModelsError.modelUnavailable(error.localizedDescription)
        }

        let rawItems = draft.items.map { (name: $0.name, quantity: $0.quantity, price: $0.price) }
        return ExtractedBill.build(
            vendor: draft.vendor.trimmingCharacters(in: .whitespacesAndNewlines),
            rawItems: rawItems,
            subtotal: draft.subtotal, tax: draft.tax,
            serviceCharge: draft.serviceCharge, total: draft.total,
            unreadableLineCount: draft.unreadableLineCount)
    }
    #endif

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
