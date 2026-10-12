import AppKit
import CallScribeCore
import SwiftUI

/// The editable fields for one recording. Shown after every recording, and from Recent recordings.
final class MetadataDialogModel: ObservableObject {
    static let autoSaveSeconds = 600

    let directory: URL
    /// Editing a transcript that's already saved (from Recent recordings).
    let isEdit: Bool
    let tagHistory: [String: Int]

    @Published var title: String
    @Published var start: Date
    @Published var organizer: String
    @Published var participants: String
    @Published var tags: String
    @Published var notes: String
    @Published var status: TranscriptionStatus.State?
    @Published var secondsLeft: Int?

    private let original: MeetingMetadata
    /// Calendar meetings edit the invited list; ad hoc calls edit detected participants.
    private let editsInvited: Bool

    init(directory: URL, meeting: MeetingMetadata, isEdit: Bool, tagHistory: [String: Int], status: TranscriptionStatus.State?) {
        self.directory = directory
        self.isEdit = isEdit
        self.tagHistory = tagHistory
        self.original = meeting
        self.editsInvited = !meeting.invited.isEmpty
        title = meeting.title == FileNaming.defaultTitle && !isEdit ? "" : meeting.title
        start = meeting.recordedStart
        organizer = meeting.organizer?.display ?? ""
        participants = editsInvited ? PeopleField.format(meeting.invited) : meeting.participants.joined(separator: ", ")
        tags = meeting.tags.isEmpty ? "" : meeting.tags.joined(separator: ", ")
        notes = meeting.notes ?? ""
        self.status = status
        secondsLeft = isEdit ? nil : Self.autoSaveSeconds
    }

    var titlePlaceholder: String { FileNaming.defaultTitle }

    var tagSuggestions: [String] { TagField.suggestions(for: tags, from: tagHistory) }

    var statusText: String {
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
        var meeting = MetadataPrefill.moving(original, toStart: start)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        meeting.title = trimmedTitle.isEmpty ? MetadataPrefill.title(calendarTitle: nil, windowTitle: nil) : trimmedTitle
        let organizerText = organizer.trimmingCharacters(in: .whitespaces)
        meeting.organizer = organizerText.isEmpty ? nil : PeopleField.parse(organizerText, keeping: [original.organizer].compactMap { $0 }).first
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
                DatePicker("Date", selection: $model.start, displayedComponents: [.date, .hourAndMinute])
                TextField("Organizer", text: $model.organizer, prompt: Text("Name (email)"))
                TextField("Participants", text: $model.participants, prompt: Text("Comma-separated"))
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Tags", text: $model.tags, prompt: Text("Comma-separated"))
                    if !model.tagSuggestions.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(model.tagSuggestions, id: \.self) { tag in
                                Button(tag) { model.tags = TagField.complete(model.tags, with: tag) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                LabeledContent("Notes") {
                    TextEditor(text: $model.notes)
                        .font(.body)
                        .frame(minHeight: 70)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                }
            }
            .formStyle(.columns)

            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if model.isEdit {
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
        let history = TagField.history(from: ManifestStore.allSessions(in: Paths.recordings).compactMap(\.1.meeting))
        let model = MetadataDialogModel(directory: directory, meeting: meeting, isEdit: isEdit,
                                        tagHistory: history, status: manifest.transcription?.state)

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

    private func save(_ directory: URL) {
        guard let (_, model, _) = windows[directory] else { return }
        let meeting = model.meeting()
        close(directory)
        pipeline.confirmMetadata(directory, meeting: meeting)
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
        if model.isEdit {
            close(directory)
        } else {
            save(directory)
        }
    }
}
