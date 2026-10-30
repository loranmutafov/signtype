import Foundation

/// Minimal client for Gemma 4 on the Gemini API (generativelanguage.googleapis.com).
/// Sends a burst of webcam frames plus the on-device guess and asks for a transcript.
struct GemmaClient {
    let apiKey: String
    let model: String

    enum GemmaError: LocalizedError {
        case http(Int, String)
        case badResponse
        case noText

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "Gemma API returned HTTP \(code): \(body.prefix(300))"
            case .badResponse: return "Gemma API returned something that was not JSON"
            case .noText: return "Gemma API returned no text"
            }
        }
    }

    /// Batch mode: transcribe a whole signing session.
    func transcribe(frames: [Data], hint: String) async throws -> String {
        let text = try await generate(prompt: Self.prompt(hint: hint, frameCount: frames.count), frames: frames, maxTokens: 256)
        let cleaned = Self.clean(text)
        guard !cleaned.isEmpty else { throw GemmaError.noText }
        return cleaned
    }

    /// Hybrid mode: identify ONE sign from a short burst of frames. Returns "" when Gemma
    /// says it is not a legible sign.
    func gloss(frames: [Data], contextBefore: String) async throws -> String {
        var p = """
        You are given \(frames.count) sequential webcam frames, roughly four per second, covering a single \
        American Sign Language sign performed by a person at their laptop. Identify the sign and reply \
        with its English meaning as one or two lowercase words (for example "hello", "thank you", "help").
        """
        let ctx = contextBefore.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ctx.isEmpty {
            p += "\n\nThe text they had already written before this sign was: \"\(ctx.suffix(80))\"."
        }
        p += "\n\nReply with ONLY the word(s). If the frames do not show a legible, deliberate sign (for example the person is just adjusting their hair or reaching for something), reply with exactly: ?"
        let text = try await generate(prompt: p, frames: frames, maxTokens: 16)
        let cleaned = Self.clean(text).lowercased()
        if cleaned.isEmpty || cleaned == "?" || cleaned.hasPrefix("?") || cleaned.count > 40 { return "" }
        return cleaned
    }

    private func generate(prompt: String, frames: [Data], maxTokens: Int) async throws -> String {
        var parts: [[String: Any]] = [["text": prompt]]
        for f in frames {
            parts.append(["inline_data": ["mime_type": "image/jpeg", "data": f.base64EncodedString()]])
        }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["temperature": 0.2, "maxOutputTokens": maxTokens],
        ]
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw GemmaError.badResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw GemmaError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let outParts = content["parts"] as? [[String: Any]] else {
            throw GemmaError.badResponse
        }
        return outParts.compactMap { $0["text"] as? String }.joined()
    }

    private static func prompt(hint: String, frameCount: Int) -> String {
        var p = """
        You are given \(frameCount) sequential webcam frames, roughly two per second, of a person signing in \
        American Sign Language (mostly fingerspelling) to their laptop camera. Transcribe what they signed \
        as plain English text. Fingerspelled words should be written as normal words.
        """
        let h = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !h.isEmpty {
            p += "\n\nAn on-device fingerspelling classifier produced this rough, error-prone guess (letters may be wrong or missing): \"\(h)\". Use it only as a hint."
        }
        p += "\n\nReply with ONLY the transcribed text. No quotes, no commentary. If nothing legible was signed, reply with an empty string."
        return p
    }

    private static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }
}
