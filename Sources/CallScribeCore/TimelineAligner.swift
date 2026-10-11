import Foundation

/// Keeps both stream files on the same timeline.
///
/// Each stream's file should contain `activeElapsed * sampleRate` samples. When a source stalls
/// (device rebuild, tap restart, headset unplugged), the stream falls behind; the aligner says how
/// much silence to insert so later audio lands at the right time.
public struct TimelineAligner: Sendable {
    public let sampleRate: Double

    public init(sampleRate: Double = 16_000) {
        self.sampleRate = sampleRate
    }

    /// Silence (in samples) to insert before `incoming` new samples.
    /// - Parameters:
    ///   - samplesWritten: samples already in the file.
    ///   - incoming: samples about to be appended (they end at `activeElapsed`).
    ///   - activeElapsed: non-paused recording time now, in seconds.
    ///   - tolerance: deficits shorter than this are treated as normal buffering jitter.
    public func silenceToInsert(samplesWritten: Int64, incoming: Int, activeElapsed: Double, tolerance: Double = 0.5) -> Int {
        let expected = Int64(activeElapsed * sampleRate)
        let deficit = expected - (samplesWritten + Int64(incoming))
        return deficit > Int64(tolerance * sampleRate) ? Int(deficit) : 0
    }
}
