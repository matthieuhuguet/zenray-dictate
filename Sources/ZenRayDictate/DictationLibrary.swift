import Foundation

// 3 October 2026, 15:58 CEST: settings, vocabulary, modes and history share one durable library.
enum DictationEngine: String, Codable, CaseIterable { case gemini, whisper, parakeet }
struct TextRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var spoken: String
    var written: String
}
struct DictationMode: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var prompt: String
    var tone: String = ""
    var applications: [String] = []
    var useScreenContext = false
}
struct DictationPreferences: Codable {
    var engine: DictationEngine = .gemini
    var localOnly = false
    var allowLocalFallback = true
    var keepAudio = false
    var keepHistory = true
    var learnVocabulary = false
    var whisperMode = false
    var fnPushToTalk = true
    var shortcutKeyCode: UInt32 = 2
    var shortcutModifiers: UInt32 = 4096
    var activeMode = "verbatim"
    var language = "auto"
    var clipboardRestoreDelay: Double = 0.6
    var doublePressInterval: Double = 0.35
    var model = "Flash"
    var whisperExecutable = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".venvs/asr-ja/bin/mlx_whisper").path
    var whisperModel = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo/snapshots/a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb").path
    var parakeetExecutable = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".venvs/asr-ja/bin/parakeet-mlx").path
    var parakeetModel = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub/models--mlx-community--parakeet-tdt_ctc-0.6b-ja/snapshots/e3810190ff521dcd208bc444a71bf877f3864566").path
    // 3 October 2026, 19:45 CEST: older libraries retain settings when new preferences are added.
    init() {}
    enum CodingKeys: String, CodingKey { case engine, localOnly, allowLocalFallback, keepAudio, keepHistory, learnVocabulary, whisperMode, fnPushToTalk, shortcutKeyCode, shortcutModifiers, activeMode, language, clipboardRestoreDelay, doublePressInterval, model, whisperExecutable, whisperModel, parakeetExecutable, parakeetModel }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy:CodingKeys.self)
        engine = try values.decodeIfPresent(DictationEngine.self,forKey:.engine) ?? engine
        localOnly = try values.decodeIfPresent(Bool.self,forKey:.localOnly) ?? localOnly
        allowLocalFallback = try values.decodeIfPresent(Bool.self,forKey:.allowLocalFallback) ?? allowLocalFallback
        keepAudio = try values.decodeIfPresent(Bool.self,forKey:.keepAudio) ?? keepAudio
        keepHistory = try values.decodeIfPresent(Bool.self,forKey:.keepHistory) ?? keepHistory
        learnVocabulary = try values.decodeIfPresent(Bool.self,forKey:.learnVocabulary) ?? learnVocabulary
        whisperMode = try values.decodeIfPresent(Bool.self,forKey:.whisperMode) ?? whisperMode
        fnPushToTalk = try values.decodeIfPresent(Bool.self,forKey:.fnPushToTalk) ?? fnPushToTalk
        shortcutKeyCode = try values.decodeIfPresent(UInt32.self,forKey:.shortcutKeyCode) ?? shortcutKeyCode
        shortcutModifiers = try values.decodeIfPresent(UInt32.self,forKey:.shortcutModifiers) ?? shortcutModifiers
        activeMode = try values.decodeIfPresent(String.self,forKey:.activeMode) ?? activeMode
        language = try values.decodeIfPresent(String.self,forKey:.language) ?? language
        clipboardRestoreDelay = try values.decodeIfPresent(Double.self,forKey:.clipboardRestoreDelay) ?? clipboardRestoreDelay
        doublePressInterval = try values.decodeIfPresent(Double.self,forKey:.doublePressInterval) ?? doublePressInterval
        model = try values.decodeIfPresent(String.self,forKey:.model) ?? model
        whisperExecutable = try values.decodeIfPresent(String.self,forKey:.whisperExecutable) ?? whisperExecutable
        whisperModel = try values.decodeIfPresent(String.self,forKey:.whisperModel) ?? whisperModel
        parakeetExecutable = try values.decodeIfPresent(String.self,forKey:.parakeetExecutable) ?? parakeetExecutable
        parakeetModel = try values.decodeIfPresent(String.self,forKey:.parakeetModel) ?? parakeetModel
    }
}

struct DictationRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var rawText: String
    var text: String
    var provider: String
    var modeID: String
    var application: String
    var audioFile: String?
    var inserted: Bool
}
struct LibraryDocument: Codable {
    var schemaVersion = 1
    var preferences = DictationPreferences()
    var vocabulary: [TextRule] = []
    var replacements: [TextRule] = []
    var snippets: [TextRule] = []
    var modes: [DictationMode] = [
        .init(id: "verbatim", name: "Verbatim", prompt: ""),
        .init(id: "clean", name: "Clean dictation", prompt: "Remove hesitations and resolve spoken self-corrections. Preserve meaning and vocabulary. Add natural punctuation. Return only the corrected text."),
        .init(id: "message", name: "Message", prompt: "Format the dictation as a natural short message. Preserve the speaker's style and all facts. Return only the message."),
        .init(id: "email", name: "Email", prompt: "Format the dictation as an email with paragraphs. Do not invent recipients, facts or a signature. Return only the email."),
        .init(id: "notes", name: "Notes", prompt: "Organize the dictation as concise notes, preserving every concrete detail. Return only the notes."),
        .init(id: "code", name: "Code", prompt: "Transcribe technical dictation precisely. Resolve camelCase, snake_case, acronyms and spoken punctuation. Preserve filenames and code. Return only the requested text."),
        .init(id: "agent", name: "Agent prompt", prompt: "Structure this spoken task for a coding agent: objective, relevant files, constraints, acceptance checks. Do not invent details. Return only the task."),
    ]
    var history: [DictationRecord] = []
    var lastError: String?
}
final class DictationLibrary {
    static let shared = DictationLibrary()
    let directory: URL
    var document: LibraryDocument
    private let file: URL
    private var recoveryBlocked = false
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ZenRayDictate/Library", isDirectory: true)
        file = self.directory.appendingPathComponent("Library.json")
        document = LibraryDocument()
        if FileManager.default.fileExists(atPath:file.path) {
            do { document = try JSONDecoder().decode(LibraryDocument.self,from:Data(contentsOf:file)) }
            catch {
                let recovery = self.directory.appendingPathComponent("Recovery",isDirectory:true)
                do {
                    try FileManager.default.createDirectory(at:recovery,withIntermediateDirectories:true)
                    try FileManager.default.copyItem(at:file,to:recovery.appendingPathComponent("Library-" + UUID().uuidString + ".json"))
                    document.lastError = "The library could not be read. Its original file is preserved in Recovery. " + error.localizedDescription
                } catch { recoveryBlocked = true; document.lastError = "The library could not be read or backed up. Do not save settings before recovering Library.json. " + error.localizedDescription }
            }
        }
    }
    func save() throws {
        guard !recoveryBlocked else { throw TranscriptionError.geminiUnavailable("Library recovery failed; the original Library.json is protected from overwrite.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func mode(for application: String, override: String? = nil) -> DictationMode {
        if let override, let selected = document.modes.first(where: { $0.id == override }) { return selected }
        return document.modes.first(where: { $0.applications.contains(application) })
            ?? document.modes.first(where: { $0.id == document.preferences.activeMode }) ?? document.modes.first ?? LibraryDocument().modes[0]
    }
    func normalize(_ text: String) -> String {
        var result = text
        if let snippet = document.snippets.first(where: { $0.spoken.caseInsensitiveCompare(text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: .punctuationCharacters)) == .orderedSame }) { return snippet.written }
        for rule in (document.vocabulary + document.replacements).sorted(by: { $0.spoken.count > $1.spoken.count }) {
            guard !rule.spoken.isEmpty else { continue }
            let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: rule.spoken) + "(?![\\p{L}\\p{N}_])"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: NSRegularExpression.escapedTemplate(for: rule.written))
            }
        }
        return result
    }
    func importCSV(_ csv: String) throws -> Int {
        let rows = try CSVRows.parse(csv)
        let rules = rows.enumerated().compactMap { index, row -> TextRule? in
            guard row.count >= 2, !row[0].isEmpty else { return nil }
            if index == 0 && ["spoken", "term", "from"].contains(row[0].lowercased()) { return nil }
            return TextRule(spoken: row[0], written: row[1])
        }
        let before = document.vocabulary.count
        for rule in rules where !document.vocabulary.contains(where: { $0.spoken.caseInsensitiveCompare(rule.spoken) == .orderedSame }) { document.vocabulary.append(rule) }
        try save(); return document.vocabulary.count - before
    }
    func learnCorrection(before: String, after: String) {
        guard document.preferences.learnVocabulary else { return }
        let old = before.split(whereSeparator: \.isWhitespace).map(String.init)
        let new = after.split(whereSeparator: \.isWhitespace).map(String.init)
        guard old.count == new.count else { return }
        for (spoken, written) in zip(old,new) where spoken != written && written.count > 1 {
            if !document.vocabulary.contains(where: { $0.spoken == spoken }) { document.vocabulary.append(.init(spoken: spoken, written: written)) }
        }
    }
    func record(raw: String, text: String, provider: String, mode: String, application: String, audioURL: URL?, inserted: Bool) throws {
        guard document.preferences.keepHistory else { return }
        var entry = DictationRecord(rawText: raw, text: text, provider: provider, modeID: mode, application: application, inserted: inserted)
        if document.preferences.keepAudio, let audioURL {
            let folder = directory.appendingPathComponent("Audio", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = entry.id.uuidString + "." + audioURL.pathExtension
            try FileManager.default.copyItem(at: audioURL, to: folder.appendingPathComponent(name))
            entry.audioFile = "Audio/" + name
        }
        document.history.append(entry)
        do { try save() } catch { document.history.removeLast(); if let file = entry.audioFile { try? FileManager.default.removeItem(at:directory.appendingPathComponent(file)) }; throw error }
    }
    func retainedAudio(for entry: DictationRecord) throws -> URL {
        guard let relative = entry.audioFile, relative.hasPrefix("Audio/"), !relative.contains(".."), relative.split(separator: "/").count == 2 else {
            throw TranscriptionError.geminiUnavailable("This dictation has no retained audio. Enable Keep audio before recording to re-transcribe it.")
        }
        return directory.appendingPathComponent(relative)
    }
}
enum CSVRows {
    static func parse(_ source: String) throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var iterator = source.makeIterator(); var next = iterator.next()
        while let character = next {
            next = iterator.next()
            if character == "\"" {
                if quoted && next == "\"" { field.append("\""); next = iterator.next() }
                else { quoted.toggle() }
            } else if !quoted && character == "," { row.append(field); field = "" }
            else if !quoted && (character == "\n" || character == "\r\n") { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(character) }
        }
        guard !quoted else { throw TranscriptionError.geminiUnavailable("CSV contains an unclosed quoted field.") }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
