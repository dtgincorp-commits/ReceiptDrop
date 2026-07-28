import Foundation

enum BillItemizationError: LocalizedError {
    case unsupportedProvider
    case missingAPIKey(String)
    case rateLimited(String)
    case api(String)
    case parsing(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "Bill itemization needs Claude, OpenAI, or Gemini. Switch the AI Provider in Settings, then try again."
        case .missingAPIKey(let provider):
            return "No \(provider) API key. Add one in Settings."
        case .rateLimited(let detail):
            return "Rate limit reached: \(detail)"
        case .api(let detail):
            return "Couldn't read this bill: \(detail)"
        case .parsing(let detail):
            return "Couldn't read the response: \(detail)"
        }
    }
}

/// Pulls just the human-readable `message` out of a provider's error body —
/// each shapes its error envelope slightly differently, but all three put a
/// plain-English `message` somewhere reachable, so the UI shows a real
/// sentence instead of a raw JSON dump.
private func shortAPIMessage(from body: String, fallback: String) -> String {
    guard let data = body.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return body.isEmpty ? fallback : body
    }
    if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
        return message
    }
    if let message = json["message"] as? String {
        return message
    }
    return fallback
}

/// Reads an itemized breakdown from a bill photo for "Check a Bill" — a
/// separate schema from `ReceiptExtractor`, which deliberately only captures
/// vendor/date/total for the permanent archive. Reuses the same provider
/// selection and Keychain-stored API keys as normal receipt extraction.
///
/// Apple On-Device isn't wired up for this schema in v1 — if it's the
/// current provider, this throws a clear error asking the user to switch,
/// rather than silently falling back to a cloud provider behind their back.
enum BillItemizationService {
    static func itemize(data: Data) async throws -> ExtractedBill {
        try ExtractionSettings.assertProviderAllowed()

        // Providers occasionally return a transient "couldn't process this
        // image, please retry" error with no code-side cause — the exact
        // same bytes succeed a moment later. Retry once automatically before
        // surfacing anything to the user, since manually tapping "Try Again"
        // for a server-side hiccup is pure friction.
        //
        // Rate limiting is a different kind of failure and must NOT be
        // retried immediately — that just burns another request against an
        // already-exhausted quota. Config errors (missing key, unsupported
        // provider) are deterministic; retrying just repeats the same
        // failure after a pointless delay.
        do {
            return try await attemptItemize(data)
        } catch BillItemizationError.missingAPIKey(let provider) {
            throw BillItemizationError.missingAPIKey(provider)
        } catch BillItemizationError.unsupportedProvider {
            throw BillItemizationError.unsupportedProvider
        } catch BillItemizationError.rateLimited(let detail) {
            throw BillItemizationError.rateLimited(detail)
        } catch {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return try await attemptItemize(data)
        }
    }

    private static func attemptItemize(_ data: Data) async throws -> ExtractedBill {
        switch ExtractionSettings.provider {
        case .claude: return try await itemizeViaClaude(data)
        case .openAI: return try await itemizeViaOpenAI(data)
        case .gemini: return try await itemizeViaGemini(data)
        case .appleOnDevice: throw BillItemizationError.unsupportedProvider
        }
    }

    private static let itemsPrompt = """
    This is a photo of a restaurant/store bill. List every line item printed \
    on it — one entry per item, in the order printed. For each: the item name \
    as printed, the quantity (as a whole number; use 1 if none is shown), and \
    the line's printed total price as a plain number string with no currency \
    symbol (this is the price for that whole line, already reflecting the \
    quantity — not a per-unit price). If a line is present but genuinely \
    illegible (smudged, torn, cut off), do not guess its name or price — omit \
    it from the items list and count it in unreadable_line_count instead. \
    Also read the subtotal, tax, service charge/tip (if separately printed), \
    and grand total as plain number strings; use an empty string for any of \
    these that aren't printed on the bill. Never invent a value that isn't \
    actually shown.
    """

    private static func parseItems(from raw: [[String: Any]]) -> [(name: String, quantity: String, price: String)] {
        raw.map {
            (name: $0["name"] as? String ?? "",
             quantity: $0["quantity"] as? String ?? "1",
             price: $0["price"] as? String ?? "")
        }
    }

    // MARK: - Claude

    private static func itemizeViaClaude(_ data: Data) async throws -> ExtractedBill {
        guard let apiKey = KeychainHelper.get(AppConstants.KeychainKeys.anthropicAPIKey), !apiKey.isEmpty else {
            throw BillItemizationError.missingAPIKey("Anthropic")
        }
        let uploadData = ClaudeService.downscaledJPEG(from: data) ?? data
        let base64 = uploadData.base64EncodedString()

        let itemSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "quantity": ["type": "string", "description": "Whole-number quantity as a string, e.g. \"1\", \"2\"."],
                "price": ["type": "string", "description": "This line's printed total price, plain number string."],
            ],
            "required": ["name", "quantity", "price"],
        ]
        let tool: [String: Any] = [
            "name": "record_bill",
            "description": "Record every line item and totals read from a bill photo.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "vendor": ["type": "string", "description": "Vendor/business name. Empty string if not present."],
                    "items": ["type": "array", "items": itemSchema, "description": "Every line item, in printed order."],
                    "subtotal": ["type": "string", "description": "Printed subtotal, empty string if not shown."],
                    "tax": ["type": "string", "description": "Printed tax amount, empty string if not shown."],
                    "service_charge": ["type": "string", "description": "Printed service charge/tip, empty string if not shown."],
                    "total": ["type": "string", "description": "Printed grand total, empty string if not shown."],
                    "unreadable_line_count": ["type": "string", "description": "Count of illegible lines omitted from items, as a string. \"0\" if none."],
                ],
                "required": ["vendor", "items", "subtotal", "tax", "service_charge", "total", "unreadable_line_count"],
            ],
        ]
        let body: [String: Any] = [
            "model": AppConstants.claudeModel,
            "max_tokens": 2048,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "record_bill"],
            "messages": [["role": "user", "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]],
                ["type": "text", "text": itemsPrompt],
            ]]],
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BillItemizationError.api("No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: respData, encoding: .utf8) ?? ""
            let message = shortAPIMessage(from: body, fallback: "HTTP \(http.statusCode)")
            if http.statusCode == 429 {
                throw BillItemizationError.rateLimited(message)
            }
            throw BillItemizationError.api(message)
        }
        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let toolUse = content.first(where: { $0["type"] as? String == "tool_use" }),
              let input = toolUse["input"] as? [String: Any] else {
            throw BillItemizationError.parsing("No tool_use block returned")
        }
        func string(_ key: String) -> String { (input[key] as? String) ?? "" }
        let rawItems = parseItems(from: input["items"] as? [[String: Any]] ?? [])
        return ExtractedBill.build(
            vendor: string("vendor"), rawItems: rawItems,
            subtotal: string("subtotal"), tax: string("tax"),
            serviceCharge: string("service_charge"), total: string("total"),
            unreadableLineCount: string("unreadable_line_count"))
    }

    // MARK: - OpenAI

    private static func itemizeViaOpenAI(_ data: Data) async throws -> ExtractedBill {
        guard let apiKey = KeychainHelper.get(AppConstants.KeychainKeys.openAIAPIKey), !apiKey.isEmpty else {
            throw BillItemizationError.missingAPIKey("OpenAI")
        }
        let uploadData = ClaudeService.downscaledJPEG(from: data) ?? data
        let base64 = uploadData.base64EncodedString()

        let itemSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "quantity": ["type": "string"],
                "price": ["type": "string"],
            ],
            "required": ["name", "quantity", "price"],
            "additionalProperties": false,
        ]
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "vendor": ["type": "string"],
                "items": ["type": "array", "items": itemSchema],
                "subtotal": ["type": "string"],
                "tax": ["type": "string"],
                "service_charge": ["type": "string"],
                "total": ["type": "string"],
                "unreadable_line_count": ["type": "string"],
            ],
            "required": ["vendor", "items", "subtotal", "tax", "service_charge", "total", "unreadable_line_count"],
            "additionalProperties": false,
        ]
        let content: [[String: Any]] = [
            ["type": "text", "text": itemsPrompt],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]],
        ]
        let body: [String: Any] = [
            "model": AppConstants.openAIModel,
            "messages": [["role": "user", "content": content]],
            "response_format": ["type": "json_schema", "json_schema": ["name": "record_bill", "strict": true, "schema": schema]],
        ]

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BillItemizationError.api("No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: respData, encoding: .utf8) ?? ""
            let message = shortAPIMessage(from: body, fallback: "HTTP \(http.statusCode)")
            if http.statusCode == 429 {
                throw BillItemizationError.rateLimited(message)
            }
            throw BillItemizationError.api(message)
        }
        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let contentString = message["content"] as? String,
              let fieldsData = contentString.data(using: .utf8),
              let fields = try JSONSerialization.jsonObject(with: fieldsData) as? [String: Any] else {
            throw BillItemizationError.parsing("Malformed response envelope")
        }
        func string(_ key: String) -> String { (fields[key] as? String) ?? "" }
        let rawItems = parseItems(from: fields["items"] as? [[String: Any]] ?? [])
        return ExtractedBill.build(
            vendor: string("vendor"), rawItems: rawItems,
            subtotal: string("subtotal"), tax: string("tax"),
            serviceCharge: string("service_charge"), total: string("total"),
            unreadableLineCount: string("unreadable_line_count"))
    }

    // MARK: - Gemini

    private static func itemizeViaGemini(_ data: Data) async throws -> ExtractedBill {
        guard let apiKey = KeychainHelper.get(AppConstants.KeychainKeys.geminiAPIKey), !apiKey.isEmpty else {
            throw BillItemizationError.missingAPIKey("Gemini")
        }
        let uploadData = ClaudeService.downscaledJPEG(from: data) ?? data
        let base64 = uploadData.base64EncodedString()

        let itemSchema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "name": ["type": "STRING"],
                "quantity": ["type": "STRING"],
                "price": ["type": "STRING"],
            ],
            "required": ["name", "quantity", "price"],
        ]
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "vendor": ["type": "STRING"],
                "items": ["type": "ARRAY", "items": itemSchema],
                "subtotal": ["type": "STRING"],
                "tax": ["type": "STRING"],
                "service_charge": ["type": "STRING"],
                "total": ["type": "STRING"],
                "unreadable_line_count": ["type": "STRING"],
            ],
            "required": ["vendor", "items", "subtotal", "tax", "service_charge", "total", "unreadable_line_count"],
        ]
        let parts: [[String: Any]] = [
            ["text": itemsPrompt],
            ["inline_data": ["mime_type": "image/jpeg", "data": base64]],
        ]
        let body: [String: Any] = [
            "contents": [["parts": parts]],
            "generationConfig": ["responseMimeType": "application/json", "responseSchema": schema],
        ]

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(AppConstants.geminiModel):generateContent?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BillItemizationError.api("No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: respData, encoding: .utf8) ?? ""
            let message = shortAPIMessage(from: body, fallback: "HTTP \(http.statusCode)")
            if http.statusCode == 429 {
                throw BillItemizationError.rateLimited(message)
            }
            throw BillItemizationError.api(message)
        }
        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let contentDict = candidates.first?["content"] as? [String: Any],
              let responseParts = contentDict["parts"] as? [[String: Any]],
              let text = responseParts.first?["text"] as? String,
              let fieldsData = text.data(using: .utf8),
              let fields = try JSONSerialization.jsonObject(with: fieldsData) as? [String: Any] else {
            throw BillItemizationError.parsing("Malformed response envelope")
        }
        func string(_ key: String) -> String { (fields[key] as? String) ?? "" }
        let rawItems = parseItems(from: fields["items"] as? [[String: Any]] ?? [])
        return ExtractedBill.build(
            vendor: string("vendor"), rawItems: rawItems,
            subtotal: string("subtotal"), tax: string("tax"),
            serviceCharge: string("service_charge"), total: string("total"),
            unreadableLineCount: string("unreadable_line_count"))
    }
}
