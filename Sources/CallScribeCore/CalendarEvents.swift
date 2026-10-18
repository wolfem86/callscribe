import Foundation

public struct CalendarEvent: Equatable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var organizer: Person?
    public var attendees: [Person]
    public var location: String?
    public var joinURL: String?
    /// Plain text with the Teams join boilerplate removed.
    public var agenda: String?
    public var isAllDay: Bool

    public init(id: String, title: String, start: Date, end: Date, organizer: Person? = nil, attendees: [Person] = [],
                location: String? = nil, joinURL: String? = nil, agenda: String? = nil, isAllDay: Bool = false) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.organizer = organizer
        self.attendees = attendees
        self.location = location
        self.joinURL = joinURL
        self.agenda = agenda
        self.isAllDay = isAllDay
    }

    public var isTeamsMeeting: Bool { joinURL != nil }

    /// The details dialog's pre-filled values for a recording of this event.
    public func meeting(recordedStart: Date, recordedEnd: Date) -> MeetingMetadata {
        var meeting = MeetingMetadata(title: title, recordedStart: recordedStart, recordedEnd: recordedEnd)
        meeting.scheduledStart = start
        meeting.scheduledEnd = end
        meeting.organizer = organizer
        meeting.invited = attendees
        meeting.location = joinURL ?? location
        meeting.agenda = agenda
        return meeting
    }
}

/// Reads the calendar file a Power Automate flow writes to OneDrive.
///
/// Accepts the raw output of "Get calendar view of events (V3)" (a JSON array, or `{"value": [...]}`),
/// and also Microsoft Graph's event shape, with case-insensitive keys, so small differences between
/// connector versions don't break it.
public enum PowerAutomateCalendar {
    public struct ParseResult: Sendable {
        public var events: [CalendarEvent]
        /// Field names seen in the file (no values), for diagnosing format differences.
        public var fieldsSeen: [String]
        public var skipped: Int
    }

    public static func parse(_ data: Data) throws -> ParseResult {
        let json = try JSONSerialization.jsonObject(with: data)
        let items: [[String: Any]]
        if let array = json as? [[String: Any]] {
            items = array
        } else if let object = json as? [String: Any], let array = lowered(object)["value"] as? [[String: Any]] {
            items = array
        } else if let object = json as? [String: Any], let body = lowered(object)["body"] as? [[String: Any]] {
            items = body
        } else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The calendar file isn't a list of events."])
        }

        var fields = Set<String>()
        var events: [CalendarEvent] = []
        var skipped = 0
        for raw in items {
            fields.formUnion(raw.keys)
            if let event = event(from: lowered(raw)) { events.append(event) } else { skipped += 1 }
        }
        return ParseResult(events: events.sorted { $0.start < $1.start }, fieldsSeen: fields.sorted(), skipped: skipped)
    }

    static func event(from item: [String: Any]) -> CalendarEvent? {
        guard let start = date(item["startwithtimezone"]) ?? date(item["start"], zone: item["timezone"]),
              let end = date(item["endwithtimezone"]) ?? date(item["end"], zone: item["timezone"]) else { return nil }
        let title = (item["subject"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bodyText = text(item["body"])
        let isHTML = (item["ishtml"] as? Bool) ?? (bodyText?.contains("<") ?? false)
        let plainBody = bodyText.map { isHTML ? AgendaCleaner.plainText(fromHTML: $0) : $0 }

        var attendees = people(item["requiredattendees"]) + people(item["optionalattendees"])
        if attendees.isEmpty { attendees = people(item["attendees"]) }
        let organizer = people(item["organizer"]).first

        let joinURL = (item["onlinemeetingurl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (lowered(item["onlinemeeting"] as? [String: Any] ?? [:])["joinurl"] as? String)
            ?? bodyText.flatMap(AgendaCleaner.teamsJoinURL)

        return CalendarEvent(
            id: (item["id"] as? String) ?? (item["icaluid"] as? String) ?? "\(title)-\(start.timeIntervalSince1970)",
            title: title.isEmpty ? "(No title)" : title,
            start: start,
            end: end,
            organizer: organizer,
            attendees: attendees.filter { $0.email?.lowercased() != organizer?.email?.lowercased() || organizer?.email == nil },
            location: text(item["location"]).flatMap { $0.isEmpty ? nil : $0 },
            joinURL: joinURL,
            agenda: plainBody.flatMap(AgendaCleaner.agenda),
            isAllDay: (item["isallday"] as? Bool) ?? false
        )
    }

    // MARK: Field helpers

    static func lowered(_ object: [String: Any]) -> [String: Any] {
        Dictionary(object.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    /// A string, or Graph's {"content": ...} / {"displayName": ...} objects.
    static func text(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let object = value as? [String: Any] {
            let keys = lowered(object)
            return (keys["content"] as? String) ?? (keys["displayname"] as? String)
        }
        return nil
    }

    /// "a@x.com;b@y.com;" strings, or Graph attendee/organizer objects.
    static func people(_ value: Any?) -> [Person] {
        if let string = value as? String {
            return string.split(whereSeparator: { $0 == ";" || $0 == "," })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { token in
                    let person = PeopleField.person(from: token)
                    if person.name.isEmpty, let email = person.email { return Person(name: NameFromEmail.guess(email), email: email) }
                    return person
                }
        }
        let objects = (value as? [[String: Any]]) ?? ((value as? [String: Any]).map { [$0] } ?? [])
        return objects.compactMap { raw in
            let item = lowered(raw)
            let address = lowered(item["emailaddress"] as? [String: Any] ?? item)
            let email = address["address"] as? String
            let name = (address["name"] as? String) ?? ""
            guard email != nil || !name.isEmpty else { return nil }
            let response = lowered(item["status"] as? [String: Any] ?? [:])["response"] as? String
            return Person(name: name.isEmpty ? email.map(NameFromEmail.guess) ?? "" : name, email: email,
                          rsvp: response.flatMap(rsvpLabel))
        }
    }

    static func rsvpLabel(_ response: String) -> String? {
        switch response.lowercased() {
        case "accepted": return "Accepted"
        case "tentativelyaccepted", "tentative": return "Tentative"
        case "declined": return "Declined"
        case "organizer": return "Organizer"
        default: return nil
        }
    }

    /// ISO 8601 with or without an offset or fractional seconds. Without an offset, `zone`
    /// ("UTC", an IANA name, or omitted) decides; Power Automate's plain values are UTC.
    static func date(_ value: Any?, zone: Any? = nil) -> Date? {
        if let object = value as? [String: Any] {
            let keys = lowered(object)
            return date(keys["datetime"], zone: keys["timezone"])
        }
        guard var string = (value as? String)?.trimmingCharacters(in: .whitespaces), !string.isEmpty else { return nil }
        // Trim 7-digit fractions ("…:00.0000000") to milliseconds for the parser.
        if let range = string.range(of: #"\.\d+"#, options: .regularExpression) {
            let digits = string[range].dropFirst()
            string.replaceSubrange(range, with: "." + String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0))
        }
        let hasOffset = string.hasSuffix("Z") || string.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
        if !hasOffset {
            let tz = (zone as? String).flatMap { TimeZone(identifier: $0) } ?? TimeZone(identifier: "UTC")!
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = tz
            for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: string) { return date }
            }
            return nil
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: string)
    }
}

/// Picks the calendar event a recording belongs to.
public enum EventMatcher {
    /// The event overlapping the recording start (or starting within ±15 min of it), preferring
    /// Teams meetings and then the closest start. All-day events are ignored.
    public static func match(_ events: [CalendarEvent], recordingStart: Date, window: TimeInterval = 15 * 60) -> CalendarEvent? {
        let candidates = events.filter { event in
            !event.isAllDay && (
                (event.start <= recordingStart && event.end > recordingStart) ||
                abs(event.start.timeIntervalSince(recordingStart)) <= window
            )
        }
        return candidates.min { a, b in
            if a.isTeamsMeeting != b.isTeamsMeeting { return a.isTeamsMeeting }
            return abs(a.start.timeIntervalSince(recordingStart)) < abs(b.start.timeIntervalSince(recordingStart))
        }
    }
}

public enum AgendaCleaner {
    public static func plainText(fromHTML html: String) -> String {
        var text = html
        for (pattern, replacement) in [
            (#"(?is)<(script|style)[^>]*>.*?</\1>"#, ""),
            (#"(?i)<br\s*/?>"#, "\n"),
            (#"(?i)</(p|div|tr|li|h\d)>"#, "\n"),
            (#"<[^>]+>"#, ""),
        ] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        for (entity, character) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
    }

    /// The description without Teams' "Microsoft Teams meeting / Join on your computer…" block.
    public static func agenda(_ text: String) -> String? {
        var lines: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            // Teams appends its block after a long underscore rule, starting with "Microsoft Teams".
            if line.hasPrefix("____") || lower.hasPrefix("microsoft teams meeting") || lower.hasPrefix("microsoft teams need help")
                || lower.hasPrefix("join the meeting now") || lower.hasPrefix("join on your computer") {
                break
            }
            lines.append(line)
        }
        let collapsed = lines.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    public static func teamsJoinURL(in text: String) -> String? {
        guard let range = text.range(of: #"https://teams\.(microsoft|live)\.com/(l/meetup-join|meet)/[^\s"'<>]+"#, options: .regularExpression) else {
            return nil
        }
        return String(text[range]).replacingOccurrences(of: "&amp;", with: "&")
    }
}

public enum NameFromEmail {
    /// "jane.smith@contoso.com" → "Jane Smith"; "" when the address doesn't contain a first and last name.
    public static func guess(_ email: String) -> String {
        let local = email.split(separator: "@").first.map(String.init) ?? email
        let parts = local.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" }).filter { !$0.allSatisfy(\.isNumber) }
        guard parts.count >= 2 else { return "" }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }
}

/// Reads meeting names out of Microsoft Teams window titles.
public enum TeamsWindowTitle {
    /// Main-window views, never a meeting name.
    static let views: Set<String> = ["chat", "activity", "calendar", "teams", "calls", "files", "apps", "onedrive",
                                     "communities", "microsoft teams", "search", "meet", "copilot", "people", "home"]

    /// The meeting or call name from one window title, or nil for main-window or generic titles.
    /// e.g. "Weekly sync | Microsoft Teams" → "Weekly sync"; "Chat | Jane Smith | Contoso | me@contoso.com | Microsoft Teams" → nil.
    public static func meetingName(from title: String) -> String? {
        var parts = title.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.last?.lowercased().hasPrefix("microsoft teams") == true { parts.removeLast() }
        guard !parts.isEmpty, !views.contains(parts[0].lowercased()) else { return nil }
        // The main window lists view, context, org, and your email; a meeting window is just its name.
        guard !parts.contains(where: { $0.contains("@") }), parts.count <= 2 else { return nil }
        let name = parts[0]
        guard name.count >= 2, !views.contains(name.lowercased()) else { return nil }
        return name
    }

    /// "Call with Jane Smith" / "Meeting with Jane Smith" → ["Jane Smith"].
    public static func participants(fromMeetingName name: String) -> [String] {
        for prefix in ["call with ", "meeting with ", "chat with "] where name.lowercased().hasPrefix(prefix) {
            return PeopleField.splitList(String(name.dropFirst(prefix.count)).replacingOccurrences(of: " and ", with: ", "))
        }
        return []
    }

    /// The best meeting name among all Teams window titles (the first that isn't a main window).
    public static func bestMeetingName(from titles: [String]) -> String? {
        titles.lazy.compactMap(meetingName(from:)).first
    }
}
