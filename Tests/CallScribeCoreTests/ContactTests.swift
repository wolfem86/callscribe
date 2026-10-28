import Foundation
import Testing
@testable import CallScribeCore

@Suite struct ContactDirectoryTests {
    @Test func learnsAndApplies() {
        var directory = ContactDirectory()
        let first = directory.learn(email: "JSmith@Contoso.com", name: "Jane Smith")
        let repeated = directory.learn(email: "jsmith@contoso.com", name: "Jane Smith")  // unchanged
        let notEmail = directory.learn(email: "not-an-email", name: "X")
        let emailAsName = directory.learn(email: "a@b.com", name: "a@b.com")
        #expect(first && !repeated && !notEmail && !emailAsName)
        #expect(directory.apply(Person(name: "", email: "jsmith@contoso.com")).name == "Jane Smith")
        // Learned names beat guesses from the address.
        #expect(directory.apply(Person(name: "Jsmith", email: "jsmith@contoso.com")).name == "Jane Smith")

        var meeting = MeetingMetadata(title: "x", recordedStart: Date(), recordedEnd: Date())
        meeting.organizer = Person(name: "", email: "jsmith@contoso.com")
        meeting.participants = ["jsmith@contoso.com", "Bo"]
        let named = directory.apply(meeting)
        #expect(named.organizer?.name == "Jane Smith")
        #expect(named.participants == ["Jane Smith", "Bo"])
    }

    @Test func mergeKeepsNewest() {
        var a = ContactDirectory(), b = ContactDirectory()
        a.learn(email: "x@c.com", name: "Old", at: Date(timeIntervalSince1970: 1))
        b.learn(email: "x@c.com", name: "New", at: Date(timeIntervalSince1970: 2))
        b.learn(email: "y@c.com", name: "Yan", at: Date(timeIntervalSince1970: 2))
        a.merge(b)
        #expect(a.name(for: "x@c.com") == "New")
        #expect(a.name(for: "y@c.com") == "Yan")
        b.merge(a)
        #expect(b == a)
    }

    @Test func roundTrips() throws {
        var directory = ContactDirectory()
        directory.learn(email: "x@c.com", name: "Xi", at: Date(timeIntervalSince1970: 100))
        #expect(try ContactDirectory.decode(directory.jsonData()) == directory)
    }
}

@Suite struct ParticipantsEditorTests {
    let original = [
        Person(name: "", email: "jsmith@contoso.com", rsvp: "Accepted"),
        Person(name: "Bo Li", email: "bo.li@contoso.com"),
        Person(name: "", email: "ana@contoso.com"),
    ]

    @Test func showsNamesWhenKnown() {
        #expect(ParticipantsEditor.display(original) == "jsmith@contoso.com, Bo Li, ana@contoso.com")
    }

    @Test func unchangedFieldKeepsPeople() {
        let result = ParticipantsEditor.parse(ParticipantsEditor.display(original), original: original)
        #expect(result.people == original)
        #expect(result.learned.map(\.email) == ["bo.li@contoso.com"])  // confirmed name with an email
    }

    @Test func nameTypedOverEmailIsLearnedAndKeepsRSVP() {
        let result = ParticipantsEditor.parse("Jane Smith, Bo Li, ana@contoso.com", original: original)
        #expect(result.people[0] == Person(name: "Jane Smith", email: "jsmith@contoso.com", rsvp: "Accepted"))
        #expect(result.learned.contains { $0.email == "jsmith@contoso.com" && $0.name == "Jane Smith" })
        #expect(!result.learned.contains { $0.email == "ana@contoso.com" })
    }

    @Test func removingOneAndAddingAnotherDoesNotLearnWrongMapping() {
        // Deleted Jane (position 0) and added Sam at the end: no in-place replacement.
        let result = ParticipantsEditor.parse("Bo Li, ana@contoso.com, Sam", original: original)
        #expect(result.people.map(\.display) == ["Bo Li (bo.li@contoso.com)", "ana@contoso.com", "Sam"])
        #expect(!result.learned.contains { $0.name == "Sam" })
    }

    @Test func explicitNameAndEmailIsLearned() {
        let result = ParticipantsEditor.parse("Cam Diaz (cam@contoso.com)", original: [])
        #expect(result.people == [Person(name: "Cam Diaz", email: "cam@contoso.com")])
        #expect(result.learned.count == 1)
    }

    @Test func guessedNameCanBeCorrectedInPlace() {
        let guessed = [Person(name: "Jane Smith", email: "jane.smith@contoso.com")]
        let result = ParticipantsEditor.parse("Janie Smith-Ruiz", original: guessed)
        #expect(result.people == [Person(name: "Janie Smith-Ruiz", email: "jane.smith@contoso.com")])
        #expect(result.learned.first?.name == "Janie Smith-Ruiz")
    }
}
