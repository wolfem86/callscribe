import AppKit
import ApplicationServices
import CallScribeCore
import Foundation

/// Reads Microsoft Teams window titles through the Accessibility API, to name calls that aren't
/// on the calendar ("Call with Jane Smith", or the meeting's name). Needs the Accessibility permission;
/// without it this quietly does nothing.
enum TeamsWindowWatcher {
    static let teamsBundleID = "com.microsoft.teams2"

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks once (macOS shows its own prompt that opens System Settings).
    static func requestAccessIfNeeded() {
        guard !isTrusted, !UserDefaults.standard.bool(forKey: "askedForAccessibility") else { return }
        UserDefaults.standard.set(true, forKey: "askedForAccessibility")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        Log.info("Accessibility: requested (used to read Teams meeting names)")
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Titles of all Teams windows right now.
    static func windowTitles() -> [String] {
        guard isTrusted else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: teamsBundleID).flatMap { app -> [String] in
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { return [] }
            return windows.compactMap { window in
                var title: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else { return nil }
                return (title as? String).flatMap { $0.isEmpty ? nil : $0 }
            }
        }
    }
}
