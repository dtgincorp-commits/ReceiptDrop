import Foundation

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
struct ClaudeService {
    func extract(data: Data, kind: ReceiptKind) async throws -> ExtractedReceipt {
        let base64 = data.base64EncodedString()
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

        let vendor = string("vendor")
        let rawWorkDate = string("work_date")
        let amount = string("amount")

        // Heuristic safety net, independent of the model's self-reported
        // confidence: catches cases where Claude states "high" confidence but
        // a field is still empty or the date fell back to today because
        // nothing parseable was found.
        var needsReview = string("confidence").lowercased() == "low"
        var reason = string("confidence_reason")
        if vendor.isEmpty {
            needsReview = true
            if reason.isEmpty { reason = "Vendor name missing" }
        }
        if amount.isEmpty || Double(amount) == nil || Double(amount) == 0 {
            needsReview = true
            if reason.isEmpty { reason = "Amount missing or unreadable" }
        }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = AppConstants.sheetDateFormat
        if rawWorkDate.isEmpty || dateFormatter.date(from: rawWorkDate) == nil {
            needsReview = true
            if reason.isEmpty { reason = "Date unreadable, defaulted to today" }
        }

        return ExtractedReceipt(
            vendor: vendor,
            workDate: Self.normalizeDate(rawWorkDate),
            amount: amount,
            comments: string("comments"),
            needsReview: needsReview,
            reviewReason: reason)
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
