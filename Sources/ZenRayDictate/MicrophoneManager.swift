import AppKit
import CoreAudio
import Foundation
import Combine

// 09 October 2026: centralized microphone management, live observation, switching and auto-lock.
public enum MicTransport: String, CaseIterable {
    case builtIn = "Intégré"
    case bluetooth = "Bluetooth"
    case continuity = "iPhone"
    case usb = "USB"
    case virtual = "Virtuel"
    case unknown = "Autre"

    public var iconName: String {
        switch self {
        case .builtIn: return "laptopcomputer"
        case .bluetooth: return "headphones"
        case .continuity: return "iphone"
        case .usb: return "mic.fill"
        case .virtual: return "waveform.circle"
        case .unknown: return "mic"
        }
    }
}

public struct AudioInputDevice: Identifiable, Equatable {
    public let id: AudioDeviceID
    public let name: String
    public let shortName: String
    public let uid: String
    public let transport: MicTransport
    public let sampleRate: Double
    public let isDefault: Bool
}

@MainActor
public final class MicrophoneManager: ObservableObject {
    public static let shared = MicrophoneManager()

    @Published public private(set) var activeDevice: AudioInputDevice?
    @Published public private(set) var availableDevices: [AudioInputDevice] = []
    @Published public var isLockedToBuiltIn: Bool {
        didSet {
            UserDefaults.standard.set(isLockedToBuiltIn, forKey: "ZenRayDictate.LockToBuiltIn")
            if isLockedToBuiltIn {
                enforceBuiltInIfNeeded()
            }
        }
    }

    public var onDeviceChanged: ((AudioInputDevice?) -> Void)?

    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var isListening = false

    private init() {
        if UserDefaults.standard.object(forKey: "ZenRayDictate.LockToBuiltIn") == nil {
            UserDefaults.standard.set(true, forKey: "ZenRayDictate.LockToBuiltIn")
        }
        self.isLockedToBuiltIn = UserDefaults.standard.bool(forKey: "ZenRayDictate.LockToBuiltIn")
        refreshDevices()
        startListening()
    }

    public func startListening() {
        guard !isListening else { return }

        var defaultInputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let inputCallback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshDevices()
                if self.isLockedToBuiltIn {
                    self.enforceBuiltInIfNeeded()
                }
            }
        }
        _ = AudioObjectAddPropertyListenerBlock(systemObject, &defaultInputAddr, .main, inputCallback)
        defaultInputListener = inputCallback

        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devicesCallback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshDevices()
                if self.isLockedToBuiltIn {
                    self.enforceBuiltInIfNeeded()
                }
            }
        }
        _ = AudioObjectAddPropertyListenerBlock(systemObject, &devicesAddr, .main, devicesCallback)
        devicesListener = devicesCallback

        isListening = true
    }

    public func refreshDevices() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr else { return }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else { return }

        var defIn = AudioDeviceID(0)
        var defSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectGetPropertyData(systemObject, &defAddr, 0, nil, &defSize, &defIn)

        var list: [AudioInputDevice] = []
        var active: AudioInputDevice?

        for id in ids {
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &streamSize) == noErr, streamSize > 0 else {
                continue
            }

            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            var nameCF: CFString?
            _ = withUnsafeMutablePointer(to: &nameCF) { ptr in
                AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, ptr)
            }
            let name = (nameCF as String?) ?? "Microphone"

            var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            var uidCF: CFString?
            _ = withUnsafeMutablePointer(to: &uidCF) { ptr in
                AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, ptr)
            }
            let uid = (uidCF as String?) ?? ""

            var rateAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var rateSize = UInt32(MemoryLayout<Float64>.size)
            var sampleRate: Float64 = 0
            _ = AudioObjectGetPropertyData(id, &rateAddr, 0, nil, &rateSize, &sampleRate)

            let transport: MicTransport
            if uid.contains("BuiltIn") || name.contains("MacBook") {
                transport = .builtIn
            } else if uid.contains(":input") || name.contains("WH-1000") || name.contains("AirPods") {
                transport = .bluetooth
            } else if uid.contains("Continuity") || name.contains("iPhone") {
                transport = .continuity
            } else if uid.contains("Loopback") || name.contains("Teams") {
                transport = .virtual
            } else {
                transport = .usb
            }

            let shortName = cleanShortName(fullName: name, transport: transport)
            let isCurrent = (id == defIn)
            let device = AudioInputDevice(
                id: id,
                name: name,
                shortName: shortName,
                uid: uid,
                transport: transport,
                sampleRate: sampleRate,
                isDefault: isCurrent
            )
            list.append(device)
            if isCurrent {
                active = device
            }
        }

        self.availableDevices = list
        self.activeDevice = active
        self.onDeviceChanged?(active)
    }

    private func cleanShortName(fullName: String, transport: MicTransport) -> String {
        var clean = fullName
            .replacingOccurrences(of: " Microphone", with: "")
            .replacingOccurrences(of: " (Built-in)", with: "")
            .trimmingCharacters(in: .whitespaces)
        if clean.isEmpty {
            clean = transport.rawValue
        }
        return clean
    }

    public func switchToDevice(id: AudioDeviceID) {
        var defAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var targetID = id
        let status = AudioObjectSetPropertyData(
            systemObject,
            &defAddr,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &targetID
        )
        if status == noErr {
            refreshDevices()
        }
    }

    public func builtInDeviceID() -> AudioDeviceID? {
        return availableDevices.first(where: { $0.transport == .builtIn })?.id
    }

    public func switchToBuiltIn() {
        if let builtInID = builtInDeviceID() {
            switchToDevice(id: builtInID)
        }
    }

    public func enforceBuiltInIfNeeded() {
        guard let current = activeDevice else { return }
        if current.transport != .builtIn {
            switchToBuiltIn()
        }
    }

    public func makePillImage(isRecording: Bool = false) -> NSImage {
        // 09 October 2026: compact orange pill with microphone icon only, matching macOS privacy indicator style
        let height: CGFloat = 20
        let width: CGFloat = 32
        let iconSize: CGFloat = 11

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let bgPath = NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2)
            // Always vibrant Apple system orange, never red
            let orangeColor = NSColor(srgbRed: 1.0, green: 0.50, blue: 0.0, alpha: 1.0)
            orangeColor.setFill()
            bgPath.fill()

            let iconName = "mic.fill"
            if let micSymbol = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .bold)
                if let configured = micSymbol.withSymbolConfiguration(config) {
                    let tinted = configured.copy() as! NSImage
                    tinted.lockFocus()
                    NSColor.white.set()
                    NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
                    tinted.unlockFocus()
                    let iconX = (width - iconSize) / 2
                    let iconY = (height - iconSize) / 2
                    let iconRect = NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize)
                    tinted.draw(in: iconRect)
                }
            }
            return true
        }

        image.isTemplate = false
        return image
    }
}
