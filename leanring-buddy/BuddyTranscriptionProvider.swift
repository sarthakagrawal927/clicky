//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession

    /// Optional: pre-load any heavy models so the first push-to-talk
    /// doesn't pay the cold-load cost. `onReady` is invoked on the
    /// MainActor exactly once when the model is fully loaded and the
    /// next session start won't block. Default no-op; WhisperKit
    /// overrides to kick off its CoreML compile / weight load. Apple
    /// Speech etc. fire `onReady` synchronously since they have nothing
    /// to warm up.
    func warmUpModelInBackground(onReady: @escaping @Sendable @MainActor () -> Void)
}

extension BuddyTranscriptionProvider {
    func warmUpModelInBackground(onReady: @escaping @Sendable @MainActor () -> Void) {
        // Default: nothing to warm. Fire ready immediately so callers
        // gating PTT on this flag don't get stuck.
        Task { @MainActor in onReady() }
    }
}

enum BuddyTranscriptionProviderFactory {
    private enum PreferredProvider: String {
        case appleSpeech = "apple"
        case whisperKit = "whisperkit"
    }

    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = resolveProvider()
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    private static func resolveProvider() -> any BuddyTranscriptionProvider {
        let preferredProviderRawValue = AppBundleConfiguration
            .stringValue(forKey: "VoiceTranscriptionProvider")?
            .lowercased()
        let preferredProvider = preferredProviderRawValue.flatMap(PreferredProvider.init(rawValue:))

        if preferredProvider == .whisperKit {
            let whisperKitProvider = WhisperKitTranscriptionProvider()
            if whisperKitProvider.isConfigured {
                return whisperKitProvider
            }
            print("⚠️ Transcription: WhisperKit preferred but not configured, falling back to Apple Speech")
        }

        return AppleSpeechTranscriptionProvider()
    }
}
