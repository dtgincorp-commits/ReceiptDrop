import Foundation

/// Verifies a saved API key actually works, without running a full receipt
/// extraction — each provider's cheapest real endpoint (a models list, not a
/// generation call) is enough to prove the key is valid and confirm the
/// provider's own rejection reason (bad key, no billing, etc.) rather than
/// only discovering a bad key when a real receipt submission fails.
enum APIKeyTester {
    enum TestError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .failed(let detail): return detail
            }
        }
    }

    static func testClaudeKey(_ apiKey: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        try await verify(request)
    }

    static func testOpenAIKey(_ apiKey: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        try await verify(request)
    }

    static func testGeminiKey(_ apiKey: String) async throws {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(apiKey)")!
        try await verify(URLRequest(url: url))
    }

    private static func verify(_ request: URLRequest) async throws {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TestError.failed("No response from server.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let message = shortMessage(from: body) ?? "HTTP \(http.statusCode)"
            throw TestError.failed(message)
        }
    }

    /// Providers wrap their error text differently — pull out just the
    /// human-readable `message` field so the alert doesn't dump raw JSON.
    private static func shortMessage(from body: String) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            return body.isEmpty ? nil : body
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let message = json["message"] as? String {
            return message
        }
        return body
    }
}
