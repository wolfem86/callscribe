import AppKit
import AVFoundation
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private var recorder: RecorderController!
    private var testSetup: TestSetupWindowController!
    private var statusItem: StatusItemController!
    private var controlWindow: ControlWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.ensure()
        Log.info("CallScribe \(Paths.appVersion) launched (pid \(ProcessInfo.processInfo.processIdentifier))")

        recorder = RecorderController(state: state)
        testSetup = TestSetupWindowController(recorder: recorder)
        statusItem = StatusItemController(state: state, recorder: recorder, testSetup: testSetup)
        controlWindow = ControlWindowController(state: state, recorder: recorder, testSetup: testSetup)

        // ⌃⌥R start/stop, ⌃⌥P pause/resume. Ignored while Test setup runs.
        HotKeyCenter.shared.register(id: 1, keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey) { [weak self] in
            guard let self, !self.state.isTesting else { return }
            self.recorder.toggleRecording()
        }
        HotKeyCenter.shared.register(id: 2, keyCode: kVK_ANSI_P, modifiers: controlKey | optionKey) { [weak self] in
            guard let self, !self.state.isTesting else { return }
            self.recorder.togglePause()
        }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.info("Microphone permission \(granted ? "granted" : "denied")")
            }
        }

        DispatchQueue.main.async { Recovery.checkOnLaunch() }
    }

    /// Opening CallScribe again (Finder, Spotlight, `open`) shows the controls in a window,
    /// in case the menu bar icon is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controlWindow.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder?.stop()
        Log.info("CallScribe quit")
    }
}
