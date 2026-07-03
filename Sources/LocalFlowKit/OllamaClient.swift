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
        case pullFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid Ollama URL."
            case .badStatus(let code): return "Ollama returned HTTP \(code)."
            case .pullFailed(let status): return "Ollama pull did not complete (status: \(status))."
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
    /// the assistant message content. Hard 8s request timeout — the model is kept
    /// warm, so a warm pass is well under this, and raw text is a safe fallback.
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
        request.timeoutInterval = 8

        // Ollama's server can refuse a connection for a beat between back-to-back
        // requests (single-slot runner respawning under memory pressure) — field-
        // reproduced: one request succeeds, the next is instantly refused. One
        // short-backoff retry rides out the blip. Only connection-level failures
        // retry: an HTTP error or a slow model must not double the wait.
        do {
            return try await sendChat(request)
        } catch let error as URLError where
            error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
            try await Task.sleep(nanoseconds: 400_000_000)
            return try await sendChat(request)
        }
    }

    private func sendChat(_ request: URLRequest) async throws -> String {
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

    // MARK: - Model availability & self-heal pull

    private struct TagsResponse: Decodable {
        let models: [Model]
        struct Model: Decodable { let name: String }
    }

    /// Queries GET /api/tags. Returns the list of locally-available model names
    /// (each the full "name:tag", e.g. "gemma3:4b") on success, or nil when the
    /// server is unreachable or the response can't be decoded. The nil-vs-empty
    /// distinction lets callers tell "server down" apart from "server up, no
    /// models" — the former should be left alone, the latter can be self-healed.
    public func availableModels() async -> [String]? {
        guard let url = URL(string: baseURL + "/api/tags") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let decoded = try? JSONDecoder().decode(TagsResponse.self, from: data)
        else { return nil }
        return decoded.models.map(\.name)
    }

    /// Whether the server currently has `name` available locally. False on any
    /// error (unreachable, decode failure) so "can't tell" is treated as "missing".
    public func hasModel(_ name: String) async -> Bool {
        guard let names = await availableModels() else { return false }
        return OllamaClient.modelListContains(names, name)
    }

    /// Pure membership test, extracted so it can be unit-tested without a server.
    /// Prefers an exact match on the full "name:tag"; when `name` carries no tag
    /// it also matches any installed "name:<tag>" (so "gemma3" finds "gemma3:4b").
    public static func modelListContains(_ names: [String], _ name: String) -> Bool {
        if names.contains(name) { return true }
        if !name.contains(":") { return names.contains { $0.hasPrefix(name + ":") } }
        return false
    }

    private struct PullRequest: Encodable {
        let name: String
        let stream: Bool
    }

    private struct PullResponse: Decodable {
        let status: String?
    }

    /// Pulls `name` from the Ollama registry, blocking until the download finishes.
    /// Sends stream:false so the server returns a single terminal JSON object
    /// instead of a progress stream; because that object doesn't arrive until the
    /// pull completes, the request can sit idle for many minutes — hence the long
    /// (30-minute) idle timeout. Success = a 2xx whose terminal "status" is
    /// "success"; a 2xx with the field absent is also treated as success (server
    /// versions differ). Throws on a non-2xx status or an explicit failure status.
    public func pullModel(_ name: String) async throws {
        guard let url = URL(string: baseURL + "/api/pull") else {
            throw OllamaError.invalidURL
        }
        let body = PullRequest(name: name, stream: false)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 1800

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OllamaError.badStatus(http.statusCode)
        }
        if let decoded = try? JSONDecoder().decode(PullResponse.self, from: data),
           let status = decoded.status, status != "success" {
            throw OllamaError.pullFailed(status)
        }
    }
}
