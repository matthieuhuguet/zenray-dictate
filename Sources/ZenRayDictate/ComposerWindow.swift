import AppKit
import WebKit

/// Floats the real ChatGPT composer instead of imitating it.
///
/// The page itself is stripped down to the composer by the bridge, the web view
/// is made transparent, and this window has no frame of its own. What you see on
/// screen is therefore ChatGPT's own bar, with its own waveform and its own
/// controls, which is why the buttons in it actually work.
///
/// It is a non activating panel, so clicking those controls never steals focus
/// from whatever you were typing in.
final class ComposerWindow {

    private var panel: NSPanel?
    private var size = CGSize(width: 720, height: 92)

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - Public

    func show(_ webView: WKWebView) {
        let p = panel ?? build()
        makeTransparent(webView)

        if webView.superview !== p.contentView {
            webView.removeFromSuperview()
            webView.frame = CGRect(origin: .zero, size: size)
            webView.autoresizingMask = [.width, .height]
            p.contentView?.subviews.forEach { $0.removeFromSuperview() }
            p.contentView?.addSubview(webView)
        }

        position()
        p.orderFrontRegardless()
    }

    /// The page reports how tall its composer really is, so the window fits it
    /// exactly rather than guessing and leaving a grey band around the pill.
    func resize(to newSize: CGSize) {
        guard newSize.width > 100, newSize.height > 30 else { return }
        size = CGSize(width: min(newSize.width, 900), height: newSize.height)
        panel?.setContentSize(size)
        panel?.contentView?.subviews.first?.frame = CGRect(origin: .zero, size: size)
        position()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Internals

    private func build() -> NSPanel {
        let p = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true          // follows the pill's own shape
        p.ignoresMouseEvents = false // the real controls must be clickable
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let host = NSView(frame: CGRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = host

        panel = p
        return p
    }

    /// Without this the web view paints an opaque sheet behind the page, which
    /// is the grey rounded square that used to frame the pill.
    private func makeTransparent(_ webView: WKWebView) {
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func position() {
        guard let p = panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        p.setFrameOrigin(NSPoint(
            x: frame.midX - p.frame.width / 2,
            y: frame.minY + 120
        ))
    }
}
