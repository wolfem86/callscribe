import Foundation

enum Paths {
    static let bundleID = "com.wolfem86.callscribe"

    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallScribe", isDirectory: true)
    }

    /// Audio lives only here. It never goes to OneDrive.
    static var recordings: URL { appSupport.appendingPathComponent("Recordings", isDirectory: true) }

    /// Test setup recordings; removed after each test.
    static var testRecordings: URL { recordings.appendingPathComponent(".tests", isDirectory: true) }

    static var logs: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/CallScribe", isDirectory: true)
    }

    static func ensure() {
        for url in [appSupport, recordings, testRecordings, logs] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
