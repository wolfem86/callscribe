import Foundation

public enum LevelMeter {
    public static let floorDB: Float = -100

    /// RMS level of the samples in dBFS, clamped to `floorDB`.
    public static func rmsDB(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return floorDB }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(samples.count)).squareRoot()
        return rms > 0 ? max(floorDB, 20 * log10(rms)) : floorDB
    }

    /// Maps dBFS to 0...1 for a meter showing the top `range` dB.
    public static func normalized(_ db: Float, range: Float = 60) -> Float {
        max(0, min(1, (db + range) / range))
    }
}
