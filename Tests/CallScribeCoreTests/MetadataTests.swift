import Foundation
import Testing
@testable import CallScribeCore

@Suite struct PeopleFieldTests {
    @Test func parsesNamesAndEmails() {
        let people = PeopleField.parse("Jane Smith (jane@contoso.com), bo@contoso.com; Ana Ruiz <ana@contoso.com>, Sam, sam")
        #expect(people == [
            Person(name: "Jane Smith", email: "jane@contoso.com"),
            Person(name: "", email: "bo@contoso.com"),
            Person(name: "Ana Ruiz", email: "ana@contoso.com"),
            Person(name: "Sam"),
        ])
    }

    @Test func keepsCalendarRSVPForUnchangedPeople() {
        let invited = [Person(name: "Bo Li", email: "bo@contoso.com", rsvp: "Accepted")]
        let parsed = PeopleField.parse(PeopleField.format(invited) + ", New Person", keeping: invited)
        #expect(parsed.first?.rsvp == "Accepted")
        #expect(parsed.last == Person(name: "New Person"))
    }

    @Test func formatRoundTrips() {
        let people = [Person(name: "Jane Smith", email: "jane@contoso.com"), Person(name: "Sam")]
        #expect(PeopleField.parse(PeopleField.format(people)) == people)
    }
}

@Suite struct TagFieldTests {
    let history = ["planning": 5, "Q4": 3, "product": 2, "people": 1]

    @Test func suggestsByPrefixAndUsage() {
        #expect(TagField.suggestions(for: "p", from: history) == ["planning", "product", "people"])
        #expect(TagField.suggestions(for: "planning, q", from: history) == ["Q4"])
        #expect(TagField.suggestions(for: "planning, ", from: history) == ["Q4", "product", "people"])
        #expect(TagField.suggestions(for: "planning", from: history).isEmpty)  // exact match: nothing to add
    }

    @Test func completesCurrentWord() {
        #expect(TagField.complete("planning, pro", with: "product") == "planning, product, ")
        #expect(TagField.complete("", with: "Q4") == "Q4, ")
    }

    @Test func historyMergesCase() {
        let meetings = [["Q4", "planning"], ["q4"], []].map { tags -> MeetingMetadata in
            var m = MeetingMetadata(title: "x", recordedStart: Date(), recordedEnd: Date())
            m.tags = tags
            return m
        }
        #expect(TagField.history(from: meetings) == ["Q4": 2, "planning": 1])
    }
}

@Suite struct PrefillAndRenameTests {
    @Test func titlePrecedence() {
        #expect(MetadataPrefill.title(calendarTitle: "Weekly sync", windowTitle: "Call with Jane") == "Weekly sync")
        #expect(MetadataPrefill.title(calendarTitle: "  ", windowTitle: "Call with Jane") == "Call with Jane")
        #expect(MetadataPrefill.title(calendarTitle: nil, windowTitle: nil) == "Ad hoc call")
    }

    @Test func movingStartKeepsLength() {
        let start = Date(timeIntervalSince1970: 1_000)
        let meeting = MeetingMetadata(title: "x", recordedStart: start, recordedEnd: start.addingTimeInterval(600))
        let moved = MetadataPrefill.moving(meeting, toStart: start.addingTimeInterval(3_600))
        #expect(moved.recordedEnd.timeIntervalSince(moved.recordedStart) == 600)
    }

    @Test func renameTargets() {
        let current = URL(fileURLWithPath: "/t/Ad hoc call - 2026-10-11 0923.md")
        // Same name, or same name with an existing counter: keep the file where it is.
        #expect(FileNaming.renameTarget(current: current, newBase: "Ad hoc call - 2026-10-11 0923", ext: "md") { _ in true } == current)
        let numbered = URL(fileURLWithPath: "/t/Sync - 2026-10-11 0923 (2).md")
        #expect(FileNaming.renameTarget(current: numbered, newBase: "Sync - 2026-10-11 0923", ext: "md") { _ in true } == numbered)
        // New name that's taken: next free counter.
        let taken: Set<String> = ["/t/Sync - 2026-10-11 0923.md"]
        let target = FileNaming.renameTarget(current: current, newBase: "Sync - 2026-10-11 0923", ext: "md") { taken.contains($0.path) }
        #expect(target.lastPathComponent == "Sync - 2026-10-11 0923 (2).md")
    }
}
