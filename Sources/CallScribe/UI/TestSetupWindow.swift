import AppKit
import CallScribeCore
import SwiftUI

/// 15-second check: speak first, then play audio through Teams or the browser.
/// Shows which stream heard what, to catch missing streams and cross-bleed. Nothing is kept.
final class TestSetupModel: ObservableObject {
    enum Step {
        case intro, running, done(TestSetupResult), failed(String)
    }

    @Published var step: Step = .intro
    @Published var elapsed = 0.0

    private let recorder: RecorderController
    private var samples: [LevelSample] = []
    private var timer: Timer?
    private var started = Date()

    init(recorder: RecorderController) {
        self.recorder = recorder
    }

    var instruction: String {
        elapsed < 7.5
            ? "Speak normally into your headset mic. Keep Teams and the browser silent."
            : "Stop talking. Play audio in Teams or the browser (e.g. Teams' Test call, or a video)."
    }

    func run() {
        guard let session = recorder.start(isTest: true) else {
            step = .failed("A recording is already in progress.")
            return
        }
        samples = []
        elapsed = 0
        started = Date()
        step = .running
        let directory = session.directory
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsed = Date().timeIntervalSince(self.started)
            let levels = self.recorder.state.levels.snapshot()
            self.samples.append(LevelSample(time: self.elapsed, micDB: levels.mic, callDB: levels.call))
            if self.elapsed >= TestSetupAnalyzer.duration { self.finish(directory: directory) }
        }
    }

    func cancel() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        let directory = recorder.session?.directory
        recorder.stop()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        step = .intro
    }

    private func finish(directory: URL) {
        timer?.invalidate()
        timer = nil
        recorder.stop()
        try? FileManager.default.removeItem(at: directory)
        let result = TestSetupAnalyzer.analyze(samples)
        Log.info(String(format: "Test setup: speak mic %.0f / call %.0f dB, play mic %.0f / call %.0f dB, passed=%@",
                        result.speakMicDB, result.speakCallDB, result.playMicDB, result.playCallDB,
                        result.passed ? "yes" : "no"))
        step = .done(result)
    }
}

struct TestSetupView: View {
    @ObservedObject var model: TestSetupModel
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.step {
            case .intro:
                Text("Test setup").font(.title2.weight(.semibold))
                Text("A 15-second recording checks both streams:")
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. For the first 7 seconds, speak into your headset.")
                    Text("2. Then stop talking and play audio through Teams or the browser.")
                }
                .foregroundStyle(.secondary)
                Text("Join Teams' test call or open a video before you start. Nothing from this test is kept.")
                    .font(.callout)
                HStack { Spacer(); Button("Start Test") { model.run() }.keyboardShortcut(.defaultAction) }

            case .running:
                Text(model.instruction).font(.headline).fixedSize(horizontal: false, vertical: true)
                ProgressView(value: min(model.elapsed, TestSetupAnalyzer.duration), total: TestSetupAnalyzer.duration)
                TimelineView(.periodic(from: .now, by: 1.0 / 15)) { _ in
                    let levels = state.levels.snapshot()
                    VStack(spacing: 12) {
                        LevelMeterView(label: "Me (mic)", db: levels.mic, ok: state.micOK, status: state.micStatus)
                        LevelMeterView(label: "Others (call)", db: levels.call, ok: state.callOK, status: state.callStatus)
                    }
                }
                HStack { Spacer(); Button("Cancel") { model.cancel() } }

            case .done(let result):
                Text(result.passed ? "Setup looks good" : "Check your setup").font(.title2.weight(.semibold))
                ResultRow(ok: result.micHeardVoice, text: result.micHeardVoice
                          ? "Your mic heard you while you spoke." : "Your mic didn't hear you. Check the input device and microphone permission.")
                ResultRow(ok: result.callHeardPlayback, text: result.callHeardPlayback
                          ? "The call stream heard Teams/browser audio." : "The call stream heard nothing. Check that audio played in Teams or the browser and that system audio recording is allowed.")
                ResultRow(ok: !result.voiceBledIntoCall, text: result.voiceBledIntoCall
                          ? "Your voice showed up on the call stream." : "No voice on the call stream while you spoke.")
                ResultRow(ok: !result.playbackBledIntoMic, text: result.playbackBledIntoMic
                          ? "Call audio leaked into your mic. Use the headset's speakers, not the Mac's." : "No call audio leaked into your mic.")
                Text(String(format: "Speaking: mic %.0f dB, call %.0f dB · Playback: mic %.0f dB, call %.0f dB",
                            result.speakMicDB, result.speakCallDB, result.playMicDB, result.playCallDB))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Run Again") { model.run() } }

            case .failed(let message):
                Text(message)
                HStack { Spacer(); Button("Try Again") { model.step = .intro } }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct ResultRow: View {
    let ok: Bool
    let text: String

    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle" : "xmark.circle")
            .foregroundStyle(ok ? Color.primary : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

final class TestSetupWindowController: NSObject, NSWindowDelegate {
    private let model: TestSetupModel
    private let state: AppState
    private var window: NSWindow?

    init(recorder: RecorderController) {
        model = TestSetupModel(recorder: recorder)
        state = recorder.state
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "CallScribe Test Setup"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: TestSetupView(model: model, state: state))
            window.center()
            self.window = window
        }
        if case .running = model.step {} else { model.step = .intro }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.cancel()
    }
}
