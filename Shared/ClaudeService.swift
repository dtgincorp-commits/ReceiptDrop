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
    func extract(data: Data, kind: ReceiptKind) async throws -> ExtractedReceipt {
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
        return try await send(content: [
            sourceBlock,
            ["type": "text", "text": "Extract this receipt's details using the record_receipt tool."],
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
    func extract(ocrText: String) async throws -> ExtractedReceipt {
        try await send(content: [
            ["type": "text", "text": "Here is text recognized from a photo of a receipt via on-device OCR. It may contain recognition noise (misread characters, garbled spacing). Extract the receipt's details using the record_receipt tool.\n\n\(ocrText)"],
        ])
    }

    private func send(content: [[String: Any]]) async throws -> ExtractedReceipt {
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
                    "confidence_reason": [
                        "type": "string",
                        "description": "If confidence is \"low\", a short phrase explaining why (e.g. \"handwritten total, hard to read\"). Empty string if confidence is \"high\".",
                    ],
                ],
                "required": ["vendor", "work_date", "amount", "comments", "confidence", "confidence_reason"],
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
            comments: string("comments"),
            modelReportedLowConfidence: string("confidence").lowercased() == "low",
            modelReason: string("confidence_reason"))
    }

    /// Best-effort normalization to yyyy-MM-dd. If Claude already returned that
    /// format we keep it; anything unparseable falls back to today's date so a
    /// row is never written with a garbage date.
    static func normalizeDate(_ raw: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = AppConstants.sheetDateFormat

        if !raw.isEmpty, formatter.date(from: raw) != nil {
            return raw
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
enum VisionOCRService {
    static func recognizeText(in data: Data) async throws -> String {
        guard let cgImage = CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else {
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

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
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
    func extract(data: Data, kind: ReceiptKind) async throws -> ExtractedReceipt {
        guard kind == .image else {
            throw OpenAIError.api("OpenAI extraction currently supports images only, not PDFs.")
        }
        let uploadData = ClaudeService.downscaledJPEG(from: data) ?? data
        let base64 = uploadData.base64EncodedString()
        let content: [[String: Any]] = [
            ["type": "text", "text": "Extract this receipt's details."],
            ["type": "image_url", "image_url": ["url": "data:\(kind.mimeType);base64,\(base64)"]],
        ]
        return try await send(content: content)
    }

    func extract(ocrText: String) async throws -> ExtractedReceipt {
        let content: [[String: Any]] = [
            ["type": "text", "text": "Here is text recognized from a photo of a receipt via on-device OCR. It may contain recognition noise (misread characters, garbled spacing). Extract the receipt's details.\n\n\(ocrText)"],
        ]
        return try await send(content: content)
    }

    private func send(content: [[String: Any]]) async throws -> ExtractedReceipt {
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
                "confidence_reason": ["type": "string", "description": "If confidence is \"low\", a short phrase explaining why. Empty string if confidence is \"high\"."],
            ],
            "required": ["vendor", "work_date", "amount", "comments", "confidence", "confidence_reason"],
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
            comments: string("comments"),
            modelReportedLowConfidence: string("confidence").lowercased() == "low",
            modelReason: string("confidence_reason"))
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
    func extract(data: Data, kind: ReceiptKind) async throws -> ExtractedReceipt {
        let uploadData = kind == .image ? (ClaudeService.downscaledJPEG(from: data) ?? data) : data
        let base64 = uploadData.base64EncodedString()
        let parts: [[String: Any]] = [
            ["text": "Extract this receipt's details."],
            ["inline_data": ["mime_type": kind.mimeType, "data": base64]],
        ]
        return try await send(parts: parts)
    }

    func extract(ocrText: String) async throws -> ExtractedReceipt {
        let parts: [[String: Any]] = [
            ["text": "Here is text recognized from a photo of a receipt via on-device OCR. It may contain recognition noise (misread characters, garbled spacing). Extract the receipt's details.\n\n\(ocrText)"],
        ]
        return try await send(parts: parts)
    }

    private func send(parts: [[String: Any]]) async throws -> ExtractedReceipt {
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
                "confidence_reason": ["type": "STRING"],
            ],
            "required": ["vendor", "work_date", "amount", "comments", "confidence", "confidence_reason"],
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
            comments: string("comments"),
            modelReportedLowConfidence: string("confidence").lowercased() == "low",
            modelReason: string("confidence_reason"))
    }
}
