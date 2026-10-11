import CallScribeCore
import Foundation

/// One recording: two independent streams written to their own WAV files on a shared timeline,
/// plus session.json describing pauses and call-stream gaps. Control methods run on the main thread.
final class RecordingSession {
    let id: String
    let directory: URL
    let isTest: Bool

    var onMicStatus: ((Bool, String) -> Void)?
    var onCallStatus: ((CallCaptureStatus) -> Void)?

    private let clockStart = ContinuousClock.now
    private let lock = NSLock()
    private var manifest: SessionManifest
    private let manifestQueue = DispatchQueue(label: "com.wolfem86.callscribe.manifest")
    private let mic = MicCapture()
    private let call = CallCapture()
    private var micSink: StreamSink!
    private var callSink: StreamSink!

    init(isTest: Bool, levels: LevelStore) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        id = "\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(6))"
        self.isTest = isTest
        directory = (isTest ? Paths.testRecordings : Paths.recordings).appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        manifest = SessionManifest(id: id, startDate: Date(), isTest: isTest)
        manifest.callGaps.begin(at: 0)  // Closed once the tap delivers.

        micSink = try StreamSink(
            name: "mic", url: directory.appendingPathComponent(manifest.micFile),
            activeElapsed: { [weak self] in self?.activeElapsed ?? 0 },
            isAccepting: { [weak self] in self?.isPaused == false },
            onLevel: { levels.setMic($0) })
        callSink = try StreamSink(
            name: "call", url: directory.appendingPathComponent(manifest.callFile),
            activeElapsed: { [weak self] in self?.activeElapsed ?? 0 },
            isAccepting: { [weak self] in self?.isPaused == false },
            onLevel: { levels.setCall($0) })
    }

    var wallElapsed: Double {
        let duration = clockStart.duration(to: .now)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    var activeElapsed: Double {
        let wall = wallElapsed
        return lock.withLock { manifest.pauses.activeElapsed(atWall: wall) }
    }

    var isPaused: Bool { lock.withLock { manifest.pauses.isOpen } }

    func start() {
        saveManifest()
        mic.onBuffer = { [weak self] in self?.micSink.ingest($0) }
        call.onBuffer = { [weak self] in self?.callSink.ingest($0) }
        mic.onStatus = { [weak self] ok, text in self?.onMicStatus?(ok, text) }
        call.onStatus = { [weak self] status in self?.callStatusChanged(status) }
        micSink.startFlushing()
        callSink.startFlushing()
        mic.start()
        call.start()
        Log.info("Session \(id): started\(isTest ? " (test)" : "")")
    }

    func pause(reason: String) {
        let wall = wallElapsed
        lock.withLock { manifest.pauses.begin(at: wall) }
        saveManifest()
        Log.info("Session \(id): paused at \(Self.format(wall)) (\(reason))")
    }

    func resume() {
        let wall = wallElapsed
        lock.withLock { manifest.pauses.end(at: wall) }
        saveManifest()
        call.rebuild(reason: "resumed")
        Log.info("Session \(id): resumed at \(Self.format(wall))")
    }

    /// Re-establishes both streams after the system woke up.
    func recoverAfterWake() {
        mic.restart(reason: "system woke")
        call.rebuild(reason: "system woke")
    }

    @discardableResult
    func stop() -> SessionManifest {
        mic.stop()
        call.stop()
        let wall = wallElapsed
        lock.withLock {
            manifest.pauses.end(at: wall)
            manifest.callGaps.end(at: wall)
        }
        micSink.close()
        callSink.close()
        let final = lock.withLock {
            manifest.endDate = Date()
            manifest.wallDuration = wall
            manifest.finished = true
            return manifest
        }
        saveManifest()
        manifestQueue.sync {}
        Log.info("Session \(id): stopped after \(Self.format(wall))\(final.isMeOnly ? " — Me only (no call audio captured)" : "")")
        return final
    }

    private func callStatusChanged(_ status: CallCaptureStatus) {
        let wall = wallElapsed
        lock.withLock {
            if case .capturing(let sources) = status {
                manifest.callGaps.end(at: wall)
                manifest.callCaptured = true
                manifest.callSources = Array(Set(manifest.callSources + sources)).sorted()
            } else {
                manifest.callGaps.begin(at: wall)
            }
        }
        saveManifest()
        onCallStatus?(status)
    }

    private func saveManifest() {
        let snapshot = lock.withLock { manifest }
        let directory = directory
        manifestQueue.async {
            do { try ManifestStore.save(snapshot, in: directory) } catch {
                Log.error("Session \(snapshot.id): couldn't write session.json: \(error.localizedDescription)")
            }
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}
