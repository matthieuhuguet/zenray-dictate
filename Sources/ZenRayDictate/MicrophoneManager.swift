import AppKit
import CoreAudio
import Foundation
import Combine

// 10 October 2026: centralized microphone observation, switching between MacBook Pro and iPhone Continuity,
// and automatic restoration when Bluetooth headsets (AirPods, WH-1000XM3/XM5) hijack the system input.
public enum MicTransport: String, CaseIterable {
    case builtIn = "Intégré"
    case continuity = "iPhone"
    case usb = "USB"
    case bluetooth = "Bluetooth"
    case virtual = "Virtuel"
    case unknown = "Autre"

    public var iconName: String {
        switch self {
        case .builtIn: return "laptopcomputer"
        case .continuity: return "iphone"
        case .usb: return "mic.fill"
        case .bluetooth: return "headphones"
        case .virtual: return "waveform.circle"
        case .unknown: return "mic"
        }
    }

    public var isPreferredPhysicalMic: Bool {
        switch self {
        case .builtIn, .continuity, .usb:
            return true
        case .bluetooth, .virtual, .unknown:
            return false
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

    private static let preferredUIDKey = "ZenRayDictate.PreferredInputUID"
    private static let legacyLockKey = "ZenRayDictate.LockToBuiltIn"

    @Published public private(set) var activeDevice: AudioInputDevice?
    @Published public private(set) var availableDevices: [AudioInputDevice] = []
    @Published public private(set) var allInputDevices: [AudioInputDevice] = []

    public var onDeviceChanged: ((AudioInputDevice?) -> Void)?

    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var isListening = false
    private var isRestoringPreferred = false

    public var preferredInputUID: String {
        get {
            UserDefaults.standard.string(forKey: Self.preferredUIDKey) ?? "BuiltInMicrophoneDevice"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.preferredUIDKey)
        }
    }

    private init() {
        // 10 October 2026: disable legacy forced built-in-only lock so iPhone Continuity can be freely selected.
        UserDefaults.standard.set(false, forKey: Self.legacyLockKey)
        refreshDevices()
        ensurePreferredNonBluetoothInput()
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
                self.ensurePreferredNonBluetoothInput()
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
                self.ensurePreferredNonBluetoothInput()
                // 10 October 2026: re-check after 200 ms and 600 ms when AirPods in-ear detection triggers delayed dIn switch.
                try? await Task.sleep(nanoseconds: 200_000_000)
                self.refreshDevices()
                self.ensurePreferredNonBluetoothInput()
                try? await Task.sleep(nanoseconds: 400_000_000)
                self.refreshDevices()
                self.ensurePreferredNonBluetoothInput()
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

        var allList: [AudioInputDevice] = []
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

            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            var nameCF: CFString?
            _ = withUnsafeMutablePointer(to: &nameCF) { ptr in
                AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, ptr)
            }
            let name = (nameCF as String?) ?? "Microphone"

            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            var uidCF: CFString?
            _ = withUnsafeMutablePointer(to: &uidCF) { ptr in
                AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, ptr)
            }
            let uid = (uidCF as String?) ?? ""

            var rateAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var rateSize = UInt32(MemoryLayout<Float64>.size)
            var sampleRate: Float64 = 0
            _ = AudioObjectGetPropertyData(id, &rateAddr, 0, nil, &rateSize, &sampleRate)
            if sampleRate <= 0 {
                continue
            }

            var transportCode: UInt32 = 0
            var transSize = UInt32(MemoryLayout<UInt32>.size)
            var transAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectGetPropertyData(id, &transAddr, 0, nil, &transSize, &transportCode)

            let transport = classifyTransport(code: transportCode, uid: uid, name: name)
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
            allList.append(device)
            if isCurrent {
                active = device
            }
        }

        // 10 October 2026: remember whichever physical mic (MacBook Pro, iPhone Continuity, or USB) the user selected.
        if let active, active.transport.isPreferredPhysicalMic {
            preferredInputUID = active.uid
        }

        let selectable = allList
            .filter { $0.transport.isPreferredPhysicalMic }
            .sorted { a, b in
                let rankA = transportRank(a.transport)
                let rankB = transportRank(b.transport)
                if rankA != rankB { return rankA < rankB }
                return a.name < b.name
            }

        self.allInputDevices = allList
        self.availableDevices = selectable.isEmpty ? allList : selectable
        self.activeDevice = active
        self.onDeviceChanged?(active)
    }

    private func classifyTransport(code: UInt32, uid: String, name: String) -> MicTransport {
        if code == kAudioDeviceTransportTypeBuiltIn || uid.contains("BuiltIn") || name.contains("MacBook") {
            return .builtIn
        }
        // 'ccwl' (0x6363776c) or 'ccwd' (0x63637764) = Continuity Camera Microphone (iPhone)
        let ccwl: UInt32 = 0x6363776c
        let ccwd: UInt32 = 0x63637764
        if code == ccwl || code == ccwd || uid.contains("Continuity") || name.contains("iPhone") {
            return .continuity
        }
        if code == kAudioDeviceTransportTypeBluetooth || code == kAudioDeviceTransportTypeBluetoothLE
            || uid.contains(":input") || name.contains("WH-1000") || name.contains("AirPods") {
            return .bluetooth
        }
        if code == kAudioDeviceTransportTypeVirtual || code == kAudioDeviceTransportTypeAggregate
            || uid.contains("Loopback") || name.contains("Teams") || uid.contains("aggregate") {
            return .virtual
        }
        if code == kAudioDeviceTransportTypeUSB {
            return .usb
        }
        return .usb
    }

    private func transportRank(_ transport: MicTransport) -> Int {
        switch transport {
        case .builtIn: return 0
        case .continuity: return 1
        case .usb: return 2
        case .bluetooth: return 3
        case .virtual: return 4
        case .unknown: return 5
        }
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
        if let chosen = allInputDevices.first(where: { $0.id == id }), chosen.transport.isPreferredPhysicalMic {
            preferredInputUID = chosen.uid
        }
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

    public func switchToDevice(uid: String) -> Bool {
        refreshDevices()
        guard let target = allInputDevices.first(where: { $0.uid == uid || $0.uid.contains(uid) || $0.name.contains(uid) }) else {
            return false
        }
        switchToDevice(id: target.id)
        return activeDevice?.id == target.id
    }

    public func builtInDeviceID() -> AudioDeviceID? {
        return allInputDevices.first(where: { $0.transport == .builtIn })?.id
    }

    public func continuityDeviceID() -> AudioDeviceID? {
        return allInputDevices.first(where: { $0.transport == .continuity })?.id
    }

    public func preferredDeviceID() -> AudioDeviceID? {
        let targetUID = preferredInputUID
        if let match = allInputDevices.first(where: { $0.uid == targetUID && $0.transport.isPreferredPhysicalMic }) {
            return match.id
        }
        if let builtIn = builtInDeviceID() {
            return builtIn
        }
        if let continuity = continuityDeviceID() {
            return continuity
        }
        return availableDevices.first?.id
    }

    public func switchToBuiltIn() {
        if let builtInID = builtInDeviceID() {
            switchToDevice(id: builtInID)
        }
    }

    // 10 October 2026: only intervene if a Bluetooth headset (AirPods, WH-1000XM3/XM5) or virtual loopback
    // hijacked the input; never override the user's choice between MacBook Pro and iPhone Continuity.
    public func ensurePreferredNonBluetoothInput() {
        guard !isRestoringPreferred else { return }
        guard let current = activeDevice else { return }
        if current.transport.isPreferredPhysicalMic {
            preferredInputUID = current.uid
            return
        }
        guard let fallbackID = preferredDeviceID(), fallbackID != current.id else { return }
        isRestoringPreferred = true
        defer { isRestoringPreferred = false }
        Log.write("MicrophoneManager: Bluetooth/virtual input '\(current.name)' detected; restoring preferred input ID \(fallbackID)")
        switchToDevice(id: fallbackID)
    }

    public func makePillImage(isRecording: Bool = false) -> NSImage {
        // 10 October 2026: pure vector orange pill (0.5 pt inset to avoid outer edge clipping) and vector microphone glyph
        // avoiding NSSymbolImageRep lockFocus bounding-box clipping at top and sides.
        let height: CGFloat = 20
        let width: CGFloat = 32

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let pillRect = rect.insetBy(dx: 0.5, dy: 0.5)
            let bgPath = NSBezierPath(roundedRect: pillRect, xRadius: pillRect.height / 2, yRadius: pillRect.height / 2)
            let orangeColor = NSColor(srgbRed: 1.0, green: 0.50, blue: 0.0, alpha: 1.0)
            orangeColor.setFill()
            bgPath.fill()

            NSColor.white.setFill()
            NSColor.white.setStroke()

            let cx = width / 2.0
            let strokeW: CGFloat = 1.35

            // 10 October 2026: microphone capsule dome (centered, y = 9.2..16.0)
            let capW: CGFloat = 3.8
            let capH: CGFloat = 6.8
            let capY: CGFloat = 9.2
            let capRect = NSRect(x: cx - capW / 2.0, y: capY, width: capW, height: capH)
            let capPath = NSBezierPath(roundedRect: capRect, xRadius: capW / 2.0, yRadius: capW / 2.0)
            capPath.fill()

            // 10 October 2026: U-shaped cradle around the capsule with rounded caps
            let cradle = NSBezierPath()
            let r: CGFloat = 3.55
            let arcCY: CGFloat = 11.1
            let armTopY: CGFloat = 11.8
            cradle.move(to: NSPoint(x: cx - r, y: armTopY))
            cradle.line(to: NSPoint(x: cx - r, y: arcCY))
            cradle.appendArc(withCenter: NSPoint(x: cx, y: arcCY), radius: r, startAngle: 180, endAngle: 360, clockwise: false)
            cradle.line(to: NSPoint(x: cx + r, y: armTopY))
            cradle.lineWidth = strokeW
            cradle.lineCapStyle = .round
            cradle.stroke()

            // 10 October 2026: vertical stem and horizontal base with rounded caps (bottom at y = 4.0)
            let baseY: CGFloat = 4.7
            let stem = NSBezierPath()
            stem.move(to: NSPoint(x: cx, y: arcCY - r))
            stem.line(to: NSPoint(x: cx, y: baseY))
            stem.lineWidth = strokeW
            stem.lineCapStyle = .round
            stem.stroke()

            let base = NSBezierPath()
            let baseHalfW: CGFloat = 2.35
            base.move(to: NSPoint(x: cx - baseHalfW, y: baseY))
            base.line(to: NSPoint(x: cx + baseHalfW, y: baseY))
            base.lineWidth = strokeW
            base.lineCapStyle = .round
            base.stroke()

            return true
        }

        image.isTemplate = false
        return image
    }
}
