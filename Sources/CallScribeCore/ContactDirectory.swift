import Foundation

/// Email → real name, learned from what you confirm in the details dialog.
/// Stored as JSON (OneDrive/CallScribe/contacts.json) so every Mac shares it.
public struct ContactDirectory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var name: String
        public var updated: Date
    }

    public var schemaVersion = 1
    /// Keyed by lowercased email.
    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    public func name(for email: String) -> String? {
        entries[email.lowercased()]?.name
    }

    /// Records a name for an email. Returns true if it changed anything.
    @discardableResult
    public mutating func learn(email: String, name: String, at date: Date = Date()) -> Bool {
        let key = email.trimmingCharacters(in: .whitespaces).lowercased()
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        guard key.contains("@"), !cleanName.isEmpty, !cleanName.contains("@"),
              entries[key]?.name != cleanName else { return false }
        entries[key] = Entry(name: cleanName, updated: date)
        return true
    }

    /// Later-updated entries win, so two Macs can merge what they each learned.
    public mutating func merge(_ other: ContactDirectory) {
        for (key, entry) in other.entries where (entries[key]?.updated ?? .distantPast) < entry.updated {
            entries[key] = entry
        }
    }

    /// Uses the learned name when there is one (it beats names guessed from the address).
    public func apply(_ person: Person) -> Person {
        guard let email = person.email, let known = name(for: email) else { return person }
        var named = person
        named.name = known
        return named
    }

    public func apply(_ meeting: MeetingMetadata) -> MeetingMetadata {
        var named = meeting
        named.organizer = meeting.organizer.map(apply)
        named.invited = meeting.invited.map(apply)
        named.participants = meeting.participants.map { entry in
            entry.contains("@") ? (name(for: entry) ?? entry) : entry
        }
        return named
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ContactDirectory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ContactDirectory.self, from: data)
    }
}

/// The Participants field for calendar meetings: shows names (emails only when no name is known),
/// and turns edits back into people, learning names typed over email addresses.
public enum ParticipantsEditor {
    /// "Jane Smith, bo@contoso.com" — the name when known, otherwise the email.
    public static func display(_ people: [Person]) -> String {
        people.map { $0.name.isEmpty ? ($0.email ?? "") : $0.name }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    public struct Result: Equatable {
        public var people: [Person]
        /// (email, name) pairs to remember.
        public var learned: [(email: String, name: String)]

        public static func == (a: Result, b: Result) -> Bool {
            a.people == b.people && a.learned.map { "\($0.email)|\($0.name)" } == b.learned.map { "\($0.email)|\($0.name)" }
        }
    }

    /// Parses the edited field against the people it was shown with.
    /// - A token matching an original person (by name, email, or "Name (email)") keeps that person, RSVP included.
    /// - A plain name typed in the same position as an email-only person replaces it and is learned.
    /// - "Name (email)" tokens are new people and are learned.
    public static func parse(_ text: String, original: [Person]) -> Result {
        let tokens = PeopleField.splitList(text)
        var used = Set<Int>()
        var people: [Person] = []
        var learned: [(email: String, name: String)] = []

        func matchIndex(_ token: String) -> Int? {
            original.indices.first { index in
                guard !used.contains(index) else { return false }
                let person = original[index]
                return [person.name, person.email ?? "", person.display].contains { !$0.isEmpty && $0.caseInsensitiveCompare(token) == .orderedSame }
            }
        }

        for (position, token) in tokens.enumerated() {
            if let index = matchIndex(token) {
                used.insert(index)
                people.append(original[index])
                continue
            }
            let typed = PeopleField.person(from: token)
            if let email = typed.email {
                people.append(typed)
                if !typed.name.isEmpty { learned.append((email, typed.name)) }
                continue
            }
            // A plain name where an email-only person used to be: the same person, now named.
            if position < original.count, !used.contains(position),
               let email = original[position].email, original[position].name.isEmpty || original[position].name == NameFromEmail.guess(email),
               !tokens.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) {
                used.insert(position)
                var renamed = original[position]
                renamed.name = typed.name
                people.append(renamed)
                learned.append((email, typed.name))
                continue
            }
            people.append(typed)
        }
        // Calendar invitees confirmed with a name are worth remembering too.
        for person in people {
            if let email = person.email, !person.name.isEmpty, !learned.contains(where: { $0.email.lowercased() == email.lowercased() }) {
                learned.append((email, person.name))
            }
        }
        return Result(people: people, learned: learned)
    }
}
