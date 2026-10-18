import AppKit
import CallScribeCore
import Foundation

/// The calendar file a Power Automate flow keeps up to date in OneDrive (default:
/// <OneDrive>/CallScribe/calendar.json). Re-read whenever it changes; never blocks recording.
final class CalendarFile {
    static let defaultRelativePath = "CallScribe/calendar.json"

    private(set) var events: [CalendarEvent] = []
    private(set) var lastModified: Date?
    private(set) var error: String?
    private var timer: Timer?
    private var loggedFields = false

    /// The configured file, or the default location in the detected OneDrive.
    var url: URL? {
        if let path = UserDefaults.standard.string(forKey: "calendarFilePath") { return URL(fileURLWithPath: path) }
        return OneDriveLocator.preferred(OneDriveLocator.candidates(in: OutputManager.cloudStorage))?
            .appendingPathComponent(Self.defaultRelativePath)
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard let url else {
            events = []
            error = "OneDrive not found"
            return
        }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard FileManager.default.fileExists(atPath: url.path), let modified else {
            if error == nil || !events.isEmpty { Log.info("Calendar: no file at \(url.path)") }
            events = []
            error = "No calendar file yet"
            lastModified = nil
            return
        }
        if modified == lastModified, error == nil { return }
        do {
            // Reading a OneDrive online-only file downloads it first.
            let result = try PowerAutomateCalendar.parse(Data(contentsOf: url))
            events = result.events
            lastModified = modified
            error = nil
            Log.info("Calendar: loaded \(result.events.count) events (\(result.skipped) skipped) from \(url.lastPathComponent)")
            if !loggedFields || result.events.isEmpty {
                Log.info("Calendar: fields in file: \(result.fieldsSeen.joined(separator: ", "))")
                loggedFields = true
            }
        } catch {
            self.error = "Couldn't read the calendar file"
            Log.error("Calendar: \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func match(recordingStart: Date) -> CalendarEvent? {
        refresh()
        return EventMatcher.match(events, recordingStart: recordingStart)
    }

    var statusText: String {
        if let error { return "Calendar: \(error)" }
        let upcoming = events.filter { $0.end > Date() }.count
        let age = lastModified.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "never"
        return "Calendar: \(upcoming) upcoming events · updated \(age)"
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.message = "Choose the calendar file your Power Automate flow writes (usually OneDrive → CallScribe → calendar.json)."
        panel.directoryURL = url?.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        UserDefaults.standard.set(chosen.path, forKey: "calendarFilePath")
        lastModified = nil
        refresh()
    }
}
