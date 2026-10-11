import Carbon.HIToolbox
import Foundation

/// Global hotkeys through Carbon's RegisterEventHotKey, which needs no Accessibility permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false
    private static let signature: OSType = 0x4353_4352  // 'CSCR'

    /// - Parameters:
    ///   - keyCode: a kVK_* virtual key code.
    ///   - modifiers: Carbon modifier flags, e.g. `controlKey | optionKey`.
    func register(id: UInt32, keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.error("Hotkey \(id): registration failed (\(status)); another app may be using it")
            return
        }
        refs.append(ref)
        handlers[id] = handler
    }

    fileprivate func fire(_ id: UInt32) {
        DispatchQueue.main.async { self.handlers[id]?() }
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if status == noErr { HotKeyCenter.shared.fire(hotKeyID.id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
