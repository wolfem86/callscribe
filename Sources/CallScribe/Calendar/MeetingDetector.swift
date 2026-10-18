import CallScribeCore
import Foundation

/// Fills in a recording's details as it happens: the matching calendar event when it starts
/// (and again at stop, in case the calendar file updated), and the Teams window's meeting name
/// sampled every 15 seconds as a fallback. Never blocks recording.
final class MeetingDetector {
    private let calendar: CalendarFile
    private var timer: Timer?
    private weak var session: RecordingSession?
    private var seenTitles = Set<String>()

    init(calendar: CalendarFile) {
        self.calendar = calendar
    }

    func recordingStarted(_ session: RecordingSession) {
        self.session = session
        seenTitles = []
        TeamsWindowWatcher.requestAccessIfNeeded()
        // Let the start return immediately; matching reads a file.
        DispatchQueue.main.async { [weak self] in
            self?.matchCalendar()
            self?.sampleWindowTitles()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.sampleWindowTitles() }
    }

    func recordingWillStop(_ session: RecordingSession) {
        timer?.invalidate()
        timer = nil
        sampleWindowTitles()
        matchCalendar()
        self.session = nil
    }

    private func matchCalendar() {
        guard let session else { return }
        let manifest = session.manifestSnapshot
        guard manifest.meeting == nil, manifest.metadataConfirmed != true else { return }
        if let event = calendar.match(recordingStart: manifest.startDate) {
            session.setPrefill(event.meeting(recordedStart: manifest.startDate, recordedEnd: manifest.startDate))
            Log.info("Calendar: matched recording to \"\(event.title)\" (\(event.attendees.count) attendees)")
        }
    }

    private func sampleWindowTitles() {
        guard let session else { return }
        let titles = TeamsWindowWatcher.windowTitles()
        for title in titles where seenTitles.insert(title).inserted {
            Log.info("Teams window: \"\(title)\"")
        }
        guard let name = TeamsWindowTitle.bestMeetingName(from: titles),
              session.manifestSnapshot.windowTitle != name else { return }
        session.setWindowDetection(title: name, participants: TeamsWindowTitle.participants(fromMeetingName: name))
    }
}
