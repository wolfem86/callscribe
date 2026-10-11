import Foundation

/// Which apps' audio the "Others" stream captures.
public enum CallSourceMode: String, Codable, CaseIterable, Sendable {
    /// Teams desktop if it's running, otherwise supported browsers (Teams on the web).
    case auto
    case teamsOnly
    case teamsAndBrowsers

    public var title: String {
        switch self {
        case .auto: return "Automatic (Teams app, else browser)"
        case .teamsOnly: return "Teams app only"
        case .teamsAndBrowsers: return "Teams app and browsers"
        }
    }
}

/// Picks the audio processes to tap from their bundle IDs.
///
/// Teams and browsers play audio from helper processes (e.g. com.microsoft.teams2.helper,
/// com.google.Chrome.helper), so matching is by prefix rather than exact bundle ID.
public enum CallTargetMatcher {
    public static let teamsPrefixes = ["com.microsoft.teams2"]
    public static let browserPrefixes = ["com.google.Chrome", "com.microsoft.edgemac"]
    public static let safariPrefixes = ["com.apple.Safari"]
    /// Safari plays audio through shared WebKit processes; only tapped while Safari is running.
    public static let webKitPrefixes = ["com.apple.WebKit.GPU", "com.apple.WebKit.WebContent"]

    public static func isTeams(_ bundleID: String) -> Bool {
        matches(bundleID, teamsPrefixes)
    }

    /// Returns indices into `bundleIDs` of the processes to tap.
    public static func select(_ bundleIDs: [String], mode: CallSourceMode, ownBundleID: String) -> [Int] {
        let candidates = bundleIDs.enumerated().filter { !$0.element.isEmpty && $0.element != ownBundleID }
        let teams = candidates.filter { isTeams($0.element) }.map(\.offset)

        let includeBrowsers: Bool
        switch mode {
        case .auto: includeBrowsers = teams.isEmpty
        case .teamsOnly: includeBrowsers = false
        case .teamsAndBrowsers: includeBrowsers = true
        }
        guard includeBrowsers else { return teams }

        var browsers = candidates.filter { matches($0.element, browserPrefixes) }.map(\.offset)
        let safari = candidates.filter { matches($0.element, safariPrefixes) }.map(\.offset)
        if !safari.isEmpty {
            browsers += safari
            browsers += candidates.filter { matches($0.element, webKitPrefixes) }.map(\.offset)
        }
        return (teams + browsers).sorted()
    }

    static func matches(_ bundleID: String, _ prefixes: [String]) -> Bool {
        prefixes.contains { bundleID.hasPrefix($0) }
    }
}
