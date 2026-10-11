import AVFoundation
import CoreAudio
import Foundation

struct AudioProcessInfo {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningInput: Bool
    let isRunningOutput: Bool
}

struct CoreAudioError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        "\(operation) failed (OSStatus \(status) \(fourCC))"
    }

    private var fourCC: String {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian) { Array($0) }
        let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
        return printable ? "'\(String(decoding: bytes, as: UTF8.self))'" : ""
    }
}

@discardableResult
func checkCA(_ status: OSStatus, _ operation: String) throws -> OSStatus {
    guard status == noErr else { throw CoreAudioError(operation: operation, status: status) }
    return status
}

enum CoreAudioUtil {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) -> T? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var ref: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ref) == noErr else { return nil }
        return ref?.takeRetainedValue() as String?
    }

    // MARK: Processes (macOS 14.2+)

    static func processes() -> [AudioProcessInfo] {
        objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).map { id in
            AudioProcessInfo(
                objectID: id,
                pid: value(id, kAudioProcessPropertyPID, initial: pid_t(-1)) ?? -1,
                bundleID: string(id, kAudioProcessPropertyBundleID) ?? "",
                isRunningInput: (value(id, kAudioProcessPropertyIsRunningInput, initial: UInt32(0)) ?? 0) != 0,
                isRunningOutput: (value(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0
            )
        }
    }

    // MARK: Devices

    static func defaultDevice(input: Bool) -> AudioObjectID? {
        let selector = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        let id = value(AudioObjectID(kAudioObjectSystemObject), selector, initial: AudioObjectID(kAudioObjectUnknown))
        return id == AudioObjectID(kAudioObjectUnknown) ? nil : id
    }

    static func deviceUID(_ device: AudioObjectID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }
    static func deviceName(_ device: AudioObjectID) -> String? { string(device, kAudioObjectPropertyName) }

    static func defaultOutputUID() throws -> String {
        guard let device = defaultDevice(input: false), let uid = deviceUID(device) else {
            throw CoreAudioError(operation: "read default output device", status: kAudioHardwareBadDeviceError)
        }
        return uid
    }

    static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        guard let asbd = value(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()) else {
            throw CoreAudioError(operation: "read tap format", status: kAudioHardwareUnspecifiedError)
        }
        return asbd
    }

    // MARK: Listeners

    final class Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock

        init(object: AudioObjectID, selector: AudioObjectPropertySelector, block: @escaping () -> Void) {
            self.object = object
            self.address = CoreAudioUtil.address(selector)
            self.block = { _, _ in block() }
            AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, self.block)
        }

        func remove() {
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
        }
    }

    static func listen(_ selector: AudioObjectPropertySelector, block: @escaping () -> Void) -> Listener {
        Listener(object: AudioObjectID(kAudioObjectSystemObject), selector: selector, block: block)
    }
}
