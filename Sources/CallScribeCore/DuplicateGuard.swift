import Foundation

public enum Speaker: String, Codable, Sendable {
    case me = "Me"
    case others = "Others"
}

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var speaker: Speaker
    public var start: Double
    public var end: Double
    public var text: String
    public var confidence: Double

    public init(speaker: Speaker, start: Double, end: Double, text: String, confidence: Double = 1) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
    }
}

public struct DroppedDuplicate: Equatable, Sendable {
    public var dropped: TranscriptSegment
    public var matchedText: String
    public var similarity: Double
}

/// Removes call audio that leaked into the mic and was transcribed as "Me".
///
/// The Others stream is captured digitally from Teams and can't contain your mic, so when the
/// same words appear in both streams at the same time, the Me copy is the leak and is dropped.
public enum DuplicateGuard {
    public static let window = 2.0
    public static let threshold = 0.8

    public static func apply(_ segments: [TranscriptSegment]) -> (kept: [TranscriptSegment], dropped: [DroppedDuplicate]) {
        let others = segments.filter { $0.speaker == .others }
        var kept: [TranscriptSegment] = []
        var dropped: [DroppedDuplicate] = []

        for segment in segments {
            guard segment.speaker == .me else {
                kept.append(segment)
                continue
            }
            let nearby = others.filter { $0.start - window < segment.end && $0.end + window > segment.start }
            guard !nearby.isEmpty else {
                kept.append(segment)
                continue
            }
            let nearbyText = nearby.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ")
            let best = max(
                nearby.map { similarity(segment.text, $0.text) }.max() ?? 0,
                containment(segment.text, in: nearbyText)
            )
            if best > threshold {
                dropped.append(DroppedDuplicate(dropped: segment, matchedText: nearbyText, similarity: best))
            } else {
                kept.append(segment)
            }
        }
        return (kept.sorted { $0.start < $1.start }, dropped)
    }

    /// Lowercase, punctuation removed, whitespace collapsed.
    public static func normalize(_ text: String) -> String {
        let scalars = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    /// 1 − normalized character edit distance.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(normalize(a)), y = Array(normalize(b))
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }

    /// Fraction of `text`'s words that appear, in order, within `other` (longest common word subsequence).
    /// Catches a leaked fragment of a longer Others segment. Needs 3+ words so short replies like
    /// "yeah, sure" aren't dropped just because the other person said them too.
    public static func containment(_ text: String, in other: String) -> Double {
        let words = normalize(text).split(separator: " ")
        let otherWords = normalize(other).split(separator: " ")
        guard words.count >= 3, !otherWords.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: otherWords.count + 1)
        var current = previous
        for word in words {
            for j in 1...otherWords.count {
                current[j] = word == otherWords[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return Double(previous[otherWords.count]) / Double(words.count)
    }
}
