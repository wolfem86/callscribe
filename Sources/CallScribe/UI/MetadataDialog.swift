import AppKit
import CallScribeCore
import SwiftUI

/// The editable fields for one recording. Shown after every recording, and from Recent recordings.
final class MetadataDialogModel: ObservableObject {
    static let autoSaveSeconds = 600

    let directory: URL
    /// Editing a transcript that's already saved (from Recent recordings).
    let isEdit: Bool
    /// Editing while the recording is still running.
    let isLive: Bool
    let tagHistory: [String: Int]
    var participantHistory: [String: Int] = [:]

    @Published var title: String
    /// Pre-filled from the actual recording. Moving the start moves the end by the same amount.
    @Published var start: Date {
        didSet { end = end.addingTimeInterval(start.timeIntervalSince(oldValue)) }
    }
    @Published var end: Date
    @Published var participants: String
    @Published var tags: String
    @Published var notes: String
    @Published var status: TranscriptionStatus.State?
    @Published var participantHighlight = 0
    @Published var tagHighlight = 0
    @Published var secondsLeft: Int?

    private let original: MeetingMetadata
    /// Calendar meetings edit the invited list; ad hoc calls edit detected participants.
    private let editsInvited: Bool

    init(directory: URL, meeting: MeetingMetadata, isEdit: Bool, isLive: Bool = false,
         tagHistory: [String: Int], status: TranscriptionStatus.State?) {
        self.directory = directory
        self.isEdit = isEdit
        self.isLive = isLive
        self.tagHistory = tagHistory
        self.original = meeting
        self.editsInvited = !meeting.invited.isEmpty
        title = meeting.title == FileNaming.defaultTitle && !isEdit ? "" : meeting.title
        start = meeting.recordedStart
        end = meeting.recordedEnd
        participants = editsInvited ? PeopleField.format(meeting.invited) : meeting.participants.joined(separator: ", ")
        tags = meeting.tags.isEmpty ? "" : meeting.tags.joined(separator: ", ")
        notes = meeting.notes ?? ""
        self.status = status
        secondsLeft = isEdit || isLive ? nil : Self.autoSaveSeconds
    }

    var titlePlaceholder: String { FileNaming.defaultTitle }

    var tagSuggestions: [String] { TagField.suggestions(for: tags, from: tagHistory) }
    /// Suggested only once something is typed, so the dialog stays quiet for calendar meetings.
    var participantSuggestions: [String] {
        let typed = participants.split(separator: ",", omittingEmptySubsequences: false).last?.trimmingCharacters(in: .whitespaces) ?? ""
        return typed.isEmpty ? [] : TagField.suggestions(for: participants, from: participantHistory, limit: 4)
    }

    var statusText: String {
        if isLive { return "Recording in progress. These details are used when it stops, so you won't be asked again." }
        switch status {
        case .pending?, .transcribing?: return "Transcribing in the background…"
        case .transcribed?: return "Transcript ready. Save to write it."
        case .done?: return isEdit ? "Saving updates the transcript and renames it if the title or date changed." : "Saved."
        case .failed?: return "Transcription failed. The audio was kept; use Retry Transcription in the menu."
        case nil: return ""
        }
    }

    /// The values to save. An empty title falls back to the pre-filled default.
    func meeting() -> MeetingMetadata {
        // Organizer isn't edited here; one from the calendar is kept as is.
        var meeting = original
        meeting.recordedStart = start
        meeting.recordedEnd = max(end, start)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        meeting.title = trimmedTitle.isEmpty ? MetadataPrefill.title(calendarTitle: nil, windowTitle: nil) : trimmedTitle
        if editsInvited {
            meeting.invited = PeopleField.parse(participants, keeping: original.invited)
        } else {
            meeting.participants = PeopleField.splitList(participants)
        }
        meeting.tags = TagField.parse(tags)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        meeting.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        return meeting
    }
}

struct MetadataDialogView: View {
    @ObservedObject var model: MetadataDialogModel
    let save: () -> Void
    let discard: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Title", text: $model.title, prompt: Text(model.titlePlaceholder))
                LabeledContent("Participants") {
                    VStack(alignment: .leading, spacing: 4) {
                        SuggestingTextField(text: $model.participants, placeholder: "Comma-separated",
                                            suggestions: model.participantSuggestions, highlighted: $model.participantHighlight,
                                            accept: { TagField.complete(model.participants, with: $0) })
                        SuggestionChips(suggestions: model.participantSuggestions, highlighted: model.participantHighlight) {
                            model.participants = TagField.complete(model.participants, with: $0)
                        }
                    }
                }
                LabeledContent("Notes") {
                    TextEditor(text: $model.notes)
                        .font(.body)
                        .frame(minHeight: 70)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                }
                LabeledContent("Tags") {
                    VStack(alignment: .leading, spacing: 4) {
                        SuggestingTextField(text: $model.tags, placeholder: "Comma-separated",
                                            suggestions: model.tagSuggestions, highlighted: $model.tagHighlight,
                                            accept: { TagField.complete(model.tags, with: $0) })
                        SuggestionChips(suggestions: model.tagSuggestions, highlighted: model.tagHighlight) {
                            model.tags = TagField.complete(model.tags, with: $0)
                        }
                    }
                }
                DatePicker("Start", selection: $model.start, displayedComponents: [.date, .hourAndMinute])
                if model.isLive {
                    LabeledContent("End") { Text("Set when the recording stops").foregroundStyle(.secondary) }
                } else {
                    DatePicker("End", selection: $model.end, in: model.start..., displayedComponents: [.date, .hourAndMinute])
                }
            }
            .formStyle(.columns)

            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if model.isEdit || model.isLive {
                    Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                } else {
                    Button("Discard Recording…", role: .destructive, action: discard)
                }
                Spacer()
                if let seconds = model.secondsLeft {
                    Text("Saves automatically in \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// One dialog window per recording.
final class MetadataDialogController: NSObject, NSWindowDelegate {
    private let pipeline: TranscriptionPipeline
    /// The recording whose details are being edited live, if any.
    private weak var liveSession: RecordingSession?
    private var windows: [URL: (NSWindow, MetadataDialogModel, Timer?)] = [:]
    private var observer: NSObjectProtocol?

    init(pipeline: TranscriptionPipeline) {
        self.pipeline = pipeline
        super.init()
        observer = NotificationCenter.default.addObserver(forName: .sessionChanged, object: nil, queue: .main) { [weak self] note in
            guard let self, let directory = note.object as? URL, let entry = self.windows[directory] else { return }
            entry.1.status = self.pipeline.status(of: directory)
        }
    }

    func show(_ directory: URL) {
        if let (window, _, _) = windows[directory] {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let manifest = try? ManifestStore.load(from: directory) else { return }
        // Already saved (including transcripts from before the dialog existed) → edit mode.
        let isEdit = manifest.metadataConfirmed == true || manifest.transcription?.state == .done
        let meeting = isEdit
            ? (manifest.meeting ?? pipeline.loadDocument(directory, manifest: manifest)?.meeting ?? TranscriptionPipeline.initialMeeting(manifest))
            : TranscriptionPipeline.initialMeeting(manifest)
        let pastMeetings = ManifestStore.allSessions(in: Paths.recordings).compactMap(\.1.meeting)
        let history = TagField.history(from: pastMeetings)
        let model = MetadataDialogModel(directory: directory, meeting: meeting, isEdit: isEdit,
                                        tagHistory: history, status: manifest.transcription?.state)
        model.participantHistory = Self.participantHistory(pastMeetings)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = isEdit ? "Edit Recording Details" : "Recording Details"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: MetadataDialogView(
            model: model,
            save: { [weak self] in self?.save(directory) },
            discard: { [weak self] in self?.confirmDiscard(directory) },
            cancel: { [weak self] in self?.close(directory) }
        ))
        window.center()

        // Ignored for 10 minutes: save with what's filled in.
        var timer: Timer?
        if !isEdit {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak model] _ in
                guard let model, let seconds = model.secondsLeft else { return }
                if seconds <= 1 {
                    Log.info("Metadata: dialog ignored for 10 minutes; saving pre-filled values")
                    self?.save(directory)
                } else {
                    model.secondsLeft = seconds - 1
                }
            }
        }
        windows[directory] = (window, model, timer)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Opens the details for the recording in progress.
    func showLive(_ session: RecordingSession) {
        let directory = session.directory
        if let (window, _, _) = windows[directory] {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        liveSession = session
        let manifest = session.manifestSnapshot
        let pastMeetings = ManifestStore.allSessions(in: Paths.recordings).compactMap(\.1.meeting)
        let history = TagField.history(from: pastMeetings)
        let model = MetadataDialogModel(directory: directory, meeting: manifest.meeting ?? TranscriptionPipeline.initialMeeting(manifest),
                                        isEdit: false, isLive: true, tagHistory: history, status: nil)
        model.participantHistory = Self.participantHistory(pastMeetings)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Call Details (Recording)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: MetadataDialogView(
            model: model,
            save: { [weak self] in self?.save(directory) },
            discard: {},
            cancel: { [weak self] in self?.close(directory) }
        ))
        window.center()
        windows[directory] = (window, model, nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The recording is stopping: keep whatever is in its live details window.
    func finishLive(_ session: RecordingSession) {
        if let (_, model, _) = windows[session.directory], model.isLive {
            save(session.directory)
        }
    }

    /// Names from past recordings' participants and invitees, by how often they appear.
    static func participantHistory(_ meetings: [MeetingMetadata]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for meeting in meetings {
            for name in meeting.participants + meeting.invited.map({ $0.name.isEmpty ? ($0.email ?? "") : $0.name }) where !name.isEmpty {
                counts[name, default: 0] += 1
            }
        }
        return counts
    }

    private func save(_ directory: URL) {
        guard let (_, model, _) = windows[directory] else { return }
        let meeting = model.meeting()
        close(directory)
        if model.isLive {
            liveSession?.updateMeeting(meeting)
        } else {
            pipeline.confirmMetadata(directory, meeting: meeting)
        }
    }

    private func confirmDiscard(_ directory: URL) {
        guard let (window, _, _) = windows[directory] else { return }
        let alert = NSAlert()
        alert.messageText = "Discard this recording?"
        alert.informativeText = "The audio and its transcript will be deleted. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.close(directory)
            self?.pipeline.discard(directory)
        }
    }

    private func close(_ directory: URL) {
        guard let (window, _, timer) = windows.removeValue(forKey: directory) else { return }
        timer?.invalidate()
        window.delegate = nil
        window.close()
    }

    /// Closing a new recording's dialog saves what's there (nothing is lost); closing an edit cancels it.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let directory = windows.first(where: { $0.value.0 === window })?.key,
              let (_, model, _) = windows[directory] else { return }
        // Closing keeps what's entered, except when editing an already-saved transcript.
        if model.isEdit {
            close(directory)
        } else {
            save(directory)
        }
    }
}
