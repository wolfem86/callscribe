import AppKit
import CallScribeCore
import Foundation

/// On launch, finds recordings that never finished (crash, force quit, power loss),
/// repairs their WAV headers, and tells the user.
enum Recovery {
    static func checkOnLaunch() {
        removeLeftoverTests()
        let unfinished = ManifestStore.unfinishedSessions(in: Paths.recordings)
        guard !unfinished.isEmpty else { return }

        var recovered: [URL] = []
        for (directory, var manifest) in unfinished {
            for file in [manifest.micFile, manifest.callFile] {
                let url = directory.appendingPathComponent(file)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                do {
                    let changed = try WAVRepair.repair(url: url)
                    Log.info("Recovery \(manifest.id): \(file) \(changed ? "repaired" : "ok"), \(String(format: "%.0f", WAVRepair.duration(url: url))) s")
                } catch {
                    Log.error("Recovery \(manifest.id): couldn't repair \(file): \(error.localizedDescription)")
                }
            }
            // A pause still open at crash time ended when the audio did; close it at its start.
            manifest.pauses.end(at: manifest.pauses.spans.last?.start ?? 0)
            manifest.recovered = true
            try? ManifestStore.save(manifest, in: directory)
            recovered.append(directory)
        }

        // Phase 2 adds "Recover and transcribe". For now the audio is repaired and kept.
        let alert = NSAlert()
        alert.messageText = recovered.count == 1
            ? "CallScribe recovered an unfinished recording"
            : "CallScribe recovered \(recovered.count) unfinished recordings"
        alert.informativeText = "CallScribe quit while recording. The audio was repaired and kept in the Recordings folder."
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting(recovered)
        }
    }

    /// Test setup audio is never kept; clear anything a crash left behind.
    private static func removeLeftoverTests() {
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: Paths.testRecordings, includingPropertiesForKeys: nil)) ?? []
        for url in leftovers { try? FileManager.default.removeItem(at: url) }
    }
}
