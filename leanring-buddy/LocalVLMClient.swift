//
//  LocalVLMClient.swift
//  leanring-buddy
//
//  Talks to a local vision-language model served by LM Studio (or any
//  other OpenAI-compatible runtime) over HTTP. Sends a screenshot plus
//  a structured prompt and returns a parsed element map describing the
//  interactive UI elements and key text on screen.
//
//  The output is designed to be passed as a *text* block alongside the
//  user's transcript to the cloud reasoning model (Claude). That way:
//    - The cloud model never sees raw screen pixels (privacy + cost).
//    - The local VLM specialises in perception (hot path, every turn).
//    - The cloud model specialises in planning (cold path, once per turn).
//
//  This file is intentionally self-contained and not yet wired into
//  CompanionManager — that wiring is the next phase of the build.
//

import Foundation

/// Describes one interactive element or block of text the local VLM
/// found on screen. Coordinates and sizes are in screen pixels.
struct LocalVLMScreenElement: Codable, Hashable {
    /// Short human-readable label, e.g. "Send" or "Email field".
    let label: String
    /// Role taxonomy borrowed from the macOS accessibility tree:
    /// "button", "text_field", "static_text", "link", "image", etc.
    let role: String
    /// `[x, y, width, height]` of the element's bounding box, in pixels
    /// from the top-left of the screenshot.
    let bbox: [Int]
    /// Verbatim text content if the element contains readable text.
    let text: String?
}

struct LocalVLMScreenAnalysis: Codable {
    let elements: [LocalVLMScreenElement]
    /// One-paragraph natural-language description of what's on screen.
    /// Useful as conversational context for the downstream planner LLM.
    let description: String
}

struct LocalVLMClientError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// Talks to a local OpenAI-compatible chat-completions endpoint (LM Studio
/// by default) to extract a structured element map from a screenshot.
final class LocalVLMClient {
    private let baseURL: URL
    private let modelIdentifier: String
    private let urlSession: URLSession

    /// `baseURL` should point at the OpenAI-compatible root (e.g.
    /// `http://localhost:1234/v1`). `modelIdentifier` is the model name
    /// as shown in LM Studio (e.g. `qwen3-vl-8b-instruct`).
    init(
        baseURL: URL = URL(string: "http://localhost:1234/v1")!,
        modelIdentifier: String = "qwen3-vl-8b-instruct"
    ) {
        self.baseURL = baseURL
        self.modelIdentifier = modelIdentifier

        let urlSessionConfiguration = URLSessionConfiguration.default
        // Local inference can be slow on cold load (model swap, first prompt).
        // 120s gives headroom; subsequent calls are typically <5s on 7B VLMs.
        urlSessionConfiguration.timeoutIntervalForRequest = 120
        urlSessionConfiguration.timeoutIntervalForResource = 180
        urlSessionConfiguration.waitsForConnectivity = false
        urlSessionConfiguration.urlCache = nil
        urlSessionConfiguration.httpCookieStorage = nil
        self.urlSession = URLSession(configuration: urlSessionConfiguration)
    }

    /// Sends `screenshotImageData` (JPEG or PNG) to the local VLM and
    /// returns the parsed element map. `userIntent` is the user's spoken
    /// transcript — passed to the VLM so it can prioritise elements the
    /// user is likely about to interact with (improves recall on busy
    /// screens).
    func analyzeScreenshot(
        screenshotImageData: Data,
        userIntent: String
    ) async throws -> LocalVLMScreenAnalysis {
        let chatCompletionsURL = baseURL.appendingPathComponent("chat/completions")

        var request = URLRequest(url: chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // LM Studio ignores Authorization by default but downstream
        // OpenAI-compatible proxies might require it. Sending a dummy token
        // is harmless and makes routing through tools like LiteLLM work.
        request.setValue("Bearer lm-studio", forHTTPHeaderField: "Authorization")

        let mediaType = Self.detectImageMediaType(for: screenshotImageData)
        let base64EncodedImage = screenshotImageData.base64EncodedString()
        let imageDataURL = "data:\(mediaType);base64,\(base64EncodedImage)"

        let systemInstruction = """
        You are a UI vision model. Output STRICT JSON only. No prose, no \
        markdown, no commentary outside the JSON object.

        Schema (note: elements FIRST, description LAST and SHORT):
        {
          "elements": [
            {
              "label": "<short, ≤4 words>",
              "role": "<button|text_field|static_text|link|image|menu_item|checkbox|tab|other>",
              "bbox": [<x>, <y>, <width>, <height>],
              "text": "<verbatim text or null>"
            }
          ],
          "description": "<ONE SHORT sentence, ≤20 words, app + main view>"
        }

        Hard rules:
        - Emit `elements` FIRST so the JSON is usable even if the response \
          gets truncated.
        - `description` is one terse sentence, not a paragraph.
        - Coordinates in screen pixels from top-left of the screenshot.
        - Prefer high recall on interactive elements (buttons, fields, links, \
          tabs). Skip pure decorative chrome.
        - If the user intent below names a target, list that element first.
        """

        let userMessage: [[String: Any]] = [
            [
                "type": "text",
                "text": "User intent: \(userIntent)\n\nAnalyse the screenshot and return the JSON element map."
            ],
            [
                "type": "image_url",
                "image_url": [
                    "url": imageDataURL
                ]
            ]
        ]

        // No `response_format` field — LM Studio's MLX engine returns
        // HTTP 400 when given `"type": "json_object"` (it only accepts
        // `"json_schema"` with a real schema, or `"text"`). We rely on
        // the regex-extract fallback further down to pluck JSON out of
        // unstructured responses, which is what we did before anyway
        // when the model decided to wrap its JSON in prose.
        let requestBody: [String: Any] = [
            "model": modelIdentifier,
            "messages": [
                ["role": "system", "content": systemInstruction],
                ["role": "user", "content": userMessage]
            ],
            "temperature": 0.1,
            "max_tokens": 2048
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (responseData, urlResponse) = try await urlSession.data(for: request)

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw LocalVLMClientError(message: "Local VLM returned a non-HTTP response.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "<binary>"
            throw LocalVLMClientError(
                message: "Local VLM error (\(httpResponse.statusCode)): \(errorBody)"
            )
        }

        return try Self.parseChatCompletionResponse(responseData)
    }

    /// True when an LM Studio (or compatible) server responds at `baseURL`.
    /// Use from the UI to surface "VLM not running" hints to the user
    /// without making them speak first.
    func isLocalVLMReachable() async -> Bool {
        let modelsURL = baseURL.appendingPathComponent("models")
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 2

        do {
            let (_, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return (200...299).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    // MARK: - Response parsing

    private static func parseChatCompletionResponse(_ responseData: Data) throws -> LocalVLMScreenAnalysis {
        let topLevelJSON = try JSONSerialization.jsonObject(with: responseData)
        guard let topLevelDictionary = topLevelJSON as? [String: Any],
              let choices = topLevelDictionary["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let messageDictionary = firstChoice["message"] as? [String: Any],
              let messageContent = messageDictionary["content"] as? String else {
            throw LocalVLMClientError(message: "Local VLM response missing message content.")
        }

        let jsonStringToDecode = extractJSONObjectString(from: messageContent)

        guard let jsonData = jsonStringToDecode.data(using: .utf8) else {
            throw LocalVLMClientError(message: "Local VLM response was not valid UTF-8.")
        }

        do {
            return try JSONDecoder().decode(LocalVLMScreenAnalysis.self, from: jsonData)
        } catch {
            throw LocalVLMClientError(
                message: "Local VLM returned malformed JSON: \(error.localizedDescription). Raw content: \(messageContent.prefix(400))"
            )
        }
    }

    /// Some VLMs wrap their JSON in a ```json ... ``` fence or precede it
    /// with a sentence even when asked for strict JSON. This pulls the
    /// first {...} block out of the string so decoding can succeed.
    private static func extractJSONObjectString(from rawContent: String) -> String {
        let trimmedContent = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedContent.hasPrefix("{") && trimmedContent.hasSuffix("}") {
            return trimmedContent
        }

        // Strip ```json … ``` fence if present.
        if let codeFenceStartRange = trimmedContent.range(of: "```"),
           let codeFenceEndRange = trimmedContent.range(
               of: "```",
               range: codeFenceStartRange.upperBound..<trimmedContent.endIndex
           ) {
            var bodyInsideFence = String(trimmedContent[codeFenceStartRange.upperBound..<codeFenceEndRange.lowerBound])
            // The line right after the opening fence may say "json".
            if let firstNewlineIndex = bodyInsideFence.firstIndex(of: "\n") {
                let firstLine = bodyInsideFence[bodyInsideFence.startIndex..<firstNewlineIndex]
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                if firstLine == "json" {
                    bodyInsideFence = String(bodyInsideFence[bodyInsideFence.index(after: firstNewlineIndex)...])
                }
            }
            return bodyInsideFence.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Greedy match the first {...} block, balancing braces.
        if let firstOpeningBraceIndex = trimmedContent.firstIndex(of: "{") {
            var braceDepth = 0
            var currentIndex = firstOpeningBraceIndex
            while currentIndex < trimmedContent.endIndex {
                let currentCharacter = trimmedContent[currentIndex]
                if currentCharacter == "{" { braceDepth += 1 }
                if currentCharacter == "}" {
                    braceDepth -= 1
                    if braceDepth == 0 {
                        return String(trimmedContent[firstOpeningBraceIndex...currentIndex])
                    }
                }
                currentIndex = trimmedContent.index(after: currentIndex)
            }
        }

        return trimmedContent
    }

    private static func detectImageMediaType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignaturePrefix: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignaturePrefix {
                return "image/png"
            }
        }
        return "image/jpeg"
    }
}
