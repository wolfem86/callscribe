import AppKit
import CallScribeCore
import Combine

/// The menu bar item: icon state, optional pulse and elapsed time, and the menu.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let state: AppState
    private let recorder: RecorderController
    private let testSetup: TestSetupWindowController
    private let models: ModelManager
    private let pipeline: TranscriptionPipeline
    private let output: OutputManager
    private var cancellables = Set<AnyCancellable>()
    private var animationTimer: Timer?
    /// Opens the details dialog for a past recording.
    var onOpenRecording: ((URL) -> Void)?

    init(state: AppState, recorder: RecorderController, testSetup: TestSetupWindowController,
         models: ModelManager, pipeline: TranscriptionPipeline, output: OutputManager) {
        self.state = state
        self.recorder = recorder
        self.testSetup = testSetup
        self.models = models
        self.pipeline = pipeline
        self.output = output
        super.init()
        item.button?.imagePosition = .imageLeading
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    // MARK: Icon

    private var iconKind: MenuBarIcon.Kind {
        switch state.phase {
        case .idle: return state.hasWarning ? .warning : (state.isProcessing ? .processing : .idle)
        case .processing: return .processing
        case .paused: return .paused
        case .recording: return state.hasWarning ? .recordingWarning : .recording
        }
    }

    func refresh() {
        guard let button = item.button else { return }
        button.image = MenuBarIcon.image(iconKind)
        button.setAccessibilityLabel(accessibilityText)

        let needsTimer = state.isActive && (Settings.showElapsed || pulseActive)
        if needsTimer, animationTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.animate() }
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        } else if !needsTimer {
            animationTimer?.invalidate()
            animationTimer = nil
        }
        animate()
    }

    private var pulseActive: Bool {
        state.phase == .recording && Settings.pulseEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func animate() {
        guard let button = item.button else { return }
        if pulseActive {
            // Very slow, subtle breathing: 5 s period between 55% and 100% opacity.
            let t = Date().timeIntervalSinceReferenceDate
            button.alphaValue = CGFloat(0.775 + 0.225 * cos(2 * .pi * t / 5))
        } else {
            button.alphaValue = 1
        }
        if state.isActive, Settings.showElapsed, let startedAt = state.startedAt {
            button.title = " " + RecordingSession.format(Date().timeIntervalSince(startedAt))
        } else if !button.title.isEmpty {
            button.title = ""
        }
    }

    private var accessibilityText: String {
        switch state.phase {
        case .idle: return "CallScribe"
        case .recording: return state.hasWarning ? "CallScribe: recording, with a warning" : "CallScribe: recording"
        case .paused: return "CallScribe: paused"
        case .processing: return "CallScribe: processing"
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let active = state.isActive && !state.isTesting

        let startStop = add(menu, active ? "Stop Recording" : "Start Recording", #selector(toggleRecording), key: "r")
        startStop.keyEquivalentModifierMask = [.control, .option]
        startStop.isEnabled = !state.isTesting
        let pause = add(menu, state.phase == .paused ? "Resume" : "Pause", #selector(togglePause), key: "p")
        pause.keyEquivalentModifierMask = [.control, .option]
        pause.isEnabled = active

        if active {
            menu.addItem(.separator())
            addInfo(menu, (state.micOK ? "Me: " : "⚠︎ Me: ") + state.micStatus)
            addInfo(menu, (state.callOK ? "Others: " : "⚠︎ Others: ") + state.callStatus)
            add(menu, recorder.levelsWindow.isVisible ? "Hide Levels Window" : "Show Levels Window", #selector(toggleLevels))
        }

        menu.addItem(.separator())
        if state.isProcessing { addInfo(menu, "Transcribing…") }
        if models.readyFolder == nil {
            addInfo(menu, models.statusText)
            if case .downloading = models.status {} else { add(menu, "Download Speech Model", #selector(downloadModel)) }
        }
        let failed = pipeline.failedSessions
        if !failed.isEmpty {
            let retry = NSMenuItem(title: "Retry Transcription", action: nil, keyEquivalent: "")
            let retryMenu = NSMenu()
            for (directory, manifest) in failed {
                let item = add(retryMenu, Self.sessionTitle(manifest), #selector(retryTranscription(_:)))
                item.representedObject = directory
                item.toolTip = manifest.transcription?.error
            }
            retry.submenu = retryMenu
            menu.addItem(retry)
        }
        let recent = pipeline.recentSessions()
        let recentItem = NSMenuItem(title: "Recent Recordings", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        if recent.isEmpty {
            addInfo(recentMenu, "No recordings yet")
        }
        for (directory, manifest) in recent {
            var title = Self.sessionTitle(manifest)
            if manifest.transcription?.state != .done { title += manifest.metadataConfirmed == true ? " (transcribing)" : " (needs details)" }
            add(recentMenu, title, #selector(openRecording(_:))).representedObject = directory
        }
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)
        add(menu, "Open Transcripts Folder", #selector(openTranscripts))

        menu.addItem(.separator())
        add(menu, "Test Setup…", #selector(showTestSetup)).isEnabled = !state.isActive
        add(menu, "Open Recordings Folder", #selector(openRecordings))
        add(menu, "View Log", #selector(viewLog))
        menu.addItem(settingsItem())

        menu.addItem(.separator())
        addInfo(menu, "CallScribe \(Paths.appVersion)")
        add(menu, "Quit CallScribe", #selector(quit), key: "q")
    }

    private func settingsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        toggle(menu, "Pulse Icon While Recording", Settings.pulseEnabled, #selector(togglePulse))
        toggle(menu, "Show Elapsed Time", Settings.showElapsed, #selector(toggleElapsed))
        toggle(menu, "Open Levels Window When Recording", Settings.showLevelsOnStart, #selector(toggleLevelsOnStart))
        toggle(menu, "Mic Voice Processing", Settings.voiceProcessing, #selector(toggleVoiceProcessing))

        let folderName = Settings.transcriptsFolder?.lastPathComponent ?? "not set"
        add(menu, "Transcripts Folder (\(folderName))…", #selector(chooseTranscriptsFolder))

        let keepItem = NSMenuItem(title: "Keep Audio Locally", action: nil, keyEquivalent: "")
        let keepMenu = NSMenu()
        for days in [0, 1, 7, 30] {
            let title = days == 0 ? "Delete After Transcribing" : "\(days) Day\(days == 1 ? "" : "s")"
            toggle(keepMenu, title, Settings.keepAudioDays == days, #selector(selectKeepAudio(_:))).tag = days
        }
        keepItem.submenu = keepMenu
        menu.addItem(keepItem)

        let sourceItem = NSMenuItem(title: "Call Audio Source", action: nil, keyEquivalent: "")
        let sourceMenu = NSMenu()
        for mode in CallSourceMode.allCases {
            let option = toggle(sourceMenu, mode.title, Settings.callSourceMode == mode, #selector(selectCallSource(_:)))
            option.representedObject = mode.rawValue
        }
        sourceItem.submenu = sourceMenu
        menu.addItem(sourceItem)

        item.submenu = menu
        return item
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    @discardableResult
    private func toggle(_ menu: NSMenu, _ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let item = add(menu, title, action)
        item.state = on ? .on : .off
        return item
    }

    private func addInfo(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    // MARK: Actions

    @objc private func toggleRecording() { recorder.toggleRecording() }
    @objc private func togglePause() { recorder.togglePause() }
    @objc private func toggleLevels() { recorder.levelsWindow.toggle() }
    @objc private func toggleLevelsOnStart() { Settings.showLevelsOnStart.toggle() }
    @objc private func showTestSetup() { testSetup.show() }
    @objc private func openRecordings() { NSWorkspace.shared.open(Paths.recordings) }
    @objc private func viewLog() { NSWorkspace.shared.open(Log.fileURL) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func downloadModel() { models.ensureModel() }
    @objc private func chooseTranscriptsFolder() { output.chooseFolder() }

    @objc private func openTranscripts() {
        if let folder = output.transcriptsFolder(allowPrompt: true) {
            NSWorkspace.shared.open(folder)
        } else {
            NSWorkspace.shared.open(OutputManager.outboxRoot)
        }
    }

    @objc private func openRecording(_ sender: NSMenuItem) {
        guard let directory = sender.representedObject as? URL else { return }
        onOpenRecording?(directory)
    }

    @objc private func retryTranscription(_ sender: NSMenuItem) {
        guard let directory = sender.representedObject as? URL else { return }
        pipeline.enqueue(directory)
    }

    @objc private func selectKeepAudio(_ sender: NSMenuItem) {
        Settings.keepAudioDays = sender.tag
        Log.info("Settings: keep audio \(sender.tag) days")
    }

    static func sessionTitle(_ manifest: SessionManifest) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(manifest.meeting?.title ?? FileNaming.defaultTitle) — \(formatter.string(from: manifest.startDate))"
    }

    @objc private func togglePulse() { Settings.pulseEnabled.toggle(); refresh() }
    @objc private func toggleElapsed() { Settings.showElapsed.toggle(); refresh() }

    @objc private func toggleVoiceProcessing() {
        Settings.voiceProcessing.toggle()
        Log.info("Settings: voice processing \(Settings.voiceProcessing ? "on" : "off") (applies to the next recording)")
    }

    @objc private func selectCallSource(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = CallSourceMode(rawValue: raw) else { return }
        Settings.callSourceMode = mode
        Log.info("Settings: call audio source = \(mode.rawValue)")
    }
}
