import AVFoundation
import CoreAudio
import Foundation

/// The "Me" stream: the default input device through AVAudioEngine.
/// Follows the system default input (headset unplug/replug) by rebuilding the engine.
/// All control methods run on the main thread.
final class MicCapture {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onStatus: ((Bool, String) -> Void)?

    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var deviceListener: CoreAudioUtil.Listener?
    private var retryTimer: Timer?
    private var pendingRestart: DispatchWorkItem?
    private var wanted = false

    func start() {
        wanted = true
        deviceListener = CoreAudioUtil.listen(kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
            self?.restart(reason: "default input device changed")
        }
        startEngine()
    }

    func stop() {
        wanted = false
        pendingRestart?.cancel()
        retryTimer?.invalidate()
        retryTimer = nil
        deviceListener?.remove()
        deviceListener = nil
        tearDown()
    }

    func restart(reason: String) {
        guard wanted else { return }
        pendingRestart?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.wanted else { return }
            Log.info("Mic: restarting (\(reason))")
            self.startEngine()
        }
        pendingRestart = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func startEngine() {
        tearDown()
        retryTimer?.invalidate()
        retryTimer = nil

        guard AVCaptureDevice.authorizationStatus(for: .audio) != .denied else {
            report(false, "Microphone access denied")
            scheduleRetry()
            return
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        do {
            if Settings.voiceProcessing {
                try input.setVoiceProcessingEnabled(true)
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw CoreAudioError(operation: "Find an input device", status: kAudioHardwareBadDeviceError)
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                self?.onBuffer?(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            Log.error("Mic: \(error.localizedDescription)")
            report(false, "Mic not capturing: \(error.localizedDescription)")
            scheduleRetry()
            return
        }

        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restart(reason: "audio engine configuration changed")
        }
        let name = CoreAudioUtil.defaultDevice(input: true).flatMap(CoreAudioUtil.deviceName) ?? "default input"
        Log.info("Mic: capturing \(name)")
        report(true, "Capturing \(name)")
    }

    private func tearDown() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func scheduleRetry() {
        guard wanted else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.startEngine()
        }
    }

    private func report(_ ok: Bool, _ text: String) {
        onStatus?(ok, text)
    }
}
