import XCTest
@testable import ZenRayDictate

// 3 October 2026, 16:25 CEST: validate persisted privacy choices, CSV boundaries and mode overrides.
final class LibraryTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:root) }
    func testUnreadableLibraryPreservesOriginalBeforeNewSave() throws {
        let bytes = Data("{broken".utf8); let file = root.appendingPathComponent("Library.json")
        try bytes.write(to:file)
        let library = DictationLibrary(directory:root)
        XCTAssertNotNil(library.document.lastError)
        try library.save()
        let recovery = try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("Recovery"),includingPropertiesForKeys:nil)
        XCTAssertEqual(recovery.count,1); XCTAssertEqual(try Data(contentsOf:recovery[0]),bytes)
    }
    func testOldPreferencesDecodeWithDefaults() throws {
        let preferences = try JSONDecoder().decode(DictationPreferences.self,from:Data("{\"keepAudio\":true,\"activeMode\":\"code\"}".utf8))
        XCTAssertTrue(preferences.keepAudio); XCTAssertEqual(preferences.activeMode,"code")
        XCTAssertEqual(preferences.engine,.gemini); XCTAssertFalse(preferences.localOnly)
    }
    func testQuotedCSVAndRejectedBrokenQuote() throws {
        XCTAssertEqual(try CSVRows.parse("spoken,written\r\n\"zen, ray\",\"Zen\"\"Ray\"\n"),[["spoken","written"],["zen, ray","Zen\"Ray"]])
        XCTAssertThrowsError(try CSVRows.parse("\"unfinished,value"))
    }
    func testReplacementBoundariesAndLiteralTemplate() {
        let library = DictationLibrary(directory:root)
        library.document.replacements = [.init(spoken:"ray",written:"$1\\path")]
        XCTAssertEqual(library.normalize("ray array ray_code RAY"),"$1\\path array ray_code $1\\path")
    }
    func testSnippetRequiresWholeUtterance() {
        let library = DictationLibrary(directory:root)
        library.document.snippets = [.init(spoken:"my address",written:"42 Sample Street")]
        XCTAssertEqual(library.normalize("My address."),"42 Sample Street")
        XCTAssertEqual(library.normalize("Use my address please"),"Use my address please")
    }
    func testCSVImportPersistsWithoutDuplicating() throws {
        let library = DictationLibrary(directory:root)
        _ = try library.importCSV("spoken,written\nzen ray,ZenRay\nZEN RAY,ZenRay")
        XCTAssertEqual(DictationLibrary(directory:root).document.vocabulary.count,1)
    }
    func testApplicationAndReplayModeDoNotChangeActiveMode() {
        let library = DictationLibrary(directory:root)
        library.document.modes[1].applications = ["com.apple.Terminal"]
        XCTAssertEqual(library.mode(for:"com.apple.Terminal").id,"clean")
        XCTAssertEqual(library.mode(for:"com.apple.Terminal",override:"code").id,"code")
        XCTAssertEqual(library.document.preferences.activeMode,"verbatim")
        library.document.modes = []
        XCTAssertEqual(library.mode(for:"").id,"verbatim")
    }
    func testHistoryDoesNotRetainAudioByDefault() throws {
        let library = DictationLibrary(directory:root)
        let audio = root.appendingPathComponent("input.wav"); try Data([1,2,3]).write(to:audio)
        try library.record(raw:"hello",text:"Hello.",provider:"fixture",mode:"verbatim",application:"fixture",audioURL:audio,inserted:false)
        let loaded = DictationLibrary(directory:root)
        XCTAssertNil(loaded.document.history.first?.audioFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("Audio").path))
        XCTAssertThrowsError(try loaded.retainedAudio(for:loaded.document.history[0]))
    }
    func testOptedInAudioIsPreservedAndTraversalRejected() throws {
        let library = DictationLibrary(directory:root); library.document.preferences.keepAudio = true
        let audio = root.appendingPathComponent("input.wav"); try Data([1,2,3]).write(to:audio)
        try library.record(raw:"hello",text:"Hello.",provider:"fixture",mode:"verbatim",application:"fixture",audioURL:audio,inserted:false)
        var entry = library.document.history[0]
        XCTAssertEqual(try Data(contentsOf:library.retainedAudio(for:entry)),Data([1,2,3]))
        entry.audioFile = "Audio/../Library.json"
        XCTAssertThrowsError(try library.retainedAudio(for:entry))
    }
    func testDisabledHistoryAndOptInLearning() throws {
        let library = DictationLibrary(directory:root); library.document.preferences.keepHistory = false
        try library.record(raw:"hello",text:"Hello",provider:"fixture",mode:"verbatim",application:"fixture",audioURL:nil,inserted:false)
        XCTAssertTrue(library.document.history.isEmpty)
        library.learnCorrection(before:"zenray",after:"ZenRay"); XCTAssertTrue(library.document.vocabulary.isEmpty)
        library.document.preferences.learnVocabulary = true
        library.learnCorrection(before:"zenray",after:"ZenRay"); XCTAssertEqual(library.document.vocabulary.first?.written,"ZenRay")
    }
}
