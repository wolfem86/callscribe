import CallScribeCore
import Foundation

/// After a recording stops, two things happen side by side: the streams are transcribed, and the
/// metadata dialog is shown. The transcript is written only when both are done (in either order),
/// then the audio is deleted per the keep-audio setting. One transcription at a time.
/// Failures keep the audio for "Retry transcription". All methods run on the main thread.
final class TranscriptionPipeline {
    private let state: AppState
    private let models: ModelManager
    private let output: OutputManager
    private var queue: [URL] = []
    private var running: URL?
    private var discarded = Set<URL>()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// Asks the UI to show the metadata dialog for a session that's waiting on it.
    var onNeedsMetadata: ((URL) -> Void)?

    init(state: AppState, models: ModelManager, output: OutputManager) {
        self.state = state
        self.models = models
        self.output = output
        observers.append(NotificationCenter.default.addObserver(forName: .modelReady, object: nil, queue: .main) { [weak self] _ in
            self?.runNext()
        })
    }

    /// On launch: resume unfinished work, move outbox files, purge old audio; then repeat housekeeping every 5 min.
    func start() {
        for (directory, manifest) in ManifestStore.allSessions(in: Paths.recordings) where manifest.finished {
            switch manifest.transcription?.state {
            case nil, .pending?, .transcribing?:
                if hasAudio(directory) { enqueue(directory) }
            case .transcribed?:
                if manifest.metadataConfirmed == true { finalizeIfReady(directory) } else { onNeedsMetadata?(directory) }
            case .done?, .failed?:
                break
            }
        }
        housekeeping()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.housekeeping() }
        refreshFailed()
    }

    func enqueue(_ directory: URL) {
        guard !queue.contains(directory) else { return }
        queue.append(directory)
        update(directory) { $0.transcription = TranscriptionStatus(state: .pending) }
        runNext()
    }

    // MARK: Metadata dialog results

    /// Saves the dialog's values. Writes the transcript now if transcription is done, or rewrites
    /// (and renames) an already-saved transcript.
    func confirmMetadata(_ directory: URL, meeting: MeetingMetadata) {
        update(directory) {
            $0.meeting = meeting
            $0.metadataConfirmed = true
        }
        Log.info("Metadata: confirmed for \(directory.lastPathComponent)")
        guard let manifest = try? ManifestStore.load(from: directory) else { return }
        if manifest.transcription?.state == .done {
            rewrite(directory, manifest: manifest)
        } else {
            finalizeIfReady(directory)
        }
    }

    /// Deletes the recording (audio, transcript cache, session) — the user confirmed in the dialog.
    func discard(_ directory: URL) {
        queue.removeAll { $0 == directory }
        if running == directory {
            discarded.insert(directory)  // finish() deletes it when Whisper returns
        } else {
            deleteSession(directory)
        }
        refreshFailed()
    }

    // MARK: Status for the UI

    func status(of directory: URL) -> TranscriptionStatus.State? {
        (try? ManifestStore.load(from: directory))?.transcription?.state
    }

    var failedSessions: [(URL, SessionManifest)] {
        ManifestStore.allSessions(in: Paths.recordings).filter { $0.1.transcription?.state == .failed && hasAudio($0.0) }
    }

    /// Most recent recordings with a transcript (saved or waiting on the dialog).
    func recentSessions(limit: Int = 20) -> [(URL, SessionManifest)] {
        Array(ManifestStore.allSessions(in: Paths.recordings).filter { _, manifest in
            [.transcribed, .done].contains(manifest.transcription?.state) || manifest.transcription?.state == .transcribing
        }.prefix(limit))
    }

    func housekeeping() {
        for (sessionID, url) in output.flushOutbox() {
            let directory = Paths.recordings.appendingPathComponent(sessionID, isDirectory: true)
            update(directory) {
                $0.transcription?.transcriptPath = url.path
                $0.transcription?.savedLocally = false
            }
            Notifier.post("Transcript moved to OneDrive", url.deletingPathExtension().lastPathComponent)
        }
        purgeExpiredAudio()
    }

    // MARK: Transcription

    private func runNext() {
        guard running == nil, let directory = queue.first else { return }
        guard let modelFolder = models.readyFolder else {
            models.ensureModel()  // .modelReady restarts the queue
            return
        }
        running = directory
        state.isProcessing = true
        update(directory) { $0.transcription = TranscriptionStatus(state: .transcribing) }

        Task.detached(priority: .utility) { [self] in
            let result: Result<TranscriptDocument, Error>
            do {
                result = .success(try await Self.transcribe(directory: directory, modelFolder: modelFolder))
            } catch {
                result = .failure(error)
            }
            await MainActor.run { self.finish(directory, result) }
        }
    }

    /// Transcribes and merges both streams; caches the document next to session.json.
    private static func transcribe(directory: URL, modelFolder: URL) async throws -> TranscriptDocument {
        let manifest = try ManifestStore.load(from: directory)
        Log.info("Transcribe: session \(manifest.id) started")
        let me = try WAVRepair.readSamples(url: directory.appendingPathComponent(manifest.micFile))
        let others = (try? WAVRepair.readSamples(url: directory.appendingPathComponent(manifest.callFile))) ?? []

        let result = try await Transcriber(modelFolder: modelFolder).transcribeSession(me: me, others: others)
        let document = TranscriptBuilder.build(meeting: initialMeeting(manifest, samples: me.count), me: result.me, others: result.others,
                                               pauses: manifest.pauses, callGaps: manifest.callGaps,
                                               callCaptured: manifest.callCaptured, callSources: manifest.callSources)
        for drop in document.droppedDuplicates {
            Log.info(String(format: "Duplicate guard: dropped Me at %@ (similarity %.2f) — matched Others",
                            TranscriptBuilder.timestamp(drop.start), drop.similarity))
        }
        try document.jsonData().write(to: directory.appendingPathComponent(SessionManifest.transcriptCacheFile), options: .atomic)
        Log.info("Transcribe: session \(manifest.id) transcribed \(document.segments.count) lines")
        return document
    }

    private func finish(_ directory: URL, _ result: Result<TranscriptDocument, Error>) {
        queue.removeAll { $0 == directory }
        running = nil
        state.isProcessing = !queue.isEmpty

        if discarded.remove(directory) != nil {
            deleteSession(directory)
        } else {
            switch result {
            case .success:
                update(directory) { $0.transcription = TranscriptionStatus(state: .transcribed) }
                let confirmed = (try? ManifestStore.load(from: directory))?.metadataConfirmed == true
                if confirmed { finalizeIfReady(directory) } else { onNeedsMetadata?(directory) }
            case .failure(let error):
                Log.error("Transcribe: \(directory.lastPathComponent) failed: \(error.localizedDescription)")
                update(directory) { $0.transcription = TranscriptionStatus(state: .failed, error: error.localizedDescription) }
                Notifier.post("Transcription failed", "The audio was kept. Choose Retry Transcription in the CallScribe menu.")
            }
        }
        refreshFailed()
        runNext()
    }

    // MARK: Writing

    /// Writes the transcript once it's transcribed and the metadata is confirmed.
    private func finalizeIfReady(_ directory: URL) {
        guard let manifest = try? ManifestStore.load(from: directory),
              manifest.transcription?.state == .transcribed, manifest.metadataConfirmed == true,
              var document = loadDocument(directory, manifest: manifest) else { return }
        document.meeting = manifest.meeting ?? document.meeting
        do {
            let saved = try output.save(markdown: TranscriptBuilder.markdown(document), json: try document.jsonData(),
                                        baseName: baseName(document.meeting), sessionID: manifest.id)
            var local = false
            if case .local = saved { local = true }
            try? document.jsonData().write(to: directory.appendingPathComponent(SessionManifest.transcriptCacheFile), options: .atomic)
            update(directory) {
                $0.transcription = TranscriptionStatus(state: .done, transcriptPath: saved.url.path, savedLocally: local)
            }
            Log.info("Output: saved \(document.segments.count) lines to \(saved.url.path)")
            if Settings.keepAudioDays == 0 { deleteAudio(directory) }
            if local {
                Notifier.post("Saved locally — OneDrive not found",
                              "\(saved.url.deletingPathExtension().lastPathComponent) will move to OneDrive when it's available.")
            } else {
                Notifier.post("Transcript saved", saved.url.deletingPathExtension().lastPathComponent)
            }
        } catch {
            Log.error("Output: couldn't save \(manifest.id): \(error.localizedDescription)")
            Notifier.post("Couldn't save transcript", error.localizedDescription)
        }
    }

    /// Re-renders a saved transcript with edited metadata, renaming it if the title or date changed.
    private func rewrite(_ directory: URL, manifest: SessionManifest) {
        guard var document = loadDocument(directory, manifest: manifest), let meeting = manifest.meeting else {
            Log.error("Metadata: no transcript found to update for \(manifest.id)")
            return
        }
        document.meeting = meeting
        do {
            let existing = manifest.transcription?.transcriptPath.map { URL(fileURLWithPath: $0) }
            let saved = try output.rewrite(markdown: TranscriptBuilder.markdown(document), json: try document.jsonData(),
                                           baseName: baseName(meeting), existing: existing, sessionID: manifest.id)
            try? document.jsonData().write(to: directory.appendingPathComponent(SessionManifest.transcriptCacheFile), options: .atomic)
            var local = false
            if case .local = saved { local = true }
            update(directory) {
                $0.transcription?.transcriptPath = saved.url.path
                $0.transcription?.savedLocally = local
            }
            Log.info("Metadata: updated transcript \(saved.url.lastPathComponent)")
        } catch {
            Log.error("Metadata: couldn't update \(manifest.id): \(error.localizedDescription)")
            Notifier.post("Couldn't update transcript", error.localizedDescription)
        }
    }

    // MARK: Helpers

    /// The meeting shown in the dialog before the user edits it.
    static func initialMeeting(_ manifest: SessionManifest, samples: Int = 0) -> MeetingMetadata {
        if let meeting = manifest.meeting { return meeting }
        let end = manifest.endDate ?? manifest.startDate.addingTimeInterval(manifest.wallDuration ?? Double(samples) / 16_000)
        var meeting = MeetingMetadata(title: MetadataPrefill.title(calendarTitle: nil, windowTitle: manifest.windowTitle),
                                      recordedStart: manifest.startDate, recordedEnd: end)
        meeting.participants = manifest.detectedParticipants ?? []
        return meeting
    }

    /// The cached document, or (for transcripts saved before the cache existed) the .json next to the saved .md.
    func loadDocument(_ directory: URL, manifest: SessionManifest) -> TranscriptDocument? {
        if let data = try? Data(contentsOf: directory.appendingPathComponent(SessionManifest.transcriptCacheFile)),
           let document = try? TranscriptDocument.decode(data) {
            return document
        }
        guard let md = manifest.transcription?.transcriptPath.map({ URL(fileURLWithPath: $0) }) else { return nil }
        let base = md.deletingPathExtension().lastPathComponent
        let candidates = [md.deletingLastPathComponent().appendingPathComponent("\(base).json"),
                          md.deletingLastPathComponent().appendingPathComponent(OneDriveLocator.dataSubfolder).appendingPathComponent("\(base).json")]
        for url in candidates {
            if let data = try? Data(contentsOf: url), let document = try? TranscriptDocument.decode(data) { return document }
        }
        return nil
    }

    private func baseName(_ meeting: MeetingMetadata) -> String {
        FileNaming.baseName(title: meeting.title, date: meeting.recordedStart)
    }

    private func hasAudio(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("me.wav").path)
    }

    private func refreshFailed() {
        state.failedTranscriptions = failedSessions.count
    }

    private func update(_ directory: URL, _ change: (inout SessionManifest) -> Void) {
        guard var manifest = try? ManifestStore.load(from: directory) else { return }
        change(&manifest)
        try? ManifestStore.save(manifest, in: directory)
        NotificationCenter.default.post(name: .sessionChanged, object: directory)
    }

    /// Deletes only the WAV files; session.json and the transcript cache stay for Recent recordings.
    private func deleteAudio(_ directory: URL) {
        for name in ["me.wav", "others.wav"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        Log.info("Audio deleted for \(directory.lastPathComponent)")
    }

    private func deleteSession(_ directory: URL) {
        // Only ever a session folder this app created under Recordings.
        guard directory.deletingLastPathComponent().standardizedFileURL == Paths.recordings.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: directory)
        Log.info("Recording discarded: \(directory.lastPathComponent)")
        NotificationCenter.default.post(name: .sessionChanged, object: directory)
    }

    private func purgeExpiredAudio() {
        let cutoff = Date().addingTimeInterval(-Double(Settings.keepAudioDays) * 86_400)
        for (directory, manifest) in ManifestStore.allSessions(in: Paths.recordings)
        where manifest.transcription?.state == .done && hasAudio(directory) && (manifest.endDate ?? manifest.startDate) < cutoff {
            deleteAudio(directory)
        }
    }
}

extension Notification.Name {
    /// A session's manifest changed (object: its folder URL).
    static let sessionChanged = Notification.Name("CallScribeSessionChanged")
}
