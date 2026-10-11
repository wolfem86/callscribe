import Foundation

/// Rotating log file at ~/Library/Logs/CallScribe/callscribe.log (5 files × 5 MB).
/// Never log transcript text, tokens, or secret URLs.
enum Log {
    private static let queue = DispatchQueue(label: "com.wolfem86.callscribe.log")
    private static let maxBytes: Int64 = 5 * 1024 * 1024
    private static let keepFiles = 5
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static var fileURL: URL { Paths.logs.appendingPathComponent("callscribe.log") }

    static func info(_ message: String) { write("INFO", message) }
    static func warn(_ message: String) { write("WARN", message) }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        queue.async {
            rotateIfNeeded()
            let url = fileURL
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    private static func rotateIfNeeded() {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > maxBytes else { return }
        let rotated = { (n: Int) in Paths.logs.appendingPathComponent("callscribe.\(n).log") }
        try? fm.removeItem(at: rotated(keepFiles - 1))
        for n in stride(from: keepFiles - 2, through: 1, by: -1) {
            try? fm.moveItem(at: rotated(n), to: rotated(n + 1))
        }
        try? fm.moveItem(at: fileURL, to: rotated(1))
    }
}
