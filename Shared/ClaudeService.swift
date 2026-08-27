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

/// A search query broken into a structured filter, e.g. "restaurant receipts
/// over 100" → vendorType "restaurant", amountMin 100.
struct QueryParseResult {
    let vendorType: String?
    let amountMin: Double?
    let amountMax: Double?

    var isEmpty: Bool { vendorType == nil && amountMin == nil && amountMax == nil }
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
        switch ExtractionSettings.provider {
        case .claude: return try await parseQueryViaClaude(text)
        case .openAI: return try await parseQueryViaOpenAI(text)
        case .gemini: return try await parseQueryViaGemini(text)
        case .perplexity: return try await parseQueryViaPerplexity(text)
        case .azureDocumentIntelligence:
            // Azure's prebuilt-receipt model is fixed-schema document
            // extraction, not an instruction-following chat model — it has
            // no way to parse a free-form search phrase.
            throw SemanticSearchError.api("Microsoft Document Intelligence can't parse search queries — switch AI Provider in Settings to search receipts.")
        case .appleOnDevice:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) { return try await parseQueryOnDevice(text) }
            #endif
            // Older OS / toolchain without Foundation Models: fall back to
            // Gemini (still needs a Gemini key on those builds).
            return try await parseQueryViaGemini(text)
        }
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
                    "vendor_type": ["type": ["string", "null"], "enum": VendorTypeToken.allValidValues + [NSNull()], "description": "The kind of business being searched for, mapped onto the closest fit from the enum. Null if the query doesn't mention a business type at all — do not force \"other\" just because the query has no type in it."],
                    "amount_min": ["type": ["number", "null"], "description": "Minimum amount if the query implies a lower bound (e.g. 'over 100', 'at least 50'). Null if none."],
                    "amount_max": ["type": ["number", "null"], "description": "Maximum amount if the query implies an upper bound (e.g. 'under 20', 'below $50'). Null if none."],
                ],
                "required": ["vendor_type", "amount_min", "amount_max"],
            ],
        ]
        let body: [String: Any] = [
            "model": AppConstants.claudeModel,
            "max_tokens": 512,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "parse_search_query"],
            "messages": [["role": "user", "content": "Parse this receipt search query: \"\(text)\""]],
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
        return QueryParseResult(
            vendorType: VendorTypeToken.resolve(input["vendor_type"] as? String),
            amountMin: (input["amount_min"] as? NSNumber)?.doubleValue,
            amountMax: (input["amount_max"] as? NSNumber)?.doubleValue)
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
            ],
            "required": ["vendor_type", "amount_min", "amount_max"],
            "additionalProperties": false,
        ]
        let body: [String: Any] = [
            "model": AppConstants.openAIModel,
            "messages": [["role": "user", "content": "Parse this receipt search query into a structured filter. Map any mentioned business type onto the closest enum value; use null (not a forced guess) if no business type is mentioned: \"\(text)\""]],
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
        return QueryParseResult(
            vendorType: VendorTypeToken.resolve(fields["vendor_type"] as? String),
            amountMin: (fields["amount_min"] as? NSNumber)?.doubleValue,
            amountMax: (fields["amount_max"] as? NSNumber)?.doubleValue)
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
            ],
            "required": ["vendor_type", "amount_min", "amount_max"],
            "additionalProperties": false,
        ]
        let body: [String: Any] = [
            "model": AppConstants.perplexityModel,
            "messages": [["role": "user", "content": "Parse this receipt search query into a structured filter. Map any mentioned business type onto the closest enum value; use null (not a forced guess) if no business type is mentioned: \"\(text)\""]],
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
        return QueryParseResult(
            vendorType: VendorTypeToken.resolve(fields["vendor_type"] as? String),
            amountMin: (fields["amount_min"] as? NSNumber)?.doubleValue,
            amountMax: (fields["amount_max"] as? NSNumber)?.doubleValue)
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
            ],
        ]
        let body: [String: Any] = [
            "contents": [["parts": [["text": "Parse this receipt search query into a structured filter. Map any mentioned business type onto the closest enum value; use null if the query doesn't mention a business type — do not force \"other\" onto a query with no type in it: \"\(text)\""]]]],
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
        return QueryParseResult(
            vendorType: VendorTypeToken.resolve(fields["vendor_type"] as? String),
            amountMin: (fields["amount_min"] as? NSNumber)?.doubleValue,
            amountMax: (fields["amount_max"] as? NSNumber)?.doubleValue)
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
