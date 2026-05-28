//
//  WhisperKitTranscriptionProvider.swift
//  leanring-buddy
//
//  Local on-device transcription via WhisperKit (Argmax). Buffers
//  push-to-talk audio in PCM16, then runs Whisper inference locally on
//  Apple Silicon (CoreML / Neural Engine) when the user releases the
//  hotkey. No network calls. Speech never leaves the machine.
//
//  Requires the WhisperKit Swift Package dependency. The file is wrapped
//  in `#if canImport(WhisperKit)` so the project still compiles if the
//  package has not been added yet — the provider will simply report as
//  unavailable in that case.
//

import AVFoundation
import Foundation

#if canImport(WhisperKit)
import WhisperKit
#endif

struct WhisperKitTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class WhisperKitTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "WhisperKit (local)"
    let requiresSpeechRecognitionPermission = false

    private let modelName: String

    init() {
        // The model identifier picked by the user from Info.plist. Defaults to
        // Whisper large-v3 turbo, which is the best accuracy/latency tradeoff
        // available on Apple Silicon for short utterances.
        self.modelName = AppBundleConfiguration.stringValue(forKey: "WhisperKitModel")
            ?? "openai_whisper-large-v3-v20240930_turbo"
    }

    var isConfigured: Bool {
        #if canImport(WhisperKit)
        return true
        #else
        return false
        #endif
    }

    var unavailableExplanation: String? {
        guard !isConfigured else { return nil }
        return "WhisperKit Swift Package is not installed. Add https://github.com/argmaxinc/WhisperKit via Xcode → File → Add Package Dependencies."
    }

    /// Kicks off the Whisper model load on a background priority task so
    /// the first push-to-talk doesn't pay the cold-load cost. `onReady`
    /// fires on MainActor when the model is fully loaded — callers gate
    /// PTT on this signal to avoid the audio-engine-after-release race.
    func warmUpModelInBackground(onReady: @escaping @Sendable @MainActor () -> Void) {
        #if canImport(WhisperKit)
        let modelNameSnapshot = modelName
        Task.detached(priority: .utility) {
            do {
                _ = try await WhisperKitTranscriptionSession.warmUpSharedModel(named: modelNameSnapshot)
                print("🎙️ WhisperKit pre-warm: model \(modelNameSnapshot) ready")
                await MainActor.run { onReady() }
            } catch {
                print("⚠️ WhisperKit pre-warm failed: \(error.localizedDescription)")
                // Fire onReady anyway so the gate doesn't trap forever.
                // The first real session start will surface the error.
                await MainActor.run { onReady() }
            }
        }
        #else
        Task { @MainActor in onReady() }
        #endif
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        #if canImport(WhisperKit)
        let session = WhisperKitTranscriptionSession(
            modelName: modelName,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
        await session.warmUpModelIfNeeded()
        return session
        #else
        throw WhisperKitTranscriptionProviderError(
            message: unavailableExplanation
                ?? "WhisperKit is not available."
        )
        #endif
    }
}

#if canImport(WhisperKit)

private actor WhisperKitModelHost {
    private let modelName: String
    private var loadedWhisperKit: WhisperKit?
    private var loadTask: Task<WhisperKit, Error>?

    init(modelName: String) {
        self.modelName = modelName
    }

    func sharedWhisperKit() async throws -> WhisperKit {
        if let loadedWhisperKit {
            return loadedWhisperKit
        }

        if let loadTask {
            return try await loadTask.value
        }

        let modelName = self.modelName
        let newLoadTask = Task<WhisperKit, Error> {
            // WhisperKit downloads the model from HuggingFace on first use and
            // caches it locally under the app's container Documents directory.
            // Subsequent loads are fast (CoreML compiled cache).
            let configuration = WhisperKitConfig(
                model: modelName,
                modelRepo: "argmaxinc/whisperkit-coreml",
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: true
            )
            return try await WhisperKit(configuration)
        }

        loadTask = newLoadTask

        do {
            let whisperKit = try await newLoadTask.value
            loadedWhisperKit = whisperKit
            loadTask = nil
            return whisperKit
        } catch {
            loadTask = nil
            throw error
        }
    }
}

private final class WhisperKitTranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 8.0

    private static let targetSampleRate = 16_000
    // One shared model host across all sessions so the WhisperKit instance
    // stays warm between push-to-talk presses. Without this, every session
    // would pay the ~1-2s model load cost.
    private static var sharedModelHost: WhisperKitModelHost?
    private static let sharedModelHostLock = NSLock()

    private let modelName: String
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.learningbuddy.whisperkit.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: Double(targetSampleRate)
    )

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var transcriptionTask: Task<Void, Never>?

    init(
        modelName: String,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.modelName = modelName
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    fileprivate func warmUpModelIfNeeded() async {
        // Kick off the model load eagerly so it's ready before the first
        // requestFinalTranscript() call. Errors are swallowed here — they'll
        // surface again on the real transcription request with full context.
        _ = try? await Self.sharedModelHost(modelName: modelName).sharedWhisperKit()
    }

    /// Triggers the shared WhisperKit model load without standing up a
    /// full session (no audio engine, no buffers). Used by the
    /// provider's `warmUpModelInBackground()` so app launch can pre-load.
    fileprivate static func warmUpSharedModel(named modelName: String) async throws -> WhisperKit {
        try await sharedModelHost(modelName: modelName).sharedWhisperKit()
    }

    private static func sharedModelHost(modelName: String) -> WhisperKitModelHost {
        sharedModelHostLock.lock()
        defer { sharedModelHostLock.unlock() }
        if let sharedModelHost {
            return sharedModelHost
        }
        let newHost = WhisperKitModelHost(modelName: modelName)
        sharedModelHost = newHost
        return newHost
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        stateQueue.async { [weak self] in
            guard let self else { return }
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            let bufferedAudioSnapshot = self.bufferedPCM16AudioData
            self.transcriptionTask = Task { [weak self] in
                await self?.transcribeBufferedAudio(bufferedAudioSnapshot)
            }
        }
    }

    func cancel() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.isCancelled = true
            self.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }
        transcriptionTask?.cancel()
    }

    private func transcribeBufferedAudio(_ bufferedAudioData: Data) async {
        guard !Task.isCancelled else { return }

        let isEmptyOrCancelled = stateQueue.sync {
            isCancelled || bufferedAudioData.isEmpty
        }

        if isEmptyOrCancelled {
            deliverFinalTranscript("")
            return
        }

        let floatAudioSamples = Self.convertPCM16DataToFloatSamples(bufferedAudioData)

        // Whisper expects at least ~0.1s of audio (1600 samples @ 16 kHz). Very
        // short clips usually mean the user accidentally tapped the hotkey;
        // returning empty is correct and quiet.
        guard floatAudioSamples.count >= 1600 else {
            deliverFinalTranscript("")
            return
        }

        do {
            let whisperKit = try await Self.sharedModelHost(modelName: modelName)
                .sharedWhisperKit()

            let transcriptionResults = try await whisperKit.transcribe(
                audioArray: floatAudioSamples
            )

            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            let transcriptText = transcriptionResults
                .map { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }
            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            print("[WhisperKit Transcription] ❌ Inference failed: \(error.localizedDescription)")
            onError(error)
        }
    }

    // Whisper expects mono 16 kHz float samples in the range [-1.0, 1.0].
    // Our buffered audio is little-endian PCM16, so we divide by Int16.max.
    private static func convertPCM16DataToFloatSamples(_ pcm16Data: Data) -> [Float] {
        let sampleCount = pcm16Data.count / MemoryLayout<Int16>.size
        var floatSamples = [Float](repeating: 0, count: sampleCount)

        pcm16Data.withUnsafeBytes { rawBufferPointer in
            guard let int16BasePointer = rawBufferPointer.bindMemory(to: Int16.self).baseAddress else {
                return
            }
            for sampleIndex in 0..<sampleCount {
                let sampleValue = Int16(littleEndian: int16BasePointer[sampleIndex])
                floatSamples[sampleIndex] = Float(sampleValue) / Float(Int16.max)
            }
        }

        return floatSamples
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    deinit {
        cancel()
    }
}

#endif
