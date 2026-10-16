import AppKit
import AVFoundation
import Foundation

/// Starts, pauses, and stops recordings. Manual start never waits on anything:
/// permission prompts, the consent reminder, and the levels window all happen alongside.
final class RecorderController {
    let state: AppState
    private(set) var session: RecordingSession?
    private var pausedForSleep = false
    private var observers: [NSObjectProtocol] = []
    /// Called with each finished (non-test) recording's folder.
    var onRecordingFinished: ((URL) -> Void)?

    lazy var levelsWindow = LevelsWindowController(state: state)

    init(state: AppState) {
        self.state = state
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemWillSleep()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemDidWake()
        })
    }

    func toggleRecording() {
        if session == nil { start() } else { stop() }
    }

    @discardableResult
    func start(isTest: Bool = false) -> RecordingSession? {
        guard session == nil else { return nil }
        let session: RecordingSession
        do {
            session = try RecordingSession(isTest: isTest, levels: state.levels)
        } catch {
            Log.error("Couldn't start recording: \(error.localizedDescription)")
            showAlert("Couldn't start recording", error.localizedDescription)
            return nil
        }

        session.onMicStatus = { [weak self] ok, text in
            self?.state.micOK = ok
            self?.state.micStatus = text
        }
        session.onCallStatus = { [weak self] status in
            self?.state.callOK = status.isCapturing
            self?.state.callStatus = status.text
        }
        self.session = session
        state.levels.reset()
        state.micOK = true
        state.callOK = true
        state.micStatus = "Starting…"
        state.callStatus = "Starting…"
        state.isTesting = isTest
        state.startedAt = Date()
        state.phase = .recording
        session.start()

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { if granted { self.session?.recoverAfterWake() } }
            }
        }
        if !isTest {
            if Settings.showLevelsOnStart { levelsWindow.show() }
        }
        return session
    }

    func stop() {
        guard let session else { return }
        self.session = nil
        pausedForSleep = false
        let manifest = session.stop()
        state.phase = .idle
        state.isTesting = false
        state.startedAt = nil
        state.micOK = true
        state.callOK = true
        state.micStatus = "Not recording"
        state.callStatus = "Not recording"
        state.levels.reset()
        if !manifest.isTest {
            levelsWindow.close()
            onRecordingFinished?(session.directory)
        }
    }

    func togglePause() {
        guard let session else { return }
        if session.isPaused {
            session.resume()
            state.phase = .recording
        } else {
            session.pause(reason: "user")
            state.phase = .paused
        }
    }

    // MARK: Sleep/wake: pause while asleep so the files don't fill with hours of silence.

    private func systemWillSleep() {
        guard let session, !session.isPaused else { return }
        session.pause(reason: "system sleep")
        pausedForSleep = true
        state.phase = .paused
    }

    private func systemDidWake() {
        onWake?()
        guard let session else { return }
        if pausedForSleep {
            pausedForSleep = false
            session.resume()
            state.phase = .recording
        }
        session.recoverAfterWake()
    }

    var onWake: (() -> Void)?

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
