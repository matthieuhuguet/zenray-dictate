import CoreAudio
import Foundation

enum AudioInput {
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static var isWatching = false

    static func startKeepingPreferred() {
        _ = selectPreferred()
        guard !isWatching else { return }
        isWatching = true

        var address = defaultInputAddress
        AudioObjectAddPropertyListenerBlock(system, &address, .main) { _, _ in
            _ = selectPreferred()
        }
    }

    @discardableResult
    static func selectPreferred() -> String? {
        let inputs = devices().filter(hasInput)
        let chosen = inputs.first { name(of: $0).localizedCaseInsensitiveContains("MacBook Pro Microphone") }
            ?? inputs.first { name(of: $0).localizedCaseInsensitiveContains("iPhone") }
        guard let chosen else { return nil }

        var current = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultInputAddress
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &current) == noErr else {
            return nil
        }

        if current != chosen {
            var selected = chosen
            guard AudioObjectSetPropertyData(system, &address, 0, nil, size, &selected) == noErr else {
                return nil
            }
            Log.write("input microphone: \(name(of: chosen))")
        }
        return name(of: chosen)
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func devices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }

        var result = [AudioDeviceID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &result) == noErr else { return [] }
        return result
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func name(of device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return "" }
        return value?.takeUnretainedValue() as String? ?? ""
    }
}
