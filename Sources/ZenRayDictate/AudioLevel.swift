import AVFoundation

// 26 October 2026, 12:20 CEST: Whisper invents words on near-silence (« Thank you. », « Mm. » measured on a recording whose peak was
// -44.8 dBFS). Claude answers « nothing heard » by itself; the local engines get this gate instead.
// FR : Whisper invente des mots sur un quasi-silence ; ce contrôle de niveau l'en empêche.
enum AudioLevel {
    /// Under this peak (dBFS) a recording holds no speech. Speech peaks around -30 to -6 dBFS, the room noise at -50 to -44.
    static let silencePeakDecibels = -42.0

    /// Highest absolute sample of the file, in dBFS (-160 for digital silence); nil if the file cannot be read.
    static func peakDecibels(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let chunk: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return nil }
        var peak: Float = 0
        while file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
            for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channel[index])) }
        }
        return peak > 0 ? 20 * log10(Double(peak)) : -160
    }

    /// True when the recording is too quiet to contain speech. An unreadable file is not called silent.
    static func isSilent(_ url: URL) -> Bool {
        guard let peak = peakDecibels(of: url) else { return false }
        return peak < silencePeakDecibels
    }
}
