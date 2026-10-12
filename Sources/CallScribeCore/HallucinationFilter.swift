import Foundation

/// Catches Whisper's well-known stock outputs on non-speech ("Thank you.", "Thanks for watching!")
/// and chunks too faint to be the speaker on this stream.
public enum HallucinationFilter {
    static let stockPhrases: Set<String> = [
        "thank you", "thank you very much", "thanks", "thanks for watching", "thank you for watching",
        "thank you so much for watching", "you", "bye", "bye bye", "please subscribe",
        "subtitles by the amaraorg community", "i ll see you next time",
    ]

    /// A stock phrase is dropped when Whisper is unsure of it, or when it's all that came out of a
    /// long stretch of audio. A real "Thank you" is short and dense, so it survives.
    public static func isLikelyHallucination(text: String, confidence: Double, chunkDuration: Double) -> Bool {
        let normalized = DuplicateGuard.normalize(text)
        guard stockPhrases.contains(normalized) else { return false }
        if confidence < 0.4 { return true }
        let words = Double(normalized.split(separator: " ").count)
        return chunkDuration >= 4 && words / chunkDuration < 0.5
    }

    /// Loudest 20 ms frame in a span, in dBFS.
    public static func peakDB(_ samples: [Float], from start: Double, to end: Double, sampleRate: Double = 16_000) -> Float {
        let from = max(0, Int(start * sampleRate)), to = min(samples.count, Int(end * sampleRate))
        var peak = LevelMeter.floorDB
        var index = from
        while index + LeakAwareVAD.frameSize <= to {
            peak = max(peak, LevelMeter.rmsDB(Array(samples[index..<(index + LeakAwareVAD.frameSize)])))
            index += LeakAwareVAD.frameSize
        }
        return peak
    }

    /// Drops chunks whose peak is more than `margin` dB below the loudest chunk on the stream:
    /// faint blips and distant voices rather than the person at this microphone.
    public static func dropFaintChunks(_ chunks: [SpeechRegion], in samples: [Float], margin: Float = 22) -> [SpeechRegion] {
        let peaks = chunks.map { peakDB(samples, from: $0.start, to: $0.end) }
        guard let loudest = peaks.max() else { return [] }
        return zip(chunks, peaks).filter { $0.1 >= loudest - margin }.map(\.0)
    }
}
