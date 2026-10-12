import Foundation

/// Parsing and formatting for the metadata dialog's free-text fields.
public enum PeopleField {
    /// "Jane Smith (jane@contoso.com), bo@contoso.com, Ana <ana@contoso.com>" → people.
    /// Existing people (e.g. from the calendar) are matched by display text so their RSVP is kept.
    public static func parse(_ text: String, keeping existing: [Person] = []) -> [Person] {
        splitList(text).map { token in
            if let match = existing.first(where: { $0.display.caseInsensitiveCompare(token) == .orderedSame }) {
                return match
            }
            return person(from: token)
        }
    }

    public static func format(_ people: [Person]) -> String {
        people.map(\.display).joined(separator: ", ")
    }

    public static func person(from token: String) -> Person {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        for (open, close) in [("(", ")"), ("<", ">")] {
            if let start = trimmed.lastIndex(of: Character(open)), trimmed.hasSuffix(close) {
                let email = String(trimmed[trimmed.index(after: start)..<trimmed.index(before: trimmed.endIndex)])
                    .trimmingCharacters(in: .whitespaces)
                if email.contains("@") {
                    return Person(name: String(trimmed[..<start]).trimmingCharacters(in: .whitespaces), email: email)
                }
            }
        }
        if trimmed.contains("@"), !trimmed.contains(" ") {
            return Person(name: "", email: trimmed)
        }
        return Person(name: trimmed)
    }

    /// Splits on commas and semicolons, trims, drops empties and case-insensitive duplicates.
    public static func splitList(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

public enum TagField {
    public static func parse(_ text: String) -> [String] {
        PeopleField.splitList(text)
    }

    /// Past tags matching the word being typed (after the last comma), most-used first,
    /// excluding tags already entered.
    public static func suggestions(for text: String, from history: [String: Int], limit: Int = 6) -> [String] {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        let current = (parts.last.map(String.init) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let entered = Set(parts.dropLast().map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        return history
            .filter { !entered.contains($0.key.lowercased()) }
            .filter { current.isEmpty || $0.key.lowercased().hasPrefix(current) }
            .filter { $0.key.lowercased() != current }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.lowercased() < $1.key.lowercased() }
            .prefix(limit)
            .map(\.key)
    }

    /// Replaces the word being typed with `tag` and leaves the cursor ready for the next one.
    public static func complete(_ text: String, with tag: String) -> String {
        var parts = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.isEmpty { parts = [""] }
        parts[parts.count - 1] = tag
        return parts.filter { !$0.isEmpty }.joined(separator: ", ") + ", "
    }

    /// Tag → number of recordings it was used on.
    public static func history(from meetings: [MeetingMetadata]) -> [String: Int] {
        var counts: [String: Int] = [:]
        var canonical: [String: String] = [:]
        for tag in meetings.flatMap(\.tags) {
            let key = canonical[tag.lowercased()] ?? tag
            canonical[tag.lowercased()] = key
            counts[key, default: 0] += 1
        }
        return counts
    }
}

public enum MetadataPrefill {
    /// Title precedence: calendar event → Teams call window → "Ad hoc call".
    public static func title(calendarTitle: String?, windowTitle: String?) -> String {
        for candidate in [calendarTitle, windowTitle] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        }
        return FileNaming.defaultTitle
    }

    /// Applies an edited start date, keeping the recording's length.
    public static func moving(_ meeting: MeetingMetadata, toStart start: Date) -> MeetingMetadata {
        var moved = meeting
        let length = meeting.recordedEnd.timeIntervalSince(meeting.recordedStart)
        moved.recordedStart = start
        moved.recordedEnd = start.addingTimeInterval(length)
        return moved
    }
}

extension FileNaming {
    /// Target URL when a transcript is renamed: keeps the current file's URL if the name is unchanged,
    /// otherwise the first free "<base>.ext" / "<base> (2).ext" in the folder (ignoring the current file).
    public static func renameTarget(current: URL, newBase: String, ext: String,
                                    exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let folder = current.deletingLastPathComponent()
        let currentBase = current.deletingPathExtension().lastPathComponent
        if currentBase == newBase || currentBase.hasPrefix(newBase + " (") && currentBase.hasSuffix(")")
            && Int(currentBase.dropFirst(newBase.count + 2).dropLast()) != nil {
            return current
        }
        return uniqueURL(in: folder, base: newBase, ext: ext) { $0.standardizedFileURL != current.standardizedFileURL && exists($0) }
    }
}
