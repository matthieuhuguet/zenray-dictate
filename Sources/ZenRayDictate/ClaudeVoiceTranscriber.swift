import AVFoundation
import Foundation

// 25 October 2026, 19:05 CEST: Claude speech-to-text engine. It streams the recording to the same
// voice_stream WebSocket that claude.ai, Claude Desktop and Claude Code use (server model harmonic-asr-8,
// measured on FLEURS: WER en 2.96 %, fr 4.40 %, CER ja 1.22 %, against Nova-3 9.63 / 10.51 / 8.28).
// 25 October 2026, 21:40 CEST: live mode. Like claude.ai, the socket opens when Fn is pressed and audio is sent
// while Matthieu speaks; at stop only CloseStream remains, and the latest interim text is shown at once.
// 26 October 2026, 11:30 CEST: every failure is typed (ClaudeDictationFailure), an expired sign-in is renewed by
// ClaudeCredentials, a connection lost during the recording never returns a partial text, and busy or offline retries once.
// FR : moteur de dictée Claude ; en direct, la connexion s'ouvre à l'appui sur Fn et le son part pendant la parole.
final class ClaudeVoiceTranscriber: @unchecked Sendable {
    typealias Failure = ClaudeDictationFailure

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
        static let busyCloseCode = 4029                       // « Too many active sessions »
        static let busyRetryDelayNanoseconds: UInt64 = 1_500_000_000
        static let networkRetryDelayNanoseconds: UInt64 = 1_000_000_000
        static let maxAttempts = 3
        static let fileDeadlineSeconds: Double = 45          // after this the pipeline falls back to the local Whisper
        static let maxKeytermLength = 40                      // longer entries are snippets, not bias words
        static let maxKeytermCharacters = 1500                // total budget of the keyterms query value
    }

    // MARK: File mode

    /// File mode: used for retries, imports, the composer and as the fallback when the live session fails.
    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        let preferences = DictationLibrary.shared.document.preferences
        let pcm = try Self.pcm16(from: audioURL)
        let credentials = ClaudeCredentials.shared
        var attempt = 0
        while true {
            attempt += 1
            do {
                let token = try await credentials.freshToken(cli: preferences.claudeExecutable)
                return try await stream(pcm, preferences: preferences, token: token)
            } catch let failure as Failure {
                guard attempt < Wire.maxAttempts else { throw failure }
                switch failure {
                case .unauthorized:
                    // The server rejected a token that looked valid (revoked or expired early): renew it through the CLI.
                    Log.write("Claude dictation: token rejected by the server; renewing the sign-in (attempt \(attempt))")
                    credentials.forget()
                    _ = try await credentials.forceRefresh(cli: preferences.claudeExecutable)
                case .busy:
                    Log.write("Claude dictation: server busy; retrying in 1.5 s")
                    try await Task.sleep(nanoseconds: Wire.busyRetryDelayNanoseconds)
                case .network where attempt < 2:
                    Log.write("Claude dictation: network error (\(failure.localizedDescription)); retrying once")
                    try await Task.sleep(nanoseconds: Wire.networkRetryDelayNanoseconds)
                default:
                    throw failure
                }
            }
        }
    }

    private func stream(_ pcm: Data, preferences: DictationPreferences, token: String) async throws -> TranscriptionResult {
        let task = URLSession.shared.webSocketTask(with: try Self.request(preferences: preferences, token: token, live: false))
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let collector = TranscriptCollector()
        let reader = Task { await collector.read(task) }
        do {
            try await task.send(.string("{\"type\":\"KeepAlive\"}"))
            var offset = 0
            while offset < pcm.count {
                let end = min(offset + Wire.chunkBytes, pcm.count)
                try await task.send(.data(pcm.subdata(in: offset..<end)))
                offset = end
                try await Task.sleep(nanoseconds: Wire.chunkPauseNanoseconds)
            }
            await collector.markClosing()
            try await task.send(.string("{\"type\":\"CloseStream\"}"))
        } catch {
            // A refused upgrade or a closed socket surfaces here first; the reader may know the precise reason.
            reader.cancel()
            if let known = await collector.failure { throw known }
            throw Failure.classify(error, status: (task.response as? HTTPURLResponse)?.statusCode)
        }
        let outcome = await collector.wait(seconds: Wire.finishTimeoutSeconds)
        reader.cancel()
        if let failure = outcome.failure { throw failure }
        Log.write("Claude dictation: \(outcome.provider), \(outcome.text.count) characters")
        return TranscriptionResult(text: outcome.text, provider: "Claude " + outcome.provider)
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
        guard var components = URLComponents(string: preferences.claudeVoiceBaseURL + Wire.path) else { throw Failure.rejected("adresse du serveur invalide") }
        components.queryItems = query
        guard let url = components.url else { throw Failure.rejected("adresse du serveur invalide") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("cli", forHTTPHeaderField: "x-app")
        return request
    }

    // MARK: Audio and vocabulary

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

    /// Bias words: the user's explicit list plus the « written » form of the vocabulary rules. A bias word is a short term:
    /// long phrases (snippets) and newlines are skipped, and the whole list stays under `maxKeytermCharacters`, so the
    /// request URL never grows past what the server accepts. / un mot-clé est un terme court, la liste reste bornée.
    static func keyterms(preferences: DictationPreferences) -> [String] {
        let typed = preferences.claudeKeyterms.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let learned = DictationLibrary.shared.document.vocabulary.map(\.written)
        var seen = Set<String>(); var total = 0; var kept: [String] = []
        for term in typed + learned {
            guard !term.isEmpty, term.count <= Wire.maxKeytermLength, !term.contains(","), !term.contains("\n"),
                  seen.insert(term.lowercased()).inserted, kept.count < preferences.claudeKeytermLimit,
                  total + term.count + 1 <= Wire.maxKeytermCharacters else { continue }
            kept.append(term); total += term.count + 1
        }
        return kept
    }
}

struct TranscriptOutcome { let text: String; let provider: String; let failure: ClaudeDictationFailure? }

/// Gathers frames: TranscriptInterim is the live text, TranscriptText a sealed segment, an endpoint closes it.
/// A socket that closes before CloseStream was sent is a lost connection: its partial text is never returned as final.
actor TranscriptCollector {
    private var finals: [String] = []
    private var current = ""
    private var interim = ""
    private(set) var provider = "harmonic"
    private(set) var failure: ClaudeDictationFailure?
    private var finished = false
    private var closing = false
    private var droppedEarly = false

    /// Latest best text: sealed segments plus the live tail. / meilleur texte disponible maintenant.
    var liveText: String {
        let tail = current.isEmpty ? interim : current
        return (finals + (tail.isEmpty ? [] : [tail])).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Call right before CloseStream is sent: from then on a close is the expected end. / une fermeture devient normale.
    func markClosing() { closing = true }

    func read(_ task: URLSessionWebSocketTask) async {
        while !finished {
            let message: URLSessionWebSocketTask.Message
            do { message = try await task.receive() }
            catch {
                if failure == nil {
                    let code = task.closeCode
                    if code != .invalid && code != .normalClosure {
                        failure = Self.closeFailure(code: code.rawValue, reason: task.closeReason.flatMap { String(data: $0, encoding: .utf8) })
                    } else if !closing {
                        failure = ClaudeDictationFailure.classify(error, status: (task.response as? HTTPURLResponse)?.statusCode)
                    }
                    if !closing { droppedEarly = true }
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
            case "TranscriptError", "error": failure = failure ?? Self.frameFailure(object)
            default: break
            }
        }
    }

    /// Final text, or the failure to report. A lost connection always fails, an error frame fails only without text.
    func wait(seconds: Double) async -> TranscriptOutcome {
        let deadline = Date().addingTimeInterval(seconds)
        while !finished && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        let text = (finals + (current.isEmpty ? [] : [current])).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if droppedEarly, let failure { return TranscriptOutcome(text: "", provider: provider, failure: failure) }
        if text.isEmpty { return TranscriptOutcome(text: "", provider: provider, failure: failure ?? .empty) }
        return TranscriptOutcome(text: text, provider: provider, failure: nil)
    }

    static func closeFailure(code: Int, reason: String?) -> ClaudeDictationFailure {
        let text = reason ?? ""
        if code == ClaudeVoiceTranscriber.Wire.busyCloseCode { return .busy }
        if text.localizedCaseInsensitiveContains("authoriz") { return .unauthorized }
        return .rejected(text.isEmpty ? "connexion fermée (code \(code))" : text)
    }

    static func frameFailure(_ object: [String: Any]) -> ClaudeDictationFailure {
        let nested = object["error"] as? [String: Any]
        let message = (nested?["message"] as? String) ?? (object["description"] as? String) ?? ""
        let code = ((nested?["details"] as? [String: Any])?["error_code"] as? String) ?? (object["error_code"] as? String) ?? ""
        if code == "rate_limit" || (object["limit"] as? String) == "concurrent" { return .busy }
        if message.localizedCaseInsensitiveContains("authoriz") || code.contains("session_invalid") || code.contains("unauthor") { return .unauthorized }
        return .rejected(message.isEmpty ? (code.isEmpty ? "erreur du serveur" : code) : message)
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

    /// `token` must be valid now: the caller checks it, because opening with an expired token only fails after the recording.
    init(preferences: DictationPreferences, token: String) throws {
        task = URLSession.shared.webSocketTask(with: try ClaudeVoiceTranscriber.request(preferences: preferences, token: token, live: true))
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

    /// Sends CloseStream and waits for the final text. Throws a typed failure, never a partial text.
    func finish() async throws -> TranscriptionResult {
        await collector.markClosing()
        continuation.finish()
        await sender.value
        let outcome = await collector.wait(seconds: ClaudeVoiceTranscriber.Wire.liveFinalTimeoutSeconds)
        reader.cancel(); task.cancel(with: .normalClosure, reason: nil)
        if let failure = outcome.failure {
            if failure == .unauthorized { ClaudeCredentials.shared.forget() }
            throw failure
        }
        Log.write("Claude live dictation: \(outcome.provider), \(outcome.text.count) characters, session \(Int(Date().timeIntervalSince(openedAt) * 1000)) ms")
        return TranscriptionResult(text: outcome.text, provider: "Claude " + outcome.provider)
    }

    func cancel() { continuation.finish(); reader.cancel(); sender.cancel(); task.cancel(with: .goingAway, reason: nil) }
}
