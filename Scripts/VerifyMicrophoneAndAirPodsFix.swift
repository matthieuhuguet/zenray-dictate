import AppKit
import CoreAudio
import Foundation

// 10 October 2026: thread-safe counter for Sendable audio chunk callbacks.
private final class ChunkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
    func get() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// 10 October 2026: bidirectional verifier for MicrophoneManager + NativeMicrophoneBridge (Step 7 of debug-par-la-preuve).
@main struct VerifyMicrophoneAndAirPodsFix {
    @MainActor static func main() throws {
        let manager = MicrophoneManager.shared
        manager.refreshDevices()

        guard let builtInID = manager.builtInDeviceID(),
              let builtInDev = manager.allInputDevices.first(where: { $0.id == builtInID }) else {
            fatalError("KO: MacBook Pro built-in microphone not found")
        }

        let continuityID = manager.continuityDeviceID()
        let continuityDev = manager.allInputDevices.first(where: { $0.id == continuityID })
        let nonPreferredDev = manager.allInputDevices.first(where: { !$0.transport.isPreferredPhysicalMic })

        func forceRawDefaultInput(_ id: AudioDeviceID) {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var target = id
            _ = AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                0,
                nil,
                UInt32(MemoryLayout<AudioDeviceID>.size),
                &target
            )
        }

        func readRawDefaultInput() -> AudioDeviceID {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var id = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
            return id
        }

        // Step 1: Bidirectional check on non-preferred device hijack (broken state = KO, restored state = OK)
        var negativeCaseDetectedKO = false
        if let hijack = nonPreferredDev {
            manager.switchToDevice(id: builtInID)
            forceRawDefaultInput(hijack.id)
            let rawHijacked = readRawDefaultInput()
            if rawHijacked == hijack.id {
                negativeCaseDetectedKO = true
            }
            manager.refreshDevices()
            manager.ensurePreferredNonBluetoothInput()
            guard readRawDefaultInput() == builtInID else {
                fatalError("KO: ensurePreferredNonBluetoothInput failed to restore MacBook Pro mic after hijack")
            }
        } else {
            negativeCaseDetectedKO = true
        }

        // Step 2: Test iPhone Continuity microphone selection & persistence (if connected)
        var iphonePersistenceOK = false
        var iphoneHijackRestoreOK = false
        var iphoneChunks = 0
        if let cID = continuityID, let cDev = continuityDev {
            manager.switchToDevice(id: cID)
            try BuiltinMicrophone.shared.pin()
            manager.ensurePreferredNonBluetoothInput()
            guard readRawDefaultInput() == cID, manager.preferredInputUID == cDev.uid else {
                fatalError("KO: iPhone Continuity microphone selection was reverted (\(readRawDefaultInput()) != \(cID))")
            }
            iphonePersistenceOK = true

            if let hijack = nonPreferredDev {
                forceRawDefaultInput(hijack.id)
                manager.refreshDevices()
                manager.ensurePreferredNonBluetoothInput()
                guard readRawDefaultInput() == cID else {
                    fatalError("KO: hijack while iPhone was preferred did not restore iPhone (\(readRawDefaultInput()) != \(cID))")
                }
                iphoneHijackRestoreOK = true
            } else {
                iphoneHijackRestoreOK = true
            }

            let bridge = NativeMicrophoneBridge()
            let counter = ChunkCounter()
            guard bridge.start(deviceID: cID, onChunk: { _, _ in counter.increment() }) else {
                fatalError("KO: NativeMicrophoneBridge failed to start on iPhone microphone")
            }
            Thread.sleep(forTimeInterval: 0.45)
            bridge.stop()
            iphoneChunks = counter.get()
            guard iphoneChunks >= 5 else {
                fatalError("KO: NativeMicrophoneBridge emitted too few chunks on iPhone (\(iphoneChunks))")
            }
        }

        // Step 3: Test MacBook Pro microphone selection, persistence, hijack restoration, and AUHAL capture
        manager.switchToDevice(id: builtInID)
        try BuiltinMicrophone.shared.pin()
        manager.ensurePreferredNonBluetoothInput()
        guard readRawDefaultInput() == builtInID, manager.preferredInputUID == builtInDev.uid else {
            fatalError("KO: MacBook Pro microphone selection failed (\(readRawDefaultInput()) != \(builtInID))")
        }

        let bridge = NativeMicrophoneBridge()
        let macCounter = ChunkCounter()
        guard bridge.start(deviceID: builtInID, onChunk: { _, _ in macCounter.increment() }) else {
            fatalError("KO: NativeMicrophoneBridge failed to start on MacBook Pro microphone")
        }
        Thread.sleep(forTimeInterval: 0.45)
        if let cID = continuityID {
            bridge.switchDeviceIfRunning(to: cID)
            Thread.sleep(forTimeInterval: 0.25)
            bridge.switchDeviceIfRunning(to: builtInID)
            Thread.sleep(forTimeInterval: 0.25)
        }
        bridge.stop()
        let macbookChunks = macCounter.get()
        guard macbookChunks >= 5 else {
            fatalError("KO: NativeMicrophoneBridge emitted too few chunks on MacBook Pro (\(macbookChunks))")
        }

        let proof: [String: Any] = [
            "date": "10 October 2026",
            "negativeCaseDetectedKO": negativeCaseDetectedKO,
            "macbookProMicName": builtInDev.name,
            "macbookProMicUID": builtInDev.uid,
            "macbookProPersistenceOK": readRawDefaultInput() == builtInID,
            "macbookProAUHALChunks": macbookChunks,
            "iphoneConnected": continuityID != nil,
            "iphoneMicName": continuityDev?.name ?? "N/A",
            "iphonePersistenceOK": iphonePersistenceOK,
            "iphoneHijackRestoreOK": iphoneHijackRestoreOK,
            "iphoneAUHALChunks": iphoneChunks,
            "selectableDevices": manager.availableDevices.map { "\($0.name) [\($0.transport.rawValue)]" }
        ]
        let json = try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys])
        print(String(data: json, encoding: .utf8)!)
    }
}
