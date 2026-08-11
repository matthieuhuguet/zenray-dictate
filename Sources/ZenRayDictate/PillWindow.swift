import AppKit
import SwiftUI

/// The floating ChatGPT composer pill. It never takes keyboard focus, so the
/// app you were typing in stays active while you dictate.
final class PillWindow {

    private var panel: NSPanel?
    private let model = PillModel()

    // MARK: - Public

    /// Builds the panel ahead of time. Laying out an NSHostingView costs a
    /// visible fraction of a second the first time, which is exactly the delay
    /// you notice between pressing Fn and seeing the pill.
    func prewarm() {
        if panel == nil { build() }
    }

    func show(state: DictationEngine.State) {
        model.error = nil
        model.state = state
        present()
    }

    func update(state: DictationEngine.State) {
        model.state = state
        if state == .idle && model.error == nil { hide() }
    }

    /// Shows a failure and takes itself away, so nothing is ever left on screen.
    func fail(_ message: String, hint: String? = nil) {
        model.state = .idle
        model.error = message
        model.hint = hint
        present()
        autoHide(after: 4.5, token: message)
    }

    /// A short confirmation that disappears on its own.
    func flash(_ message: String) {
        model.state = .idle
        model.error = nil
        model.note = message
        present()
        autoHide(after: 2.0, token: message)
    }

    func hide() {
        panel?.orderOut(nil)
        model.error = nil
        model.note = nil
        model.hint = nil
    }

    // MARK: - Internals

    private func autoHide(after seconds: TimeInterval, token: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            guard self.model.error == token || self.model.note == token else { return }
            self.hide()
        }
    }

    private func present() {
        if panel == nil { build() }
        position()
        panel?.orderFrontRegardless()
    }

    private func build() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.animationBehavior = .utilityWindow
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = NSHostingView(rootView: PillView(model: model))
        panel = p
    }

    /// Bottom centre of whichever screen holds the pointer, so the pill follows
    /// the display you are actually working on.
    private func position() {
        guard let p = panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = p.frame.size
        p.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 120
        ))
    }
}

// MARK: - Model

final class PillModel: ObservableObject {
    @Published var state: DictationEngine.State = .idle
    @Published var error: String?
    @Published var note: String?
    @Published var hint: String?
}

// MARK: - View

struct PillView: View {
    @ObservedObject var model: PillModel
    @Environment(\.colorScheme) private var scheme

    private var isError: Bool { model.error != nil }

    private var label: String {
        if let e = model.error { return e }
        if let n = model.note { return n }
        switch model.state {
        case .starting, .recording: return "Listening…"
        case .transcribing:         return "Transcribing…"
        case .idle:                 return "Ask ChatGPT"
        }
    }

    private var surface: Color {
        scheme == .dark ? Color(red: 0.17, green: 0.17, blue: 0.18) : .white
    }

    private var ink: Color {
        scheme == .dark ? .white : .black
    }

    private var accent: Color {
        isError ? Color(red: 0.80, green: 0.27, blue: 0.24)
                : Color(red: 0.85, green: 0.47, blue: 0.24)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Image(systemName: isError ? "exclamationmark.triangle" : "plus")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(isError ? accent : ink.opacity(0.7))

                Text(label)
                    .font(.system(size: 18, weight: .regular))
                    .lineLimit(1)
                    .foregroundStyle(ink.opacity(model.state == .idle && !isError && model.note == nil ? 0.35 : 0.8))

                Spacer(minLength: 8)

                if model.state == .transcribing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 24, height: 24)
                } else if !isError {
                    Image(systemName: "mic")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(ink.opacity(0.7))
                }

                ZStack {
                    Circle().fill(accent).frame(width: 40, height: 40)
                    WaveIcon(active: model.state == .recording || model.state == .starting)
                }
            }
            .padding(.leading, 24)
            .padding(.trailing, 10)
            .frame(width: 600, height: 62)

            if let hint = model.hint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(ink.opacity(0.5))
                    .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 31, style: .continuous)
                .fill(surface)
                .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.18), radius: 24, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 31, style: .continuous)
                .stroke(ink.opacity(scheme == .dark ? 0.10 : 0.06), lineWidth: 1)
        )
        .padding(14)
        .animation(.easeOut(duration: 0.18), value: model.state)
        .animation(.easeOut(duration: 0.18), value: model.error)
    }
}

/// The four bar glyph inside the coloured circle.
struct WaveIcon: View {
    let active: Bool
    @State private var phase = false

    private let heights: [CGFloat] = [9, 17, 13, 8]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, h in
                Capsule()
                    .fill(Color.white)
                    .frame(width: 3, height: active && phase ? h * 1.5 : h)
                    .animation(
                        active
                            ? .easeInOut(duration: 0.42)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.09)
                            : .default,
                        value: phase
                    )
            }
        }
        .onAppear { phase = true }
    }
}
