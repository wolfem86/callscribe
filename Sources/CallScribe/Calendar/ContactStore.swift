import AppKit
import CallScribeCore
import Foundation

/// The learned email → name directory. Kept in OneDrive (CallScribe/contacts.json, next to the
/// calendar file) so every Mac shares it, with a local copy for when OneDrive isn't available.
/// Each save re-reads and merges first, so two Macs don't overwrite each other's names.
final class ContactStore {
    static let fileName = "contacts.json"

    private(set) var directory = ContactDirectory()

    private var localURL: URL { Paths.appSupport.appendingPathComponent(Self.fileName) }

    private var sharedURL: URL? {
        OneDriveLocator.preferred(OneDriveLocator.candidates(in: OutputManager.cloudStorage))?
            .appendingPathComponent("CallScribe", isDirectory: true)
            .appendingPathComponent(Self.fileName)
    }

    init() {
        reload()
    }

    /// Creates the file on launch if it doesn't exist yet (so it's visible in OneDrive), filled with
    /// names already confirmed in past recordings.
    func initialize(from pastMeetings: [MeetingMetadata]) {
        reload()
        var seeded = 0
        for meeting in pastMeetings {
            for person in meeting.invited + [meeting.organizer].compactMap({ $0 }) {
                if let email = person.email, directory.name(for: email) == nil,
                   directory.learn(email: email, name: person.name, at: meeting.recordedStart) {
                    seeded += 1
                }
            }
        }
        let missing = [localURL, sharedURL].compactMap { $0 }.contains { !FileManager.default.fileExists(atPath: $0.path) }
        if missing || seeded > 0 {
            save()
            Log.info("Contacts: \(directory.entries.count) names in \((sharedURL ?? localURL).path)\(seeded > 0 ? " (\(seeded) from past recordings)" : "")")
        }
        if sharedURL == nil { Log.info("Contacts: OneDrive not found; keeping names locally until it is") }
    }

    func reload() {
        var merged = ContactDirectory()
        for url in [localURL, sharedURL].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url), let stored = try? ContactDirectory.decode(data) {
                merged.merge(stored)
            }
        }
        directory = merged
    }

    func learn(_ pairs: [(email: String, name: String)]) {
        guard !pairs.isEmpty else { return }
        reload()
        var changed: [String] = []
        for pair in pairs where directory.learn(email: pair.email, name: pair.name) {
            changed.append(pair.email)
        }
        guard !changed.isEmpty else { return }
        save()
        Log.info("Contacts: learned \(changed.count) name\(changed.count == 1 ? "" : "s")")
    }

    func apply(_ meeting: MeetingMetadata) -> MeetingMetadata { directory.apply(meeting) }

    /// Opens the shared file (or the local one) so names can be reviewed or corrected by hand.
    func openFile() {
        if !FileManager.default.fileExists(atPath: (sharedURL ?? localURL).path) { save() }
        NSWorkspace.shared.open(sharedURL ?? localURL)
    }

    private func save() {
        guard let data = try? directory.jsonData() else { return }
        for url in [localURL, sharedURL].compactMap({ $0 }) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                Log.warn("Contacts: couldn't write \(url.path): \(error.localizedDescription)")
            }
        }
    }
}
