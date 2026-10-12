import Foundation

public struct SpeechRegion: Equatable, Sendable, Codable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var duration: Double { end - start }
}

public struct LeakAnalysis: Sendable {
    /// How much quieter the call audio is when it leaks into the mic (Me dB − Others dB), if measurable.
    public var couplingDB: Float?
    public var noiseFloorDB: Float
    /// Regions where the mic has *your* speech (not leaked call audio).
    public var regions: [SpeechRegion]
    /// Seconds of mic audio above the noise floor that were attributed to leakage and ignored.
    public var leakSeconds: Double
}

/// Voice activity detection for the Me stream that ignores call audio leaking into the headset mic.
///
/// Wired headsets often leak the call's playback into their own mic (electrically or from the earcups).
/// The Others stream is the exact signal being played, so the expected leak level at any moment is
/// `othersDB + couplingDB`. A mic frame counts as speech only when it's well above both the noise
/// floor and that expected leak.
public enum LeakAwareVAD {
    public static let frameSize = 320  // 20 ms at 16 kHz

    public struct Config: Sendable {
        public var speechAboveNoiseDB: Float = 10
        /// Never counts anything quieter than this as speech (matters for digitally silent streams).
        public var minimumSpeechDB: Float = -65
        /// Mic must exceed the expected leak by this much to count as your speech.
        public var marginOverLeakDB: Float = 9
        public var farEndActiveDB: Float = -45
        public var hangover = 0.2
        public var mergeGap = 0.3
        public var minRegion = 0.4

        public init() {}
    }

    public static func frameLevels(_ samples: [Float]) -> [Float] {
        let count = samples.count / frameSize
        return (0..<count).map { i in
            LevelMeter.rmsDB(Array(samples[(i * frameSize)..<((i + 1) * frameSize)]))
        }
    }

    public static func analyze(me: [Float], others: [Float], sampleRate: Double = 16_000, config: Config = Config()) -> LeakAnalysis {
        let meDB = frameLevels(me)
        let otherDB = frameLevels(others)
        let frames = min(meDB.count, otherDB.count)
        let frameSeconds = Double(frameSize) / sampleRate
        guard frames > 0 else { return LeakAnalysis(couplingDB: nil, noiseFloorDB: LevelMeter.floorDB, regions: [], leakSeconds: 0) }

        let noise = percentile(Array(meDB[0..<frames]), 0.1)

        // Coupling: typical Me−Others difference while the far end is talking and the mic is above its floor.
        // The median keeps occasional double-talk from skewing it.
        let farEndDiffs = (0..<frames)
            .filter { otherDB[$0] > config.farEndActiveDB && meDB[$0] > noise + 3 }
            .map { meDB[$0] - otherDB[$0] }
        let coupling: Float? = farEndDiffs.count >= 25 ? percentile(farEndDiffs, 0.5) : nil

        var speech = [Bool](repeating: false, count: frames)
        var leakFrames = 0
        for i in 0..<frames {
            guard meDB[i] > max(noise + config.speechAboveNoiseDB, config.minimumSpeechDB) else { continue }
            if let coupling, otherDB[i] > LevelMeter.floorDB + 1 {
                let expectedLeak = otherDB[i] + coupling
                if meDB[i] > expectedLeak + config.marginOverLeakDB {
                    speech[i] = true
                } else {
                    leakFrames += 1
                }
            } else {
                speech[i] = true
            }
        }

        let regions = buildRegions(speech, frameSeconds: frameSeconds, config: config)
        return LeakAnalysis(couplingDB: coupling, noiseFloorDB: noise, regions: regions, leakSeconds: Double(leakFrames) * frameSeconds)
    }

    /// Plain level-based speech regions for a stream with no leak to account for (the Others stream).
    public static func speechRegions(in samples: [Float], sampleRate: Double = 16_000) -> [SpeechRegion] {
        analyze(me: samples, others: [Float](repeating: 0, count: samples.count), sampleRate: sampleRate).regions
    }

    static func buildRegions(_ speech: [Bool], frameSeconds: Double, config: Config) -> [SpeechRegion] {
        var raw: [SpeechRegion] = []
        var start: Int?
        for (i, active) in speech.enumerated() {
            if active, start == nil { start = i }
            if !active, let s = start {
                raw.append(SpeechRegion(start: Double(s) * frameSeconds, end: Double(i) * frameSeconds + config.hangover))
                start = nil
            }
        }
        if let s = start {
            raw.append(SpeechRegion(start: Double(s) * frameSeconds, end: Double(speech.count) * frameSeconds))
        }

        var merged: [SpeechRegion] = []
        for region in raw {
            if let last = merged.last, region.start - last.end <= config.mergeGap {
                merged[merged.count - 1].end = max(last.end, region.end)
            } else {
                merged.append(region)
            }
        }
        let total = Double(speech.count) * frameSeconds
        return merged
            .map { SpeechRegion(start: $0.start, end: min($0.end, total)) }
            .filter { $0.duration >= config.minRegion }
    }

    static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return LevelMeter.floorDB }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }
}
