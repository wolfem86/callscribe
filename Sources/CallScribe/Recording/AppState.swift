import CallScribeCore
import Foundation

enum RecorderPhase {
    case idle, recording, paused, processing
}

/// Shared UI state. Mutated on the main thread only.
final class AppState: ObservableObject {
    @Published var phase: RecorderPhase = .idle
    @Published var isTesting = false
    @Published var startedAt: Date?
    @Published var micOK = true
    @Published var callOK = true
    @Published var micStatus = "Not recording"
    @Published var callStatus = "Not recording"
    /// Transcription running in the background (shown when not recording).
    @Published var isProcessing = false
    @Published var failedTranscriptions = 0

    let levels = LevelStore()

    var isActive: Bool { phase == .recording || phase == .paused }
    var hasWarning: Bool {
        isActive ? (!micOK || !callOK) : failedTranscriptions > 0
    }
}

/// Latest level per stream, written from capture threads and read by the UI at ~15 Hz.
final class LevelStore: @unchecked Sendable {
    private let lock = NSLock()
    private var mic: (db: Float, at: ContinuousClock.Instant) = (LevelMeter.floorDB, .now)
    private var call: (db: Float, at: ContinuousClock.Instant) = (LevelMeter.floorDB, .now)

    func setMic(_ db: Float) { lock.withLock { mic = (db, .now) } }
    func setCall(_ db: Float) { lock.withLock { call = (db, .now) } }

    /// Levels in dBFS; a stream that hasn't delivered for half a second reads as silent.
    func snapshot() -> (mic: Float, call: Float) {
        lock.withLock {
            let now = ContinuousClock.now
            let fresh = { (entry: (db: Float, at: ContinuousClock.Instant)) in
                entry.at.duration(to: now) < .milliseconds(500) ? entry.db : LevelMeter.floorDB
            }
            return (fresh(mic), fresh(call))
        }
    }

    func reset() {
        lock.withLock {
            mic = (LevelMeter.floorDB, .now)
            call = (LevelMeter.floorDB, .now)
        }
    }
}
