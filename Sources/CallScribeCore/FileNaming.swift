import Foundation

/// "<Meeting Title> - YYYY-MM-DD HHMM.md", safe for macOS and OneDrive.
public enum FileNaming {
    public static let maxTitleLength = 80
    public static let defaultTitle = "Ad hoc call"

    public static func sanitizedTitle(_ title: String) -> String {
        // / : \ * ? " < > | and control characters are invalid in OneDrive or macOS file names.
        let invalid = CharacterSet(charactersIn: "/:\\*?\"<>|").union(.controlCharacters).union(.newlines)
        let replaced = String(title.unicodeScalars.map { invalid.contains($0) ? " " : Character($0) })
        var cleaned = replaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if cleaned.count > maxTitleLength {
            cleaned = String(cleaned.prefix(maxTitleLength))
        }
        // Leading dots make hidden files; trailing dots and spaces are invalid on OneDrive.
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return cleaned.isEmpty ? defaultTitle : cleaned
    }

    public static func baseName(title: String, date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "\(sanitizedTitle(title)) - \(formatter.string(from: date))"
    }

    /// `base.ext`, or `base (2).ext`, `base (3).ext`… for the first name that doesn't exist yet.
    public static func uniqueURL(in directory: URL, base: String, ext: String,
                                 exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var number = 2
        while exists(candidate) {
            candidate = directory.appendingPathComponent("\(base) (\(number)).\(ext)")
            number += 1
        }
        return candidate
    }
}

/// Finds OneDrive folders under ~/Library/CloudStorage (e.g. "OneDrive-Contoso", "OneDrive-Personal").
public enum OneDriveLocator {
    public static let transcriptsSubfolder = "Call Transcripts"
    public static let dataSubfolder = ".data"

    public static func candidates(in cloudStorage: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: cloudStorage, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { $0.lastPathComponent.hasPrefix("OneDrive") }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Work/school accounts first: they're the ones meeting transcripts belong in.
    public static func preferred(_ candidates: [URL]) -> URL? {
        candidates.first { !$0.lastPathComponent.localizedCaseInsensitiveContains("personal") } ?? candidates.first
    }
}
