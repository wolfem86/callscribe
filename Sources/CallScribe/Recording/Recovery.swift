import AppKit
import CallScribeCore
import Foundation

/// On launch, finds recordings that never finished (crash, force quit, power loss),
/// repairs their WAV headers, and tells the user.
enum Recovery {
    /// - Parameter transcribe: called with the recovered folders if the user chooses to transcribe them.
    static func checkOnLaunch(transcribe: ([URL]) -> Void) {
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
            manifest.finished = true
            manifest.endDate = manifest.endDate ?? manifest.startDate.addingTimeInterval(
                WAVRepair.duration(url: directory.appendingPathComponent(manifest.micFile)) + manifest.pauses.totalDuration(upTo: .infinity))
            // Pending until the user chooses to transcribe; "Later" leaves it for Retry.
            manifest.transcription = TranscriptionStatus(state: .failed, error: "Recovered after a crash; not transcribed yet")
            try? ManifestStore.save(manifest, in: directory)
            recovered.append(directory)
        }

        let alert = NSAlert()
        alert.messageText = recovered.count == 1
            ? "CallScribe recovered an unfinished recording"
            : "CallScribe recovered \(recovered.count) unfinished recordings"
        alert.informativeText = "CallScribe quit while recording. The audio was repaired and kept."
        alert.addButton(withTitle: "Recover and Transcribe")
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            transcribe(recovered)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting(recovered)
        default:
            break
        }
    }

    /// Test setup audio is never kept; clear anything a crash left behind.
    private static func removeLeftoverTests() {
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: Paths.testRecordings, includingPropertiesForKeys: nil)) ?? []
        for url in leftovers { try? FileManager.default.removeItem(at: url) }
    }
}
