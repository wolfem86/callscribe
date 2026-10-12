import Foundation
import WhisperKit

/// Downloads the Whisper model (and its tokenizer) to Application Support on first launch.
/// Never bundled with the app. Files already downloaded are skipped, so an interrupted
/// download picks up where it left off on the next try.
final class ModelManager: ObservableObject {
    enum Status: Equatable {
        case missing
        case downloading(Double)
        case ready(URL)
        case failed(String)
    }

    @Published private(set) var status: Status = .missing
    private var task: Task<Void, Never>?

    static var modelsRoot: URL { Paths.appSupport.appendingPathComponent("Models", isDirectory: true) }

    init() {
        if let path = Settings.modelFolder, Self.isComplete(URL(fileURLWithPath: path)), Self.hasTokenizer {
            status = .ready(URL(fileURLWithPath: path))
        }
    }

    var readyFolder: URL? {
        if case .ready(let url) = status { return url }
        return nil
    }

    var statusText: String {
        switch status {
        case .missing: return "Speech model not downloaded"
        case .downloading(let fraction): return String(format: "Downloading speech model… %.0f%%", fraction * 100)
        case .ready: return "Speech model ready"
        case .failed(let message): return "Model download failed: \(message)"
        }
    }

    /// Starts the download if needed. Safe to call repeatedly.
    func ensureModel() {
        if readyFolder != nil { return }
        if case .downloading = status { return }
        let variant = Settings.modelVariant
        status = .downloading(0)
        Log.info("Model: downloading \(variant)")
        task = Task {
            do {
                try FileManager.default.createDirectory(at: Self.modelsRoot, withIntermediateDirectories: true)
                let folder = try await WhisperKit.download(variant: variant, downloadBase: Self.modelsRoot) { progress in
                    let fraction = progress.fractionCompleted
                    DispatchQueue.main.async { [self] in
                        if case .downloading = self.status { self.status = .downloading(min(fraction, 0.99)) }
                    }
                }
                // Loading once fetches and caches the tokenizer (so later transcription works offline)
                // and runs Core ML's one-time model compilation now rather than after the first call.
                await MainActor.run { self.status = .downloading(0.99) }
                let config = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: Self.modelsRoot,
                                              verbose: false, logLevel: .error, prewarm: true, load: true, download: false)
                let whisper = try await WhisperKit(config)
                await whisper.unloadModels()
                await MainActor.run {
                    Settings.modelFolder = folder.path
                    self.status = .ready(folder)
                    Log.info("Model: ready at \(folder.path)")
                    NotificationCenter.default.post(name: .modelReady, object: nil)
                }
            } catch {
                await MainActor.run {
                    self.status = .failed(error.localizedDescription)
                    Log.error("Model: download failed: \(error.localizedDescription)")
                }
            }
        }
    }

    static func isComplete(_ folder: URL) -> Bool {
        ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    private static var hasTokenizer: Bool {
        let enumerator = FileManager.default.enumerator(at: modelsRoot, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "tokenizer.json" { return true }
        }
        return false
    }
}

extension Notification.Name {
    static let modelReady = Notification.Name("CallScribeModelReady")
}
