//
//  BuddyTTSClient.swift
//  leanring-buddy
//
//  Shared protocol surface for text-to-speech backends. Only
//  LocalTTSClient (AVSpeechSynthesizer) conforms today. The protocol
//  stays so a future on-device runtime (Kokoro/Piper-MLX) can plug in
//  via a new conformer without touching CompanionManager.
//

import Foundation

@MainActor
protocol BuddyTTSClient: AnyObject {
    /// Speaks `text` and returns when audio playback has started (not
    /// when it has finished). The caller polls `isPlaying` to detect
    /// completion.
    func speakText(_ text: String) async throws

    /// Whether speech audio is currently being played out of the device.
    var isPlaying: Bool { get }

    /// Stops any in-progress speech immediately. Safe to call when
    /// nothing is playing.
    func stopPlayback()
}

enum BuddyTTSClientFactory {
    @MainActor
    static func makeDefault() -> any BuddyTTSClient {
        print("🔊 TTS: using local AVSpeechSynthesizer")
        return LocalTTSClient()
    }
}
