import AppKit
import SwiftUI

/// The floating ChatGPT composer pill. It never takes keyboard focus, so the
/// app you were typing in stays active while you dictate.
final class PillWindow {

    private var panel: NSPanel?
    private let model = PillModel()

    func show(state: DictationEngine.State) {
        model.state = state
        if panel == nil { build() }
        position()
        panel?.orderFrontRegardless()
    }

    func update(state: DictationEngine.State) {
        model.state = state
    }

    func flash(message: String) {
        model.message = message
        if panel == nil { build() }
        position()
        panel?.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            guard self?.model.message == message else { return }
            self?.hide()
        }
    }

    func hide() {
        panel?.orderOut(nil)
        model.message = nil
    }

    private func build() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 76),
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
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = NSHostingView(rootView: PillView(model: model))
        panel = p
    }

    private func position() {
        guard let p = panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = p.frame.size
        p.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + frame.height * 0.22
        ))
    }
}

// MARK: - Model

final class PillModel: ObservableObject {
    @Published var state: DictationEngine.State = .idle
    @Published var message: String?
}

// MARK: - View

struct PillView: View {
    @ObservedObject var model: PillModel
    @State private var pulse = false

    private var label: String {
        if let m = model.message { return m }
        switch model.state {
        case .recording:    return "Listening…"
        case .transcribing: return "Transcribing…"
        case .idle:         return "Ask ChatGPT"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "plus")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(Color.black.opacity(0.75))

            Text(label)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(model.message == nil && model.state == .idle
                                 ? Color.black.opacity(0.35)
                                 : Color.black.opacity(0.75))

            Spacer(minLength: 8)

            if model.state == .transcribing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.9)
                    .frame(width: 26, height: 26)
            } else {
                Image(systemName: "mic")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(Color.black.opacity(0.75))
            }

            ZStack {
                Circle()
                    .fill(Color(red: 0.85, green: 0.47, blue: 0.24))
                    .frame(width: 42, height: 42)
                WaveIcon(active: model.state == .recording)
            }
            .scaleEffect(model.state == .recording && pulse ? 1.06 : 1.0)
            .animation(
                model.state == .recording
                    ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
        }
        .padding(.leading, 24)
        .padding(.trailing, 10)
        .frame(width: 600, height: 64)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.18), radius: 26, x: 0, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
        .padding(10)
        .onAppear { pulse = true }
    }
}

/// The four bar glyph inside the orange circle.
struct WaveIcon: View {
    let active: Bool
    @State private var phase = false

    private let heights: [CGFloat] = [10, 18, 14, 8]

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
