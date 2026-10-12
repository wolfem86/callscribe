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

    /// WhisperKit model variant (argmaxinc/whisperkit-coreml).
    static var modelVariant: String {
        get { defaults.string(forKey: "modelVariant") ?? "openai_whisper-large-v3-v20240930_turbo_632MB" }
        set { defaults.set(newValue, forKey: "modelVariant") }
    }

    /// Folder of the downloaded model, once ready.
    static var modelFolder: String? {
        get { defaults.string(forKey: "modelFolder") }
        set { defaults.set(newValue, forKey: "modelFolder") }
    }

    static var transcriptionLanguage: String {
        get { defaults.string(forKey: "transcriptionLanguage") ?? "en" }
        set { defaults.set(newValue, forKey: "transcriptionLanguage") }
    }

    /// Folder transcripts are saved to (normally <OneDrive>/Call Transcripts), stored as bookmark data
    /// so it survives the folder being renamed or moved.
    static var transcriptsFolder: URL? {
        get {
            guard let data = defaults.data(forKey: "transcriptsFolderBookmark") else { return nil }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                return defaults.string(forKey: "transcriptsFolderPath").map { URL(fileURLWithPath: $0, isDirectory: true) }
            }
            if stale, let fresh = try? url.bookmarkData() { defaults.set(fresh, forKey: "transcriptsFolderBookmark") }
            return url
        }
        set {
            defaults.set(try? newValue?.bookmarkData(), forKey: "transcriptsFolderBookmark")
            defaults.set(newValue?.path, forKey: "transcriptsFolderPath")
        }
    }

    /// Days to keep audio after the transcript is saved. 0 deletes it right away.
    static var keepAudioDays: Int {
        get { defaults.integer(forKey: "keepAudioDays") }
        set { defaults.set(newValue, forKey: "keepAudioDays") }
    }

    static var consentMessage: String {
        get {
            defaults.string(forKey: "consentMessage")
                ?? "Heads up: I'm recording this call to create a transcript for my notes. The audio stays on my Mac. Let me know if you'd rather I didn't."
        }
        set { defaults.set(newValue, forKey: "consentMessage") }
    }
}
