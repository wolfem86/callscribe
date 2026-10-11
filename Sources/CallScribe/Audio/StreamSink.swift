import AVFoundation
import CallScribeCore
import Foundation

/// Converts any input format to 16 kHz mono Float32. Reconfigures when the input format changes
/// (e.g. a different headset or a rebuilt tap).
final class StreamConverter {
    static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.outputFormat)
            converter?.downmix = true
            inputFormat = buffer.format
        }
        guard let converter else { return [] }

        let ratio = Self.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else { return [] }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// One stream's path to disk: convert → align to the shared timeline → buffer → flush every 3 s.
final class StreamSink {
    let name: String
    let url: URL

    private let writer: WAVWriter
    private let queue: DispatchQueue
    private let converter = StreamConverter()
    private let converterLock = NSLock()
    private let aligner = TimelineAligner()
    private let activeElapsed: () -> Double
    private let isAccepting: () -> Bool
    private let onLevel: (Float) -> Void
    private var timer: DispatchSourceTimer?

    init(name: String, url: URL,
         activeElapsed: @escaping () -> Double,
         isAccepting: @escaping () -> Bool,
         onLevel: @escaping (Float) -> Void) throws {
        self.name = name
        self.url = url
        self.writer = try WAVWriter(url: url)
        self.queue = DispatchQueue(label: "com.wolfem86.callscribe.sink.\(name)")
        self.activeElapsed = activeElapsed
        self.isAccepting = isAccepting
        self.onLevel = onLevel
    }

    /// Called on the capture thread. The buffer may be only valid during this call, so it's
    /// converted immediately and the samples are handed to the writer queue.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard isAccepting() else { return }
        let samples = converterLock.withLock { converter.convert(buffer) }
        guard !samples.isEmpty else { return }
        onLevel(LevelMeter.rmsDB(samples))
        let elapsed = activeElapsed()
        queue.async { [self] in
            let pad = aligner.silenceToInsert(samplesWritten: writer.totalSamples, incoming: samples.count, activeElapsed: elapsed)
            insertSilence(pad)
            writer.append(PCM.int16(samples))
        }
    }

    func startFlushing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.isAccepting() { self.padToTimeline() }
            self.flush()
        }
        timer.resume()
        self.timer = timer
    }

    /// Pads to the current timeline, flushes, and closes the file.
    func close() {
        queue.sync {
            timer?.cancel()
            timer = nil
            padToTimeline()
            do { try writer.close() } catch { Log.error("\(name): close failed: \(error.localizedDescription)") }
        }
    }

    /// Keeps a stalled stream (no buffers arriving) aligned with the other one.
    private func padToTimeline() {
        let pad = aligner.silenceToInsert(samplesWritten: writer.totalSamples, incoming: 0, activeElapsed: activeElapsed(), tolerance: 1.0)
        insertSilence(pad)
    }

    private func insertSilence(_ samples: Int) {
        guard samples > 0 else { return }
        writer.appendSilence(samples)
        Log.info("\(name): inserted \(String(format: "%.1f", Double(samples) / 16_000)) s of silence to stay aligned")
    }

    private func flush() {
        do { try writer.flush() } catch { Log.error("\(name): flush failed: \(error.localizedDescription)") }
    }
}
