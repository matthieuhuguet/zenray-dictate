import AVFoundation
import Foundation

// 25 October 2026, 19:05 CEST: Claude speech-to-text engine. It streams the recording to the same
// voice_stream WebSocket that claude.ai, Claude Desktop and Claude Code use (server model harmonic-asr-8,
// measured on FLEURS: WER en 2.96 %, fr 4.40 %, CER ja 1.22 %, against Nova-3 9.63 / 10.51 / 8.28).
// 25 October 2026, 21:40 CEST: live mode. Like claude.ai, the socket opens when Fn is pressed and audio is sent
// while Matthieu speaks; at stop only CloseStream remains, and the latest interim text is shown at once.
// FR : moteur de dictée Claude ; en direct, la connexion s'ouvre à l'appui sur Fn et le son part pendant la parole.
final class ClaudeVoiceTranscriber: @unchecked Sendable {

    /// Wire constants of the voice_stream protocol, read from the Claude Code 2.1.308 binary and the
    /// claude.ai bundle of 25 October 2026. User-facing knobs live in DictationPreferences.
    struct Wire {
        static let path = "/api/ws/speech_to_text/voice_stream"
        static let sampleRate = 16_000
        static let chunkBytes = 3_200            // 100 ms of 16 kHz mono s16le
        static let chunkPauseNanoseconds: UInt64 = 5_000_000
        static let endpointingMs = "300"
        static let utteranceEndMs = "1000"
        static let finishTimeoutSeconds: Double = 20
        static let liveFinalTimeoutSeconds: Double = 6
        static let keychainService = "Claude Code-credentials"
    }

    enum Failure: LocalizedError {
        case noToken, rejected(String), empty
        var errorDescription: String? {
            switch self {
            case .noToken: return "No Claude sign-in found. Open Claude Code or the Claude app once, then retry."
            case let .rejected(reason): return "Claude dictation refused the request: \(reason)"
            case .empty: return "Claude dictation returned no text."
            }
        }
    }

    /// File mode: used for retries, imports and as a fallback when the live session fails.
    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        let preferences = DictationLibrary.shared.document.preferences
        let pcm = try Self.pcm16(from: audioURL)
        do {
            return try await stream(pcm, preferences: preferences, token: try Self.token())
        } catch let Failure.rejected(reason) where reason.localizedCaseInsensitiveContains("authoriz") {
            // The OAuth token expired: let the official Claude CLI refresh it, then retry once.
            Log.write("Claude dictation token rejected (\(reason)); refreshing through the Claude CLI")
            Self.forgetToken()
            try Self.refreshToken(cli: preferences.claudeExecutable)
            return try await stream(pcm, preferences: preferences, token: try Self.token())
        }
    }

    // MARK: Request

    static func request(preferences: DictationPreferences, token: String, live: Bool) throws -> URLRequest {
        var query = [
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(Wire.sampleRate)),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "endpointing_ms", value: Wire.endpointingMs),
            URLQueryItem(name: "utterance_end_ms", value: Wire.utteranceEndMs),
            URLQueryItem(name: "use_conversation_engine", value: "true"),
            URLQueryItem(name: "announce_provider", value: "true"),
        ]
        // Live text while speaking, as claude.ai does (TranscriptInterim frames). / texte provisoire pendant la parole.
        if live { query.append(.init(name: "forward_interims", value: "typed")) }
        // "auto" is refused by the server; omitting the language lets it detect fr, en and ja itself.
        let language = preferences.language.trimmingCharacters(in: .whitespaces).lowercased()
        if !language.isEmpty && language != "auto" { query.append(.init(name: "language", value: language)) }
        if !preferences.claudeSttProvider.isEmpty { query.append(.init(name: "stt_provider", value: preferences.claudeSttProvider)) }
        let keyterms = Self.keyterms(preferences: preferences)
        if !keyterms.isEmpty { query.append(.init(name: "keyterms", value: keyterms.joined(separator: ","))) }
        guard var components = URLComponents(string: preferences.claudeVoiceBaseURL + Wire.path) else { throw Failure.rejected("invalid base URL") }
        components.queryItems = query
        guard let url = components.url else { throw Failure.rejected("invalid base URL") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("cli", forHTTPHeaderField: "x-app")
        return request
    }

    // MARK: File stream

    private func stream(_ pcm: Data, preferences: DictationPreferences, token: String) async throws -> TranscriptionResult {
        let task = URLSession.shared.webSocketTask(with: try Self.request(preferences: preferences, token: token, live: false))
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let collector = TranscriptCollector()
        let reader = Task { await collector.read(task) }
        try await task.send(.string("{\"type\":\"KeepAlive\"}"))
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + Wire.chunkBytes, pcm.count)
            try await task.send(.data(pcm.subdata(in: offset..<end)))
            offset = end
            try await Task.sleep(nanoseconds: Wire.chunkPauseNanoseconds)
        }
        try await task.send(.string("{\"type\":\"CloseStream\"}"))
        let outcome = await collector.wait(seconds: Wire.finishTimeoutSeconds)
        reader.cancel()
        if let error = outcome.error { throw Failure.rejected(error) }
        let text = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.empty }
        Log.write("Claude dictation: \(outcome.provider), \(text.count) characters")
        return TranscriptionResult(text: text, provider: "Claude " + outcome.provider)
    }

    // MARK: Audio, credentials and vocabulary

    /// Converts the recorded WAV (any format) to 16 kHz mono little-endian Int16.
    static func pcm16(from url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(Wire.sampleRate), channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw Failure.empty }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / file.processingFormat.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw Failure.empty }
        var used = false; var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if used { status.pointee = .endOfStream; return nil }
            used = true; status.pointee = .haveData; return input
        }
        if let conversionError { throw conversionError }
        guard let samples = output.int16ChannelData?[0], output.frameLength > 0 else { throw Failure.empty }
        return Data(bytes: samples, count: Int(output.frameLength) * 2)
    }

    // The token is read once and kept in memory: reading the keychain through a process cost time on every press.
    private static let tokenLock = NSLock()
    nonisolated(unsafe) private static var cachedToken: String?
    static func forgetToken() { tokenLock.lock(); cachedToken = nil; tokenLock.unlock() }

    /// Reads the Claude Code OAuth token through /usr/bin/security, which the keychain item already trusts.
    static func token() throws -> String {
        tokenLock.lock(); if let cachedToken { tokenLock.unlock(); return cachedToken }; tokenLock.unlock()
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", Wire.keychainService, "-w"]
        process.standardOutput = pipe; process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { throw Failure.noToken }
        tokenLock.lock(); cachedToken = token; tokenLock.unlock()
        return token
    }

    /// One tiny headless Claude call refreshes the stored OAuth token, exactly as Claude Code does itself.
    static func refreshToken(cli: String) throws {
        guard FileManager.default.isExecutableFile(atPath: cli) else { throw Failure.noToken }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["-p", "ok", "--model", "haiku"]
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") }
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
    }

    /// Bias words: the user's explicit list plus every "written" form of the vocabulary rules.
    static func keyterms(preferences: DictationPreferences) -> [String] {
        let typed = preferences.claudeKeyterms.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let learned = DictationLibrary.shared.document.vocabulary.map(\.written)
        var seen = Set<String>()
        return (typed + learned).filter { !$0.isEmpty && !$0.contains(",") && seen.insert($0.lowercased()).inserted }
            .prefix(preferences.claudeKeytermLimit).map { $0 }
    }
}

/// Gathers frames: TranscriptInterim is the live text, TranscriptText a sealed segment, an endpoint closes it.
actor TranscriptCollector {
    private var finals: [String] = []
    private var current = ""
    private var interim = ""
    private(set) var provider = "harmonic"
    private var error: String?
    private var finished = false

    /// Latest best text: sealed segments plus the live tail. / meilleur texte disponible maintenant.
    var liveText: String {
        let tail = current.isEmpty ? interim : current
        return (finals + (tail.isEmpty ? [] : [tail])).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func read(_ task: URLSessionWebSocketTask) async {
        while !finished {
            guard let message = try? await task.receive() else {
                if task.closeCode != .normalClosure && task.closeCode != .invalid, error == nil, finals.isEmpty, current.isEmpty {
                    error = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? "connection closed (\(task.closeCode.rawValue))"
                }
                finished = true; return
            }
            guard case let .string(json) = message,
                  let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            switch type {
            case "ProviderInfo": provider = (object["model"] as? String) ?? provider
            case "TranscriptInterim": interim = (object["data"] as? String) ?? interim
            case "TranscriptText": current = (object["data"] as? String) ?? current; interim = ""
            case "TranscriptEndpoint": if !current.isEmpty { finals.append(current); current = "" }; interim = ""
            case "TranscriptError", "error":
                let detail = (object["error"] as? [String: Any])?["message"] as? String
                error = detail ?? (object["description"] as? String) ?? (object["error_code"] as? String) ?? type
            default: break
            }
        }
    }

    func wait(seconds: Double) async -> (text: String, provider: String, error: String?) {
        let deadline = Date().addingTimeInterval(seconds)
        while !finished && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        let text = (finals + (current.isEmpty ? [] : [current])).joined(separator: " ")
        return (text, provider, text.isEmpty ? error : nil)
    }
}

/// One live dictation: opened at Fn press, fed with audio while speaking, finished at the second Fn press.
final class ClaudeLiveSession: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let collector = TranscriptCollector()
    private let continuation: AsyncStream<Data>.Continuation
    private var sender: Task<Void, Never>!
    private var reader: Task<Void, Never>!
    private let openedAt = Date()

    init(preferences: DictationPreferences) throws {
        task = URLSession.shared.webSocketTask(with: try ClaudeVoiceTranscriber.request(preferences: preferences, token: try ClaudeVoiceTranscriber.token(), live: true))
        var cont: AsyncStream<Data>.Continuation!
        let chunks = AsyncStream<Data>(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
        task.resume()
        let task = self.task, collector = self.collector
        reader = Task { await collector.read(task) }
        sender = Task {
            try? await task.send(.string("{\"type\":\"KeepAlive\"}"))
            for await chunk in chunks { try? await task.send(.data(chunk)) }
            try? await task.send(.string("{\"type\":\"CloseStream\"}"))
        }
        Log.write("Claude live session opened")
    }

    /// Called on the audio thread with 16 kHz PCM16. / appelé depuis le fil audio.
    func feed(_ pcm: Data) { continuation.yield(pcm) }

    /// The text available right now, without waiting for the server. / texte disponible immédiatement.
    func liveText() async -> String { await collector.liveText }

    /// Sends CloseStream and waits for the final text.
    func finish() async throws -> TranscriptionResult {
        continuation.finish()
        await sender.value
        let outcome = await collector.wait(seconds: ClaudeVoiceTranscriber.Wire.liveFinalTimeoutSeconds)
        reader.cancel(); task.cancel(with: .normalClosure, reason: nil)
        if let error = outcome.error {
            if error.localizedCaseInsensitiveContains("authoriz") { ClaudeVoiceTranscriber.forgetToken() }
            throw ClaudeVoiceTranscriber.Failure.rejected(error)
        }
        let text = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClaudeVoiceTranscriber.Failure.empty }
        Log.write("Claude live dictation: \(outcome.provider), \(text.count) characters, session \(Int(Date().timeIntervalSince(openedAt) * 1000)) ms")
        return TranscriptionResult(text: text, provider: "Claude " + outcome.provider)
    }

    func cancel() { continuation.finish(); reader.cancel(); sender.cancel(); task.cancel(with: .goingAway, reason: nil) }
}
