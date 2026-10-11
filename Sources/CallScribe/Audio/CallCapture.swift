import AVFoundation
import CallScribeCore
import CoreAudio
import Foundation

enum CallCaptureStatus: Equatable {
    case capturing(sources: [String])
    case waiting(String)
    case failed(String)

    var isCapturing: Bool {
        if case .capturing = self { return true }
        return false
    }

    var text: String {
        switch self {
        case .capturing(let sources): return "Capturing \(CallCapture.friendlyName(sources))"
        case .waiting(let reason): return reason
        case .failed(let message): return "Not capturing: \(message)"
        }
    }
}

/// The "Others" stream: finds Teams (or browser) audio processes, keeps a process tap on them,
/// and rebuilds it when processes come and go, the output device changes, or callbacks stop.
/// All control methods run on the main thread.
final class CallCapture {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onStatus: ((CallCaptureStatus) -> Void)?

    private var tap: ProcessTap?
    private var currentTargets: [AudioObjectID] = []
    private var listeners: [CoreAudioUtil.Listener] = []
    private var timer: Timer?
    private var pendingWork: DispatchWorkItem?
    private var status: CallCaptureStatus = .waiting("Starting…")

    func start() {
        listeners = [
            CoreAudioUtil.listen(kAudioHardwarePropertyProcessObjectList) { [weak self] in
                self?.debounce { $0.evaluate(force: false) }
            },
            CoreAudioUtil.listen(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
                self?.debounce { $0.rebuild(reason: "default output device changed") }
            },
        ]
        // Retry while not capturing; rebuild if an active tap stops delivering callbacks.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.watchdog() }
        evaluate(force: true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pendingWork?.cancel()
        listeners.forEach { $0.remove() }
        listeners = []
        tearDownTap()
    }

    func rebuild(reason: String) {
        Log.info("Call tap: rebuilding (\(reason))")
        tearDownTap()
        evaluate(force: true)
    }

    private func debounce(_ work: @escaping (CallCapture) -> Void) {
        pendingWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            work(self)
        }
        pendingWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    private func watchdog() {
        if let tap {
            if tap.secondsSinceLastCallback > 5 { rebuild(reason: "no audio callbacks for 5 s") }
        } else {
            evaluate(force: false)
        }
    }

    private func evaluate(force: Bool) {
        let processes = CoreAudioUtil.processes()
        let indices = CallTargetMatcher.select(processes.map(\.bundleID), mode: Settings.callSourceMode, ownBundleID: Paths.bundleID)
        let targets = indices.map { processes[$0] }
        let ids = targets.map(\.objectID).sorted()
        let playing = processes.filter(\.isRunningOutput).map { "\($0.bundleID.isEmpty ? "pid \($0.pid)" : $0.bundleID)" }
        Log.info("Call tap: processes playing audio: \(playing.isEmpty ? "none" : playing.joined(separator: ", "))")

        // Unchanged targets and a live tap: nothing to do. Without a tap, fall through and retry.
        if !force, tap != nil, ids == currentTargets { return }

        tearDownTap()
        currentTargets = ids
        guard !ids.isEmpty else {
            update(.waiting(Settings.callSourceMode == .teamsOnly ? "Teams isn't running" : "Teams or a browser isn't running"))
            return
        }

        let sources = Array(Set(targets.map(\.bundleID))).sorted()
        let newTap = ProcessTap(processIDs: ids)
        newTap.onBuffer = { [weak self] buffer in self?.onBuffer?(buffer) }
        do {
            try newTap.start()
            tap = newTap
            Log.info("Call tap: capturing \(sources.joined(separator: ", "))")
            update(.capturing(sources: sources))
        } catch {
            Log.error("Call tap: \(error.localizedDescription)")
            update(.failed(error.localizedDescription))
        }
    }

    private func tearDownTap() {
        tap?.stop()
        tap = nil
    }

    private func update(_ newStatus: CallCaptureStatus) {
        guard newStatus != status else { return }
        status = newStatus
        onStatus?(newStatus)
    }

    static func friendlyName(_ bundleIDs: [String]) -> String {
        var names: [String] = []
        if bundleIDs.contains(where: CallTargetMatcher.isTeams) { names.append("Teams") }
        if bundleIDs.contains(where: { $0.hasPrefix("com.google.Chrome") }) { names.append("Chrome") }
        if bundleIDs.contains(where: { $0.hasPrefix("com.microsoft.edgemac") }) { names.append("Edge") }
        if bundleIDs.contains(where: { $0.hasPrefix("com.apple.Safari") }) { names.append("Safari") }
        return names.isEmpty ? "call audio" : names.joined(separator: " + ")
    }
}
