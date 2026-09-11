import Foundation

// Iteration timestamp: 2026-09-11.
struct TranscriptionResult {
    let text: String
    let provider: String
}

enum TranscriptionError: LocalizedError {
    case missingCodexAuth
    case invalidCodexResponse
    case codexRejected(status: Int)
    case localEngineUnavailable
    case localEngineFailed(status: Int32)

    var errorDescription: String? {
        switch self {
        case .missingCodexAuth:
            return "Codex authentication is unavailable."
        case .invalidCodexResponse:
            return "The transcription service returned no text."
        case let .codexRejected(status):
            return "Codex transcription refused the recording (HTTP \(status))."
        case .localEngineUnavailable:
            return "The local transcription engine is not installed."
        case let .localEngineFailed(status):
            return "The local transcription engine failed (code \(status))."
        }
    }
}

final class TranscriptionPipeline {

    private let codex = CodexTranscriber()
    private let local = LocalWhisperTranscriber()

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        do {
            return try await codex.transcribe(audioURL: audioURL)
        } catch {
            Log.write("Codex transcription unavailable: \(error.localizedDescription); trying local engine")
        }

        return try await local.transcribe(audioURL: audioURL)
    }
}

private final class CodexTranscriber {

    private struct AuthFile: Decodable {
        struct Tokens: Decodable {
            let accessToken: String?
            let accountID: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case accountID = "account_id"
            }
        }

        let tokens: Tokens?
    }

    private struct Response: Decodable {
        let text: String?
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        let auth = try loadAuth()
        let boundary = "----ZenRayDictate-\(UUID().uuidString)"
        let body = try multipartBody(audioURL: audioURL, boundary: boundary)

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/transcribe")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(auth.accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("1", forHTTPHeaderField: "X-OpenAI-Attach-Auth")
        request.setValue("1", forHTTPHeaderField: "X-OpenAI-Attach-Integrity-State")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidCodexResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TranscriptionError.codexRejected(status: httpResponse.statusCode)
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let text = decoded.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              text.rangeOfCharacter(from: .alphanumerics) != nil else {
            throw TranscriptionError.invalidCodexResponse
        }
        return TranscriptionResult(text: text, provider: "Codex")
    }

    private func loadAuth() throws -> (accessToken: String, accountID: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(AuthFile.self, from: data),
              let accessToken = file.tokens?.accessToken,
              let accountID = file.tokens?.accountID,
              !accessToken.isEmpty,
              !accountID.isEmpty else {
            throw TranscriptionError.missingCodexAuth
        }
        return (accessToken, accountID)
    }

    private func multipartBody(audioURL: URL, boundary: String) throws -> Data {
        let audio = try Data(contentsOf: audioURL)
        var body = Data()
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"file\"; filename=\"codex.wav\"\r\n")
        body.appendUTF8("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        body.appendUTF8("\r\n--\(boundary)--\r\n")
        return body
    }
}

private final class LocalWhisperTranscriber: @unchecked Sendable {

    private let executable = "/Users/zenray/.venvs/asr-ja/bin/mlx_whisper"
    private let model = "/Users/zenray/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo/snapshots/a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb"

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        guard FileManager.default.isExecutableFile(atPath: executable),
              FileManager.default.fileExists(atPath: model) else {
            throw TranscriptionError.localEngineUnavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.run(audioURL: audioURL)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func run(audioURL: URL) throws -> TranscriptionResult {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenRayDictate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            audioURL.path,
            "--model", model,
            "--output-dir", outputDirectory.path,
            "--output-name", "result",
            "--output-format", "json",
            "--language", "fr",
            "--verbose", "False"
        ]
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
            throw TranscriptionError.invalidCodexResponse
        }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.rangeOfCharacter(from: .alphanumerics) != nil else {
            throw TranscriptionError.invalidCodexResponse
        }
        return TranscriptionResult(text: normalized, provider: "Local Whisper")
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(string.data(using: .utf8)!)
    }
}
