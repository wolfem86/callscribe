import AppKit
import CallScribeCore
import Foundation

/// Saves transcripts. Only transcripts go to OneDrive; audio never does.
///
/// Files are written to a local staging folder first and then moved into place (JSON first,
/// Markdown last), so OneDrive never syncs a half-written file. If OneDrive isn't available,
/// they wait in a local outbox and move once it's back.
final class OutputManager {
    enum SaveResult {
        case oneDrive(URL)
        case local(URL)

        var url: URL {
            switch self {
            case .oneDrive(let url), .local(let url): return url
            }
        }
    }

    static var stagingRoot: URL { Paths.appSupport.appendingPathComponent("Staging", isDirectory: true) }
    static var outboxRoot: URL { Paths.appSupport.appendingPathComponent("Outbox", isDirectory: true) }
    static var cloudStorage: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage", isDirectory: true)
    }

    private let fm = FileManager.default

    // MARK: Folder

    /// The transcripts folder if it's available right now. On first use, auto-detects OneDrive
    /// (asking which one if there are several) and creates "Call Transcripts".
    func transcriptsFolder(allowPrompt: Bool) -> URL? {
        if let folder = Settings.transcriptsFolder {
            // A configured folder that's missing means OneDrive is unavailable; don't silently pick another.
            return isWritableDirectory(folder) ? folder : nil
        }
        let candidates = OneDriveLocator.candidates(in: Self.cloudStorage)
        let oneDrive: URL?
        switch candidates.count {
        case 0: oneDrive = nil
        case 1: oneDrive = candidates[0]
        default: oneDrive = allowPrompt ? pickOneDrive(candidates) : nil
        }
        guard let oneDrive else { return nil }
        let folder = oneDrive.appendingPathComponent(OneDriveLocator.transcriptsSubfolder, isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Log.error("Output: couldn't create \(folder.path): \(error.localizedDescription)")
            return nil
        }
        Settings.transcriptsFolder = folder
        Log.info("Output: transcripts folder set to \(folder.path)")
        return folder
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose where CallScribe saves transcripts (usually OneDrive → Call Transcripts)."
        panel.directoryURL = Settings.transcriptsFolder ?? OneDriveLocator.preferred(OneDriveLocator.candidates(in: Self.cloudStorage)) ?? Self.cloudStorage
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Settings.transcriptsFolder = url
        Log.info("Output: transcripts folder changed to \(url.path)")
        _ = flushOutbox()
    }

    private func pickOneDrive(_ candidates: [URL]) -> URL? {
        let alert = NSAlert()
        alert.messageText = "Which OneDrive should CallScribe save transcripts to?"
        alert.informativeText = "A \"\(OneDriveLocator.transcriptsSubfolder)\" folder will be created there. You can change this later in Settings."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        popup.addItems(withTitles: candidates.map(\.lastPathComponent))
        if let preferred = OneDriveLocator.preferred(candidates), let index = candidates.firstIndex(of: preferred) {
            popup.selectItem(at: index)
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Use This OneDrive")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? candidates[popup.indexOfSelectedItem] : nil
    }

    private func isWritableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue && fm.isWritableFile(atPath: url.path)
    }

    // MARK: Save

    func save(markdown: String, json: Data, baseName: String, sessionID: String) throws -> SaveResult {
        let staging = Self.stagingRoot.appendingPathComponent(sessionID, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let stagedMD = staging.appendingPathComponent("\(baseName).md")
        let stagedJSON = staging.appendingPathComponent("\(baseName).json")
        try Data(markdown.utf8).write(to: stagedMD, options: .atomic)
        try json.write(to: stagedJSON, options: .atomic)

        if let folder = transcriptsFolder(allowPrompt: true) {
            let url = try moveIntoFolder(md: stagedMD, json: stagedJSON, baseName: baseName, folder: folder)
            try? fm.removeItem(at: staging)
            return .oneDrive(url)
        }

        let outbox = Self.outboxRoot.appendingPathComponent(sessionID, isDirectory: true)
        try fm.createDirectory(at: outbox, withIntermediateDirectories: true)
        let localMD = outbox.appendingPathComponent(stagedMD.lastPathComponent)
        try? fm.removeItem(at: localMD)
        try? fm.removeItem(at: outbox.appendingPathComponent(stagedJSON.lastPathComponent))
        try fm.moveItem(at: stagedJSON, to: outbox.appendingPathComponent(stagedJSON.lastPathComponent))
        try fm.moveItem(at: stagedMD, to: localMD)
        try? fm.removeItem(at: staging)
        Log.warn("Output: OneDrive not available; saved \(localMD.lastPathComponent) locally")
        return .local(localMD)
    }

    /// Replaces an already-saved transcript with re-rendered content, renaming the .md and .json when the
    /// title or date changed. If the old file is gone (moved or deleted in OneDrive), saves a new one.
    func rewrite(markdown: String, json: Data, baseName: String, existing: URL?, sessionID: String) throws -> SaveResult {
        guard let existing, fm.fileExists(atPath: existing.path) else {
            return try save(markdown: markdown, json: json, baseName: baseName, sessionID: sessionID)
        }
        let folder = existing.deletingLastPathComponent()
        let inOutbox = folder.standardizedFileURL.path.hasPrefix(Self.outboxRoot.standardizedFileURL.path)
        let jsonFolder = inOutbox ? folder : folder.appendingPathComponent(OneDriveLocator.dataSubfolder, isDirectory: true)
        let oldBase = existing.deletingPathExtension().lastPathComponent
        let target = FileNaming.renameTarget(current: existing, newBase: baseName, ext: "md")
        let newBase = target.deletingPathExtension().lastPathComponent

        // Stage both files, then swap them in: JSON first, Markdown last.
        let staging = Self.stagingRoot.appendingPathComponent(sessionID, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let stagedMD = staging.appendingPathComponent("\(newBase).md")
        let stagedJSON = staging.appendingPathComponent("\(newBase).json")
        try Data(markdown.utf8).write(to: stagedMD, options: .atomic)
        try json.write(to: stagedJSON, options: .atomic)

        try fm.createDirectory(at: jsonFolder, withIntermediateDirectories: true)
        try place(stagedJSON, at: jsonFolder.appendingPathComponent("\(newBase).json"),
                  replacing: jsonFolder.appendingPathComponent("\(oldBase).json"))
        try place(stagedMD, at: target, replacing: existing)
        try? fm.removeItem(at: staging)
        if target != existing { Log.info("Output: renamed \(existing.lastPathComponent) → \(target.lastPathComponent)") }
        return inOutbox ? .local(target) : .oneDrive(target)
    }

    /// Moves `staged` to `destination`, replacing it atomically if it exists, and removes `old` when renamed.
    private func place(_ staged: URL, at destination: URL, replacing old: URL) throws {
        if destination.standardizedFileURL == old.standardizedFileURL, fm.fileExists(atPath: old.path) {
            _ = try fm.replaceItemAt(old, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: destination)
            if fm.fileExists(atPath: old.path) { try fm.removeItem(at: old) }
        }
    }

    /// Moves transcripts waiting in the outbox into the transcripts folder. Returns (sessionID, new .md URL) pairs.
    func flushOutbox() -> [(String, URL)] {
        let items = (try? fm.contentsOfDirectory(at: Self.outboxRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        guard !items.isEmpty, let folder = transcriptsFolder(allowPrompt: false) else { return [] }
        var moved: [(String, URL)] = []
        for item in items {
            let files = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
            guard let md = files.first(where: { $0.pathExtension == "md" }) else { continue }
            let base = md.deletingPathExtension().lastPathComponent
            let json = item.appendingPathComponent("\(base).json")
            do {
                let url = try moveIntoFolder(md: md, json: fm.fileExists(atPath: json.path) ? json : nil, baseName: base, folder: folder)
                try? fm.removeItem(at: item)
                moved.append((item.lastPathComponent, url))
                Log.info("Output: moved \(url.lastPathComponent) from the local outbox to OneDrive")
            } catch {
                Log.error("Output: couldn't move \(md.lastPathComponent) to OneDrive: \(error.localizedDescription)")
            }
        }
        return moved
    }

    private func moveIntoFolder(md: URL, json: URL?, baseName: String, folder: URL) throws -> URL {
        let target = FileNaming.uniqueURL(in: folder, base: baseName, ext: "md")
        let finalBase = target.deletingPathExtension().lastPathComponent
        if let json {
            let dataFolder = folder.appendingPathComponent(OneDriveLocator.dataSubfolder, isDirectory: true)
            try fm.createDirectory(at: dataFolder, withIntermediateDirectories: true)
            let jsonTarget = FileNaming.uniqueURL(in: dataFolder, base: finalBase, ext: "json")
            try fm.moveItem(at: json, to: jsonTarget)
        }
        try fm.moveItem(at: md, to: target)
        return target
    }
}
