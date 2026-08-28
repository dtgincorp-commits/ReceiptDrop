import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum ClaudeError: LocalizedError {
    case missingAPIKey
    case api(String)
    case parsing(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Anthropic API key. Add one in Settings."
        case .api(let detail):
            return "Claude API error: \(detail)"
        case .parsing(let detail):
            return "Couldn't read Claude's response: \(detail)"
        }
    }
}

/// Reads a receipt with the Anthropic Messages API (plain URLSession).
///
/// We force a single tool call (`tool_choice: {type: "tool", ...}`) so Claude
/// must return its answer as validated JSON in the tool_use `input`, rather
/// than free-form prose we'd have to scrape. Images go in a base64 `image`
/// block; PDFs in a base64 `document` block.
struct ClaudeService: ReceiptExtractor {
    func extract(data: Data, kind: ReceiptKind, categoryContext: String = "") async throws -> ExtractedReceipt {
        // Only the upload is downscaled — the file saved to disk via
        // LocalReceiptStore stays full resolution. 1568px matches Anthropic's
        // own server-side resize threshold, so this is upload/memory savings
        // only, not a quality tradeoff: Claude sees the same pixels either way.
        let uploadData = kind == .image ? (Self.downscaledJPEG(from: data) ?? data) : data
        let base64 = uploadData.base64EncodedString()
        let sourceBlock: [String: Any]
        switch kind {
        case .image:
            sourceBlock = [
                "type": "image",
                "source": ["type": "base64", "media_type": kind.mimeType, "data": base64],
            ]
        case .pdf:
            sourceBlock = [
                "type": "document",
                "source": ["type": "base64", "media_type": kind.mimeType, "data": base64],
            ]
        }
        let preamble = ExtractionPrompt.preamble(categoryContext: categoryContext)
        return try await send(content: [
            sourceBlock,
            ["type": "text", "text": "\(preamble) Extract this receipt's details using the record_receipt tool."],
        ])
    }

    /// Downscales a JPEG so its long edge is at most `maxPixel`, using ImageIO
    /// (never decodes the full image into memory — important in the share
    /// extension, which iOS kills around ~120MB). Returns nil if the image is
    /// already small enough or can't be read, in which case callers should
    /// fall back to the original data rather than block the submission.
    static func downscaledJPEG(from data: Data, maxPixel: Int = 1568) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           max(width, height) <= maxPixel {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Extracts structured fields from text already OCR'd on-device (the
    /// "Scan Text" flow) — no image bytes are sent to Claude at all, which is
    /// faster and cheaper than the image/PDF path above.
    func extract(ocrText: String, categoryContext: String = "") async throws -> ExtractedReceipt {
        let preamble = ExtractionPrompt.preamble(categoryContext: categoryContext)
        return try await send(content: [
            ["type": "text", "text": "\(preamble) Here is text recognized from a photo of a receipt via on-device OCR. It may contain recognition noise (misread characters, garbled spacing). Extract the receipt's details using the record_receipt tool.\n\n\(ocrText)"],
        ], sourceText: ocrText)
    }

    /// `sourceText`, when given, is the raw receipt text — cross-checked
    /// against the model's reported date in `ExtractedReceipt.build`. Only
    /// `extract(ocrText:)` has this; the image/PDF path has no text to check
    /// against, so it stays nil there.
    private func send(content: [[String: Any]], sourceText: String? = nil) async throws -> ExtractedReceipt {
        guard let apiKey = KeychainHelper.get(AppConstants.KeychainKeys.anthropicAPIKey),
              !apiKey.isEmpty else {
            throw ClaudeError.missingAPIKey
        }

        let tool: [String: Any] = [
            "name": "record_receipt",
            "description": "Record the structured data extracted from a receipt, invoice, or bill.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "vendor": [
                        "type": "string",
                        "description": "The contractor or vendor / business name on the receipt. Empty string if not present.",
                    ],
                    "work_date": [
                        "type": "string",
                        "description": "The primary date on the receipt, normalized to yyyy-MM-dd. Empty string if none is shown.",
                    ],
                    "amount": [
                        "type": "string",
                        "description": "The grand total as a plain number string with no currency symbol or thousands separators, e.g. 1234.56.",
                    ],
                    "comments": [
                        "type": "string",
                        "description": "A short (max ~12 word) description of what was purchased.",
                    ],
                    "confidence": [
                        "type": "string",
                        "enum": ["high", "low"],
                        "description": "\"low\" if the receipt is handwritten, blurry, damaged, or any field (vendor, date, amount) was hard to read or guessed. \"high\" only if you're confident every field is accurate.",
                    ],
                    // A generic instruction here ("explain why confidence is
                    // low") produced generic phrases back ("ambiguous total,
                    // unclear date") — no help to whoever has to act on the
                    // flag. Naming what a specific answer looks like gets a
                    // specific one back instead.
                    "confidence_reason": [
                        "type": "string",
                        "description": "If confidence is \"low\", name the specific ambiguous detail on THIS receipt — e.g. \"total shows $84.50 but the 15% tip line above it is blank, unclear if tip is included\" or \"two dates printed, 08/09/26 and 09/08/26, unclear which is the transaction date\" — not a generic phrase like \"ambiguous total\" or \"unclear date\". Empty string if confidence is \"high\".",
                    ],
                    "vendor_type": [
                        "type": "string",
                        "enum": VendorTypeToken.allValidValues,
                        "description": "The kind of business this vendor is, judged from its name/context. Pick the closest fit from the list; use \"other\" if none fit well.",
                    ],
                ],
                "required": ["vendor", "work_date", "amount", "comments", "confidence", "confidence_reason", "vendor_type"],
            ],
        ]

        let body: [String: Any] = [
            "model": AppConstants.claudeModel,
            "max_tokens": 1024,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "record_receipt"],
            "messages": [["role": "user", "content": content]],
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeError.api("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClaudeError.api(String(data: respData, encoding: .utf8) ?? "HTTP \(http.statusCode)")
        }

        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw ClaudeError.parsing("Malformed response envelope")
        }
        guard let toolUse = content.first(where: { $0["type"] as? String == "tool_use" }),
              let input = toolUse["input"] as? [String: Any] else {
            throw ClaudeError.parsing("No tool_use block returned")
        }

        func string(_ key: String) -> String {
            (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        return ExtractedReceipt.build(
            vendor: string("vendor"), rawWorkDate: string("work_date"), amount: string("amount"),
            comments: string("comments"), rawVendorType: string("vendor_type"),
            modelReportedLowConfidence: string("confidence").lowercased() == "low",
            modelReason: string("confidence_reason"), sourceText: sourceText)
    }

    /// Parses a raw date string in any of the formats receipts commonly use —
    /// not just yyyy-MM-dd. Returns nil if none match. Two-digit years (e.g.
    /// "3/20/24") are read via the `yy` pattern, which maps to the 2000s.
    /// Shared by `normalizeDate` and `ExtractedReceipt.build` so the "is this a
    /// real date?" decision and the stored value never disagree.
    static func flexibleDate(_ raw: String) -> Date? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // The 13 formats below are exact full-string matches — a model that
        // ignores its instructions and copies a receipt's date+time verbatim
        // (e.g. "08/07/2026 3:42 PM") would otherwise fail every one of them
        // even though the date itself is perfectly readable. Strip the parts
        // that aren't the date before attempting to match.
        trimmed = trimmed.replacingOccurrences(
            of: #"\s*\d{1,2}:\d{2}(:\d{2})?\s*[AaPp]\.?[Mm]\.?\s*$"#,
            with: "", options: .regularExpression)
        trimmed = trimmed.replacingOccurrences(
            of: #"\s*\d{1,2}:\d{2}(:\d{2})?\s*$"#,
            with: "", options: .regularExpression)
        trimmed = trimmed.replacingOccurrences(
            of: #"^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*,?\s*"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        trimmed = trimmed.replacingOccurrences(
            of: #"^(Receipt Date|Work Date|Date)\s*:?\s*"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        // True ISO only, matched by shape first. DateFormatter treats "/"
        // and "-" as interchangeable separators, so leaving "yyyy-MM-dd" in
        // the general format list below let it silently claim short US
        // dates like "8/8/26" as year 8 / month 8 / day 26 (promoted to
        // 2008) whenever the day was 12 or lower — invalid days above 12
        // were the only thing saving the correct pattern's turn. Gating this
        // pattern on the string actually looking like yyyy-M(M)-d(d) first
        // stops it from matching anything else.
        if trimmed.range(of: #"^\d{4}-\d{1,2}-\d{1,2}$"#, options: .regularExpression) != nil {
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: trimmed) { return date }
        }

        let formats = [
            "M/d/yyyy", "MM/dd/yyyy",
            "M/d/yy", "MM/dd/yy",
            "M-d-yyyy", "MM-dd-yyyy", "M-d-yy", "MM-dd-yy",
            "yyyy/MM/dd",
            "MMM d, yyyy", "MMMM d, yyyy", "d MMM yyyy",
        ]
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                // The lenient `yyyy` patterns match two-digit years too,
                // parsing "3/20/24" as literal year 0024 before the `yy`
                // patterns ever run — promote any sub-100 year to the 2000s
                // so the "maps to the 2000s" contract above actually holds.
                var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
                if let year = components.year, year < 100 {
                    components.year = 2000 + year
                    return Calendar.current.date(from: components) ?? date
                }
                return date
            }
        }
        return nil
    }

    /// Best-effort normalization to yyyy-MM-dd. Accepts any format
    /// `flexibleDate` understands; anything unparseable falls back to today's
    /// date so a row is never written with a garbage date.
    static func normalizeDate(_ raw: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = AppConstants.sheetDateFormat
        if let date = flexibleDate(raw) {
            return formatter.string(from: date)
        }
        return formatter.string(from: Date())
    }
}

// MARK: - On-device OCR (Vision)

enum VisionOCRError: LocalizedError {
    case unreadableImage

    var errorDescription: String? { "Couldn't read this image for text recognition." }
}

/// Recognizes text in a receipt photo entirely on-device via the Vision
/// framework — no network call, no API cost. Used by the "On-Device OCR
/// Text" extraction mode: the recognized text (not the image) is what gets
/// sent to whichever AI provider is selected, cutting upload size and token
/// cost dramatically for easy-to-read receipts.
/// Decodes image bytes for Vision along with the EXIF orientation needed to
/// read them the right way up.
///
/// `CGImageSourceCreateImageAtIndex` hands back the *stored* pixel buffer and
/// ignores the file's orientation tag entirely. Every photo an iPhone takes
/// holding the phone upright is stored landscape with orientation 6 ("rotate
/// 90° clockwise"), so a `VNImageRequestHandler` built without that tag reads
/// the receipt sideways. Vision still recognizes the individual words — it
/// handles rotated text fine — but every bounding box comes back in the
/// sideways frame, so a receipt's rows run along x instead of y. Anything
/// grouping observations into visual rows then splits every label from its
/// own number ("TOTAL" from "$145.17"), and the flat reader emits lines in
/// scrambled order.
///
/// Confirmed against a real Home Depot receipt photographed in portrait:
/// without the tag, "TOTAL" and "$145.17" landed 0.22 apart in normalized y
/// while sharing an x-range; with it, they group onto one row.
private func visionImage(from data: Data) -> (CGImage, CGImagePropertyOrientation)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let raw = (properties?[kCGImagePropertyOrientation] as? UInt32) ?? 1
    return (cgImage, CGImagePropertyOrientation(rawValue: raw) ?? .up)
}

enum VisionOCRService {
    static func recognizeText(in data: Data) async throws -> String {
        guard let (cgImage, orientation) = visionImage(from: data) else {
            throw VisionOCRError.unreadableImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let lines = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Document-aware receipt OCR backed by Vision's RecognizeDocumentsRequest —
/// the same Apple framework that powers system receipt features. It understands
/// document structure natively: tables (item name | price as cells), text
/// alignment (.leading for names, .trailing for prices), and grouped paragraphs.
/// This replaces the previous bounding-box approach, which manually re-implemented
/// what this API already does better.
enum VisionLayoutService {
    struct LayoutRow {
        let leftText: String    // name / label / header
        let rightText: String   // price or empty for centered text
    }

    /// Runs RecognizeDocumentsRequest on the image and converts the structured
    /// observation into "Name    Price" rows. Falls back to the flat-text OCR
    /// path if the document request fails.
    ///
    /// `RecognizeDocumentsRequest` is a Vision type only declared in the iOS 26
    /// SDK — `@available` alone can't gate it, since that only checks runtime
    /// availability, not whether the *compiling* toolchain's SDK even declares
    /// the symbol. Gated behind `canImport(FoundationModels)` (a framework that
    /// only exists in the same iOS 26 SDK generation) as an SDK-version proxy,
    /// matching the pattern already used in FoundationModelsService.swift — the
    /// only caller of this function is already inside that same gate.
    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    static func recognizeRows(in data: Data) async throws -> [LayoutRow] {
        let request = RecognizeDocumentsRequest()
        let observations = try await request.perform(on: data)
        guard let document = observations.first?.document else { return [] }

        var rows: [LayoutRow] = []

        // Tables: each row is a line item (name cell + price cell).
        // Vision parses receipt tables natively — cells are already row-ordered.
        for table in document.tables {
            for row in table.rows {
                let cells = row.sorted { $0.columnRange.lowerBound < $1.columnRange.lowerBound }
                let left = cells.dropLast().map { $0.content.text.transcript }.joined(separator: " ")
                let right = cells.last?.content.text.transcript ?? ""
                rows.append(LayoutRow(leftText: left, rightText: right))
            }
        }

        // Paragraphs: trailing-aligned blocks are prices/totals; leading = names.
        for textBlock in document.paragraphs {
            let transcript = textBlock.transcript
            if textBlock.textAlignment == .trailing {
                rows.append(LayoutRow(leftText: "", rightText: transcript))
            } else {
                rows.append(LayoutRow(leftText: transcript, rightText: ""))
            }
        }

        return rows
    }
    #endif

    /// Raw-OCR fallback for thermal-printer receipts where RecognizeDocumentsRequest
    /// finds no formal table structure. Uses VNRecognizeTextRequest with bounding
    /// boxes to reconstruct visual rows, then applies a price-suffix regex to pair
    /// item names with trailing price amounts.
    ///
    /// This is the proven industry approach for parsing monospace receipt text:
    /// group text observations sharing the same vertical band, detect the rightmost
    /// token that matches a dollar amount, treat everything to the left as the item
    /// name. Works on thermal printer receipts where RecognizeDocumentsRequest sees
    /// only paragraphs (not tables).
    static func recognizeRowsViaRawOCR(in data: Data) async throws -> [LayoutRow] {
        guard let (cgImage, orientation) = visionImage(from: data) else {
            return []
        }

        typealias OcrObs = (text: String, box: CGRect)

        let observations: [OcrObs] = try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { req, error in
                if let error { continuation.resume(throwing: error); return }
                let result = (req.results as? [VNRecognizedTextObservation] ?? []).compactMap { obs -> OcrObs? in
                    guard let text = obs.topCandidates(1).first?.string else { return nil }
                    return (text: text, box: obs.boundingBox)
                }
                continuation.resume(returning: result)
            }
            request.recognitionLevel = .accurate
            // Language correction can mangle price amounts like "14.00"; disable it.
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            do { try handler.perform([request]) } catch { continuation.resume(throwing: error) }
        }

        // Sort top-to-bottom (Vision normalized coords: 0 = bottom, 1 = top)
        let sorted = observations.sorted { $0.box.maxY > $1.box.maxY }

        // Group observations into visual rows. Two observations belong to the same
        // row when their Y-centers are close relative to the receipt's own text
        // size — NOT a fixed fraction of image height. Text size varies hugely
        // with how close the photo was taken: a receipt filling the frame has
        // tall lines, so a small absolute tolerance is already a large multiple
        // of the line height and groups correctly. The same receipt photographed
        // at arm's length (more background, shorter lines) shrinks the text, and
        // a fixed 0.012 tolerance that used to be a small fraction of line height
        // becomes a large one — large enough to span two adjacent lines. That's
        // exactly what happened on a real Home Depot receipt (50 observations,
        // median text height 0.024, so 0.012 = 0.5x median height): "SALES TAX"
        // and "TOTAL 10.44" merged into one row, `BillTotalsParser` never saw a
        // line starting with "total", and the real total ($145.17) was dropped
        // in favor of the tax amount ($10.44).
        //
        // Deriving the tolerance from the median observed text height instead
        // makes it self-scaling: 0.4x median height was measured on that photo
        // to split every genuinely distinct line while still keeping same-line
        // label/price pairs (whose Y-centers differ far less than a full line
        // height) together. Clamped to [0.006, 0.02] so neither extreme of
        // framing breaks grouping: a close-up photo with very tall text can't
        // inflate the tolerance enough to start merging real gaps between
        // lines, and a very distant photo with tiny text can't shrink it enough
        // to split a label from its own trailing price.
        let heights = sorted.map { $0.box.height }.sorted()
        let medianHeight = heights.isEmpty ? 0 : heights[heights.count / 2]
        let rowTolerance = min(max(medianHeight * 0.4, 0.006), 0.02)

        var groups: [[OcrObs]] = []
        var current: [OcrObs] = []

        for obs in sorted {
            if current.isEmpty {
                current = [obs]
            } else {
                let groupMidY = current.map { $0.box.midY }.reduce(0, +) / CGFloat(current.count)
                if abs(obs.box.midY - groupMidY) < rowTolerance {
                    current.append(obs)
                } else {
                    groups.append(current)
                    current = [obs]
                }
            }
        }
        if !current.isEmpty { groups.append(current) }

        // Standalone price token: an observation that is itself just a price number.
        // Decimal is required (e.g. "14.00", "$9.75") — this prevents plain integers
        // like "4" (table number), "3271" (check number) from being treated as prices.
        let priceTokenPattern = #"^\$?(\d{1,6}\.\d{1,2})\s*$"#
        guard let priceTokenRegex = try? NSRegularExpression(pattern: priceTokenPattern) else { return [] }

        // End-of-line price suffix: "Item Name 14.00" or "Item Name $14.00"
        // Decimal required for the same false-positive reason; 1+ space is enough —
        // the old 2+ requirement broke single-space-formatted receipts (Apple Store,
        // many paper receipts, and email-printed receipts).
        let priceSuffixPattern = #"^(.*\S)\s+\$?(\d{1,6}\.\d{1,2})\s*$"#
        guard let priceSuffixRegex = try? NSRegularExpression(pattern: priceSuffixPattern) else { return [] }

        var rows: [LayoutRow] = []
        for group in groups {
            let lineObs = group.sorted { $0.box.minX < $1.box.minX }
            let texts = lineObs.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !texts.isEmpty else { continue }

            var leftText = ""
            var rightText = ""

            // Strategy 1: rightmost observation is a standalone price token.
            if texts.count > 1, let last = texts.last {
                let r = NSRange(last.startIndex..., in: last)
                if let m = priceTokenRegex.firstMatch(in: last, range: r),
                   let priceRange = Range(m.range(at: 1), in: last) {
                    rightText = String(last[priceRange])
                    leftText = texts.dropLast().joined(separator: " ")
                }
            }

            // Strategy 2: price is embedded at the end of the joined line text
            // (handles "Chicken Wings 14.00" as a single merged observation).
            if rightText.isEmpty {
                let fullLine = texts.joined(separator: " ")
                let r = NSRange(fullLine.startIndex..., in: fullLine)
                if let m = priceSuffixRegex.firstMatch(in: fullLine, range: r),
                   let nameRange = Range(m.range(at: 1), in: fullLine),
                   let priceRange = Range(m.range(at: 2), in: fullLine) {
                    leftText = String(fullLine[nameRange])
                    rightText = String(fullLine[priceRange])
                } else {
                    leftText = fullLine
                }
            }

            rows.append(LayoutRow(
                leftText: leftText.trimmingCharacters(in: .whitespacesAndNewlines),
                rightText: rightText.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }

        return rows
    }

    /// Tier 3 fallback: parses flat OCR text (one observation per line from
    /// VisionOCRService) using the same price-suffix regex. This is the most
    /// universal approach — it works on any receipt format regardless of font,
    /// column layout, or photo angle, because it only needs the text content,
    /// not spatial bounding boxes.
    ///
    /// Use this when bounding-box row reconstruction finds no items (e.g. Apple
    /// Store receipts, printed email receipts, or any format where the name+price
    /// appear as a single merged observation rather than spatially separate ones).
    static func recognizeRowsFromOCRText(_ text: String) -> [LayoutRow] {
        guard !text.isEmpty,
              let priceSuffixRegex = try? NSRegularExpression(
                  pattern: #"^(.*\S)\s+\$?(\d{1,6}\.\d{1,2})\s*$"#
              ) else { return [] }

        return text.components(separatedBy: .newlines).compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            let r = NSRange(t.startIndex..., in: t)
            guard let m = priceSuffixRegex.firstMatch(in: t, range: r),
                  let nameRange = Range(m.range(at: 1), in: t),
                  let priceRange = Range(m.range(at: 2), in: t) else {
                return LayoutRow(leftText: t, rightText: "")
            }
            return LayoutRow(
                leftText: String(t[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines),
                rightText: String(t[priceRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Converts layout rows to a string where each printed line reads
    /// "LeftText    RightText" — preserving the item name / price pairing.
    static func layoutString(from rows: [LayoutRow]) -> String {
        rows.map { row in
            if row.leftText.isEmpty { return row.rightText }
            if row.rightText.isEmpty { return row.leftText }
            return "\(row.leftText)    \(row.rightText)"
        }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .joined(separator: "\n")
    }
}

// MARK: - OpenAI

enum OpenAIError: LocalizedError {
    case missingAPIKey
    case api(String)
    case parsing(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "No OpenAI API key. Add one in Settings."
        case .api(let detail): return "OpenAI API error: \(detail)"
        case .parsing(let detail): return "Couldn't read OpenAI's response: \(detail)"
        }
    }
}

/// Reads a receipt with OpenAI's Chat Completions API, using a strict JSON
/// schema response format (OpenAI's equivalent of Claude's forced tool use)
/// so the model must return validated structured JSON rather than prose.
struct OpenAIService: ReceiptExtractor {
    func extract(data: Data, kind: ReceiptKind, categoryContext: String = "") async throws -> ExtractedReceipt {
        guard kind == .image else {
            throw OpenAIError.api("OpenAI extraction currently supports images only, not PDFs.")
        }
        let uploadData = ClaudeService.downscaledJPEG(from: data) ?? data
        let base64 = uploadData.base64EncodedString()
        let preamble = ExtractionPrompt.preamble(categoryContext: categoryContext)
        let content: [[String: Any]] = [
            ["type": "text", "text": "\(preamble) Extract this receipt's details."],
            ["type": "image_url", "image_url": ["url": "data:\(kind.mimeType);base64,\(base64)"]],
        ]
        return try await send(content: content)
    }

    func extract(ocrText: String, categoryContext: String = "") async throws -> ExtractedReceipt {
        let preamble = ExtractionPrompt.preamble(categoryContext: categoryContext)
        let content: [[String: Any]] = [
            ["type": "text", "text": "\(preamble) Here is text recognized from a photo of a receipt via on-device OCR. It may contain recognition noise (misread characters, garbled spacing). Extract the receipt's details.\n\n\(ocrText)"],
        ]
        return try await send(content: content, sourceText: ocrText)
    }

    private func send(content: [[String: Any]], sourceText: String? = nil) async throws -> ExtractedReceipt {
        guard let apiKey = KeychainHelper.get(AppConstants.KeychainKeys.openAIAPIKey),
              !apiKey.isEmpty else {
            throw OpenAIError.missingAPIKey
        }

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "vendor": ["type": "string", "description": "The contractor or vendor / business name on the receipt. Empty string if not present."],
                "work_date": ["type": "string", "description": "The primary date on the receipt, normalized to yyyy-MM-dd. Empty string if none is shown."],
                "amount": ["type": "string", "description": "The grand total as a plain number string with no currency symbol or thousands separators, e.g. 1234.56."],
                "comments": ["type": "string", "description": "A short (max ~12 word) description of what was purchased."],
                "confidence": ["type": "string", "enum": ["high", "low"], "description": "\"low\" if the receipt is handwritten, blurry, damaged, or any field was hard to read or guessed. \"high\" only if every field is confidently accurate."],
                // A generic instruction here produced generic phrases back
                // ("ambiguous total, unclear date") — no help to whoever has
                // to act on the flag. Naming what a specific answer looks
                // like gets a specific one back instead.
                "confidence_reason": ["type": "string", "description": "If confidence is \"low\", name the specific ambiguous detail on THIS receipt — e.g. \"total shows $84.50 but the tip line above it is blank\" or \"two dates printed, 08/09/26 and 09/08/26\" — not a generic phrase like \"ambiguous total\" or \"unclear date\". Empty string if confidence is \"high\"."],
                "vendor_type": ["type": "string", "enum": VendorTypeToken.allValidValues, "description": "The kind of business this vendor is, judged from its name/context. Pick the closest fit; use \"other\" if none fit well."],
            ],
            "required": ["vendor", "work_date", "amount", "comments", "confidence", "confidence_reason", "vendor_type"],
            "additionalProperties": false,
        ]

        let body: [String: Any] = [
            "model": AppConstants.openAIModel,
            "messages": [["role": "user", "content": content]],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "record_receipt", "strict": true, "schema": schema],
            ],
        ]

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIError.api("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAIError.api(String(data: respData, encoding: .utf8) ?? "HTTP \(http.statusCode)")
        }

        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let contentString = message["content"] as? String,
              let fieldsData = contentString.data(using: .utf8),
              let fields = try JSONSerialization.jsonObject(with: fieldsData) as? [String: Any] else {
            throw OpenAIError.parsing("Malformed response envelope")
        }

        func string(_ key: String) -> String {
            (fields[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        return ExtractedReceipt.build(
            vendor: string("vendor"), rawWorkDate: string("work_date"), amount: string("amount"),
            comments: string("comments"), rawVendorType: string("vendor_type"),
            modelReportedLowConfidence: string("confidence").lowercased() == "low",
            modelReason: string("confidence_reason"), sourceText: sourceText)
    }
}

// MARK: - Perplexity

enum PerplexityError: LocalizedError {
    case missingAPIKey
    case api(String)
    case parsing(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "No Perplexity API key. Add one in Settings."
        case .api(let detail): return "Perplexity API error: \(detail)"
        case .parsing(let detail): return "Couldn't read Perplexity's response: \(detail)"
        }
    }
}

/// Reads a receipt with Perplexity's Chat Completions API. Perplexity's API
/// is OpenAI-compatible (same endpoint shape, Bearer auth, `image_url`
/// content parts, `json_schema` response format), so this mirrors
/// `OpenAIService` closely rather than inventing a new request shape.
struct PerplexityService: ReceiptExtractor {
    func extract(data: Data, kind: ReceiptKind, categoryContext: String = "") async throws -> ExtractedReceipt {
        guard kind == .image else {
            throw PerplexityError.api("Perplexity extraction currently supports images only, not PDFs.")
        }
        let uploadData = ClaudeService.downscaledJPEG(from: data) ?? data
        let base64 = uploadData.base64EncodedString()
        let preamble = ExtractionPrompt.preamble(categoryContext: categoryContext)
        let content: [[String: Any]] = [
            ["type": "text", "text": "\(preamble) Extract this receipt's details."],
            ["type": "image_url", "image_url": ["url": "data:\(kind.mimeType);base64,\(base64)"]],
        ]
        return try await send(content: content)
    }

    func extract(ocrText: String, categoryContext: String = "") async throws -> ExtractedReceipt {
        let preamble = ExtractionPrompt.preamble(categoryContext: categoryContext)
        let content: [[String: Any]] = [
            ["type": "text", "text": "\(preamble) Here is text recognized from a photo of a receipt via on-device OCR. It may contain recognition noise (misread characters, garbled spacing). Extract the receipt's details.\n\n\(ocrText)"],
        ]
        return try await send(content: content, sourceText: ocrText)
    }

    private func send(content: [[String: Any]], sourceText: String? = nil) async throws -> ExtractedReceipt {
        guard let apiKey = KeychainHelper.get(AppConstants.KeychainKeys.perplexityAPIKey),
              !apiKey.isEmpty else {
            throw PerplexityError.missingAPIKey
        }

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "vendor": ["type": "string", "description": "The contractor or vendor / business name on the receipt. Empty string if not present."],
                "work_date": ["type": "string", "description": "The primary date on the receipt, normalized to yyyy-MM-dd. Empty string if none is shown."],
                "amount": ["type": "string", "description": "The grand total as a plain number string with no currency symbol or thousands separators, e.g. 1234.56."],
                "comments": ["type": "string", "description": "A short (max ~12 word) description of what was purchased."],
                "confidence": ["type": "string", "enum": ["high", "low"], "description": "\"low\" if the receipt is handwritten, blurry, damaged, or any field was hard to read or guessed. \"high\" only if every field is confidently accurate."],
                // A generic instruction here produced generic phrases back
                // ("ambiguous total, unclear date") — no help to whoever has
                // to act on the flag. Naming what a specific answer looks
                // like gets a specific one back instead.
                "confidence_reason": ["type": "string", "description": "If confidence is \"low\", name the specific ambiguous detail on THIS receipt — e.g. \"total shows $84.50 but the tip line above it is blank\" or \"two dates printed, 08/09/26 and 09/08/26\" — not a generic phrase like \"ambiguous total\" or \"unclear date\". Empty string if confidence is \"high\"."],
                "vendor_type": ["type": "string", "enum": VendorTypeToken.allValidValues, "description": "The kind of business this vendor is, judged from its name/context. Pick the closest fit; use \"other\" if none fit well."],
            ],
            "required": ["vendor", "work_date", "amount", "comments", "confidence", "confidence_reason", "vendor_type"],
            "additionalProperties": false,
        ]

        let body: [String: Any] = [
            "model": AppConstants.perplexityModel,
            "messages": [["role": "user", "content": content]],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["schema": schema],
            ],
        ]

        var request = URLRequest(url: URL(string: "https://api.perplexity.ai/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PerplexityError.api("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PerplexityError.api(String(data: respData, encoding: .utf8) ?? "HTTP \(http.statusCode)")
        }

        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let contentString = message["content"] as? String,
              let fieldsData = contentString.data(using: .utf8),
              let fields = try JSONSerialization.jsonObject(with: fieldsData) as? [String: Any] else {
            throw PerplexityError.parsing("Malformed response envelope")
        }

        func string(_ key: String) -> String {
            (fields[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        return ExtractedReceipt.build(
            vendor: string("vendor"), rawWorkDate: string("work_date"), amount: string("amount"),
            comments: string("comments"), rawVendorType: string("vendor_type"),
            modelReportedLowConfidence: string("confidence").lowercased() == "low",
            modelReason: string("confidence_reason"), sourceText: sourceText)
    }
}

// MARK: - Google Gemini

enum GeminiError: LocalizedError {
    case missingAPIKey
    case api(String)
    case parsing(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "No Google Gemini API key. Add one in Settings."
        case .api(let detail): return "Gemini API error: \(detail)"
        case .parsing(let detail): return "Couldn't read Gemini's response: \(detail)"
        }
    }
}

/// Reads a receipt with Google's Gemini API, using `responseSchema` to force
/// structured JSON output — Gemini's equivalent of Claude's forced tool use.
struct GeminiService: ReceiptExtractor {
    func extract(data: Data, kind: ReceiptKind, categoryContext: String = "") async throws -> ExtractedReceipt {
        let uploadData = kind == .image ? (ClaudeService.downscaledJPEG(from: data) ?? data) : data
        let base64 = uploadData.base64EncodedString()
        let preamble = ExtractionPrompt.preamble(categoryContext: categoryContext)
        let parts: [[String: Any]] = [
            ["text": "\(preamble) Extract this receipt's details."],
            ["inline_data": ["mime_type": kind.mimeType, "data": base64]],
        ]
        return try await send(parts: parts)
    }

    func extract(ocrText: String, categoryContext: String = "") async throws -> ExtractedReceipt {
        let preamble = ExtractionPrompt.preamble(categoryContext: categoryContext)
        let parts: [[String: Any]] = [
            ["text": "\(preamble) Here is text recognized from a photo of a receipt via on-device OCR. It may contain recognition noise (misread characters, garbled spacing). Extract the receipt's details.\n\n\(ocrText)"],
        ]
        return try await send(parts: parts, sourceText: ocrText)
    }

    private func send(parts: [[String: Any]], sourceText: String? = nil) async throws -> ExtractedReceipt {
        guard let apiKey = KeychainHelper.get(AppConstants.KeychainKeys.geminiAPIKey),
              !apiKey.isEmpty else {
            throw GeminiError.missingAPIKey
        }

        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "vendor": ["type": "STRING"],
                "work_date": ["type": "STRING"],
                "amount": ["type": "STRING"],
                "comments": ["type": "STRING"],
                "confidence": ["type": "STRING", "enum": ["high", "low"]],
                // Unlike the other providers' schemas, none of Gemini's
                // fields carry a "description" here — but confidence_reason
                // needs one anyway: with no guidance at all the model fell
                // back to generic phrases like "ambiguous total, unclear
                // date" instead of describing what's actually on the
                // receipt. Gemini's schema format supports "description"
                // per-property, so add just this one rather than restyling
                // the whole schema.
                "confidence_reason": ["type": "STRING", "description": "If confidence is \"low\", name the specific ambiguous detail on THIS receipt — e.g. \"total shows $84.50 but the tip line above it is blank\" or \"two dates printed, 08/09/26 and 09/08/26\" — not a generic phrase like \"ambiguous total\" or \"unclear date\". Empty string if confidence is \"high\"."],
                "vendor_type": ["type": "STRING", "enum": VendorTypeToken.allValidValues],
            ],
            "required": ["vendor", "work_date", "amount", "comments", "confidence", "confidence_reason", "vendor_type"],
        ]

        let body: [String: Any] = [
            "contents": [["parts": parts]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": schema,
            ],
        ]

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(AppConstants.geminiModel):generateContent?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.api("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GeminiError.api(String(data: respData, encoding: .utf8) ?? "HTTP \(http.statusCode)")
        }

        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let contentDict = candidates.first?["content"] as? [String: Any],
              let responseParts = contentDict["parts"] as? [[String: Any]],
              let text = responseParts.first?["text"] as? String,
              let fieldsData = text.data(using: .utf8),
              let fields = try JSONSerialization.jsonObject(with: fieldsData) as? [String: Any] else {
            throw GeminiError.parsing("Malformed response envelope")
        }

        func string(_ key: String) -> String {
            (fields[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        return ExtractedReceipt.build(
            vendor: string("vendor"), rawWorkDate: string("work_date"), amount: string("amount"),
            comments: string("comments"), rawVendorType: string("vendor_type"),
            modelReportedLowConfidence: string("confidence").lowercased() == "low",
            modelReason: string("confidence_reason"), sourceText: sourceText)
    }
}

// MARK: - Semantic search

/// The fixed vocabulary of time periods a search query can name. Every
/// parser — all four cloud providers and the on-device model — returns one
/// of these tokens plus a number or two; `SearchDateResolver` turns that into
/// concrete dates in Swift.
///
/// Deliberately a descriptor rather than "have the model return ISO dates":
/// the models don't reliably know today's date, and even when told it, date
/// arithmetic ("2 weeks ago") is exactly the kind of thing a small on-device
/// model gets wrong. Just as importantly, if each provider computed its own
/// dates, "last month" would quietly mean something different on Apple
/// on-device than on Gemini. One Swift resolver keeps the meaning of every
/// phrase identical across providers, and unit-testable (see
/// `ExtractionLogicTests`) — which the live parsing itself is not, since
/// there's no mockable seam for the models.
enum QueryDateRangeKind: String, CaseIterable {
    case none
    case lastNDays = "last_n_days"
    case thisWeek = "this_week"
    case lastWeek = "last_week"
    case thisMonth = "this_month"
    case lastMonth = "last_month"
    case thisYear = "this_year"
    case lastYear = "last_year"
    case namedMonth = "named_month"
    case specificYear = "specific_year"

    /// The `enum` array handed to every provider's schema, so the allowed
    /// tokens can't drift between the five parsers.
    static var allValidValues: [String] { allCases.map(\.rawValue) }
}

/// What a parser read out of the query's time phrase, before resolution.
/// `count`/`month`/`year` are only meaningful for the kinds that use them.
struct QueryDateDescriptor {
    var kind: QueryDateRangeKind = .none
    var count: Int?
    var month: Int?
    var year: Int?
}

/// Turns a `QueryDateDescriptor` into an absolute, inclusive date range.
/// Pure Swift, `now` injected (same pattern as `SpendingInsightsService.buildDigest(now:)`)
/// so the calendar edge cases — "last month" from January, a named month
/// that hasn't happened yet this year — are testable without waiting for
/// the real clock to reach them.
enum SearchDateResolver {
    /// Inclusive bounds: `from` is the start of the first day, `to` the last
    /// instant of the last day. Callers compare a receipt's date against both
    /// with `>=` / `<=`. Returns nil for `.none` (and for a nonsensical
    /// descriptor, e.g. `last_n_days` with no count) — nil means "no date
    /// filter", which is what preserves the old behavior for queries that
    /// name no time period at all.
    static func resolve(_ descriptor: QueryDateDescriptor,
                        now: Date = Date(),
                        calendar: Calendar = .current) -> (from: Date, to: Date)? {
        let today = calendar.startOfDay(for: now)
        func endOfDay(_ day: Date) -> Date {
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))!.addingTimeInterval(-1)
        }

        switch descriptor.kind {
        case .none:
            return nil

        case .lastNDays:
            // "2 weeks ago" is read as the last 14 days, not the single day
            // 14 days back: someone searching that means "recently, about
            // two weeks back," and the literal reading would return an
            // almost-always-empty list. Over-inclusive beats silently empty
            // in a tax app. The window includes today, so N = 14 spans today
            // plus the previous 13 days.
            guard let count = descriptor.count, count > 0 else { return nil }
            guard let start = calendar.date(byAdding: .day, value: -(count - 1), to: today) else { return nil }
            return (start, endOfDay(today))

        case .thisWeek, .thisMonth, .thisYear:
            // "This <period>" is period-to-date: it ends today, not at the
            // period's end. Clamping matters only cosmetically (no receipt is
            // dated in the future), but it makes the chip label honest —
            // "Aug 1 – Aug 18", not "Aug 1 – Aug 31".
            let unit: Calendar.Component = descriptor.kind == .thisWeek ? .weekOfYear
                : (descriptor.kind == .thisMonth ? .month : .year)
            guard let interval = calendar.dateInterval(of: unit, for: now) else { return nil }
            return (interval.start, endOfDay(today))

        case .lastWeek, .lastMonth, .lastYear:
            // The whole previous calendar period, first day to last — "last
            // month" in January is the previous December, which is the case
            // that motivated pinning this down in tests.
            let unit: Calendar.Component = descriptor.kind == .lastWeek ? .weekOfYear
                : (descriptor.kind == .lastMonth ? .month : .year)
            guard let current = calendar.dateInterval(of: unit, for: now),
                  let previousDate = calendar.date(byAdding: unit, value: -1, to: current.start),
                  let previous = calendar.dateInterval(of: unit, for: previousDate) else { return nil }
            return (previous.start, previous.end.addingTimeInterval(-1))

        case .namedMonth:
            guard let month = descriptor.month, (1...12).contains(month) else { return nil }
            var year = descriptor.year ?? calendar.component(.year, from: now)
            if descriptor.year == nil && month > calendar.component(.month, from: now) {
                // "July" said in March means last July — nobody searches
                // their receipts for a month that hasn't happened yet.
                year -= 1
            }
            guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let interval = calendar.dateInterval(of: .month, for: start) else { return nil }
            return (interval.start, interval.end.addingTimeInterval(-1))

        case .specificYear:
            guard let year = descriptor.year, year > 1900,
                  let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let interval = calendar.dateInterval(of: .year, for: start) else { return nil }
            return (interval.start, interval.end.addingTimeInterval(-1))
        }
    }

    /// Human-readable label for a resolved range, used by the removable
    /// filter chip. Recognizes the two shapes users actually see most — a
    /// whole calendar month, and a window ending today — and falls back to
    /// spelling out both ends.
    static func label(from: Date, to: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let monthInterval = calendar.dateInterval(of: .month, for: from)
        if let monthInterval, calendar.isDate(from, inSameDayAs: monthInterval.start),
           calendar.isDate(to, inSameDayAs: monthInterval.end.addingTimeInterval(-1)) {
            return format(from, "MMM yyyy")
        }
        if calendar.isDate(to, inSameDayAs: now) {
            let days = (calendar.dateComponents([.day], from: calendar.startOfDay(for: from),
                                                to: calendar.startOfDay(for: now)).day ?? 0) + 1
            if days > 1 { return "Last \(days) days" }
            return "Today"
        }
        // A single explicit day ("August 4th") is now a common shape, since
        // `SearchQueryDateParser` resolves those deterministically — without
        // this the chip would read "Aug 4 – Aug 4". Deliberately placed after
        // the ends-today branch so that today still labels as "Today".
        if calendar.isDate(from, inSameDayAs: to) { return format(from, "MMM d") }
        return "\(format(from, "MMM d")) – \(format(to, "MMM d"))"
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// Pulls the descriptor fields out of a provider's decoded JSON (or
    /// Claude's tool input) and resolves them. Shared by all four cloud
    /// parsers so the key names and the -1/null sentinel handling can't drift.
    static func range(from fields: [String: Any], now: Date = Date()) -> Resolved {
        let token = kind(forToken: fields["date_range_kind"] as? String)
        func number(_ key: String) -> Int? {
            guard let value = (fields[key] as? NSNumber)?.intValue, value > 0 else { return nil }
            return value
        }
        let descriptor = QueryDateDescriptor(
            kind: token.kind,
            count: number("date_count"), month: number("date_month"), year: number("date_year"))
        guard let resolved = resolve(descriptor, now: now) else {
            return Resolved(from: nil, to: nil, unrecognizedToken: token.unrecognized)
        }
        return Resolved(from: resolved.from, to: resolved.to, unrecognizedToken: token.unrecognized)
    }

    /// What reading a parser's date fields produced.
    ///
    /// `unrecognizedToken` is the part that didn't exist before: a parser
    /// that returns a descriptor outside `QueryDateRangeKind` used to be
    /// coerced to `.none` and the date half of the query simply evaporated,
    /// leaving a result that *looked* filtered. That is the single worst
    /// failure shape in a tax app — a wrong answer wearing a right answer's
    /// clothes — and it is exactly what the date feature was added to stop,
    /// reintroduced one level further down. Carrying the token up lets
    /// `SemanticSearchService` either fall back to a deterministic reading of
    /// the query or tell the user it didn't understand, but never quietly
    /// drop the constraint.
    struct Resolved {
        var from: Date?
        var to: Date?
        var unrecognizedToken: String?
    }

    /// Classifies a raw descriptor token from any of the five parsers.
    ///
    /// Empty, "none" and "null" all mean the query named no time period —
    /// that is a *valid* answer and must stay distinguishable from a model
    /// inventing a token like "specific_date" or "august_4", which means the
    /// query named a period the vocabulary cannot express.
    static func kind(forToken raw: String?) -> (kind: QueryDateRangeKind, unrecognized: String?) {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty || trimmed == "none" || trimmed == "null" { return (.none, nil) }
        if let known = QueryDateRangeKind(rawValue: trimmed) { return (known, nil) }
        return (.none, trimmed)
    }

    /// The date half of every parser's prompt. One string for all five
    /// parsers — the on-device instructions and the four cloud prompts —
    /// so a phrase can't mean one thing on one provider and something else
    /// on another.
    ///
    /// KNOWN, DELIBERATELY DEFERRED: the "yesterday" example below maps to
    /// `last_n_days` with `date_count 2`, and that window *includes today*
    /// (see `resolve`), so searching "yesterday" also returns today's
    /// receipts. It is over-inclusive rather than under-inclusive, so it
    /// fails in the safe direction, and fixing it properly needs a
    /// descriptor kind for a single relative day — which belongs with the
    /// rest of the vocabulary work (quarters, `last_n_months`,
    /// `since`/`before`), not as a half-fix here. Do not "tidy" the example
    /// away without adding that kind; removing it just sends "yesterday"
    /// back to `none`, which is worse.
    static let promptGuidance = """
    Time periods: if the query names one, describe it with date_range_kind \
    (one of: \(QueryDateRangeKind.allValidValues.joined(separator: ", "))) plus \
    date_count / date_month / date_year. Never work out actual calendar dates \
    yourself — you do not know today's date; the app resolves the descriptor. \
    Use "none" when the query names no time period. Examples: "anything from 2 \
    weeks ago" or "past two weeks" -> last_n_days with date_count 14 (a phrase \
    like "N weeks ago" means the whole recent window, not one single day); \
    "in the last 30 days" -> last_n_days, date_count 30; "yesterday" -> \
    last_n_days, date_count 2; "this week" -> this_week; "from last month" -> \
    last_month; "so far this month" -> this_month; "in July" -> named_month \
    with date_month 7 and no date_year; "July 2025" -> named_month, date_month \
    7, date_year 2025; "in 2025" -> specific_year with date_year 2025.
    """
}

/// A search query broken into a structured filter, e.g. "restaurant receipts
/// over 100" → vendorType "restaurant", amountMin 100.
///
/// `dateFrom`/`dateTo` are already resolved to absolute dates by
/// `SearchDateResolver` — the parsers never hand a relative phrase further
/// down. Before these existed, every date phrase in every query on every
/// provider was silently dropped: "anything from 2 weeks ago" parsed, showed
/// no date chip, and returned the user's entire history as if it had been
/// filtered. Silent wrong results are the worst failure mode in a tax app,
/// which is why the range is carried here rather than being left to the
/// plain text search.
struct QueryParseResult {
    let vendorType: String?
    let amountMin: Double?
    let amountMax: Double?
    let dateFrom: Date?
    let dateTo: Date?
    /// Set when the parser named a time period using a token outside
    /// `QueryDateRangeKind` — i.e. it understood that the query named a
    /// period but had no legal way to say which. Purely a signal for
    /// `SemanticSearchService.finalize`, which either replaces it with a
    /// deterministic reading or refuses the search; it never reaches the UI
    /// and is deliberately excluded from `isEmpty`.
    let unrecognizedDateToken: String?

    init(vendorType: String?, amountMin: Double?, amountMax: Double?,
         dateFrom: Date? = nil, dateTo: Date? = nil,
         unrecognizedDateToken: String? = nil) {
        self.vendorType = vendorType
        self.amountMin = amountMin
        self.amountMax = amountMax
        self.dateFrom = dateFrom
        self.dateTo = dateTo
        self.unrecognizedDateToken = unrecognizedDateToken
    }

    var isEmpty: Bool {
        vendorType == nil && amountMin == nil && amountMax == nil && dateFrom == nil && dateTo == nil
    }
}

enum SemanticSearchError: LocalizedError {
    case missingAPIKey
    case api(String)
    case parsing(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key configured for the selected AI Provider — add one in Settings to use natural-language search."
        case .api(let detail):
            return "AI search error: \(detail)"
        case .parsing(let detail):
            return "Couldn't understand that search: \(detail)"
        }
    }
}

/// Rejects a vendor-type filter the query text cannot support.
///
/// Only `other` is gated, and deliberately so. Every other token is a
/// *semantic* mapping the model is genuinely good at and a lexical check
/// would wreck: "dinner receipts" correctly becomes `restaurant`, "filled up
/// the truck" becomes `gas_station`, and neither query contains the token's
/// own word. `other` is the one token with no synonyms — the only honest
/// reason to return it is that the user described a business the vocabulary
/// doesn't cover, which requires them to have named a business at all. So if
/// the query contains nothing business-shaped, `other` is not a
/// classification, it is the model reaching for a word that means
/// "unspecified" — the exact confusion that produced an "Other" chip on
/// "anything on August 4th receipt date", filtering a tax history down to an
/// arbitrary subset while looking like it had understood the question.
///
/// Three rounds of prompt wording have tried to teach this rule and it keeps
/// coming back under load, so it is enforced here instead: the instructions
/// still ask for the right behavior, but nothing depends on the model
/// obeying them.
///
/// Fails in the widening direction on purpose. Dropping a filter shows the
/// user more receipts than they asked for, which they can see and narrow.
/// The failure this replaces hid receipts behind a filter they never
/// requested, and a hidden receipt is a lost deduction.
enum SearchVendorTypeGuard {

    /// Words that make "other" a legitimate answer. The token vocabulary
    /// itself (built-in and user-added, plus every word of their display
    /// names), the literal "other"/"misc", and the everyday synonyms people
    /// actually type instead of the token names.
    private static var businessWords: Set<String> {
        var words: Set<String> = [
            "other", "misc", "miscellaneous", "business", "vendor", "shop", "store",
            "restaurant", "restaurants", "food", "dining", "diner", "meal", "meals",
            "cafe", "coffee", "bar", "takeout", "lunch", "dinner", "breakfast",
            "gas", "fuel", "petrol", "station", "grocery", "groceries", "supermarket",
            "hardware", "lumber", "retail", "auto", "car", "mechanic", "repair",
            "hotel", "motel", "lodging", "inn", "medical", "doctor", "dentist",
            "pharmacy", "clinic", "hospital", "professional", "legal", "lawyer",
            "accountant", "notary", "entertainment", "movie", "theater", "utilities",
            "utility", "electric", "internet", "phone"
        ]
        for token in VendorTypeToken.allValidValues {
            for part in token.lowercased().split(whereSeparator: { !$0.isLetter }) {
                words.insert(String(part))
            }
            let display = VendorTypeToken.displayName(for: token).lowercased()
            for part in display.split(whereSeparator: { !$0.isLetter }) {
                words.insert(String(part))
            }
        }
        return words
    }

    /// The model's vendor type, or nil if it must not be applied.
    static func sanitized(_ vendorType: String?, query: String) -> String? {
        guard let vendorType, !vendorType.isEmpty else { return nil }
        guard vendorType.caseInsensitiveCompare(VendorType.other.rawValue) == .orderedSame else {
            return vendorType
        }
        return mentionsABusinessType(query) ? vendorType : nil
    }

    /// Whole-word match only: "another" must not license "other", and
    /// "carpet" must not license "car".
    static func mentionsABusinessType(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        let vocabulary = businessWords
        return words.contains { vocabulary.contains($0) }
    }
}

/// Parses a free-form search phrase (e.g. "restaurants over 100") into a
/// structured filter — the AI provider currently selected in Settings, same
/// keys/models as receipt extraction. `vendorType` is constrained to
/// `VendorType`'s fixed vocabulary (the same one used at extraction time),
/// so its output can be compared directly against `HistoryEntry.vendorType`
/// with a plain local equality check — no second AI call needed to figure
/// out which vendors match, since that's already decided and stored on each
/// receipt (see `VendorTypeClassificationService` for how existing/manual
/// entries get that field backfilled).
enum SemanticSearchService {
    static func parseQuery(_ text: String) async throws -> QueryParseResult {
        try ExtractionSettings.assertProviderAllowed()

        // Deterministic first, model second. Any date the user typed
        // literally — "August 4th", "8/4/26", "between Aug 1 and Aug 10" — is
        // settled in Swift before a model is consulted, and overrides
        // whatever the model says about dates.
        //
        // This is a deliberate change of strategy. Three rounds of "add more
        // words to the instructions" (the $100–$100 amount bound, the "other"
        // vendor type, the date fields) each fixed the tested phrasing and
        // broke on the next one, because a small on-device model holds a
        // constraint only as firmly as the surrounding prompt lets it. The
        // same conclusion was already reached once on the extraction side and
        // written up in DATE_GUARDRAIL_PLAN.md, which produced
        // `ReceiptDateDetector`; this is that lesson applied to search. The
        // prompt stays best-effort. Swift is where the guarantees live.
        let explicit = SearchQueryDateParser.explicitRange(in: text)

        let parsed: QueryParseResult
        switch ExtractionSettings.provider {
        case .claude: parsed = try await parseQueryViaClaude(text)
        case .openAI: parsed = try await parseQueryViaOpenAI(text)
        case .gemini: parsed = try await parseQueryViaGemini(text)
        case .perplexity: parsed = try await parseQueryViaPerplexity(text)
        case .azureDocumentIntelligence:
            // Azure's prebuilt-receipt model is fixed-schema document
            // extraction, not an instruction-following chat model — it has
            // no way to parse a free-form search phrase. It can still serve a
            // query whose date the Swift pre-pass read on its own, though,
            // which is strictly better than the flat refusal it used to give.
            if let explicit {
                return QueryParseResult(vendorType: nil, amountMin: nil, amountMax: nil,
                                        dateFrom: explicit.from, dateTo: explicit.to)
            }
            throw SemanticSearchError.api("Microsoft Document Intelligence can't parse search queries — switch AI Provider in Settings to search receipts.")
        case .appleOnDevice:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                parsed = try await parseQueryOnDevice(text)
                return try finalize(parsed, query: text, explicit: explicit)
            }
            #endif
            // Older OS / toolchain without Foundation Models: fall back to
            // Gemini (still needs a Gemini key on those builds).
            parsed = try await parseQueryViaGemini(text)
        }

        return try finalize(parsed, query: text, explicit: explicit)
    }

    /// The deterministic pass every provider's answer goes through before it
    /// can become a filter. Kept separate from the network calls, and
    /// internal rather than private, so the guarantees below are unit-tested
    /// without a model or a key in the loop — which is the point of moving
    /// them out of the prompt in the first place.
    ///
    /// Three jobs, in order:
    ///
    /// 1. Drop a `vendorType` of "other" that the query text can't support
    ///    (see `SearchVendorTypeGuard`).
    /// 2. Let a date the Swift pre-pass read literally out of the query
    ///    override whatever the model returned. If the pre-pass fired, the
    ///    model's date opinion — including an unrecognized descriptor — is
    ///    irrelevant, because we already have the answer.
    /// 3. Otherwise, refuse the search outright if the model named a time
    ///    period it had no legal token for. Showing an error is worse UX than
    ///    showing results and much better than showing the *wrong* results
    ///    with a filter chip implying they were narrowed.
    static func finalize(_ parsed: QueryParseResult, query: String,
                         explicit: (from: Date, to: Date)?) throws -> QueryParseResult {
        let vendorType = SearchVendorTypeGuard.sanitized(parsed.vendorType, query: query)

        if let explicit {
            return QueryParseResult(vendorType: vendorType,
                                    amountMin: parsed.amountMin, amountMax: parsed.amountMax,
                                    dateFrom: explicit.from, dateTo: explicit.to)
        }
        if let token = parsed.unrecognizedDateToken {
            throw SemanticSearchError.parsing(
                "the date part (\"\(token)\"). Try a phrase like \"in July\", \"last month\", \"August 4th\", or \"in the last 30 days\".")
        }
        return QueryParseResult(vendorType: vendorType,
                                amountMin: parsed.amountMin, amountMax: parsed.amountMax,
                                dateFrom: parsed.dateFrom, dateTo: parsed.dateTo)
    }

    // MARK: Claude

    private static func parseQueryViaClaude(_ text: String) async throws -> QueryParseResult {
        guard let apiKey = KeychainHelper.get(AppConstants.KeychainKeys.anthropicAPIKey), !apiKey.isEmpty else {
            throw SemanticSearchError.missingAPIKey
        }
        let tool: [String: Any] = [
            "name": "parse_search_query",
            "description": "Extract a structured filter from a natural-language receipt search query.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "vendor_type": ["type": ["string", "null"], "enum": VendorTypeToken.allValidValues + [NSNull()], "description": "The kind of business being searched for, mapped onto the closest fit from the enum. Null if the query doesn't mention a business type at all. Note that \"other\" is itself a real business category — a business that fits none of the listed types — NOT a value meaning \"unspecified\" or \"any\". A query naming no business type (e.g. \"anything from 2 weeks ago\") must be null, never \"other\"."],
                    "amount_min": ["type": ["number", "null"], "description": "Minimum amount if the query implies a lower bound (e.g. 'over 100', 'at least 50'). Null if none."],
                    "amount_max": ["type": ["number", "null"], "description": "Maximum amount if the query implies an upper bound (e.g. 'under 20', 'below $50'). Null if none."],
                    "date_range_kind": ["type": "string", "enum": QueryDateRangeKind.allValidValues, "description": "The time period the query names, as a descriptor token. \"none\" if it names no time period. Do not compute calendar dates — the app resolves the descriptor."],
                    "date_count": ["type": ["integer", "null"], "description": "Number of days for last_n_days (e.g. \"2 weeks ago\" -> 14). Null otherwise."],
                    "date_month": ["type": ["integer", "null"], "description": "Month number 1-12 for named_month. Null otherwise."],
                    "date_year": ["type": ["integer", "null"], "description": "Four-digit year for specific_year, or for named_month when the query states one. Null otherwise."],
                ],
                "required": ["vendor_type", "amount_min", "amount_max", "date_range_kind", "date_count", "date_month", "date_year"],
            ],
        ]
        let body: [String: Any] = [
            "model": AppConstants.claudeModel,
            "max_tokens": 512,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "parse_search_query"],
            "messages": [["role": "user", "content": "Parse this receipt search query: \"\(text)\"\n\n\(SearchDateResolver.promptGuidance)"]],
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SemanticSearchError.api(String(data: respData, encoding: .utf8) ?? "HTTP request failed")
        }
        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let toolUse = content.first(where: { $0["type"] as? String == "tool_use" }),
              let input = toolUse["input"] as? [String: Any] else {
            throw SemanticSearchError.parsing("Malformed response")
        }
        let dates = SearchDateResolver.range(from: input)
        return QueryParseResult(
            vendorType: VendorTypeToken.resolve(input["vendor_type"] as? String),
            amountMin: (input["amount_min"] as? NSNumber)?.doubleValue,
            amountMax: (input["amount_max"] as? NSNumber)?.doubleValue,
            dateFrom: dates.from, dateTo: dates.to,
            unrecognizedDateToken: dates.unrecognizedToken)
    }

    // MARK: OpenAI

    private static func parseQueryViaOpenAI(_ text: String) async throws -> QueryParseResult {
        guard let apiKey = KeychainHelper.get(AppConstants.KeychainKeys.openAIAPIKey), !apiKey.isEmpty else {
            throw SemanticSearchError.missingAPIKey
        }
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "vendor_type": ["type": ["string", "null"], "enum": VendorTypeToken.allValidValues + [NSNull()]],
                "amount_min": ["type": ["number", "null"]],
                "amount_max": ["type": ["number", "null"]],
                "date_range_kind": ["type": "string", "enum": QueryDateRangeKind.allValidValues],
                "date_count": ["type": ["integer", "null"]],
                "date_month": ["type": ["integer", "null"]],
                "date_year": ["type": ["integer", "null"]],
            ],
            "required": ["vendor_type", "amount_min", "amount_max", "date_range_kind", "date_count", "date_month", "date_year"],
            "additionalProperties": false,
        ]
        let body: [String: Any] = [
            "model": AppConstants.openAIModel,
            "messages": [["role": "user", "content": "Parse this receipt search query into a structured filter. Map any mentioned business type onto the closest enum value; use null (not a forced guess) if no business type is mentioned. \"other\" is a real business category (a business fitting none of the listed types), NOT a value meaning \"unspecified\" or \"any\" — a query naming no business type at all, such as \"anything from 2 weeks ago\", must be null and never \"other\". \(SearchDateResolver.promptGuidance) Query: \"\(text)\""]],
            "response_format": ["type": "json_schema", "json_schema": ["name": "parse_search_query", "strict": true, "schema": schema]],
        ]
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SemanticSearchError.api(String(data: respData, encoding: .utf8) ?? "HTTP request failed")
        }
        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let contentString = message["content"] as? String,
              let fieldsData = contentString.data(using: .utf8),
              let fields = try JSONSerialization.jsonObject(with: fieldsData) as? [String: Any] else {
            throw SemanticSearchError.parsing("Malformed response")
        }
        let dates = SearchDateResolver.range(from: fields)
        return QueryParseResult(
            vendorType: VendorTypeToken.resolve(fields["vendor_type"] as? String),
            amountMin: (fields["amount_min"] as? NSNumber)?.doubleValue,
            amountMax: (fields["amount_max"] as? NSNumber)?.doubleValue,
            dateFrom: dates.from, dateTo: dates.to,
            unrecognizedDateToken: dates.unrecognizedToken)
    }

    // MARK: Perplexity

    private static func parseQueryViaPerplexity(_ text: String) async throws -> QueryParseResult {
        guard let apiKey = KeychainHelper.get(AppConstants.KeychainKeys.perplexityAPIKey), !apiKey.isEmpty else {
            throw SemanticSearchError.missingAPIKey
        }
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "vendor_type": ["type": ["string", "null"], "enum": VendorTypeToken.allValidValues + [NSNull()]],
                "amount_min": ["type": ["number", "null"]],
                "amount_max": ["type": ["number", "null"]],
                "date_range_kind": ["type": "string", "enum": QueryDateRangeKind.allValidValues],
                "date_count": ["type": ["integer", "null"]],
                "date_month": ["type": ["integer", "null"]],
                "date_year": ["type": ["integer", "null"]],
            ],
            "required": ["vendor_type", "amount_min", "amount_max", "date_range_kind", "date_count", "date_month", "date_year"],
            "additionalProperties": false,
        ]
        let body: [String: Any] = [
            "model": AppConstants.perplexityModel,
            "messages": [["role": "user", "content": "Parse this receipt search query into a structured filter. Map any mentioned business type onto the closest enum value; use null (not a forced guess) if no business type is mentioned. \"other\" is a real business category (a business fitting none of the listed types), NOT a value meaning \"unspecified\" or \"any\" — a query naming no business type at all, such as \"anything from 2 weeks ago\", must be null and never \"other\". \(SearchDateResolver.promptGuidance) Query: \"\(text)\""]],
            "response_format": ["type": "json_schema", "json_schema": ["schema": schema]],
        ]
        var request = URLRequest(url: URL(string: "https://api.perplexity.ai/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SemanticSearchError.api(String(data: respData, encoding: .utf8) ?? "HTTP request failed")
        }
        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let contentString = message["content"] as? String,
              let fieldsData = contentString.data(using: .utf8),
              let fields = try JSONSerialization.jsonObject(with: fieldsData) as? [String: Any] else {
            throw SemanticSearchError.parsing("Malformed response")
        }
        let dates = SearchDateResolver.range(from: fields)
        return QueryParseResult(
            vendorType: VendorTypeToken.resolve(fields["vendor_type"] as? String),
            amountMin: (fields["amount_min"] as? NSNumber)?.doubleValue,
            amountMax: (fields["amount_max"] as? NSNumber)?.doubleValue,
            dateFrom: dates.from, dateTo: dates.to,
            unrecognizedDateToken: dates.unrecognizedToken)
    }

    // MARK: Gemini

    private static func parseQueryViaGemini(_ text: String) async throws -> QueryParseResult {
        guard let apiKey = KeychainHelper.get(AppConstants.KeychainKeys.geminiAPIKey), !apiKey.isEmpty else {
            throw SemanticSearchError.missingAPIKey
        }
        // nullable alongside enum is supported by Gemini's schema (same
        // OpenAPI-style subset used elsewhere in this file) — genuine null
        // for "no business type mentioned" matters here: without it, the
        // model would be forced to pick some value even for pure amount
        // queries like ">80", which would corrupt the "other" bucket into
        // meaning two different things.
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "vendor_type": ["type": "STRING", "enum": VendorTypeToken.allValidValues, "nullable": true],
                "amount_min": ["type": "NUMBER", "nullable": true],
                "amount_max": ["type": "NUMBER", "nullable": true],
                "date_range_kind": ["type": "STRING", "enum": QueryDateRangeKind.allValidValues, "nullable": true],
                "date_count": ["type": "INTEGER", "nullable": true],
                "date_month": ["type": "INTEGER", "nullable": true],
                "date_year": ["type": "INTEGER", "nullable": true],
            ],
        ]
        let body: [String: Any] = [
            "contents": [["parts": [["text": "Parse this receipt search query into a structured filter. Map any mentioned business type onto the closest enum value; use null if the query doesn't mention a business type. \"other\" is a real business category (a business fitting none of the listed types), NOT a value meaning \"unspecified\" or \"any\" — a query naming no business type at all, such as \"anything from 2 weeks ago\", must be null and never \"other\". \(SearchDateResolver.promptGuidance) Query: \"\(text)\""]]]],
            "generationConfig": ["responseMimeType": "application/json", "responseSchema": schema],
        ]
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(AppConstants.geminiModel):generateContent?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SemanticSearchError.api(String(data: respData, encoding: .utf8) ?? "HTTP request failed")
        }
        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let contentDict = candidates.first?["content"] as? [String: Any],
              let parts = contentDict["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String,
              let fieldsData = text.data(using: .utf8),
              let fields = try JSONSerialization.jsonObject(with: fieldsData) as? [String: Any] else {
            throw SemanticSearchError.parsing("Malformed response")
        }
        let dates = SearchDateResolver.range(from: fields)
        return QueryParseResult(
            vendorType: VendorTypeToken.resolve(fields["vendor_type"] as? String),
            amountMin: (fields["amount_min"] as? NSNumber)?.doubleValue,
            amountMax: (fields["amount_max"] as? NSNumber)?.doubleValue,
            dateFrom: dates.from, dateTo: dates.to,
            unrecognizedDateToken: dates.unrecognizedToken)
    }
}

// MARK: - Vendor type backfill

enum VendorTypeClassificationError: LocalizedError {
    case missingAPIKey
    case api(String)
    case parsing(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key configured for the selected AI Provider — add one in Settings to classify vendor types."
        case .api(let detail):
            return "AI classification error: \(detail)"
        case .parsing(let detail):
            return "Couldn't read the classification response: \(detail)"
        }
    }
}

/// One-time (re-runnable) classification of vendor names into `VendorType`,
/// used to backfill receipts that never got a type at extraction time —
/// manual entries (no AI ever touched them) and anything saved before this
/// field existed. Classifies from vendor name only, never re-sending the
/// photo — the name alone is enough and re-extracting images for a whole
/// history would be needlessly slow and expensive.
///
/// Asks for one type per vendor as a positional array aligned with the
/// input list, rather than per-vendor round trips — one call classifies
/// every unclassified vendor name at once. Defensively re-zips only up to
/// however many entries the model actually returned, in case of a
/// length mismatch, leaving any leftover vendors unclassified for the next run
/// rather than misaligning names to the wrong types.
enum VendorTypeClassificationService {
    static func classify(vendorNames: [String]) async throws -> [String: String] {
        guard !vendorNames.isEmpty else { return [:] }
        switch ExtractionSettings.provider {
        case .claude: return try await classifyViaClaude(vendorNames)
        case .openAI: return try await classifyViaOpenAI(vendorNames)
        case .gemini: return try await classifyViaGemini(vendorNames)
        case .perplexity: return try await classifyViaPerplexity(vendorNames)
        case .azureDocumentIntelligence:
            // Fixed-schema document extraction, not a chat model — no way
            // to classify a vendor name into a business type from text alone.
            throw VendorTypeClassificationError.api("Microsoft Document Intelligence can't classify vendor types — switch AI Provider in Settings to use this.")
        case .appleOnDevice:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) { return try await classifyOnDevice(vendorNames) }
            #endif
            throw VendorTypeClassificationError.api("Apple On-Device needs iOS 26 or later.")
        }
    }

    static func prompt(for vendorNames: [String]) -> String {
        let numbered = vendorNames.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return """
        Numbered list of vendor/business names from receipts:

        \(numbered)

        Classify each one's business type. Return exactly \(vendorNames.count) values, in the same order as the list, one per vendor. Judge based on what the name itself suggests — for example, "Thai Favorite Cuisine" or "Joe's Grill" should be classified as restaurant based on the name alone. Use "other" only if truly nothing fits.
        """
    }

    static func zip(_ vendorNames: [String], with types: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for (name, rawType) in Swift.zip(vendorNames, types) {
            if let resolved = VendorTypeToken.resolve(rawType) {
                result[name] = resolved
            }
        }
        return result
    }

    // MARK: Claude

    private static func classifyViaClaude(_ vendorNames: [String]) async throws -> [String: String] {
        guard let apiKey = KeychainHelper.get(AppConstants.KeychainKeys.anthropicAPIKey), !apiKey.isEmpty else {
            throw VendorTypeClassificationError.missingAPIKey
        }
        let tool: [String: Any] = [
            "name": "classify_vendor_types",
            "description": "Classify each vendor's business type, in order.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "vendor_types": ["type": "array", "items": ["type": "string", "enum": VendorTypeToken.allValidValues], "description": "One type per vendor, same order as the input list."],
                ],
                "required": ["vendor_types"],
            ],
        ]
        let body: [String: Any] = [
            "model": AppConstants.claudeModel,
            "max_tokens": 1024,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "classify_vendor_types"],
            "messages": [["role": "user", "content": prompt(for: vendorNames)]],
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VendorTypeClassificationError.api(String(data: respData, encoding: .utf8) ?? "HTTP request failed")
        }
        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let toolUse = content.first(where: { $0["type"] as? String == "tool_use" }),
              let input = toolUse["input"] as? [String: Any],
              let types = input["vendor_types"] as? [String] else {
            throw VendorTypeClassificationError.parsing("Malformed response")
        }
        return zip(vendorNames, with: types)
    }

    // MARK: OpenAI

    private static func classifyViaOpenAI(_ vendorNames: [String]) async throws -> [String: String] {
        guard let apiKey = KeychainHelper.get(AppConstants.KeychainKeys.openAIAPIKey), !apiKey.isEmpty else {
            throw VendorTypeClassificationError.missingAPIKey
        }
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["vendor_types": ["type": "array", "items": ["type": "string", "enum": VendorTypeToken.allValidValues]]],
            "required": ["vendor_types"],
            "additionalProperties": false,
        ]
        let body: [String: Any] = [
            "model": AppConstants.openAIModel,
            "messages": [["role": "user", "content": prompt(for: vendorNames)]],
            "response_format": ["type": "json_schema", "json_schema": ["name": "classify_vendor_types", "strict": true, "schema": schema]],
        ]
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VendorTypeClassificationError.api(String(data: respData, encoding: .utf8) ?? "HTTP request failed")
        }
        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let contentString = message["content"] as? String,
              let fieldsData = contentString.data(using: .utf8),
              let fields = try JSONSerialization.jsonObject(with: fieldsData) as? [String: Any],
              let types = fields["vendor_types"] as? [String] else {
            throw VendorTypeClassificationError.parsing("Malformed response")
        }
        return zip(vendorNames, with: types)
    }

    // MARK: Perplexity

    private static func classifyViaPerplexity(_ vendorNames: [String]) async throws -> [String: String] {
        guard let apiKey = KeychainHelper.get(AppConstants.KeychainKeys.perplexityAPIKey), !apiKey.isEmpty else {
            throw VendorTypeClassificationError.missingAPIKey
        }
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["vendor_types": ["type": "array", "items": ["type": "string", "enum": VendorTypeToken.allValidValues]]],
            "required": ["vendor_types"],
            "additionalProperties": false,
        ]
        let body: [String: Any] = [
            "model": AppConstants.perplexityModel,
            "messages": [["role": "user", "content": prompt(for: vendorNames)]],
            "response_format": ["type": "json_schema", "json_schema": ["schema": schema]],
        ]
        var request = URLRequest(url: URL(string: "https://api.perplexity.ai/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VendorTypeClassificationError.api(String(data: respData, encoding: .utf8) ?? "HTTP request failed")
        }
        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let contentString = message["content"] as? String,
              let fieldsData = contentString.data(using: .utf8),
              let fields = try JSONSerialization.jsonObject(with: fieldsData) as? [String: Any],
              let types = fields["vendor_types"] as? [String] else {
            throw VendorTypeClassificationError.parsing("Malformed response")
        }
        return zip(vendorNames, with: types)
    }

    // MARK: Gemini

    private static func classifyViaGemini(_ vendorNames: [String]) async throws -> [String: String] {
        guard let apiKey = KeychainHelper.get(AppConstants.KeychainKeys.geminiAPIKey), !apiKey.isEmpty else {
            throw VendorTypeClassificationError.missingAPIKey
        }
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": ["vendor_types": ["type": "ARRAY", "items": ["type": "STRING", "enum": VendorTypeToken.allValidValues]]],
            "required": ["vendor_types"],
        ]
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt(for: vendorNames)]]]],
            "generationConfig": ["responseMimeType": "application/json", "responseSchema": schema],
        ]
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(AppConstants.geminiModel):generateContent?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VendorTypeClassificationError.api(String(data: respData, encoding: .utf8) ?? "HTTP request failed")
        }
        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let contentDict = candidates.first?["content"] as? [String: Any],
              let parts = contentDict["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String,
              let fieldsData = text.data(using: .utf8),
              let fields = try JSONSerialization.jsonObject(with: fieldsData) as? [String: Any],
              let types = fields["vendor_types"] as? [String] else {
            throw VendorTypeClassificationError.parsing("Malformed response")
        }
        return zip(vendorNames, with: types)
    }
}
