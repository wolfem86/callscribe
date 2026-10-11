import AppKit
import SwiftUI

/// The menu's controls in a window. Shown when CallScribe is opened again while already running,
/// so the app stays usable when the menu bar icon is hidden (e.g. behind the MacBook notch).
struct ControlView: View {
    @ObservedObject var state: AppState
    let recorder: RecorderController
    let testSetup: TestSetupWindowController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(statusText).font(.headline)
            if state.isActive && !state.isTesting {
                Label(state.micStatus, systemImage: state.micOK ? "mic" : "exclamationmark.triangle")
                    .font(.caption)
                Label(state.callStatus, systemImage: state.callOK ? "speaker.wave.2" : "exclamationmark.triangle")
                    .font(.caption)
            }
            HStack {
                Button(state.isActive ? "Stop Recording" : "Start Recording") { recorder.toggleRecording() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.isTesting)
                Button(state.phase == .paused ? "Resume" : "Pause") { recorder.togglePause() }
                    .disabled(!state.isActive || state.isTesting)
            }
            Divider()
            HStack {
                Button("Test Setup…") { testSetup.show() }.disabled(state.isActive)
                Button("Recordings") { NSWorkspace.shared.open(Paths.recordings) }
                Button("Log") { NSWorkspace.shared.open(Log.fileURL) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            Text("Shortcuts: ⌃⌥R start/stop · ⌃⌥P pause/resume")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 400)
    }

    private var statusText: String {
        switch state.phase {
        case .idle: return "CallScribe is ready"
        case .recording: return state.isTesting ? "Test setup running" : "Recording"
        case .paused: return "Paused"
        case .processing: return "Processing"
        }
    }
}

final class ControlWindowController {
    private let state: AppState
    private let recorder: RecorderController
    private let testSetup: TestSetupWindowController
    private var window: NSWindow?

    init(state: AppState, recorder: RecorderController, testSetup: TestSetupWindowController) {
        self.state = state
        self.recorder = recorder
        self.testSetup = testSetup
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "CallScribe"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ControlView(state: state, recorder: recorder, testSetup: testSetup))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
