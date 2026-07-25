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
// NOTE (iOS 27 multimodal): the Foundation Models framework in iOS 27 also
// accepts images directly in a prompt, so the OCR step could be dropped in
// favor of passing the receipt image straight to the model. The OCR-first path
// here is deliberately conservative: it works on iOS 26 too and reuses code the
// app already trusts. See `extract(data:kind:)` for where to swap in the
// image-attachment API once you've confirmed its exact signature on your SDK.
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

/// On-device receipt extractor backed by Apple's Foundation Models framework.
@available(iOS 26.0, *)
struct FoundationModelsService: ReceiptExtractor {

    /// Image/PDF entry point. OCRs on-device, then reasons over the text.
    func extract(data: Data, kind: ReceiptKind, categoryContext: String = "") async throws -> ExtractedReceipt {
        let imageData: Data
        switch kind {
        case .image:
            imageData = data
        case .pdf:
            // Vision OCR wants raster image data; render the first PDF page.
            guard let rendered = Self.renderPDFPageToPNG(data) else {
                // Fall back to an empty read → HITL flags it for manual review
                // rather than throwing the submission away.
                return try await extract(ocrText: "", categoryContext: categoryContext)
            }
            imageData = rendered
        }

        let ocrText = (try? await VisionOCRService.recognizeText(in: imageData)) ?? ""
        return try await extract(ocrText: ocrText, categoryContext: categoryContext)
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

#endif
