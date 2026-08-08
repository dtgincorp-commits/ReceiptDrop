import Foundation

enum AzureDocIntelError: LocalizedError {
    case missingCredentials
    case api(String)
    case parsing(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "No Microsoft Document Intelligence endpoint/key. Add both in Settings."
        case .api(let detail):
            return "Document Intelligence error: \(detail)"
        case .parsing(let detail):
            return "Couldn't read Document Intelligence's response: \(detail)"
        }
    }
}

/// Azure AI Document Intelligence — Microsoft's cloud document-parsing
/// service, using its `prebuilt-receipt` model. Unlike Claude/OpenAI/Gemini/
/// Perplexity this isn't a chat model given a prompt: it's a fixed-schema
/// extraction endpoint (merchant, date, totals, line items), so there's
/// nothing to steer with `ExtractionPrompt`'s category context, and no
/// OCR-text path — the model only accepts image/PDF bytes.
///
/// Analysis is asynchronous server-side: submitting returns a 202 with an
/// `Operation-Location` header that's polled until the result is ready.
struct AzureDocumentIntelligenceService: ReceiptExtractor {
    func extract(data: Data, kind: ReceiptKind, categoryContext: String = "") async throws -> ExtractedReceipt {
        let fields = try await Self.analyze(data: data)
        return Self.buildReceipt(from: fields)
    }

    func extract(ocrText: String, categoryContext: String = "") async throws -> ExtractedReceipt {
        throw AzureDocIntelError.api(
            "Microsoft Document Intelligence reads the receipt image directly — it can't work from OCR text alone. Switch Extraction Mode to Full Image.")
    }

    // MARK: - Shared analysis call (also used by BillItemizationService)

    /// Submits image/PDF bytes to the prebuilt-receipt model and polls until
    /// Azure finishes processing. Returns the raw `analyzeResult.documents[0]
    /// .fields` dictionary for callers to map into their own shape.
    static func analyze(data: Data) async throws -> [String: Any] {
        guard let endpoint = KeychainHelper.get(AppConstants.KeychainKeys.azureDocIntelEndpoint), !endpoint.isEmpty,
              let apiKey = KeychainHelper.get(AppConstants.KeychainKeys.azureDocIntelKey), !apiKey.isEmpty
        else {
            throw AzureDocIntelError.missingCredentials
        }

        let trimmedEndpoint = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let submitURL = URL(string:
            "\(trimmedEndpoint)/documentintelligence/documentModels/\(AppConstants.azureDocIntelModel):analyze?api-version=\(AppConstants.azureDocIntelAPIVersion)")
        else {
            throw AzureDocIntelError.api("Invalid endpoint URL")
        }

        var request = URLRequest(url: submitURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (submitData, submitResponse) = try await URLSession.shared.data(for: request)
        guard let http = submitResponse as? HTTPURLResponse else {
            throw AzureDocIntelError.api("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: submitData, encoding: .utf8) ?? ""
            throw AzureDocIntelError.api("HTTP \(http.statusCode): \(body)")
        }
        guard let operationLocation = http.value(forHTTPHeaderField: "Operation-Location"),
              let pollURL = URL(string: operationLocation)
        else {
            throw AzureDocIntelError.api("No Operation-Location header in response")
        }

        // Azure's analysis runs async server-side — poll until it finishes.
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            var pollRequest = URLRequest(url: pollURL)
            pollRequest.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
            let (pollData, _) = try await URLSession.shared.data(for: pollRequest)
            guard let pollJSON = try? JSONSerialization.jsonObject(with: pollData) as? [String: Any] else {
                throw AzureDocIntelError.parsing("Malformed poll response")
            }
            switch pollJSON["status"] as? String {
            case "succeeded":
                guard let analyzeResult = pollJSON["analyzeResult"] as? [String: Any],
                      let documents = analyzeResult["documents"] as? [[String: Any]],
                      let fields = documents.first?["fields"] as? [String: Any]
                else {
                    throw AzureDocIntelError.parsing("No fields in analyzeResult")
                }
                return fields
            case "failed":
                throw AzureDocIntelError.api("Analysis failed: \(pollJSON)")
            default:
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        throw AzureDocIntelError.api("Timed out waiting for Document Intelligence to finish")
    }

    // MARK: - Field helpers (shared with BillItemizationService's Azure path)

    static func string(_ fields: [String: Any], _ key: String) -> String {
        guard let field = fields[key] as? [String: Any] else { return "" }
        return (field["valueString"] as? String) ?? (field["content"] as? String) ?? ""
    }

    static func amount(_ fields: [String: Any], _ key: String) -> Double? {
        guard let field = fields[key] as? [String: Any],
              let currency = field["valueCurrency"] as? [String: Any]
        else { return nil }
        return currency["amount"] as? Double
    }

    static func dateString(_ fields: [String: Any], _ key: String) -> String {
        guard let field = fields[key] as? [String: Any] else { return "" }
        return field["valueDate"] as? String ?? ""
    }

    // MARK: - Receipt mapping (for normal archive extraction)

    private static func buildReceipt(from fields: [String: Any]) -> ExtractedReceipt {
        let vendor = string(fields, "MerchantName")
        let workDate = dateString(fields, "TransactionDate")
        let total = amount(fields, "Total")

        var comments = ""
        if let itemsArray = (fields["Items"] as? [String: Any])?["valueArray"] as? [Any], !itemsArray.isEmpty {
            comments = "\(itemsArray.count) item\(itemsArray.count == 1 ? "" : "s")"
        }

        return ExtractedReceipt.build(
            vendor: vendor,
            rawWorkDate: workDate,
            amount: total.map { String($0) } ?? "",
            comments: comments,
            rawVendorType: "", // the prebuilt-receipt model doesn't classify business type
            modelReportedLowConfidence: false,
            modelReason: "")
    }
}
