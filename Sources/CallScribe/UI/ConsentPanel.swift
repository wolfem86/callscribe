import AppKit
import SwiftUI

/// Non-blocking reminder shown as a recording starts, with the consent message ready to paste into Teams chat.
final class ConsentPanel {
    static let shared = ConsentPanel()

    private var panel: NSPanel?
    private var autoClose: DispatchWorkItem?

    func show() {
        close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Recording started"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.contentView = NSHostingView(rootView: ConsentView(
            message: Settings.consentMessage,
            copy: { [weak self] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Settings.consentMessage, forType: .string)
                self?.close()
            },
            dismiss: { [weak self] in self?.close() }
        ))
        panel.setContentSize(panel.contentView!.fittingSize)
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - 20, y: screen.maxY - 240))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        let item = DispatchWorkItem { [weak self] in self?.close() }
        autoClose = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: item)
    }

    func close() {
        autoClose?.cancel()
        panel?.close()
        panel = nil
    }
}

private struct ConsentView: View {
    let message: String
    let copy: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Make sure everyone on the call agrees to be recorded.")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Dismiss", action: dismiss)
                Button("Copy consent message", action: copy)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
