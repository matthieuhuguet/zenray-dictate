import AppKit

// 3 October 2026, 16:05 CEST: the recording capsule never activates or steals the target application's focus.
final class DictationCapsule {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "Ready")
    private let waveform = WaveformView()
    enum Tokens {
        static let width: CGFloat = 300
        static let height: CGFloat = 58
        static let inset: CGFloat = 22
    }
    init() {
        panel = NSPanel(contentRect: NSRect(x:0,y:0,width:Tokens.width,height:Tokens.height), styleMask:[.borderless,.nonactivatingPanel], backing:.buffered,defer:false)
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear
        let background = NSVisualEffectView(frame:panel.contentRect(forFrameRect:panel.frame))
        background.material = .hudWindow; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = Tokens.height / 2
        let stack = NSStackView(views:[label,waveform]); stack.orientation = .vertical
        stack.spacing = 3; stack.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont(name:DictationTypography.sans,size:12) ?? .systemFont(ofSize:12); label.alignment = .center
        waveform.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack); panel.contentView = background
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:background.leadingAnchor,constant:18),stack.trailingAnchor.constraint(equalTo:background.trailingAnchor,constant:-18),stack.centerYAnchor.constraint(equalTo:background.centerYAnchor),waveform.heightAnchor.constraint(equalToConstant:18)])
        panel.ignoresMouseEvents = true
    }
    func show(_ text: String) {
        label.stringValue = text
        if let screen = NSScreen.main {
            let rect = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x:rect.midX-Tokens.width/2,y:rect.minY+Tokens.inset))
        }
        panel.orderFrontRegardless()
    }
    func add(level: Float) { waveform.add(level:CGFloat(level)) }
    func hide() { panel.orderOut(nil); waveform.reset() }
}
