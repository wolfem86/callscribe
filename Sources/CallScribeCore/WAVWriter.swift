import Foundation

/// Sample conversion helpers.
public enum PCM {
    public static func int16(_ samples: [Float]) -> [Int16] {
        samples.map { sample in
            let clamped = max(-1, min(1, sample))
            return Int16((clamped * 32767).rounded())
        }
    }
}

/// Crash-safe 16-bit mono PCM WAV writer.
///
/// Samples are buffered in memory and written by `flush()`, which also patches the RIFF and
/// data size fields and fsyncs. If the app dies between flushes, at most one flush interval is
/// lost and the file on disk is always a valid WAV (or repairable with `WAVRepair`).
/// Not thread-safe: callers serialize access (StreamSink uses one serial queue per writer).
public final class WAVWriter {
    public static let headerSize = 44

    public let url: URL
    public let sampleRate: Int
    private let handle: FileHandle
    private var pending = Data()
    private var flushedBytes: Int64 = 0
    public private(set) var isClosed = false

    /// Samples written so far, including those not yet flushed.
    public var totalSamples: Int64 { (flushedBytes + Int64(pending.count)) / 2 }

    public init(url: URL, sampleRate: Int = 16_000) throws {
        self.url = url
        self.sampleRate = sampleRate
        let header = WAVWriter.header(dataBytes: 0, sampleRate: sampleRate)
        guard FileManager.default.createFile(atPath: url.path, contents: header) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    public func append(_ samples: [Int16]) {
        guard !isClosed, !samples.isEmpty else { return }
        samples.withUnsafeBufferPointer { pending.append(Data(buffer: $0)) }
    }

    public func appendSilence(_ sampleCount: Int) {
        guard !isClosed, sampleCount > 0 else { return }
        pending.append(Data(count: sampleCount * 2))
    }

    public func flush() throws {
        guard !isClosed else { return }
        if !pending.isEmpty {
            try handle.seekToEnd()
            try handle.write(contentsOf: pending)
            flushedBytes += Int64(pending.count)
            pending.removeAll(keepingCapacity: true)
        }
        try WAVWriter.writeHeader(to: handle, dataBytes: flushedBytes, sampleRate: sampleRate)
        try handle.synchronize()
    }

    public func close() throws {
        guard !isClosed else { return }
        try flush()
        try handle.close()
        isClosed = true
    }

    static func writeHeader(to handle: FileHandle, dataBytes: Int64, sampleRate: Int) throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(dataBytes: UInt32(clamping: dataBytes), sampleRate: sampleRate))
        try handle.seekToEnd()
    }

    public static func header(dataBytes: UInt32, sampleRate: Int) -> Data {
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(le32(dataBytes &+ 36))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(le32(16))                       // fmt chunk size
        data.append(le16(1))                        // PCM
        data.append(le16(1))                        // mono
        data.append(le32(UInt32(sampleRate)))
        data.append(le32(UInt32(sampleRate * 2)))   // byte rate
        data.append(le16(2))                        // block align
        data.append(le16(16))                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.append(le32(dataBytes))
        return data
    }

    static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}

/// Repairs WAV files left behind by a crash (header sizes not matching the file length).
public enum WAVRepair {
    /// Rewrites the header to match the file's actual length. Returns true if anything changed.
    @discardableResult
    public static func repair(url: URL, sampleRate: Int = 16_000) throws -> Bool {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        var dataBytes = max(0, size - Int64(WAVWriter.headerSize))
        if dataBytes % 2 != 0 { dataBytes -= 1 }
        let existing = try handle.read(upToCount: WAVWriter.headerSize) ?? Data()
        let expected = WAVWriter.header(dataBytes: UInt32(clamping: dataBytes), sampleRate: sampleRate)
        let expectedLength = UInt64(WAVWriter.headerSize) + UInt64(dataBytes)
        if existing == expected && UInt64(size) == expectedLength { return false }

        try handle.truncate(atOffset: expectedLength)
        try WAVWriter.writeHeader(to: handle, dataBytes: dataBytes, sampleRate: sampleRate)
        try handle.synchronize()
        return true
    }

    /// Reads a 16-bit mono WAV written by `WAVWriter` as Float samples in −1...1.
    public static func readSamples(url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > WAVWriter.headerSize else { return [] }
        let count = (data.count - WAVWriter.headerSize) / 2
        return data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: WAVWriter.headerSize)
            return (0..<count).map { i in
                Float(Int16(littleEndian: base.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
            }
        }
    }

    /// Duration in seconds based on the data size in the header.
    public static func duration(url: URL, sampleRate: Int = 16_000) -> Double {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: WAVWriter.headerSize), header.count == WAVWriter.headerSize else { return 0 }
        let bytes = header.subdata(in: 40..<44).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        return Double(bytes) / Double(sampleRate * 2)
    }
}
