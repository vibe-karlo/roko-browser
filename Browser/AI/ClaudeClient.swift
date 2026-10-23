import Foundation

struct Source: Hashable, Identifiable, Sendable {
    let url: URL
    let title: String
    var id: URL { url }
}

enum ClaudeEvent {
    case text(String)
    case source(Source)
    case searching(String)
}

struct ClaudeError: LocalizedError {
    let message: String
    /// Claude's safety classifier declined; another model may answer.
    var isRefusal = false
    var errorDescription: String? { message }
}

/// Minimal streaming client for the Messages API. Swift has no official
/// Anthropic SDK, so this speaks the documented HTTP + server-sent-events protocol.
///
/// Today the key lives in this phone's Keychain. For an App Store build, point
/// `endpoint` at your own proxy and drop the key: nothing else changes.
struct ClaudeClient {
    enum Model: String {
        /// Browse for Me questions worth some research: searches and weighs
        /// several sources. $2 / $10 per million tokens in and out.
        case sonnet = "claude-sonnet-5-5"
        /// Summaries and quick questions: fast, and a twentieth of Sonnet's
        /// price ($0.10 / $0.50).
        case haiku = "claude-haiku-5-5"

        /// Sonnet has a server-side fallback when its safety classifier
        /// declines; Haiku has none and would reject the field.
        var hasServerFallback: Bool { self == .sonnet }

        /// Sonnet filters search results before reading them (the newer tool);
        /// Haiku has the basic one, which is fine for a quick question.
        var webSearchTool: String { self == .sonnet ? "web_search_20260209" : "web_search_20250305" }
    }

    var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    let apiKey: String

    /// Settings' "Use Claude" switch. Off keeps the key but sends nothing to
    /// Claude: every feature falls back to Apple's models.
    static let enabledKey = "claude.enabled"

    static var configured: ClaudeClient? {
        guard UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true else { return nil }
        return Keychain.claudeAPIKey.map { ClaudeClient(apiKey: $0) }
    }

    /// Streams one answer. With `searches` above zero, Claude searches and reads
    /// the web itself on Anthropic's servers, up to that many times; the app
    /// only renders what comes back.
    func stream(system: String, prompt: String, model: Model = .sonnet, effort: String, maxTokens: Int = 32_000,
                searches: Int = 0) -> AsyncThrowingStream<ClaudeEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var messages: [[String: Any]] = [["role": "user", "content": prompt]]
                    // A long search turn can pause; sending the partial turn back resumes it.
                    for _ in 0..<5 {
                        let turn = try await send(system: system, messages: messages, model: model, effort: effort,
                                                  maxTokens: maxTokens, searches: searches, continuation: continuation)
                        switch turn.stopReason {
                        case "pause_turn":
                            messages.append(["role": "assistant", "content": turn.content])
                        case "refusal":
                            throw ClaudeError(message: "Claude declined to answer this one.", isRefusal: true)
                        default:
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Turn {
        var content: [[String: Any]]
        var stopReason: String?
    }

    private func send(system: String, messages: [[String: Any]], model: Model, effort: String, maxTokens: Int,
                      searches: Int, continuation: AsyncThrowingStream<ClaudeEvent, Error>.Continuation) async throws -> Turn {
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": maxTokens,
            "stream": true,
            "system": system,
            "messages": messages,
            "output_config": ["effort": effort],
        ]
        if model.hasServerFallback {
            // If a safety classifier declines, the API retries on a fallback model itself.
            body["fallbacks"] = "default"
        }
        if searches > 0 {
            body["tools"] = [["type": model.webSearchTool, "name": "web_search", "max_uses": searches]]
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if model.hasServerFallback {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var raw = Data()
            for try await byte in bytes { raw.append(byte) }
            throw ClaudeError(message: Self.errorMessage(from: raw, status: status))
        }

        var blocks: [Int: [String: Any]] = [:]
        var partialJSON: [Int: String] = [:]
        var stopReason: String?

        for try await line in bytes.lines {
            guard line.hasPrefix("data:"),
                  let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            let index = event["index"] as? Int ?? 0

            switch type {
            case "content_block_start":
                blocks[index] = event["content_block"] as? [String: Any] ?? [:]
                if let results = blocks[index]?["content"] as? [[String: Any]],
                   blocks[index]?["type"] as? String == "web_search_tool_result" {
                    for result in results {
                        if let source = Self.source(from: result) { continuation.yield(.source(source)) }
                    }
                }

            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any] else { continue }
                var block = blocks[index] ?? [:]
                switch delta["type"] as? String {
                case "text_delta":
                    let text = delta["text"] as? String ?? ""
                    block["text"] = (block["text"] as? String ?? "") + text
                    continuation.yield(.text(text))
                case "citations_delta":
                    if let citation = delta["citation"] as? [String: Any] {
                        block["citations"] = (block["citations"] as? [[String: Any]] ?? []) + [citation]
                        if let source = Self.source(from: citation) { continuation.yield(.source(source)) }
                    }
                case "thinking_delta":
                    block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
                case "signature_delta":
                    block["signature"] = delta["signature"]
                case "input_json_delta":
                    partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
                default:
                    break
                }
                blocks[index] = block

            case "content_block_stop":
                if let json = partialJSON[index], let data = json.data(using: .utf8),
                   let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    blocks[index]?["input"] = input
                    if blocks[index]?["type"] as? String == "server_tool_use", let query = input["query"] as? String {
                        continuation.yield(.searching(query))
                    }
                }

            case "message_delta":
                if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                    stopReason = reason
                }

            case "error":
                let error = event["error"] as? [String: Any]
                throw ClaudeError(message: error?["message"] as? String ?? "The answer stopped unexpectedly.")

            default:
                break
            }
        }

        let content = blocks.keys.sorted().compactMap { blocks[$0] }.map(Self.stripNulls)
        return Turn(content: content, stopReason: stopReason)
    }

    private static func source(from item: [String: Any]) -> Source? {
        guard let string = item["url"] as? String, let url = URL(string: string) else { return nil }
        let title = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.displayHost
        return Source(url: url, title: title)
    }

    private static func stripNulls(_ block: [String: Any]) -> [String: Any] {
        block.filter { !($0.value is NSNull) }
    }

    private static func errorMessage(from data: Data, status: Int) -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = (json?["error"] as? [String: Any])?["message"] as? String
        switch status {
        case 401: return "The Claude API key was rejected. Check it in Settings."
        case 429: return "Claude is rate-limiting this key. Try again in a moment."
        case 529: return "Claude is overloaded right now. Try again in a moment."
        default: return message ?? "Claude returned an error (\(status))."
        }
    }
}
