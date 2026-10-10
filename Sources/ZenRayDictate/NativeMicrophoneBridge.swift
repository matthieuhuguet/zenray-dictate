import AudioToolbox
import CoreAudio
import Foundation

// 10 October 2026: input-only AUHAL microphone bridge that binds directly to the selected
// CoreAudio input device (MacBook Pro or iPhone Continuity) and streams 16 kHz mono PCM16
// into WKWebView's WebAudio MediaStreamDestination, bypassing WebKit's buggy VPIO/AUVPAggregate
// when AirPods Pro or Sony WH-1000XM3/XM5 are connected as output.
final class NativeMicrophoneBridge: @unchecked Sendable {
    typealias ChunkHandler = @Sendable (_ base64PCM16: String, _ sampleRate: Int) -> Void

    private let lock = NSLock()
    private var audioUnit: AudioUnit?
    private var currentDeviceID: AudioDeviceID = 0
    private var hardwareSampleRate: Double = 48_000
    private let targetSampleRate: Double = 16_000
    private var resamplePhase: Double = 0
    private var pendingSamples: [Int16] = []
    private let chunkSamples = 640 // 10 October 2026: 40 ms chunks at 16 kHz (1280 bytes)
    private var onChunk: ChunkHandler?
    private var running = false
    private var renderBuffer = [Float](repeating: 0, count: 8192)

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func start(deviceID: AudioDeviceID, onChunk: @escaping ChunkHandler) -> Bool {
        stop()
        lock.lock()
        defer { lock.unlock() }

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            Log.write("NativeMicrophoneBridge: HALOutput component not found")
            return false
        }
        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let u = unit else {
            Log.write("NativeMicrophoneBridge: failed to instantiate HALOutput")
            return false
        }

        var enableInput: UInt32 = 1
        var disableOutput: UInt32 = 0
        let sIn = AudioUnitSetProperty(
            u,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        let sOut = AudioUnitSetProperty(
            u,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        var dev = deviceID
        let sDev = AudioUnitSetProperty(
            u,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &dev,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if sIn != noErr || sOut != noErr || sDev != noErr {
            Log.write("NativeMicrophoneBridge: setup failed (sIn=\(sIn), sOut=\(sOut), sDev=\(sDev), dev=\(deviceID))")
            AudioComponentInstanceDispose(u)
            return false
        }

        var hwFormat = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let sHw = AudioUnitGetProperty(
            u,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &hwFormat,
            &fmtSize
        )
        let hwRate = (sHw == noErr && hwFormat.mSampleRate > 0) ? hwFormat.mSampleRate : 48_000
        self.hardwareSampleRate = hwRate

        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: hwRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let sFmt = AudioUnitSetProperty(
            u,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &clientFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        if sFmt != noErr {
            Log.write("NativeMicrophoneBridge: client format failed (\(sFmt))")
            AudioComponentInstanceDispose(u)
            return false
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var callback = AURenderCallbackStruct(
            inputProc: { (inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _) -> OSStatus in
                let bridge = Unmanaged<NativeMicrophoneBridge>.fromOpaque(inRefCon).takeUnretainedValue()
                return bridge.handleRender(
                    ioActionFlags: ioActionFlags,
                    inTimeStamp: inTimeStamp,
                    inNumberFrames: inNumberFrames
                )
            },
            inputProcRefCon: selfPtr
        )
        let sCb = AudioUnitSetProperty(
            u,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        let sInit = AudioUnitInitialize(u)
        let sStart = AudioOutputUnitStart(u)
        if sCb != noErr || sInit != noErr || sStart != noErr {
            Log.write("NativeMicrophoneBridge: start failed (sCb=\(sCb), sInit=\(sInit), sStart=\(sStart))")
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
            return false
        }

        self.audioUnit = u
        self.currentDeviceID = deviceID
        self.resamplePhase = 0
        self.verificationReadIndex = 0
        self.pendingSamples.removeAll(keepingCapacity: true)
        self.onChunk = onChunk
        self.running = true
        Log.write("NativeMicrophoneBridge: started on deviceID=\(deviceID) at \(Int(hwRate)) Hz -> 16000 Hz")
        return true
    }

    #if DEBUG
    nonisolated(unsafe) static var verificationSamples: [Int16]?
    #endif
    private var verificationReadIndex = 0

    func switchDeviceIfRunning(to newDeviceID: AudioDeviceID) {
        lock.lock()
        let isActive = running
        let oldID = currentDeviceID
        let handler = onChunk
        lock.unlock()
        guard isActive, newDeviceID != 0, newDeviceID != oldID, let handler else { return }
        _ = start(deviceID: newDeviceID, onChunk: handler)
    }

    func stop() {
        lock.lock()
        let u = audioUnit
        let wasRunning = running
        audioUnit = nil
        running = false
        currentDeviceID = 0
        onChunk = nil
        pendingSamples.removeAll(keepingCapacity: false)
        lock.unlock()

        if let u {
            AudioOutputUnitStop(u)
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
            if wasRunning {
                Log.write("NativeMicrophoneBridge: stopped")
            }
        }
    }

    private func handleRender(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inNumberFrames: UInt32
    ) -> OSStatus {
        lock.lock()
        guard running, let u = audioUnit else {
            lock.unlock()
            return noErr
        }
        let frameCount = Int(inNumberFrames)
        if frameCount <= 0 || frameCount > renderBuffer.count {
            lock.unlock()
            return noErr
        }

        let status: OSStatus = renderBuffer.withUnsafeMutableBufferPointer { ptr in
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: inNumberFrames * 4,
                    mData: ptr.baseAddress
                )
            )
            return AudioUnitRender(u, ioActionFlags, inTimeStamp, 1, inNumberFrames, &abl)
        }
        guard status == noErr else {
            lock.unlock()
            return status
        }

        let step = hardwareSampleRate / targetSampleRate
        var idx = resamplePhase
        while Int(idx) < frameCount {
            let i0 = Int(idx)
            let s0 = renderBuffer[i0]
            let s1 = (i0 + 1 < frameCount) ? renderBuffer[i0 + 1] : s0
            let s2 = (i0 + 2 < frameCount) ? renderBuffer[i0 + 2] : s1
            let sample = (step >= 2.5) ? ((s0 + s1 + s2) / 3.0) : s0
            let clamped = max(-1.0 as Float, min(1.0 as Float, sample))
            var pcm16 = Int16(clamped * 32767.0)
            #if DEBUG
            if let vSamples = Self.verificationSamples {
                if verificationReadIndex < vSamples.count {
                    pcm16 = vSamples[verificationReadIndex]
                    verificationReadIndex += 1
                } else {
                    pcm16 = 0
                }
            }
            #endif
            pendingSamples.append(pcm16)
            idx += step
        }
        resamplePhase = idx - Double(frameCount)

        var emittedBase64: [String] = []
        while pendingSamples.count >= chunkSamples {
            let slice = Array(pendingSamples.prefix(chunkSamples))
            pendingSamples.removeFirst(chunkSamples)
            let data = slice.withUnsafeBufferPointer { buf in
                Data(buffer: buf)
            }
            emittedBase64.append(data.base64EncodedString())
        }
        let handler = onChunk
        let rate = Int(targetSampleRate)
        lock.unlock()

        if let handler, !emittedBase64.isEmpty {
            for b64 in emittedBase64 {
                handler(b64, rate)
            }
        }
        return noErr
    }
}
