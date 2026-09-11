import AppKit
import AVFoundation
import QuartzCore

// Iteration timestamp: 2026-09-11.
final class ComposerWindowController: NSWindowController, NSWindowDelegate {

    private let composer = ComposerViewController()
    private var fadeSerial = 0

    override init(window: NSWindow?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: ComposerTokens.windowWidth, height: ComposerTokens.windowHeight),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.contentViewController = composer
        window.delegate = self
        window.title = "ZenRay Dictate"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentMinSize = ComposerTokens.windowSize
        window.contentMaxSize = ComposerTokens.windowSize
        window.setContentSize(ComposerTokens.windowSize)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        positionAtBottomCenter(window)
        enforceFixedFrame(window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard let window else { return }
        fadeSerial += 1
        enforceFixedFrame(window)
        positionAtBottomCenter(window)
        window.alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        composer.focusEditor()
    }

    func toggleVisibility() {
        guard let window else { return }
        if window.isVisible && window.alphaValue > 0.99 {
            fadeOut(reason: "Fn")
        } else {
            show()
        }
    }

    func fadeOut(reason: String = "focus loss") {
        guard let window, window.isVisible else { return }
        fadeSerial += 1
        let serial = fadeSerial

        NSAnimationContext.runAnimationGroup { context in
            context.duration = ComposerTokens.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self, weak window] in
            guard let self, self.fadeSerial == serial else { return }
            window?.orderOut(nil)
            window?.alphaValue = 1
            Log.write("composer faded out: \(reason)")
        }
    }

    func toggleDictation() {
        show()
        composer.toggleDictation()
    }
    func cancelRecording() { composer.cancelRecording() }
    func retryPendingRecording() { composer.retryPendingRecording() }
    func copyComposerText() { composer.copyComposerText() }
    func pasteComposerText() {
        show()
        composer.pasteComposerText()
    }
    func retryLastCopy() { composer.retryLastCopy() }
    func clearComposer() {
        show()
        composer.clearComposer()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !window.isKeyWindow else { return }
            self.fadeOut(reason: "window lost key")
        }
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        sender.frameRect(forContentRect: NSRect(origin: .zero, size: ComposerTokens.windowSize)).size
    }

    func windowDidResize(_ notification: Notification) {
        guard let window else { return }
        enforceFixedFrame(window)
    }

    private func enforceFixedFrame(_ window: NSWindow) {
        let contentRect = window.contentRect(forFrameRect: window.frame)
        let widthDelta = abs(contentRect.width - ComposerTokens.windowWidth)
        let heightDelta = abs(contentRect.height - ComposerTokens.windowHeight)
        guard widthDelta > 0.5 || heightDelta > 0.5 else { return }

        var frame = window.frame
        frame.size = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: ComposerTokens.windowSize)
        ).size
        window.setFrame(frame, display: true)
        Log.write("composer frame restored to 860x360 after content resize")
    }

    private func positionAtBottomCenter(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - window.frame.width / 2,
            y: visibleFrame.minY + ComposerTokens.bottomInset
        )
        window.setFrameOrigin(origin)
        Log.write(
            "composer positioned bottom center: source=NSScreen.visibleFrame, "
                + "origin=\(Int(origin.x))x\(Int(origin.y)), "
                + "bottomInset=\(Int(ComposerTokens.bottomInset))pt"
        )
    }
}

private enum ComposerTokens {
    static let windowWidth: CGFloat = 860
    static let windowHeight: CGFloat = 140
    static let windowSize = NSSize(width: windowWidth, height: windowHeight)
    static let bottomInset: CGFloat = 24
    static let fadeDuration: TimeInterval = 0.16
    static let cardRadius: CGFloat = 24
    static let contentInset: CGFloat = 18
    static let editorFontSize: CGFloat = 20
    static let iconPointSize: CGFloat = 15
    static let buttonSize: CGFloat = 36
    static let waveformBars = 56
    static let waveformWidth: CGFloat = 4
    static let primaryButtonFill = NSColor(calibratedWhite: 0.12, alpha: 1)
    static let secondaryButtonFill = NSColor.quaternaryLabelColor.withAlphaComponent(0.18)
}

private enum ComposerState: Equatable {
    case idle
    case recording
    case transcribing
    case failed(String)
}

private final class CircularButton: NSButton {
    var circleFillColor = NSColor.clear {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let diameter = floor(min(bounds.width, bounds.height))
        let circleRect = NSRect(
            x: floor((bounds.width - diameter) / 2) + 0.5,
            y: floor((bounds.height - diameter) / 2) + 0.5,
            width: max(0, diameter - 1),
            height: max(0, diameter - 1)
        )
        circleFillColor.setFill()
        NSBezierPath(ovalIn: circleRect).fill()
        super.draw(dirtyRect)
    }
}

private final class ComposerViewController: NSViewController, NSTextViewDelegate {

    private let capture = AudioCapture()
    private let transcriber = TranscriptionPipeline()
    private let pending = PendingRecordingStore()
    private let card = ComposerCardView()
    private let editor = ComposerTextView()
    private let editorScroll = ComposerEditorScrollView()
    private let placeholder = NSTextField(labelWithString: "Ask anything")
    private let waveform = WaveformView()
    private let stateLabel = NSTextField(labelWithString: "Ready")
    private let primaryButton = CircularButton()
    private let cancelButton = CircularButton()
    private let progress = NSProgressIndicator()
    private var state: ComposerState = .idle
    private var lastClipboardText: String?
    private var localKeyMonitor: Any?

    override func loadView() { view = card }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureInterface()
        installLocalKeyMonitor()
        capture.onLevel = { [weak self] level in self?.waveform.add(level: CGFloat(level)) }
        capture.onDuration = { [weak self] duration in self?.updateDuration(duration) }
        if let saved = pending.existingURL() {
            state = .failed("A recording is ready to retry")
            stateLabel.stringValue = "Recording ready to retry"
            updateActionButton()
            Log.write("pending recording restored: \(saved.lastPathComponent)")
        }
    }

    deinit {
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
    }

    func focusEditor() {
        guard isViewLoaded, let window = view.window else { return }
        window.makeFirstResponder(editor)
    }

    func toggleDictation() {
        switch state {
        case .idle:
            startDictation()
        case .failed:
            if pending.existingURL() != nil {
                retryPendingRecording()
            } else {
                startDictation()
            }
        case .recording:
            stopDictation()
        case .transcribing:
            Log.write("dictation toggle ignored while transcribing")
        }
    }

    func cancelRecording() {
        guard state == .recording else { return }
        capture.cancel()
        waveform.reset()
        state = .idle
        updateActionButton()
        stateLabel.stringValue = "Ready"
    }

    func retryPendingRecording() {
        guard state != .recording, let url = pending.existingURL() else {
            Log.write("retry ignored: no pending recording")
            return
        }
        state = .transcribing
        stateLabel.stringValue = "Retrying transcription"
        progress.startAnimation(nil)
        updateActionButton()
        transcribe(url: url)
    }

    func copyComposerText() {
        let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lastClipboardText = text
        guard writeClipboard(text) else {
            stateLabel.stringValue = "Copy failed, retry available"
            Log.write("copy independent composer text failed: retry is available")
            return
        }
        stateLabel.stringValue = "Copied"
        Log.write("copied independent composer text: \(text.count) characters")
    }

    func retryLastCopy() {
        guard let text = lastClipboardText, !text.isEmpty else {
            stateLabel.stringValue = "Nothing to copy"
            Log.write("retry copy ignored: no composer text in memory")
            return
        }
        guard writeClipboard(text) else {
            stateLabel.stringValue = "Copy failed, retry available"
            Log.write("retry independent composer text failed")
            return
        }
        stateLabel.stringValue = "Copied"
        Log.write("retried independent composer copy: \(text.count) characters")
    }

    func pasteComposerText() {
        guard state != .recording else { return }
        focusEditor()
        editor.paste(nil)
        editorDidChange(editor)
        Log.write("pasted text into independent composer")
    }

    func cutComposerText() {
        guard state != .recording else { return }
        let text = editor.string
        guard !text.isEmpty else { return }
        lastClipboardText = text
        guard writeClipboard(text) else {
            Log.write("cut independent composer text failed: pasteboard rejected the string")
            stateLabel.stringValue = "Copy failed, retry available"
            return
        }
        editor.string = ""
        editorDidChange(editor)
        state = .idle
        stateLabel.stringValue = "Ready"
        updateActionButton()
        focusEditor()
        Log.write("cut independent composer text: \(text.count) characters")
    }

    func clearComposer() {
        guard state != .recording else { return }
        editor.string = ""
        editorDidChange(editor)
        state = .idle
        stateLabel.stringValue = "Ready"
        updateActionButton()
        focusEditor()
    }

    private func configureInterface() {
        view.wantsLayer = true

        editorScroll.drawsBackground = false
        editorScroll.borderType = .noBorder
        editorScroll.hasVerticalScroller = true
        editorScroll.hasHorizontalScroller = false
        editorScroll.horizontalScrollElasticity = .none
        editorScroll.translatesAutoresizingMaskIntoConstraints = false

        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.drawsBackground = false
        editor.allowsUndo = true
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.font = NSFont(name: "Inter", size: ComposerTokens.editorFontSize)
            ?? NSFont.systemFont(ofSize: ComposerTokens.editorFontSize)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.textContainerInset = NSSize(width: 0, height: 6)
        editor.textContainer?.lineBreakMode = .byCharWrapping
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = self
        editorScroll.documentView = editor

        placeholder.font = editor.font
        placeholder.textColor = .secondaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.isBezeled = false
        placeholder.isEditable = false
        placeholder.isSelectable = false

        waveform.translatesAutoresizingMaskIntoConstraints = false
        waveform.isActive = false

        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.alignment = .center

        configureButton(cancelButton, symbol: "xmark", accessibility: "Cancel recording", action: #selector(cancelPressed))
        configureButton(primaryButton, symbol: "mic.fill", accessibility: "Start dictation", action: #selector(primaryPressed))
        primaryButton.contentTintColor = .white
        primaryButton.circleFillColor = ComposerTokens.primaryButtonFill

        progress.controlSize = .small
        progress.style = .spinning
        progress.isDisplayedWhenStopped = false
        progress.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(editorScroll)
        card.addSubview(placeholder)
        card.addSubview(cancelButton)
        card.addSubview(waveform)
        card.addSubview(stateLabel)
        card.addSubview(primaryButton)
        card.addSubview(progress)

        NSLayoutConstraint.activate([
            editorScroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: ComposerTokens.contentInset),
            editorScroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -ComposerTokens.contentInset),
            editorScroll.topAnchor.constraint(equalTo: card.topAnchor, constant: ComposerTokens.contentInset),
            editorScroll.bottomAnchor.constraint(equalTo: waveform.topAnchor, constant: -8),

            placeholder.leadingAnchor.constraint(equalTo: editorScroll.leadingAnchor, constant: 4),
            placeholder.topAnchor.constraint(equalTo: editorScroll.topAnchor, constant: 8),

            cancelButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: ComposerTokens.contentInset),
            cancelButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -ComposerTokens.contentInset),
            cancelButton.widthAnchor.constraint(equalToConstant: ComposerTokens.buttonSize),
            cancelButton.heightAnchor.constraint(equalToConstant: ComposerTokens.buttonSize),
            cancelButton.widthAnchor.constraint(equalTo: cancelButton.heightAnchor),

            waveform.leadingAnchor.constraint(equalTo: cancelButton.trailingAnchor, constant: 16),
            waveform.trailingAnchor.constraint(equalTo: primaryButton.leadingAnchor, constant: -16),
            waveform.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -ComposerTokens.contentInset - 5),
            waveform.heightAnchor.constraint(equalToConstant: 32),

            stateLabel.leadingAnchor.constraint(equalTo: waveform.leadingAnchor),
            stateLabel.trailingAnchor.constraint(equalTo: waveform.trailingAnchor),
            stateLabel.topAnchor.constraint(equalTo: waveform.bottomAnchor, constant: 4),
            stateLabel.heightAnchor.constraint(equalToConstant: 16),

            primaryButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -ComposerTokens.contentInset),
            primaryButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -ComposerTokens.contentInset),
            primaryButton.widthAnchor.constraint(equalToConstant: ComposerTokens.buttonSize),
            primaryButton.heightAnchor.constraint(equalToConstant: ComposerTokens.buttonSize),
            primaryButton.widthAnchor.constraint(equalTo: primaryButton.heightAnchor),

            progress.centerXAnchor.constraint(equalTo: primaryButton.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: primaryButton.centerYAnchor)
        ])
        updatePlaceholder()
        updateActionButton()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        editorScroll.fitDocumentViewToViewport()
    }

    private func installLocalKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.view.window, window.isKeyWindow else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let character = event.charactersIgnoringModifiers?.lowercased()

            if modifiers == .command, character == "q" {
                self.clearComposer()
                return nil
            }
            if modifiers == .command, character == "x" {
                self.cutComposerText()
                return nil
            }
            return event
        }
    }

    private func configureButton(_ button: NSButton, symbol: String, accessibility: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)
        button.image = image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: ComposerTokens.iconPointSize, weight: .medium)
        )
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.setButtonType(.momentaryPushIn)
        button.contentTintColor = .labelColor
        button.toolTip = accessibility
        button.target = self
        button.action = action
        if let circularButton = button as? CircularButton {
            circularButton.circleFillColor = ComposerTokens.secondaryButtonFill
        }
    }

    private func startDictation() {
        requestMicrophoneAccess { [weak self] allowed in
            guard let self else { return }
            guard allowed else {
                self.state = .failed("Microphone access is required")
                self.stateLabel.stringValue = "Allow microphone access in System Settings"
                self.updateActionButton()
                return
            }
            self.beginCapture()
        }
    }

    private func beginCapture() {
        do {
            _ = try capture.start()
            state = .recording
            waveform.reset()
            waveform.isActive = true
            stateLabel.stringValue = "Listening"
            updateActionButton()
        } catch {
            state = .failed(error.localizedDescription)
            stateLabel.stringValue = error.localizedDescription
            updateActionButton()
            Log.write("independent dictation start failed: \(error.localizedDescription)")
        }
    }

    private func stopDictation() {
        guard let url = capture.stop() else {
            state = .failed("No audio was captured")
            stateLabel.stringValue = "No audio captured"
            waveform.isActive = false
            updateActionButton()
            return
        }
        waveform.isActive = false
        state = .transcribing
        stateLabel.stringValue = "Transcribing"
        progress.startAnimation(nil)
        updateActionButton()
        transcribe(url: url)
    }

    private func transcribe(url: URL) {
        let savedURL: URL
        do {
            savedURL = try pending.preserve(url: url)
        } catch {
            state = .failed("Recording could not be saved for retry")
            stateLabel.stringValue = "Recording could not be saved"
            progress.stopAnimation(nil)
            updateActionButton()
            Log.write("pending recording save failed: \(error.localizedDescription)")
            return
        }
        if url.standardizedFileURL != savedURL.standardizedFileURL {
            try? FileManager.default.removeItem(at: url)
        }

        Task { [weak self] in
            do {
                let result = try await self?.transcriber.transcribe(audioURL: savedURL)
                guard let self, let result else { return }
                await MainActor.run { self.finishTranscription(result) }
            } catch {
                guard let self else { return }
                await MainActor.run { self.failTranscription(error) }
            }
        }
    }

    private func finishTranscription(_ result: TranscriptionResult) {
        let current = editor.string
        let separator = current.isEmpty || current.hasSuffix(" ") || current.hasSuffix("\n") ? "" : " "
        editor.string = current + separator + result.text
        editorDidChange(editor)
        let copied = writeClipboard(editor.string)
        lastClipboardText = editor.string
        pending.clear()
        state = .idle
        stateLabel.stringValue = copied ? "Copied" : "Copy failed, retry available"
        progress.stopAnimation(nil)
        waveform.reset()
        updateActionButton()
        focusEditor()
        Log.write("independent transcription inserted: provider=\(result.provider), characters=\(result.text.count)")
        Log.write(copied
            ? "independent transcription copied to clipboard: characters=\(editor.string.count)"
            : "independent transcription clipboard copy failed: retry is available")
    }

    private func failTranscription(_ error: Error) {
        state = .failed("Saved for retry")
        stateLabel.stringValue = "Saved for retry"
        progress.stopAnimation(nil)
        updateActionButton()
        Log.write("independent transcription failed and was saved: \(error.localizedDescription)")
    }

    private func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                DispatchQueue.main.async { completion(allowed) }
            }
        default:
            completion(false)
        }
    }

    private func updateDuration(_ duration: TimeInterval) {
        guard state == .recording else { return }
        let seconds = Int(duration.rounded(.down))
        let minutes = seconds / 60
        let remainder = seconds % 60
        let durationText = String(format: "%02d:%02d", minutes, remainder)
        stateLabel.stringValue = "Listening · \(durationText)"
    }

    private func updatePlaceholder() { placeholder.isHidden = !editor.string.isEmpty }

    @discardableResult
    private func writeClipboard(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    private func updateActionButton() {
        switch state {
        case .idle:
            primaryButton.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Start dictation")
            primaryButton.toolTip = "Start dictation"
            cancelButton.toolTip = "Clear text"
            cancelButton.setAccessibilityLabel("Clear text")
            primaryButton.isEnabled = true
            progress.stopAnimation(nil)
        case .recording:
            primaryButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop dictation")
            primaryButton.toolTip = "Stop dictation"
            cancelButton.toolTip = "Cancel recording"
            cancelButton.setAccessibilityLabel("Cancel recording")
            primaryButton.isEnabled = true
        case .transcribing:
            primaryButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Transcribing")
            primaryButton.toolTip = "Transcribing"
            cancelButton.toolTip = "Clear text"
            cancelButton.setAccessibilityLabel("Clear text")
            primaryButton.isEnabled = false
        case .failed:
            primaryButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Retry transcription")
            primaryButton.toolTip = "Retry transcription"
            cancelButton.toolTip = "Clear text"
            cancelButton.setAccessibilityLabel("Clear text")
            primaryButton.isEnabled = true
        }
    }

    @objc private func cancelPressed() {
        if state == .recording {
            cancelRecording()
        } else {
            clearComposer()
        }
    }

    @objc private func primaryPressed() {
        switch state {
        case .failed:
            retryPendingRecording()
        default:
            toggleDictation()
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) { updatePlaceholder() }
    func textDidChange(_ notification: Notification) { updatePlaceholder() }
    func editorDidChange(_ textView: NSTextView) { updatePlaceholder() }
}

private final class ComposerTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleClipboardKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleClipboardKey(event) { return }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) {
            pasteAsPlainText(sender)
            Log.write("pasted plain text into independent composer: characters=\(text.count)")
        } else {
            super.paste(sender)
        }
    }

    private func handleClipboardKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command, let key = event.charactersIgnoringModifiers?.lowercased() else {
            return false
        }

        switch key {
        case "a":
            selectAll(nil)
            return true
        case "c":
            copy(nil)
            return true
        case "v":
            paste(nil)
            return true
        default:
            return false
        }
    }
}

private final class ComposerEditorScrollView: NSScrollView {
    private var isFittingDocumentView = false

    override func layout() {
        super.layout()
        fitDocumentViewToViewport()
    }

    func fitDocumentViewToViewport() {
        guard !isFittingDocumentView, let documentView, contentSize.width > 0 else { return }
        let viewportWidth = contentSize.width
        let textView = documentView as? NSTextView
        let containerWidth = textView?.textContainer?.containerSize.width ?? 0
        let needsFrameUpdate = abs(documentView.frame.width - viewportWidth) > 0.5
        let needsContainerUpdate = abs(containerWidth - viewportWidth) > 0.5
        guard needsFrameUpdate || needsContainerUpdate else { return }

        isFittingDocumentView = true
        defer { isFittingDocumentView = false }

        if needsFrameUpdate {
            var frame = documentView.frame
            frame.origin.x = 0
            frame.size.width = viewportWidth
            frame.size.height = max(frame.size.height, contentSize.height)
            documentView.frame = frame
        }

        if let textView {
            textView.textContainer?.lineBreakMode = .byCharWrapping
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(
                width: viewportWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
    }
}

private final class ComposerCardView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let background = dark
            ? NSColor(calibratedWhite: 0.12, alpha: 0.98)
            : NSColor(calibratedWhite: 0.985, alpha: 0.98)
        let border = dark
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor.black.withAlphaComponent(0.10)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: ComposerTokens.cardRadius, yRadius: ComposerTokens.cardRadius)
        background.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private final class WaveformView: NSView {
    var isActive = false { didSet { needsDisplay = true } }
    private var levels = Array(repeating: CGFloat(0.08), count: ComposerTokens.waveformBars)

    func add(level: CGFloat) {
        levels.removeFirst()
        levels.append(min(1, max(0.05, level)))
        needsDisplay = true
    }

    func reset() {
        levels = Array(repeating: CGFloat(0.08), count: ComposerTokens.waveformBars)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let color = isActive ? NSColor.labelColor.withAlphaComponent(0.56) : NSColor.secondaryLabelColor.withAlphaComponent(0.28)
        color.setFill()
        let width = bounds.width / CGFloat(levels.count)
        for (index, level) in levels.enumerated() {
            let barHeight = max(3, bounds.height * level)
            let x = CGFloat(index) * width + (width - ComposerTokens.waveformWidth) / 2
            let rect = NSRect(x: x, y: (bounds.height - barHeight) / 2, width: ComposerTokens.waveformWidth, height: barHeight)
            NSBezierPath(roundedRect: rect, xRadius: ComposerTokens.waveformWidth / 2, yRadius: ComposerTokens.waveformWidth / 2).fill()
        }
    }
}

private final class PendingRecordingStore {
    private let fileManager = FileManager.default
    private let pendingDirectory: URL
    private let pendingURL: URL

    init() {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        pendingDirectory = support.appendingPathComponent("ZenRayDictate", isDirectory: true)
            .appendingPathComponent("Pending", isDirectory: true)
        pendingURL = pendingDirectory.appendingPathComponent("last-recording.wav")
    }

    func existingURL() -> URL? {
        guard fileManager.fileExists(atPath: pendingURL.path) else { return nil }
        return pendingURL
    }

    @discardableResult
    func preserve(url: URL) throws -> URL {
        try fileManager.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        if url.standardizedFileURL == pendingURL.standardizedFileURL {
            return pendingURL
        }
        if fileManager.fileExists(atPath: pendingURL.path) {
            try fileManager.removeItem(at: pendingURL)
        }
        try fileManager.copyItem(at: url, to: pendingURL)
        return pendingURL
    }

    func clear() {
        if fileManager.fileExists(atPath: pendingURL.path) {
            try? fileManager.removeItem(at: pendingURL)
        }
    }
}
