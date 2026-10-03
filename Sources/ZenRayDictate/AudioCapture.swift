import AVFoundation
import Foundation

// Iteration timestamp: 2026-09-15 09:00.
final class AudioCapture: NSObject {

    enum CaptureError: LocalizedError {
        case microphoneDenied
        case inputUnavailable
        case engineStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "Microphone access is not allowed for ZenRay Dictate."
            case .inputUnavailable:
                return "No microphone input is available."
            case let .engineStartFailed(message):
                return "Audio capture could not start: \(message)"
            }
        }
    }

    // 3 October 2026, 16:10 CEST: normalize capture to 16 kHz mono and expose whisper gain.
    var gain: Float = 1
    var onLevel: ((Float) -> Void)?
    var onDuration: ((TimeInterval) -> Void)?

    private let fileManager = FileManager.default
    private let captureDirectory: URL
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var meterTimer: Timer?
    private var startedAt: Date?
    private(set) var currentURL: URL?

    override init() {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        captureDirectory = supportDirectory
            .appendingPathComponent("ZenRayDictate", isDirectory: true)
            .appendingPathComponent("Library/Pending", isDirectory: true)
        super.init()
    }

    var isCapturing: Bool { audioEngine?.isRunning == true }

    func start() throws -> URL {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw CaptureError.microphoneDenied
        }

        let input = AVAudioEngine()
        let inputNode = input.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw CaptureError.inputUnavailable
        }

        try fileManager.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let url = captureDirectory.appendingPathComponent("capture-\(UUID().uuidString).wav")
        guard let outputFormat = AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16_000,channels:1,interleaved:false),
              let converter = AVAudioConverter(from:inputFormat,to:outputFormat) else { throw CaptureError.inputUnavailable }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: outputFormat.sampleRate,
            AVNumberOfChannelsKey: outputFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)

        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            do {
                let count = AVAudioFrameCount(ceil(Double(buffer.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate)) + 32
                guard let converted = AVAudioPCMBuffer(pcmFormat:outputFormat,frameCapacity:count) else { return }
                var used = false; var conversionError: NSError?
                converter.convert(to:converted,error:&conversionError) { _, status in
                    if used { status.pointee = .noDataNow; return nil }
                    used = true; status.pointee = .haveData; return buffer
                }
                if let conversionError { throw conversionError }
                if self.gain != 1, let samples = converted.floatChannelData?[0] {
                    for index in 0..<Int(converted.frameLength) { samples[index] = min(1,max(-1,samples[index]*self.gain)) }
                }
                try file.write(from: converted)
            } catch {
                Log.write("audio capture write failed: \(error.localizedDescription)")
            }
            let level = self.level(from: buffer)
            DispatchQueue.main.async { [weak self] in
                self?.onLevel?(level)
            }
        }

        audioEngine = input
        audioFile = file
        currentURL = url
        startedAt = Date()

        input.prepare()
        do {
            try input.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            cleanupCapture()
            throw CaptureError.engineStartFailed(error.localizedDescription)
        }

        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.startedAt else { return }
            self.onDuration?(Date().timeIntervalSince(startedAt))
        }
        Log.write("independent audio capture started")
        return url
    }

    func stop() -> URL? {
        guard let engine = audioEngine, let url = currentURL else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        audioFile = nil
        audioEngine = nil
        startedAt = nil
        currentURL = nil

        guard let recording = try? AVAudioFile(forReading: url), recording.length > 0 else {
            Log.write("independent audio capture stopped without audio")
            return nil
        }
        Log.write("independent audio capture stopped: \(fileSize(of: url)) bytes")
        return url
    }

    func cancel() {
        let url = currentURL
        _ = stop()
        if let url { try? fileManager.removeItem(at: url) }
        Log.write("independent audio capture cancelled")
    }

    private func cleanupCapture() {
        meterTimer?.invalidate()
        meterTimer = nil
        audioFile = nil
        audioEngine = nil
        startedAt = nil
        currentURL = nil
    }

    private func fileSize(of url: URL) -> UInt64 {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    private func level(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0.05 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0.05 }
        var sum: Float = 0
        for index in 0..<count {
            let sample = channelData[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(count))
        return min(1, max(0.05, rms * 8))
    }
}
