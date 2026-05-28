//
//  BuddyPlannerClient.swift
//  leanring-buddy
//
//  Shared protocol surface for the reasoning/planning model — the
//  cold-path LLM that takes the user's transcript + (optional) screen
//  context and produces pace's spoken response and action tags.
//
//  Only one conformer ships today: `LocalPlannerClient` (text-only,
//  talks to a local OpenAI-compatible reasoner like LM Studio).
//
//  The protocol is intentionally kept generic so an alternate local
//  runtime (Ollama, raw llama.cpp, MLX-server) can drop in by writing
//  a new conformer — no other layer of the app would need to change.
//
//  Earlier versions had a cloud Claude conformer; that was removed
//  when the project committed to a no-cloud-LLM stance.
//

import Foundation

@MainActor
protocol BuddyPlannerClient: AnyObject {
    /// Human-readable name used in logs and the panel UI.
    var displayName: String { get }

    /// Whether this planner can consume screenshot images directly. False
    /// for the local 4B/8B reasoners which are text-only. Pipeline uses
    /// this to decide whether to even attach images.
    var supportsImageInput: Bool { get }

    /// Generate the next assistant turn as a streamed text response.
    /// `images` are passed only when `supportsImageInput` is true. The
    /// returned text is the full accumulated response after the stream
    /// completes; `onTextChunk` is called progressively for UI display.
    func generateResponseStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval)
}

enum BuddyPlannerClientFactory {
    /// Resolves the active planner from Info.plist. Today this always
    /// returns a `LocalPlannerClient`; the factory shape stays so a
    /// future Ollama / raw llama.cpp / other conformer can plug in
    /// without touching CompanionManager.
    @MainActor
    static func makeDefault() -> any BuddyPlannerClient {
        let resolvedClient = LocalPlannerClient.makeFromInfoPlist()
        print("🧠 Planner: using \(resolvedClient.displayName)")
        return resolvedClient
    }
}
