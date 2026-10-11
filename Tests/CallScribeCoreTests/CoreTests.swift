import Foundation
import Testing
@testable import CallScribeCore

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("callscribe-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func fileSize(_ url: URL) throws -> Int64 {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
}

@Suite struct WAVTests {
    @Test func headerIsValidPCM16Mono() {
        let header = WAVWriter.header(dataBytes: 3200, sampleRate: 16_000)
        #expect(header.count == 44)
        #expect(String(decoding: header.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: header[8..<12], as: UTF8.self) == "WAVE")
        #expect(header[40..<44] == WAVWriter.le32(3200))
        #expect(header[4..<8] == WAVWriter.le32(3236))
    }

    @Test func flushPatchesSizesOnDisk() throws {
        let url = try tempDir().appendingPathComponent("a.wav")
        let writer = try WAVWriter(url: url)
        writer.append([Int16](repeating: 100, count: 16_000))
        writer.appendSilence(8_000)
        #expect(writer.totalSamples == 24_000)
        try writer.flush()
        #expect(try fileSize(url) == 44 + 48_000)
        #expect(WAVRepair.duration(url: url) == 1.5)
        // Already consistent: repair is a no-op.
        #expect(try WAVRepair.repair(url: url) == false)
        try writer.close()
    }

    @Test func repairFixesCrashedFile() throws {
        let url = try tempDir().appendingPathComponent("b.wav")
        // Simulate a crash: header says 0 bytes, but 3201 bytes of data follow (odd byte included).
        var data = WAVWriter.header(dataBytes: 0, sampleRate: 16_000)
        data.append(Data(count: 3201))
        try data.write(to: url)
        #expect(try WAVRepair.repair(url: url) == true)
        #expect(try fileSize(url) == 44 + 3200)
        #expect(WAVRepair.duration(url: url) == 0.1)
    }

    @Test func repairHandlesTruncatedHeader() throws {
        let url = try tempDir().appendingPathComponent("c.wav")
        try Data([0x52, 0x49]).write(to: url)
        #expect(try WAVRepair.repair(url: url) == true)
        #expect(try fileSize(url) == 44)
    }

    @Test func pcmClamps() {
        #expect(PCM.int16([2, -2, 0, 0.5]) == [32767, -32767, 0, 16384])
    }
}

@Suite struct SpanListTests {
    @Test func activeElapsedExcludesPauses() {
        var pauses = SpanList()
        pauses.begin(at: 10)
        pauses.end(at: 15)
        pauses.begin(at: 20)
        #expect(pauses.isOpen)
        #expect(pauses.activeElapsed(atWall: 8) == 8)
        #expect(pauses.activeElapsed(atWall: 12) == 10)
        #expect(pauses.activeElapsed(atWall: 25) == 15)  // 25 - 5 - 5 (open pause)
    }

    @Test func wallTimeMapsAudioBackAcrossPauses() {
        var pauses = SpanList()
        pauses.begin(at: 10); pauses.end(at: 15)
        pauses.begin(at: 30); pauses.end(at: 40)
        #expect(pauses.wallTime(forAudioTime: 5) == 5)
        #expect(pauses.wallTime(forAudioTime: 10) == 15)   // boundary maps to resume
        #expect(pauses.wallTime(forAudioTime: 20) == 25)
        #expect(pauses.wallTime(forAudioTime: 26) == 41)
    }

    @Test func beginAndEndAreIdempotent() {
        var spans = SpanList()
        spans.end(at: 3)
        spans.begin(at: 4)
        spans.begin(at: 5)
        spans.end(at: 6)
        spans.end(at: 7)
        #expect(spans.spans == [TimeSpan(start: 4, end: 6)])
    }
}

@Suite struct AlignerTests {
    let aligner = TimelineAligner()

    @Test func noPaddingWithinTolerance() {
        #expect(aligner.silenceToInsert(samplesWritten: 15_000, incoming: 800, activeElapsed: 1.0) == 0)
    }

    @Test func padsAfterStall() {
        // 3 s of active time, only 1 s written, 0.1 s incoming → 1.9 s of silence.
        #expect(aligner.silenceToInsert(samplesWritten: 16_000, incoming: 1_600, activeElapsed: 3.0) == 30_400)
    }

    @Test func neverNegativeWhenAhead() {
        #expect(aligner.silenceToInsert(samplesWritten: 64_000, incoming: 0, activeElapsed: 1.0) == 0)
    }
}

@Suite struct MatcherTests {
    let own = "com.wolfem86.callscribe"

    @Test func teamsHelpersMatchByPrefix() {
        let ids = ["com.apple.Music", "com.microsoft.teams2", "com.microsoft.teams2.helper", "com.google.Chrome.helper"]
        #expect(CallTargetMatcher.select(ids, mode: .auto, ownBundleID: own) == [1, 2])
    }

    @Test func autoFallsBackToBrowsersWithoutTeams() {
        let ids = ["com.google.Chrome.helper", "com.microsoft.edgemac.helper", "com.apple.Music"]
        #expect(CallTargetMatcher.select(ids, mode: .auto, ownBundleID: own) == [0, 1])
        #expect(CallTargetMatcher.select(ids, mode: .teamsOnly, ownBundleID: own) == [])
    }

    @Test func webKitOnlyWhenSafariRuns() {
        let withoutSafari = ["com.apple.WebKit.GPU", "com.apple.mail"]
        #expect(CallTargetMatcher.select(withoutSafari, mode: .auto, ownBundleID: own) == [])
        let withSafari = ["com.apple.WebKit.GPU", "com.apple.Safari", "com.apple.WebKit.WebContent"]
        #expect(CallTargetMatcher.select(withSafari, mode: .auto, ownBundleID: own) == [0, 1, 2])
    }

    @Test func excludesOwnProcessAndClassicTeams() {
        let ids = [own, "com.microsoft.teams", "com.microsoft.teams2"]
        #expect(CallTargetMatcher.select(ids, mode: .teamsAndBrowsers, ownBundleID: own) == [2])
    }
}

@Suite struct LevelAndTestSetupTests {
    @Test func rmsOfFullScaleSquareIsZeroDB() {
        #expect(abs(LevelMeter.rmsDB([1, -1, 1, -1])) < 0.001)
        #expect(LevelMeter.rmsDB([0, 0]) == LevelMeter.floorDB)
        #expect(LevelMeter.normalized(-30) == 0.5)
    }

    private func samples(speakMic: Float, speakCall: Float, playMic: Float, playCall: Float) -> [LevelSample] {
        stride(from: 0.0, to: 15.0, by: 0.1).map { t in
            t < 7.5 ? LevelSample(time: t, micDB: speakMic, callDB: speakCall)
                    : LevelSample(time: t, micDB: playMic, callDB: playCall)
        }
    }

    @Test func cleanSetupPasses() {
        let result = TestSetupAnalyzer.analyze(samples(speakMic: -20, speakCall: -90, playMic: -70, playCall: -25))
        #expect(result.passed)
    }

    @Test func detectsBleedAndMissingStreams() {
        let bleed = TestSetupAnalyzer.analyze(samples(speakMic: -20, speakCall: -90, playMic: -30, playCall: -25))
        #expect(bleed.playbackBledIntoMic)
        #expect(!bleed.passed)
        let silentCall = TestSetupAnalyzer.analyze(samples(speakMic: -20, speakCall: -100, playMic: -80, playCall: -100))
        #expect(!silentCall.callHeardPlayback)
    }
}

@Suite struct ManifestTests {
    @Test func roundTripAndUnfinishedScan() throws {
        let root = try tempDir()
        for (index, finished) in [false, true].enumerated() {
            let dir = root.appendingPathComponent("s\(index)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var manifest = SessionManifest(id: "s\(index)", startDate: Date(timeIntervalSince1970: 1_000 + Double(index)), isTest: false)
            manifest.finished = finished
            manifest.pauses.begin(at: 3)
            try ManifestStore.save(manifest, in: dir)
            #expect(try ManifestStore.load(from: dir) == manifest)
        }
        let unfinished = ManifestStore.unfinishedSessions(in: root)
        #expect(unfinished.map(\.1.id) == ["s0"])
        #expect(ManifestStore.unfinishedSessions(in: root, excluding: "s0").isEmpty)
    }
}
