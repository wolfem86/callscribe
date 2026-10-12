import Foundation
import Testing
@testable import CallScribeCore

/// Deterministic speech-like noise burst.
private func burst(seconds: Double, amplitude: Float, seed: UInt64) -> [Float] {
    var state = seed
    return (0..<Int(seconds * 16_000)).map { i in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let noise = Float(Int64(bitPattern: state >> 11) % 2000) / 1000 - 1
        let envelope = Float(0.6 + 0.4 * sin(Double(i) / 800))  // syllable-ish modulation
        return noise * amplitude * envelope
    }
}

private func silence(_ seconds: Double, floor: Float = 0.0003, seed: UInt64 = 7) -> [Float] {
    burst(seconds: seconds, amplitude: floor, seed: seed)
}

@Suite struct LeakAwareVADTests {
    /// Mirrors the real test call: you speak (Me only), then the far end speaks and leaks into Me at −28 dB.
    @Test func ignoresLeakedCallAudio() {
        let leakGain: Float = 0.04  // ≈ −28 dB
        let farEnd = burst(seconds: 6, amplitude: 0.3, seed: 42)

        var me = silence(2) + burst(seconds: 4, amplitude: 0.02, seed: 1) + silence(2)
        var others = [Float](repeating: 0, count: me.count)
        let floor = silence(6, seed: 9)
        me += farEnd.enumerated().map { $0.element * leakGain + floor[$0.offset] }
        others += farEnd
        me += silence(2)
        others += [Float](repeating: 0, count: 32_000)

        let result = LeakAwareVAD.analyze(me: me, others: others)
        #expect(result.couplingDB != nil)
        #expect(abs((result.couplingDB ?? 0) + 28) < 3)
        #expect(result.regions.count == 1)
        let region = result.regions[0]
        #expect(region.start > 1.8 && region.start < 2.3)
        #expect(region.end > 5.8 && region.end < 6.5)
        #expect(result.leakSeconds > 4)
    }

    @Test func keepsYourSpeechOverQuietFarEnd() {
        // Far end is quiet (only leaks at about −80 dB); your speech must still count.
        let farEnd = burst(seconds: 4, amplitude: 0.003, seed: 3)
        let me = burst(seconds: 4, amplitude: 0.05, seed: 4).enumerated().map { $0.element + farEnd[$0.offset] * 0.04 }
        let paddedMe = silence(1) + me + silence(1)
        let paddedOthers = [Float](repeating: 0, count: 16_000) + farEnd + [Float](repeating: 0, count: 16_000)
        let result = LeakAwareVAD.analyze(me: paddedMe, others: paddedOthers)
        #expect(result.regions.count == 1)
        #expect((result.regions.first?.duration ?? 0) > 3.5)
    }

    @Test func noCouplingWithoutFarEnd() {
        let me = silence(1) + burst(seconds: 2, amplitude: 0.05, seed: 5) + silence(1)
        let result = LeakAwareVAD.analyze(me: me, others: [Float](repeating: 0, count: me.count))
        #expect(result.couplingDB == nil)
        #expect(result.regions.count == 1)
    }

    @Test func speechRegionsOnDigitallySilentStream() {
        let audio = [Float](repeating: 0, count: 16_000) + burst(seconds: 2, amplitude: 0.2, seed: 11)
            + [Float](repeating: 0, count: 16_000) + burst(seconds: 1, amplitude: 0.0002, seed: 12)  // −74 dB: below the floor
        let regions = LeakAwareVAD.speechRegions(in: audio)
        #expect(regions.count == 1)
        #expect(abs(regions[0].start - 1) < 0.1)
    }

    @Test func mergesShortGapsAndDropsBlips() {
        let config = LeakAwareVAD.Config()
        let frames = [Bool](repeating: true, count: 20) + [Bool](repeating: false, count: 5)
            + [Bool](repeating: true, count: 20) + [Bool](repeating: false, count: 100) + [true, true]
        let regions = LeakAwareVAD.buildRegions(frames, frameSeconds: 0.02, config: config)
        #expect(regions.count == 1)  // 0.1 s gap merged; 0.04 s blip + hangover = 0.24 s dropped
        #expect(abs(regions[0].start) < 0.001)
    }
}

@Suite struct DuplicateGuardTests {
    @Test func dropsLeakedMeCopyNotOthers() {
        let segments = [
            TranscriptSegment(speaker: .others, start: 49.5, end: 57.0, text: "Phone test. Alpha, bravo, charlie, delta, echo."),
            TranscriptSegment(speaker: .me, start: 49.6, end: 57.1, text: "phone test alpha bravo charlie delta echo"),
            TranscriptSegment(speaker: .me, start: 3.5, end: 11.5, text: "Mac test. One, two, three."),
        ]
        let result = DuplicateGuard.apply(segments)
        #expect(result.kept.map(\.speaker) == [.me, .others])
        #expect(result.kept.first?.text == "Mac test. One, two, three.")
        #expect(result.dropped.count == 1)
        #expect(result.dropped.first?.dropped.speaker == .me)
    }

    @Test func dropsLeakedFragmentOfLongerOthersLine() {
        let segments = [
            TranscriptSegment(speaker: .others, start: 10, end: 20, text: "Red, green, blue, yellow, orange, purple."),
            TranscriptSegment(speaker: .me, start: 12, end: 15, text: "green blue yellow"),
        ]
        #expect(DuplicateGuard.apply(segments).dropped.count == 1)
    }

    @Test func keepsShortRepliesAndDistantRepeats() {
        let segments = [
            TranscriptSegment(speaker: .others, start: 10, end: 11, text: "Yeah, sure."),
            TranscriptSegment(speaker: .me, start: 11.5, end: 12, text: "Sure."),
            TranscriptSegment(speaker: .others, start: 30, end: 33, text: "Let's meet on Friday afternoon."),
            TranscriptSegment(speaker: .me, start: 60, end: 63, text: "Let's meet on Friday afternoon."),
        ]
        let result = DuplicateGuard.apply(segments)
        #expect(result.dropped.isEmpty)
        #expect(result.kept.count == 4)
    }

    @Test func similarityAndNormalization() {
        #expect(DuplicateGuard.normalize("  Hello,   WORLD!! ") == "hello world")
        #expect(DuplicateGuard.similarity("Hello world", "hello, world.") == 1)
        #expect(DuplicateGuard.similarity("abc", "") == 0)
        #expect(DuplicateGuard.containment("a b", in: "a b c") == 0)  // under 3 words
    }
}

@Suite struct WAVReadTests {
    @Test func readsBackWrittenSamples() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("read-\(UUID().uuidString).wav")
        let writer = try WAVWriter(url: url)
        writer.append([0, 16384, -16384, 32767])
        try writer.close()
        let samples = try WAVRepair.readSamples(url: url)
        #expect(samples == [0, 0.5, -0.5, Float(32767) / 32768])
    }
}

@Suite struct HallucinationFilterTests {
    @Test func dropsStockPhrasesFromLongOrUnsureChunks() {
        #expect(HallucinationFilter.isLikelyHallucination(text: "Thank you.", confidence: 0.8, chunkDuration: 9))
        #expect(HallucinationFilter.isLikelyHallucination(text: "Thank you.", confidence: 0.17, chunkDuration: 2))
        #expect(HallucinationFilter.isLikelyHallucination(text: "Thanks for watching!", confidence: 0.9, chunkDuration: 30))
    }

    @Test func keepsRealSpeech() {
        #expect(!HallucinationFilter.isLikelyHallucination(text: "Thank you.", confidence: 0.85, chunkDuration: 1.5))
        #expect(!HallucinationFilter.isLikelyHallucination(text: "Thank you for the update on the budget.", confidence: 0.3, chunkDuration: 20))
    }

    @Test func dropsFaintChunks() {
        let loud = [Float](repeating: 0.05, count: 16_000)    // ≈ −26 dB
        let faint = [Float](repeating: 0.002, count: 16_000)  // ≈ −54 dB
        let audio = loud + faint + loud
        let chunks = [SpeechRegion(start: 0, end: 1), SpeechRegion(start: 1, end: 2), SpeechRegion(start: 2, end: 3)]
        #expect(HallucinationFilter.dropFaintChunks(chunks, in: audio) == [chunks[0], chunks[2]])
    }
}
