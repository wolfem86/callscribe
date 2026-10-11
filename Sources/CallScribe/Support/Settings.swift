import Foundation
import CallScribeCore

enum Settings {
    private static var defaults: UserDefaults { .standard }

    /// macOS voice processing on the mic. Off by default: it ducks other audio and isn't needed with a headset.
    static var voiceProcessing: Bool {
        get { defaults.bool(forKey: "voiceProcessing") }
        set { defaults.set(newValue, forKey: "voiceProcessing") }
    }

    /// Slow opacity pulse on the menu bar icon while recording.
    static var pulseEnabled: Bool {
        get { defaults.object(forKey: "pulseEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pulseEnabled") }
    }

    /// Elapsed recording time next to the menu bar icon.
    static var showElapsed: Bool {
        get { defaults.bool(forKey: "showElapsed") }
        set { defaults.set(newValue, forKey: "showElapsed") }
    }

    static var callSourceMode: CallSourceMode {
        get { defaults.string(forKey: "callSourceMode").flatMap(CallSourceMode.init(rawValue:)) ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "callSourceMode") }
    }

    static var consentMessage: String {
        get {
            defaults.string(forKey: "consentMessage")
                ?? "Heads up: I'm recording this call to create a transcript for my notes. The audio stays on my Mac. Let me know if you'd rather I didn't."
        }
        set { defaults.set(newValue, forKey: "consentMessage") }
    }
}
