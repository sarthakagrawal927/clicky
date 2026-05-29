//
//  AppleMLXPlannerClient.swift
//  leanring-buddy
//
//  In-process planner via mlx-swift-lm. Bypasses LM Studio's HTTP path
//  for the planner role — model weights load into Pace's own address
//  space and inference runs on Apple silicon GPUs through the MLX
//  framework. The VLM still goes through LM Studio for now (mlx-swift-lm
//  doesn't ship a vision backend yet).
//
//  Why this exists
//  ---------------
//  The LM Studio HTTP path adds ~50-100ms of roundtrip + queueing per
//  turn, plus exposes us to LM Studio's slot/TTL/context-length
//  reconfiguration drift (see diag-pace.py findings from 2026-05-29
//  where the planner had silently been reloaded with CONTEXT=32768,
//  PARALLEL=32, causing 14000ms median latency). In-process MLX has:
//
//    - No HTTP roundtrip
//    - Stable prompt cache scoped to Pace's process
//    - Config under Pace's direct control
//    - Unlocks speculative decoding (FM-3B drafter + Qwen-30B-A3B
//      verifier — separate iteration once this is in place)
//
//  Wiring status
//  -------------
//  This file ships as a *placeholder* conformer. It compiles today but
//  throws `notWiredYet` on every call. To activate:
//
//    1. Add the mlx-swift-lm Swift Package dependency in Xcode:
//       File → Add Package Dependencies → enter
//       https://github.com/ml-explore/mlx-swift-examples
//       and select the `MLXLLM` library.
//
//    2. Locate the Qwen3-30B-A3B model weights in MLX format
//       (typically converted via `python -m mlx_lm.convert` from the
//       Hugging Face safetensors). Place under Pace's Application
//       Support directory; the path goes into the
//       `AppleMLXModelDirectory` Info.plist key.
//
//    3. Fill in the MARK: - MLX inference block below. The protocol
//       conformance and factory wiring are already in place — the
//       only thing missing is the actual MLX API calls.
//
//    4. Set `PlannerProvider=appleMLX` in Info.plist to make this
//       the active planner. Until then it stays dormant and the
//       existing LocalPlannerClient / FoundationModels paths keep
//       working unchanged.
//

import Foundation

struct AppleMLXPlannerClientError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class AppleMLXPlannerClient: BuddyPlannerClient {
    let displayName = "Qwen3-30B-A3B in-process (mlx-swift-lm)"
    // The planner is text-only — images go through LocalVLMClient which
    // still uses LM Studio (no MLX vision backend yet).
    let supportsImageInput: Bool = false

    private let modelDirectoryPath: String

    init() {
        // Model weights location is configurable via Info.plist so power
        // users can swap which MLX checkpoint Pace loads without
        // recompiling. Default points at a known location under
        // Application Support — Pace's first-launch flow will download
        // there if missing (separate task once the actual inference
        // path is wired).
        self.modelDirectoryPath = AppBundleConfiguration.stringValue(
            forKey: "AppleMLXModelDirectory"
        ) ?? Self.defaultModelDirectoryPath()
    }

    private static func defaultModelDirectoryPath() -> String {
        let applicationSupportDirectory = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory,
            .userDomainMask,
            true
        ).first ?? NSTemporaryDirectory()
        return (applicationSupportDirectory as NSString)
            .appendingPathComponent("Pace/mlx-models/Qwen3-30B-A3B-4bit")
    }

    /// Whether the SPM dependency is installed AND the model directory
    /// exists on disk. Both are required before this planner can serve
    /// a turn. The factory uses this to decide whether to fall back to
    /// LocalPlannerClient — no silent degradation, the user gets a
    /// clear log line about what's missing.
    var isConfigured: Bool {
        #if canImport(MLXLLM)
        return FileManager.default.fileExists(atPath: modelDirectoryPath)
        #else
        return false
        #endif
    }

    /// Plain-language explanation surfaced to the panel UI when this
    /// planner isn't usable yet. Mirrors WhisperKitTranscriptionProvider's
    /// approach — one actionable string the user can follow without
    /// reading source.
    var unavailableExplanation: String? {
        guard !isConfigured else { return nil }
        #if canImport(MLXLLM)
        return (
            "MLXLLM library is importable but the model weights directory "
            + "doesn't exist at \(modelDirectoryPath). Convert Qwen3-30B-A3B "
            + "to MLX format and place under that path, or override via "
            + "Info.plist key AppleMLXModelDirectory."
        )
        #else
        return (
            "mlx-swift-lm Swift Package is not installed. Add "
            + "https://github.com/ml-explore/mlx-swift-examples via "
            + "Xcode → File → Add Package Dependencies, then select the "
            + "MLXLLM library when adding to the target."
        )
        #endif
    }

    func resetForNewTurn() {
        // The mlx-swift-lm session is stateless across calls (we pass
        // the full message history each time), so there's nothing
        // process-side to reset. Prompt-cache hits stay valid as long
        // as the system prompt prefix is byte-stable — that contract
        // is enforced by `CompanionSystemPrompt.build(includeAgentMode:)`
        // emitting the same bytes for a given config.
    }

    func generateResponseStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        if !images.isEmpty {
            print(
                "ℹ️ AppleMLXPlannerClient: received \(images.count) image(s) "
                + "but the MLX planner is text-only — ignoring"
            )
        }

        guard isConfigured else {
            // Don't silently no-op: throw so the caller (CompanionManager)
            // surfaces the actionable explanation to the user via the
            // panel UI. Most common cause at this point is "SPM dep not
            // added yet"; second-most is "model weights not downloaded".
            throw AppleMLXPlannerClientError(
                message: unavailableExplanation
                    ?? "AppleMLXPlannerClient is not configured."
            )
        }

        // MARK: - MLX inference (TODO: fill in once MLXLLM is added)
        //
        // The shape this block needs to implement:
        //
        //   1. Lazily load the model on first call. Cache the
        //      LLMModelContainer (or equivalent) on the planner instance
        //      so subsequent turns reuse it.
        //   2. Format the message list as MLXLLM expects:
        //      [.system(systemPrompt), .user(...), .assistant(...), ...,
        //       .user(userPrompt)].
        //   3. Stream tokens via the MLXLLM streaming API. On each
        //      chunk, call onTextChunk on MainActor with the new tokens.
        //   4. Accumulate the full response. Return (text, elapsed).
        //
        // Defensive notes:
        //   - Strip <think>…</think> blocks from accumulated text before
        //     onTextChunk so the streaming TTS pipeline never sees the
        //     model's reasoning. The same regex LocalPlannerClient
        //     applies (LocalPlannerClient.stripThinkingBlocks) is the
        //     reference behavior — extract a shared helper if needed.
        //   - max_tokens 1024 matches LocalPlannerClient's budget.
        //     Thinking models eat ~600 of those before answering.
        //   - temperature 0.4 matches LocalPlannerClient. Greedy hurts
        //     conversational variety; full greedy is reserved for the
        //     typed FM path where determinism matters more.

        throw AppleMLXPlannerClientError(
            message: (
                "AppleMLXPlannerClient is configured but the inference path "
                + "isn't wired yet — see the MARK: - MLX inference block in "
                + "AppleMLXPlannerClient.swift. Falling back via the factory's "
                + "isConfigured check would skip this throw in production."
            )
        )
    }
}
