//
//  PaceScreenWatchMode.swift
//  leanring-buddy
//
//  Explicit watch-mode loop. The user-facing trigger is still future UI,
//  but the runtime primitive is here: sample screens, diff fingerprints,
//  and emit only meaningful visual changes.
//

import Foundation

struct PaceScreenWatchConfiguration {
    let sampleIntervalInSeconds: TimeInterval
    let minimumSecondsBetweenEvents: TimeInterval

    static let `default` = PaceScreenWatchConfiguration(
        sampleIntervalInSeconds: 1.0,
        minimumSecondsBetweenEvents: 2.5
    )
}

struct PaceScreenWatchEvent {
    let screenLabel: String
    let diff: PaceScreenImageDiff
    let capture: CompanionScreenCapture
    let detectedAt: Date
}

struct PaceScreenWatchChangeDetector {
    private var previousFingerprintByScreenLabel: [String: PaceScreenVisualFingerprint] = [:]
    private var lastEventDateByScreenLabel: [String: Date] = [:]
    private let configuration: PaceScreenWatchConfiguration

    init(configuration: PaceScreenWatchConfiguration = .default) {
        self.configuration = configuration
    }

    mutating func meaningfulChanges(
        in captures: [CompanionScreenCapture],
        now: Date = Date()
    ) -> [PaceScreenWatchEvent] {
        var events: [PaceScreenWatchEvent] = []

        for capture in captures {
            guard let currentFingerprint = PaceScreenImageDiffer.fingerprint(for: capture.imageData) else {
                continue
            }

            defer {
                previousFingerprintByScreenLabel[capture.label] = currentFingerprint
            }

            guard let previousFingerprint = previousFingerprintByScreenLabel[capture.label],
                  let diff = PaceScreenImageDiffer.diff(
                    from: previousFingerprint,
                    to: currentFingerprint
                  ),
                  diff.isMeaningful else {
                continue
            }

            if let lastEventDate = lastEventDateByScreenLabel[capture.label],
               now.timeIntervalSince(lastEventDate) < configuration.minimumSecondsBetweenEvents {
                continue
            }

            lastEventDateByScreenLabel[capture.label] = now
            events.append(PaceScreenWatchEvent(
                screenLabel: capture.label,
                diff: diff,
                capture: capture,
                detectedAt: now
            ))
        }

        return events
    }

    mutating func reset() {
        previousFingerprintByScreenLabel.removeAll()
        lastEventDateByScreenLabel.removeAll()
    }
}

@MainActor
final class PaceScreenWatchModeController {
    typealias EventHandler = @MainActor (PaceScreenWatchEvent) async -> Void

    private var watchTask: Task<Void, Never>?
    private var changeDetector: PaceScreenWatchChangeDetector
    private let configuration: PaceScreenWatchConfiguration

    init(configuration: PaceScreenWatchConfiguration = .default) {
        self.configuration = configuration
        self.changeDetector = PaceScreenWatchChangeDetector(configuration: configuration)
    }

    var isWatching: Bool {
        watchTask != nil
    }

    func startWatching(
        for durationInSeconds: TimeInterval? = nil,
        onMeaningfulChange: @escaping EventHandler
    ) {
        stopWatching()
        changeDetector.reset()

        let watchStartDate = Date()
        watchTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                if let durationInSeconds,
                   Date().timeIntervalSince(watchStartDate) >= durationInSeconds {
                    break
                }

                do {
                    let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                    let events = self.changeDetector.meaningfulChanges(in: captures)
                    for event in events {
                        await onMeaningfulChange(event)
                    }
                } catch {
                    print("⚠️ Pace watch mode capture failed: \(error.localizedDescription)")
                }

                let sleepNanoseconds = UInt64(configuration.sampleIntervalInSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: sleepNanoseconds)
            }

            self.watchTask = nil
        }
    }

    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
        changeDetector.reset()
    }
}
