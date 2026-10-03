import CoreAudio
import Foundation

// 3 October 2026, 21:55 CEST: pin only the default input, keeping AirPods output independent.
final class BuiltinMicrophone: @unchecked Sendable {
    static let shared = BuiltinMicrophone()
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var listening = false
    private var listener: AudioObjectPropertyListenerBlock?
    var onFailure: ((Error) -> Void)?

    private func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector:selector,mScope:scope,mElement:kAudioObjectPropertyElementMain)
    }
    private func number(_ object:AudioObjectID,_ selector:AudioObjectPropertySelector) throws -> UInt32 {
        var property=address(selector),size=UInt32(MemoryLayout<UInt32>.size),value:UInt32=0
        try check(AudioObjectGetPropertyData(object,&property,0,nil,&size,&value))
        return value
    }
    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw NSError(domain:"ZenRayDictate.AudioInput",code:Int(status),userInfo:[NSLocalizedDescriptionKey:"Cannot lock the MacBook microphone (CoreAudio \(status))."]) }
    }
    func builtInDevice() throws -> AudioDeviceID {
        var property=address(kAudioHardwarePropertyDevices),size:UInt32=0
        try check(AudioObjectGetPropertyDataSize(system,&property,0,nil,&size))
        var devices=Array(repeating:AudioDeviceID(0),count:Int(size)/MemoryLayout<AudioDeviceID>.size)
        try devices.withUnsafeMutableBytes { buffer in try check(AudioObjectGetPropertyData(system,&property,0,nil,&size,buffer.baseAddress!)) }
        for device in devices {
            guard try number(device,kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn else { continue }
            var streams=address(kAudioDevicePropertyStreams,scope:kAudioObjectPropertyScopeInput),streamSize:UInt32=0
            if AudioObjectGetPropertyDataSize(device,&streams,0,nil,&streamSize)==noErr,streamSize>0 { return device }
        }
        throw NSError(domain:"ZenRayDictate.AudioInput",code:1,userInfo:[NSLocalizedDescriptionKey:"The built-in MacBook microphone is unavailable. AirPods will not be substituted."])
    }
    func name(_ device:AudioDeviceID) throws -> String {
        var property=address(kAudioObjectPropertyName),size=UInt32(MemoryLayout<UnsafeRawPointer?>.size),value:UnsafeRawPointer?
        try check(AudioObjectGetPropertyData(device,&property,0,nil,&size,&value))
        guard let value else { return "Unknown device" }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }
    func currentInput() throws -> AudioDeviceID { try number(system,kAudioHardwarePropertyDefaultInputDevice) }
    func currentOutput() throws -> AudioDeviceID { try number(system,kAudioHardwarePropertyDefaultOutputDevice) }
    func pin() throws {
        let device=try builtInDevice()
        if try currentInput() != device {
            var property=address(kAudioHardwarePropertyDefaultInputDevice),selected=device
            try check(AudioObjectSetPropertyData(system,&property,0,nil,UInt32(MemoryLayout<AudioDeviceID>.size),&selected))
        }
        guard try currentInput()==device else { throw NSError(domain:"ZenRayDictate.AudioInput",code:2,userInfo:[NSLocalizedDescriptionKey:"The MacBook microphone selection did not take effect."]) }
    }
    func start() throws {
        try pin()
        guard !listening else { return }
        let callback:AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            do { try self?.pin() } catch { self?.onFailure?(error) }
        }
        var property=address(kAudioHardwarePropertyDefaultInputDevice)
        try check(AudioObjectAddPropertyListenerBlock(system,&property,.main,callback))
        listener=callback;listening=true
    }
    func stop() {
        guard let listener else { return }
        var property=address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectRemovePropertyListenerBlock(system,&property,.main,listener)
        self.listener=nil;listening=false
    }
}
