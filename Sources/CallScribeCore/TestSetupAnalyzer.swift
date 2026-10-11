import Foundation

public struct LevelSample: Sendable, Equatable {
    public var time: Double
    public var micDB: Float
    public var callDB: Float

    public init(time: Double, micDB: Float, callDB: Float) {
        self.time = time
        self.micDB = micDB
        self.callDB = callDB
    }
}

public struct TestSetupResult: Sendable, Equatable {
    public var speakMicDB: Float
    public var speakCallDB: Float
    public var playMicDB: Float
    public var playCallDB: Float

    public var micHeardVoice: Bool { speakMicDB > TestSetupAnalyzer.activityThresholdDB }
    public var callHeardPlayback: Bool { playCallDB > TestSetupAnalyzer.activityThresholdDB }
    /// Your voice showed up on the Others stream.
    public var voiceBledIntoCall: Bool { speakCallDB > TestSetupAnalyzer.bleedThresholdDB }
    /// Call playback showed up on your mic (speaker audio leaking into the headset mic).
    public var playbackBledIntoMic: Bool { playMicDB > TestSetupAnalyzer.bleedThresholdDB }

    public var passed: Bool { micHeardVoice && callHeardPlayback && !voiceBledIntoCall && !playbackBledIntoMic }
}

/// Analyzes the 15-second Test setup: speak during the first phase, play call audio during the second.
public enum TestSetupAnalyzer {
    public static let duration = 15.0
    public static let speakPhase = 0.5..<7.0
    public static let playPhase = 8.5..<15.0
    public static let activityThresholdDB: Float = -45
    public static let bleedThresholdDB: Float = -40

    public static func analyze(_ samples: [LevelSample]) -> TestSetupResult {
        let speak = samples.filter { speakPhase.contains($0.time) }
        let play = samples.filter { playPhase.contains($0.time) }
        return TestSetupResult(
            speakMicDB: percentile(speak.map(\.micDB), 0.8),
            speakCallDB: percentile(speak.map(\.callDB), 0.8),
            playMicDB: percentile(play.map(\.micDB), 0.8),
            playCallDB: percentile(play.map(\.callDB), 0.8)
        )
    }

    static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return LevelMeter.floorDB }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[index]
    }
}
