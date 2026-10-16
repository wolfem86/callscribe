import AppKit
import CallScribeCore
import SwiftUI

struct LevelMeterView: View {
    let label: String
    let db: Float
    let ok: Bool
    let status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.headline)
                Spacer()
                Text(db <= LevelMeter.floorDB ? "silent" : String(format: "%.0f dB", db))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(LevelMeter.normalized(db)))
                }
            }
            .frame(height: 8)
            Label(status, systemImage: ok ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(ok ? Color.secondary : Color.orange)
                .lineLimit(2)
        }
    }
}

/// Live level meters for both streams, polled at 15 Hz.
struct LevelsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15)) { context in
            let levels = state.levels.snapshot()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(state.phase == .paused ? "Paused" : "Recording")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if let startedAt = state.startedAt {
                        Text(RecordingSession.format(context.date.timeIntervalSince(startedAt)))
                            .font(.subheadline.monospacedDigit())
                    }
                }
                LevelMeterView(label: "Me (mic)", db: levels.mic, ok: state.micOK, status: state.micStatus)
                LevelMeterView(label: "Others (call)", db: levels.call, ok: state.callOK, status: state.callStatus)
            }
            .padding(16)
            .frame(width: 320)
        }
    }
}

final class LevelsWindowController {
    private let state: AppState
    private var window: NSPanel?

    init(state: AppState) {
        self.state = state
    }

    func show() {
        if window == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                                styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.title = "CallScribe Levels"
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.contentView = NSHostingView(rootView: LevelsView(state: state))
            panel.setContentSize(panel.contentView!.fittingSize)
            if let screen = NSScreen.main?.visibleFrame {
                panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - 20, y: screen.maxY - 20))
            }
            window = panel
        }
        window?.orderFrontRegardless()
    }

    var isVisible: Bool { window?.isVisible == true }

    func toggle() {
        if isVisible { close() } else { show() }
    }

    func close() {
        window?.close()
    }
}
