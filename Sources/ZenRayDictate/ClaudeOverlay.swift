import AppKit
import QuartzCore

// 25 October 2026, 20:40 CEST: B1 « Papier crème » in Liquid Glass, chosen by Matthieu. Fn shows a recording capsule
// at the middle of the right edge; the text then appears in a card at the bottom centre, already copied.
// Design: /Users/zenray/.claude/skills/zenray-edit/designs/2026-10-25-zenray-dictate-papier-verre/index.html
// FR : capsule d'enregistrement à droite au milieu, puis carte de texte en bas au centre ; valeurs dans Tokens.
@MainActor
final class ClaudeOverlay {

    /// Every visual value of the B1 design, in points, seconds and sRGB. Change a value here only.
    enum Tokens {
        static let capsuleSize = NSSize(width: 300, height: 60)
        static let edgeInset: CGFloat = 16            // gap to the right edge of the visible screen
        static let bottomInset: CGFloat = 24          // gap above the Dock (visibleFrame already excludes it)
        static let micButton: CGFloat = 32
        static let micSymbol: CGFloat = 15
        static let barWidth: CGFloat = 3, barGap: CGFloat = 3, barMin: CGFloat = 5, barMax: CGFloat = 26
        static let cardWidth: CGFloat = 640
        static let cardPadding = NSEdgeInsets(top: 16, left: 20, bottom: 14, right: 20)
        static let cardRadius: CGFloat = 20
        static let titleSize: CGFloat = 14, textSize: CGFloat = 17, actionSize: CGFloat = 12
        static let maxTextHeight: CGFloat = 220
        static let fade: TimeInterval = 0.18
        static let tintTop = 0.62, tintBottom = 0.42, rim = 0.60
        static let cream = NSColor(srgbRed: 1.0, green: 248/255, blue: 238/255, alpha: 1)
        static let clay = NSColor(srgbRed: 217/255, green: 119/255, blue: 87/255, alpha: 1)
        static let clayDeep = NSColor(srgbRed: 184/255, green: 92/255, blue: 62/255, alpha: 1)
        static let ink = NSColor(srgbRed: 42/255, green: 38/255, blue: 34/255, alpha: 1)
        static let muted = NSColor(srgbRed: 124/255, green: 115/255, blue: 104/255, alpha: 1)
        static let titleFont = "GTSectraLCG-RegularItalic", textFont = "AnthropicSerif-Regular", uiFont = "InterVariable-Medium"
    }

    var onInsert: (() -> Void)?
    var onRedo: (() -> Void)?
    var onCopy: (() -> Void)?

    private let capsule: NSPanel
    private let card: NSPanel
    private let bars = BarsView()
    private let timer = NSTextField(labelWithString: "0:00")
    private let halo = CALayer()
    private let titleLabel = NSTextField(labelWithString: "Transcription")
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private let actions = NSStackView()
    private var copyButton: ActionButton!
    private var startedAt: Date?
    private var tick: Timer?
    private var outsideMonitors: [Any] = []

    init() {
        capsule = Self.glassPanel(size: Tokens.capsuleSize, radius: Tokens.capsuleSize.height / 2)
        card = Self.glassPanel(size: NSSize(width: Tokens.cardWidth, height: 120), radius: Tokens.cardRadius)
        buildCapsule(); buildCard()
    }

    // MARK: States

    func showRecording() {
        hideCard(animated: false)
        bars.reset(); bars.dimmed = false
        startedAt = Date(); timer.stringValue = "0:00"
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateTimer() }
        }
        startPulse()
        if let screen = Self.screen() {
            let r = screen.visibleFrame
            capsule.setFrameOrigin(NSPoint(x: r.maxX - Tokens.edgeInset - Tokens.capsuleSize.width, y: r.midY - Tokens.capsuleSize.height / 2))
        }
        fadeIn(capsule); capsule.invalidateShadow()
        Log.write("overlay: recording capsule at right middle")
    }

    func add(level: Float) { bars.add(level: CGFloat(level)) }

    func showTranscribing() {
        tick?.invalidate(); tick = nil
        bars.dimmed = true; timer.stringValue = "…"
        stopPulse()
        if !capsule.isVisible { fadeIn(capsule) }
    }

    func showResult(_ text: String, insertable: Bool) {
        present(title: "Transcription", text: text, showCopy: true, showInsert: insertable)
        Log.write("overlay: result card at bottom centre, \(text.count) characters")
    }

    func showMessage(_ message: String, title: String = "Dictée impossible") {
        present(title: title, text: message, showCopy: false, showInsert: false)
    }

    func hide() {
        tick?.invalidate(); tick = nil; stopPulse()
        fadeOut(capsule); hideCard(animated: true)
    }

    func markCopied() { copyButton.setTitle("Copié") }

    // MARK: Building

    private static func screen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    private static func glassPanel(size: NSSize, radius: CGFloat) -> NSPanel {
        let panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.alphaValue = 0
        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        glass.material = .popover; glass.blendingMode = .behindWindow; glass.state = .active
        glass.appearance = NSAppearance(named: .aqua)
        glass.wantsLayer = true; glass.layer?.cornerRadius = radius; glass.layer?.masksToBounds = true
        // 25 October 2026: NSVisualEffectView ignores the layer radius for its blur; maskImage cuts the real capsule shape. / sans masque, un carré apparaît.
        glass.maskImage = roundedMask(radius: radius)
        glass.autoresizingMask = [.width, .height]
        // Cream tint and bright rim of the Liquid Glass template. / teinte crème et liseré du gabarit Liquid Glass.
        let tint = CAGradientLayer()
        tint.colors = [Tokens.cream.withAlphaComponent(Tokens.tintTop).cgColor, Tokens.cream.withAlphaComponent(Tokens.tintBottom).cgColor]
        tint.startPoint = CGPoint(x: 0.5, y: 1); tint.endPoint = CGPoint(x: 0.5, y: 0)
        tint.frame = glass.bounds; tint.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        glass.layer?.addSublayer(tint)
        glass.layer?.borderWidth = 1; glass.layer?.borderColor = NSColor.white.withAlphaComponent(Tokens.rim * 0.5).cgColor
        panel.contentView = glass
        return panel
    }

    private func buildCapsule() {
        guard let glass = capsule.contentView else { return }
        let h = Tokens.capsuleSize.height, w = Tokens.capsuleSize.width, b = Tokens.micButton
        let button = NSView(frame: NSRect(x: 14, y: (h - b) / 2, width: b, height: b))
        button.wantsLayer = true; button.layer?.cornerRadius = b / 2; button.layer?.backgroundColor = Tokens.clay.cgColor
        halo.frame = button.frame.insetBy(dx: -4, dy: -4); halo.cornerRadius = halo.frame.width / 2
        halo.backgroundColor = Tokens.clay.withAlphaComponent(0.28).cgColor
        glass.layer?.addSublayer(halo)
        let mic = NSImageView(frame: button.bounds)
        mic.image = Self.symbol("mic.fill", size: Tokens.micSymbol, color: .white)
        mic.imageScaling = .scaleNone
        button.addSubview(mic)
        glass.addSubview(button)
        timer.frame = NSRect(x: w - 54, y: (h - 20) / 2, width: 40, height: 20)
        timer.font = NSFont(name: Tokens.textFont, size: 14) ?? .systemFont(ofSize: 14)
        timer.textColor = Tokens.muted; timer.alignment = .right
        glass.addSubview(timer)
        bars.frame = NSRect(x: 14 + b + 12, y: (h - Tokens.barMax) / 2, width: w - (14 + b + 12) - 62, height: Tokens.barMax)
        glass.addSubview(bars)
    }

    private func buildCard() {
        guard let glass = card.contentView else { return }
        titleLabel.font = NSFont(name: Tokens.titleFont, size: Tokens.titleSize) ?? .systemFont(ofSize: Tokens.titleSize)
        titleLabel.textColor = Tokens.clayDeep
        textLabel.font = NSFont(name: Tokens.textFont, size: Tokens.textSize) ?? .systemFont(ofSize: Tokens.textSize)
        textLabel.textColor = Tokens.ink; textLabel.isSelectable = true
        textLabel.preferredMaxLayoutWidth = Tokens.cardWidth - Tokens.cardPadding.left - Tokens.cardPadding.right
        copyButton = ActionButton(symbol: "doc.on.doc", title: "Copier") { [weak self] in self?.onCopy?() }
        actions.orientation = .horizontal; actions.spacing = 16
        actions.setViews([copyButton,
                          ActionButton(symbol: "return", title: "Insérer") { [weak self] in self?.onInsert?() },
                          ActionButton(symbol: "arrow.clockwise", title: "Refaire") { [weak self] in self?.onRedo?() }], in: .leading)
        for view in [titleLabel, textLabel, actions] as [NSView] { glass.addSubview(view) }
    }

    private func present(title: String, text: String, showCopy: Bool, showInsert: Bool, animate: Bool = true) {
        tick?.invalidate(); tick = nil; stopPulse(); fadeOut(capsule)
        titleLabel.stringValue = title; textLabel.stringValue = text
        copyButton.setTitle(showCopy ? "Copié" : "Copier")
        actions.views[0].isHidden = !showCopy; actions.views[1].isHidden = !showInsert
        let p = Tokens.cardPadding, inner = Tokens.cardWidth - p.left - p.right
        let textHeight = min(Tokens.maxTextHeight, ceil(textLabel.sizeThatFits(NSSize(width: inner, height: .greatestFiniteMagnitude)).height))
        let titleHeight: CGFloat = 20, actionsHeight: CGFloat = 18, gap: CGFloat = 4, gap2: CGFloat = 10
        let height = p.top + titleHeight + gap + textHeight + gap2 + actionsHeight + p.bottom
        actions.frame = NSRect(x: p.left, y: p.bottom, width: inner, height: actionsHeight)
        textLabel.frame = NSRect(x: p.left, y: p.bottom + actionsHeight + gap2, width: inner, height: textHeight)
        titleLabel.frame = NSRect(x: p.left, y: height - p.top - titleHeight, width: inner, height: titleHeight)
        if let screen = Self.screen() {
            let r = screen.visibleFrame
            card.setFrame(NSRect(x: r.midX - Tokens.cardWidth / 2, y: r.minY + Tokens.bottomInset, width: Tokens.cardWidth, height: height), display: true)
        }
        if animate { fadeIn(card); watchOutsideClicks() }
        card.invalidateShadow()
    }

    // MARK: Motion

    private func updateTimer() {
        guard let startedAt else { return }
        let s = Int(Date().timeIntervalSince(startedAt))
        timer.stringValue = "\(s / 60):" + String(format: "%02d", s % 60)
    }
    private func startPulse() {
        let a = CABasicAnimation(keyPath: "opacity"); a.fromValue = 0.15; a.toValue = 0.9
        a.duration = 0.6; a.autoreverses = true; a.repeatCount = .infinity
        halo.add(a, forKey: "pulse")
    }
    private func stopPulse() { halo.removeAnimation(forKey: "pulse"); halo.opacity = 0 }
    private func fadeIn(_ panel: NSPanel) {
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = Tokens.fade; panel.animator().alphaValue = 1 }
        if panel === capsule { halo.opacity = 1 }
    }
    private func fadeOut(_ panel: NSPanel) {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = Tokens.fade; panel.animator().alphaValue = 0 }) { [weak panel] in
            Task { @MainActor in if panel?.alphaValue == 0 { panel?.orderOut(nil) } }
        }
    }
    private func hideCard(animated: Bool) {
        outsideMonitors.forEach { NSEvent.removeMonitor($0) }; outsideMonitors = []
        if animated { fadeOut(card) } else { card.alphaValue = 0; card.orderOut(nil) }
    }
    /// A click anywhere outside the card fades it away. / un clic hors de la carte la fait disparaître.
    private func watchOutsideClicks() {
        outsideMonitors.forEach { NSEvent.removeMonitor($0) }; outsideMonitors = []
        let handler: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.card.isVisible, !self.card.frame.contains(NSEvent.mouseLocation) else { return }
                self.hideCard(animated: true)
            }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) { outsideMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { handler($0); return $0 }) { outsideMonitors.append(m) }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill(); return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// Replaces the text of a visible card without fading, when the final transcript differs from the live one.
    func updateResult(_ text: String) {
        guard card.isVisible, textLabel.stringValue != text else { return }
        present(title: titleLabel.stringValue, text: text, showCopy: true, showInsert: !actions.views[1].isHidden, animate: false)
    }

    static func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .semibold).applying(.init(paletteColors: [color])))
    }
}

/// A panel that never takes keyboard focus, so the target application stays frontmost for « Insérer ».
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Text action with an SF Symbol, clickable without activating the app.
private final class ActionButton: NSButton {
    private let action0: () -> Void
    init(symbol: String, title: String, action: @escaping () -> Void) {
        action0 = action
        super.init(frame: .zero)
        isBordered = false; imagePosition = .imageLeading; imageHugsTitle = true
        image = ClaudeOverlay.symbol(symbol, size: ClaudeOverlay.Tokens.actionSize, color: ClaudeOverlay.Tokens.muted)
        setTitle(title)
        target = self; self.action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    func setTitle(_ text: String) {
        attributedTitle = NSAttributedString(string: " " + text, attributes: [
            .font: NSFont(name: ClaudeOverlay.Tokens.uiFont, size: ClaudeOverlay.Tokens.actionSize) ?? .systemFont(ofSize: ClaudeOverlay.Tokens.actionSize),
            .foregroundColor: ClaudeOverlay.Tokens.muted])
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func fire() { action0() }
}

/// Live waveform: one bar per level, newest on the right. / onde en direct, la plus récente à droite.
private final class BarsView: NSView {
    var dimmed = false { didSet { needsDisplay = true } }
    private var levels: [CGFloat] = []
    private var count: Int { max(1, Int((bounds.width + ClaudeOverlay.Tokens.barGap) / (ClaudeOverlay.Tokens.barWidth + ClaudeOverlay.Tokens.barGap))) }
    func add(level: CGFloat) {
        levels.append(min(1, max(0, level * 2.2)))
        if levels.count > count { levels.removeFirst(levels.count - count) }
        needsDisplay = true
    }
    func reset() { levels = []; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let t = ClaudeOverlay.Tokens.self
        t.clay.withAlphaComponent(dimmed ? 0.4 : 1).setFill()
        let padded = Array(repeating: CGFloat(0), count: max(0, count - levels.count)) + levels
        for (i, level) in padded.enumerated() {
            let h = t.barMin + (t.barMax - t.barMin) * level
            let rect = NSRect(x: CGFloat(i) * (t.barWidth + t.barGap), y: (bounds.height - h) / 2, width: t.barWidth, height: h)
            NSBezierPath(roundedRect: rect, xRadius: t.barWidth / 2, yRadius: t.barWidth / 2).fill()
        }
    }
}
