import CallScribeCore
import Foundation
import WhisperKit

/// Runs Whisper on one stream at a time. Loads the model per job and unloads it afterwards,
/// so the ~1–2 GB it uses isn't held while you're just recording.
final class Transcriber {
    private let modelFolder: URL

    init(modelFolder: URL) {
        self.modelFolder = modelFolder
    }

    func transcribeSession(me: [Float], others: [Float]) async throws -> (me: [TranscriptSegment], others: [TranscriptSegment], meRegions: Int, leakSeconds: Double) {
        let config = WhisperKitConfig(modelFolder: modelFolder.path, tokenizerFolder: ModelManager.modelsRoot,
                                      verbose: false, logLevel: .error, prewarm: false, load: true, download: false)
        let whisper = try await WhisperKit(config)
        defer { Task { await whisper.unloadModels() } }

        // Me: only your speech; leaked call audio is excluded by the leak-aware detector.
        let analysis = LeakAwareVAD.analyze(me: me, others: others)
        Log.info(String(format: "Transcribe: Me has %d speech regions, coupling %@, %.1f s of leak ignored",
                        analysis.regions.count, analysis.couplingDB.map { String(format: "%.1f dB", $0) } ?? "none", analysis.leakSeconds))
        let meSegments = try await transcribe(whisper, me, regions: analysis.regions, speaker: .me)

        // Others: a digital capture, so a plain level detector finds where anyone spoke.
        let otherRegions = LeakAwareVAD.speechRegions(in: others)
        Log.info("Transcribe: Others has \(otherRegions.count) speech regions")
        let otherSegments = try await transcribe(whisper, others, regions: otherRegions, speaker: .others)
        return (meSegments, otherSegments, analysis.regions.count, analysis.leakSeconds)
    }

    /// Transcribes each speech region on its own and offsets the results by the region's start, so
    /// timestamps come from the audio position and Whisper never sees silence (where it hallucinates).
    private func transcribe(_ whisper: WhisperKit, _ audio: [Float], regions: [SpeechRegion], speaker: Speaker) async throws -> [TranscriptSegment] {
        let started = Date()
        var segments: [TranscriptSegment] = []
        let allChunks = Self.chunks(regions, padding: 0.3, totalSeconds: Double(audio.count) / 16_000)
        let chunks = HallucinationFilter.dropFaintChunks(allChunks, in: audio)
        if chunks.count < allChunks.count {
            Log.info("Transcribe: \(speaker.rawValue) — skipped \(allChunks.count - chunks.count) faint chunks")
        }
        for chunk in chunks {
            let from = Int(chunk.start * 16_000), to = min(audio.count, Int(chunk.end * 16_000))
            guard to - from > 8_000 else { continue }  // under 0.5 s: nothing useful to transcribe
            let pieces = try await transcribe(whisper, Array(audio[from..<to]), speaker: speaker)
            let kept = pieces.filter { piece in
                let drop = HallucinationFilter.isLikelyHallucination(text: piece.text, confidence: piece.confidence, chunkDuration: chunk.duration)
                if drop {
                    Log.info(String(format: "Transcribe: %@ — dropped likely hallucination at %@ (confidence %.2f, %.0f s chunk)",
                                    speaker.rawValue, TranscriptBuilder.timestamp(chunk.start), piece.confidence, chunk.duration))
                }
                return !drop
            }
            segments += kept.map { piece in
                var shifted = piece
                shifted.start = min(chunk.end, piece.start + chunk.start)
                shifted.end = min(chunk.end, max(shifted.start, piece.end + chunk.start))
                return shifted
            }
        }
        Log.info(String(format: "Transcribe: %@ — %d segments from %d regions in %.0f s",
                        speaker.rawValue, segments.count, regions.count, Date().timeIntervalSince(started)))
        return segments
    }

    /// Merges nearby regions (gaps under 1.5 s) so Whisper gets whole sentences, with a little padding.
    static func chunks(_ regions: [SpeechRegion], padding: Double, totalSeconds: Double) -> [SpeechRegion] {
        var merged: [SpeechRegion] = []
        for region in regions {
            let padded = SpeechRegion(start: max(0, region.start - padding), end: min(totalSeconds, region.end + padding))
            if let last = merged.last, padded.start - last.end < 1.5 {
                merged[merged.count - 1].end = max(last.end, padded.end)
            } else {
                merged.append(padded)
            }
        }
        return merged
    }

    private func transcribe(_ whisper: WhisperKit, _ audio: [Float], speaker: Speaker) async throws -> [TranscriptSegment] {
        guard !audio.isEmpty else { return [] }
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: Settings.transcriptionLanguage,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            noSpeechThreshold: 0.6,
            concurrentWorkerCount: 2,
            chunkingStrategy: ChunkingStrategy.none
        )
        let results = try await whisper.transcribe(audioArray: audio, decodeOptions: options)
        let segments = results.flatMap(\.segments).compactMap { segment -> TranscriptSegment? in
            // Drop segments Whisper itself flags as probably not speech.
            if segment.noSpeechProb > 0.6 && segment.avgLogprob < -0.8 { return nil }
            return TranscriptSegment(speaker: speaker, start: Double(segment.start), end: Double(segment.end),
                                     text: segment.text, confidence: Double(exp(segment.avgLogprob)))
        }
        return segments
    }
}
