import Foundation

// Iteration timestamp: 2026-09-11.
struct TranscriptionResult {
    let text: String
    let provider: String
}

enum TranscriptionError: LocalizedError {
    case geminiUnavailable(String)
    case invalidResponse
    case localEngineUnavailable
    case localEngineFailed(status: Int32)

    var errorDescription: String? {
        switch self {
        case let .geminiUnavailable(message):
            return message
        case .invalidResponse:
            return "The transcription service returned no text."
        case .localEngineUnavailable:
            return "The local transcription engine is not installed."
        case let .localEngineFailed(status):
            return "The local transcription engine failed (code \(status))."
        }
    }
}

final class TranscriptionPipeline {

    // 3 October 2026, 16:00 CEST: the website owns its authentication and dictation transport.
    @MainActor private static let gemini = GeminiWebTranscriber()
    private let local = LocalWhisperTranscriber()

    @MainActor static func showGemini() { gemini.showSession() }
    // 3 October 2026, 21:35 CEST: default interaction goes directly to Gemini's live composer.
    @MainActor static func showComposer() { gemini.showComposer() }
    @MainActor static func startLive() { gemini.pressFn() }
    @MainActor static func stopLive() { gemini.releaseFn() }
    @MainActor static func toggleLive() { gemini.toggleLiveMicrophone() }
    @MainActor static func liveHandsFree() { gemini.fnSpace() }
    @MainActor static func cancelLive() { gemini.cancelLiveMicrophone() }

    @MainActor static func rewrite(_ text: String, instruction: String, model: String) async throws -> String {
        try await gemini.rewrite(text, instruction: instruction, model: model)
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        let preferences = DictationLibrary.shared.document.preferences
        if preferences.engine == .parakeet { return try await LocalParakeetTranscriber().transcribe(audioURL: audioURL) }
        if preferences.localOnly || preferences.engine == .whisper { return try await local.transcribe(audioURL: audioURL) }
        do {
            return try await Self.gemini.transcribe(audioURL: audioURL)
        } catch {
            if !preferences.allowLocalFallback { throw error }
            Log.write("Gemini web dictation unavailable: \(error.localizedDescription); trying local engine")
        }

        return try await local.transcribe(audioURL: audioURL)
    }
}

private final class LocalWhisperTranscriber: @unchecked Sendable {


    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        let settings = DictationLibrary.shared.document.preferences
        let terms = DictationLibrary.shared.document.vocabulary.map(\.written).joined(separator: ", ")
        guard FileManager.default.isExecutableFile(atPath: settings.whisperExecutable),
              FileManager.default.fileExists(atPath: settings.whisperModel) else {
            throw TranscriptionError.localEngineUnavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.run(audioURL: audioURL,settings:settings,terms:terms)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func run(audioURL: URL, settings: DictationPreferences, terms: String) throws -> TranscriptionResult {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenRayDictate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: settings.whisperExecutable)
        process.arguments = [
            audioURL.path,
            "--model", settings.whisperModel,
            "--output-dir", outputDirectory.path,
            "--output-name", "result",
            "--output-format", "json",
            "--verbose", "False"
        ]
        if settings.language != "auto", !settings.language.isEmpty { process.arguments! += ["--language", settings.language] }
        if !terms.isEmpty { process.arguments! += ["--initial-prompt", terms] }
        process.environment = ProcessInfo.processInfo.environment.merging(["HF_HUB_OFFLINE":"1","TRANSFORMERS_OFFLINE":"1"]) { _,new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw TranscriptionError.localEngineFailed(status: process.terminationStatus)
        }

        let resultURL = outputDirectory.appendingPathComponent("result.json")
        guard let data = try? Data(contentsOf: resultURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw TranscriptionError.invalidResponse
        }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.rangeOfCharacter(from: .alphanumerics) != nil else {
            throw TranscriptionError.invalidResponse
        }
        return TranscriptionResult(text: normalized, provider: "Local Whisper")
    }
}


// 3 October 2026, 16:02 CEST: use the already installed Parakeet executable without installing models.
private final class LocalParakeetTranscriber: @unchecked Sendable {
    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        let settings = DictationLibrary.shared.document.preferences
        guard FileManager.default.isExecutableFile(atPath: settings.parakeetExecutable) else { throw TranscriptionError.localEngineUnavailable }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ZenRayParakeet-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: folder) }
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: settings.parakeetExecutable)
                    process.arguments = [audioURL.path, "--model", settings.parakeetModel, "--output-dir", folder.path, "--output-format", "txt", "--output-template", "result"]
                    process.environment = ProcessInfo.processInfo.environment.merging(["HF_HUB_OFFLINE":"1","TRANSFORMERS_OFFLINE":"1"]) { _,new in new }
                    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                    try process.run(); process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw TranscriptionError.localEngineFailed(status: process.terminationStatus) }
                    let text = try String(contentsOf: folder.appendingPathComponent("result.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { throw TranscriptionError.invalidResponse }
                    continuation.resume(returning: .init(text: text, provider: "Local Parakeet"))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
