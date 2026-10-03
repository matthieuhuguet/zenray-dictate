import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

// 3 October 2026, 19:52 CEST: font families are defined once for the app library.
enum DictationTypography {
    static let sans = "InterVariable"
    static let mono = "AnthropicMono"
    static let numbers = "AnthropicSerif"
}

// 3 October 2026, 16:10 CEST: every mode, vocabulary rule and history operation is accessible in the app.
@MainActor
final class LibraryWindow {
    private var window: NSWindow?
    private var model: LibraryViewModel?
    func show(coordinator: DictationCoordinator, onSettingsChanged: @escaping () -> Void) {
        if let window { model?.reload(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true); return }
        let model = LibraryViewModel(coordinator:coordinator,onSettingsChanged:onSettingsChanged)
        self.model = model
        let root = LibraryView(model:model)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:840,height:640),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "ZenRayDictate · Library and settings"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:root); window.center(); self.window = window
        coordinator.onUpdate = { [weak model] in model?.reload() }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
}
@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var preferences = DictationLibrary.shared.document.preferences
    @Published var records = DictationLibrary.shared.document.history.reversed().map { $0 }
    @Published var modesJSON = ""
    @Published var vocabularyJSON = ""
    @Published var replacementsJSON = ""
    @Published var snippetsJSON = ""
    @Published var message = ""
    @Published var selectedID: UUID?
    @Published var editedText = ""
    @Published var replayMode = "verbatim"
    @Published var shortcutLabel = "Record shortcut"
    private var shortcutMonitor: Any?
    private let coordinator: DictationCoordinator
    private let onSettingsChanged: () -> Void
    init(coordinator: DictationCoordinator, onSettingsChanged: @escaping () -> Void) {
        self.coordinator = coordinator; self.onSettingsChanged = onSettingsChanged; reload()
    }
    var modes: [DictationMode] { DictationLibrary.shared.document.modes }
    func reload() {
        let document = DictationLibrary.shared.document
        if let error = document.lastError { message = error }
        records = document.history.reversed().map { $0 }
        preferences = document.preferences
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        func encode<T:Encodable>(_ value:T)->String { (try? encoder.encode(value)).flatMap { String(data:$0,encoding:.utf8) } ?? "[]" }
        modesJSON = encode(document.modes); vocabularyJSON = encode(document.vocabulary)
        replacementsJSON = encode(document.replacements); snippetsJSON = encode(document.snippets)
    }
    // 3 October 2026, 16:40 CEST: users record a shortcut instead of entering Carbon key codes.
    func recordShortcut() {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        shortcutLabel = "Press the shortcut (Escape to cancel)"
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self else { return event }
            if let monitor = self.shortcutMonitor { NSEvent.removeMonitor(monitor); self.shortcutMonitor = nil }
            guard event.keyCode != 53 else { self.shortcutLabel = "Record shortcut"; return nil }
            let flags = event.modifierFlags
            guard !flags.intersection([.control,.command,.option,.shift]).isEmpty else { self.shortcutLabel = "Include a modifier key"; return nil }
            var mask: UInt32 = 0
            if flags.contains(.control) { mask |= UInt32(controlKey) }
            if flags.contains(.command) { mask |= UInt32(cmdKey) }
            if flags.contains(.option) { mask |= UInt32(optionKey) }
            if flags.contains(.shift) { mask |= UInt32(shiftKey) }
            self.preferences.shortcutKeyCode = UInt32(event.keyCode); self.preferences.shortcutModifiers = mask
            self.shortcutLabel = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + (event.charactersIgnoringModifiers?.uppercased() ?? "Key")
            return nil
        }
    }
    func save() {
        do {
            let decoder = JSONDecoder()
            var document = DictationLibrary.shared.document
            document.preferences = preferences
            document.modes = try decoder.decode([DictationMode].self,from:Data(modesJSON.utf8))
            document.vocabulary = try decoder.decode([TextRule].self,from:Data(vocabularyJSON.utf8))
            document.replacements = try decoder.decode([TextRule].self,from:Data(replacementsJSON.utf8))
            document.snippets = try decoder.decode([TextRule].self,from:Data(snippetsJSON.utf8))
            guard !document.modes.isEmpty, Set(document.modes.map(\.id)).count == document.modes.count,
                  document.modes.contains(where:{$0.id == preferences.activeMode}), preferences.doublePressInterval > 0,
                  preferences.clipboardRestoreDelay > 0 else { throw TranscriptionError.geminiUnavailable("Modes require unique IDs, a valid active mode and positive timing values.") }
            let old = DictationLibrary.shared.document
            DictationLibrary.shared.document = document
            do { try DictationLibrary.shared.save() } catch { DictationLibrary.shared.document = old; throw error }
            onSettingsChanged(); message = "Saved"
        } catch { message = error.localizedDescription }
    }
    func importCSV() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText,.plainText]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let count = try DictationLibrary.shared.importCSV(String(contentsOf:url,encoding:.utf8)); reload(); message = "Imported \(count) terms" }
        catch { message = error.localizedDescription }
    }
    func importMedia() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio,.movie]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { coordinator.importMedia(url) }
    }
    func drop(_ providers:[NSItemProvider]) -> Bool {
        guard let provider = providers.first, provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return false }
        provider.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil) { [weak self] item,_ in
            let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation:$0,relativeTo:nil) }
            if let url { Task { @MainActor in self?.coordinator.importMedia(url) } }
        }
        return true
    }
    func chooseRecord() { editedText = records.first(where:{$0.id == selectedID})?.text ?? "" }
    func copy() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(editedText,forType:.string) }
    func saveCorrection() {
        guard let index = DictationLibrary.shared.document.history.firstIndex(where:{$0.id == selectedID}) else { return }
        let old = DictationLibrary.shared.document.history[index].text
        DictationLibrary.shared.learnCorrection(before:old,after:editedText)
        DictationLibrary.shared.document.history[index].text = editedText
        do { try DictationLibrary.shared.save(); reload(); message = "Correction saved" } catch { message = error.localizedDescription }
    }
    func replay() { if let record = records.first(where:{$0.id == selectedID}) { coordinator.reprocess(record,modeID:replayMode) } }
}
private struct LibraryView: View {
    @ObservedObject var model: LibraryViewModel
    var body: some View {
        VStack {
            TabView {
                ScrollView { Form {
                    Picker("Engine",selection:$model.preferences.engine) { ForEach(DictationEngine.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                    Toggle("100% local (no Gemini requests)",isOn:$model.preferences.localOnly)
                    Toggle("Whisper fallback if Gemini fails",isOn:$model.preferences.allowLocalFallback)
                    Toggle("Hold Fn to dictate",isOn:$model.preferences.fnPushToTalk)
                    Toggle("Whispering: boost quiet audio",isOn:$model.preferences.whisperMode)
                    Toggle("Keep text history",isOn:$model.preferences.keepHistory)
                    Toggle("Keep audio for re-transcription (off by default)",isOn:$model.preferences.keepAudio)
                    Toggle("Learn vocabulary from corrections in History",isOn:$model.preferences.learnVocabulary)
                    Picker("Active mode",selection:$model.preferences.activeMode) { ForEach(model.modes) { Text($0.name).tag($0.id) } }
                    TextField("Language (auto, fr, en, ja…)",text:$model.preferences.language)
                    TextField("Gemini model in the session",text:$model.preferences.model)
                    TextField("Whisper executable",text:$model.preferences.whisperExecutable)
                    TextField("Whisper model",text:$model.preferences.whisperModel)
                    TextField("Parakeet executable",text:$model.preferences.parakeetExecutable)
                    TextField("Parakeet model",text:$model.preferences.parakeetModel)
                    Button(model.shortcutLabel) { model.recordShortcut() }
                    Text("Default shortcut: Control+D. Fn+Space or double Fn enables hands-free. Hold Control+Shift+D for Command Mode. Set macOS ‘Press 🌐 key to’ to ‘Do Nothing’. The system shortcut setting remains yours.").font(.caption)
                    Button("Gemini session / Sign in") { TranscriptionPipeline.showGemini() }
                    Button("Open the single data folder") { try? FileManager.default.createDirectory(at:DictationLibrary.shared.directory,withIntermediateDirectories:true); NSWorkspace.shared.open(DictationLibrary.shared.directory) }
                }.padding() }.tabItem { Text("Settings") }
                VStack(alignment:.leading) {
                    Text("Edit custom prompts, tone and application bundle IDs. useScreenContext opts into reading the focused text field for spelling. Gemini handles cloud formatting; local mode returns dictionary-corrected text.")
                    TextEditor(text:$model.modesJSON).font(.custom(DictationTypography.mono,size:13))
                }.padding().tabItem { Text("Modes") }
                VStack {
                    HStack { Button("Import CSV") { model.importCSV() }; Text("CSV columns: spoken,written. Snippets match the whole utterance.") }
                    HStack {
                        VStack { Text("Vocabulary"); TextEditor(text:$model.vocabularyJSON) }
                        VStack { Text("Replacements"); TextEditor(text:$model.replacementsJSON) }
                        VStack { Text("Voice snippets"); TextEditor(text:$model.snippetsJSON) }
                    }.font(.custom(DictationTypography.mono,size:13))
                }.padding().tabItem { Text("Vocabulary") }
                VStack {
                    HStack { Button("Import audio or video") { model.importMedia() }; Text("Drop audio/video here. Audio is not kept by default.") }
                    HSplitView {
                        List(model.records,selection:$model.selectedID) { record in
                            VStack(alignment:.leading) { Text(record.text).lineLimit(2); Text(record.date.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(Locale(identifier:"en_GB"))) + " · " + record.provider + " · " + record.modeID).font(.custom(DictationTypography.numbers,size:12)) }.tag(record.id)
                        }.frame(minWidth:250)
                        VStack {
                            TextEditor(text:$model.editedText)
                            HStack { Button("Copy") { model.copy() }; Button("Save correction") { model.saveCorrection() } }
                            Picker("Reprocess with",selection:$model.replayMode) { ForEach(model.modes) { Text($0.name).tag($0.id) } }
                            Button("Reprocess") { model.replay() }.disabled(model.selectedID == nil)
                        }
                    }.onChange(of:model.selectedID) { model.chooseRecord() }
                }.padding().onDrop(of:[UTType.fileURL],isTargeted:nil,perform:model.drop).tabItem { Text("History") }
            }
            HStack { Text(model.message).foregroundStyle(.secondary); Spacer(); Button("Save settings, modes and vocabulary") { model.save() } }.padding()
        }.font(.custom(DictationTypography.sans,size:14)).frame(minWidth:740,minHeight:560)
    }
}
