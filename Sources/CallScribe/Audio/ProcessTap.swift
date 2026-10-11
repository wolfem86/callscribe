import AVFoundation
import CoreAudio
import Foundation

/// A Core Audio process tap on specific processes, read through a private aggregate device.
/// Captures only those processes' output (never system-wide output, never our own process).
final class ProcessTap {
    let processIDs: [AudioObjectID]
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.wolfem86.callscribe.tap", qos: .userInitiated)
    private let lock = NSLock()
    private var lastCallback = ContinuousClock.now

    init(processIDs: [AudioObjectID]) {
        self.processIDs = processIDs
    }

    var secondsSinceLastCallback: Double {
        let duration = lock.withLock { lastCallback }.duration(to: .now)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    func start() throws {
        do {
            try startUnchecked()
        } catch {
            stop()
            throw error
        }
    }

    private func startUnchecked() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processIDs)
        description.uuid = UUID()
        description.name = "CallScribe"
        description.muteBehavior = .unmuted
        description.isPrivate = true
        try checkCA(AudioHardwareCreateProcessTap(description, &tapID), "Create process tap")

        var streamDescription = try CoreAudioUtil.tapFormat(tapID)
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw CoreAudioError(operation: "Read tap audio format", status: kAudioHardwareUnsupportedOperationError)
        }

        // The output device only provides the clock; the tap delivers the processes' audio regardless
        // of which device Teams plays to. Drift compensation covers the mismatch.
        let outputUID = try CoreAudioUtil.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CallScribe Call Tap",
            kAudioAggregateDeviceUIDKey: "com.wolfem86.callscribe.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try checkCA(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Create aggregate device")

        try checkCA(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            self.lock.withLock { self.lastCallback = .now }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  buffer.frameLength > 0 else { return }
            self.onBuffer?(buffer)
        }, "Create IO proc")

        try checkCA(AudioDeviceStart(aggregateID, ioProcID), "Start aggregate device")
        lock.withLock { lastCallback = .now }
        Log.info("Call tap: format \(format.sampleRate) Hz, \(format.channelCount) ch, interleaved=\(format.isInterleaved); clock device \(outputUID); processes \(processIDs)")
    }

    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }
}
