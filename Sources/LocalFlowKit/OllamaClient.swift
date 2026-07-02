import Foundation

/// Minimal client for a locally running Ollama server. The only host it ever
/// talks to is the configured base URL (default http://localhost:11434); nothing
/// leaves the machine. Stateless and Sendable so it can be captured in the
/// cleanup timeout task group freely.
public struct OllamaClient: Sendable {
    public static let defaultBaseURL = "http://localhost:11434"

    /// Base URL is configurable via the "ollamaURL" user default so the server
    /// can be pointed elsewhere on the loopback without a rebuild.
    private var baseURL: String {
        UserDefaults.standard.string(forKey: "ollamaURL") ?? OllamaClient.defaultBaseURL
    }

    public init() {}

    public enum OllamaError: Error, LocalizedError {
        case invalidURL
        case badStatus(Int)

        public var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid Ollama URL."
            case .badStatus(let code): return "Ollama returned HTTP \(code)."
            }
        }
    }

    // MARK: - Chat

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let options: Options
        let keepAlive: String

        struct Message: Encodable {
            let role: String
            let content: String
        }
        struct Options: Encodable {
            let temperature: Double
        }

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, options
            case keepAlive = "keep_alive"
        }
    }

    private struct ChatResponse: Decodable {
        let message: Message
        struct Message: Decodable { let content: String }
    }

    /// Sends a single system+user turn to /api/chat (non-streaming) and returns
    /// the assistant message content. Hard 15s request timeout.
    public func chat(model: String, system: String, user: String) async throws -> String {
        guard let url = URL(string: baseURL + "/api/chat") else {
            throw OllamaError.invalidURL
        }
        let body = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user)
            ],
            stream: false,
            options: .init(temperature: 0.1),
            keepAlive: "2h"
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OllamaError.badStatus(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.message.content
    }

    // MARK: - Preload

    private struct GenerateRequest: Encodable {
        let model: String
        let keepAlive: String

        enum CodingKeys: String, CodingKey {
            case model
            case keepAlive = "keep_alive"
        }
    }

    /// Loads the model into memory without generating anything (empty prompt).
    /// Fire-and-forget: any error is ignored so a cold or missing server never
    /// surfaces here. Uses a longer timeout since a cold load can take a while.
    public func preload(model: String) async {
        guard let url = URL(string: baseURL + "/api/generate") else { return }
        let body = GenerateRequest(model: model, keepAlive: "2h")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)
        request.timeoutInterval = 120
        _ = try? await URLSession.shared.data(for: request)
    }
}
