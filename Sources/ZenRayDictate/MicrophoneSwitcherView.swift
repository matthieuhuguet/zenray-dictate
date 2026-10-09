import SwiftUI
import AppKit

// 09 October 2026: visual microphone pill and switcher view for ZenRay Dictate.
public struct MicrophoneSwitcherView: View {
    @ObservedObject var manager = MicrophoneManager.shared
    public var onClose: (() -> Void)?

    public init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 16) {
            // Header: The Active Microphone Pill (Pastille UI)
            VStack(spacing: 10) {
                HStack {
                    Text("Entrée microphone active")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    if let onClose {
                        Button(action: onClose) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // The Pill UI: macOS orange indicator style
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)

                    Text(manager.activeDevice?.name ?? "Aucun micro actif")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    // Transport tag
                    if let active = manager.activeDevice {
                        Text(active.transport.rawValue)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.25))
                            .clipShape(Capsule())
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(red: 1.0, green: 0.50, blue: 0.0))
                .clipShape(Capsule())
                .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1)

                // Sub-info: Sample rate and status
                if let active = manager.activeDevice {
                    HStack(spacing: 12) {
                        Label {
                            Text("\(Int(active.sampleRate)) Hz")
                        } icon: {
                            Image(systemName: "waveform")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                        if active.transport == .bluetooth {
                            Label("Mode mains-libres casque", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.red)
                        } else if active.transport == .builtIn {
                            Label("Micro intégré haute fidélité", systemImage: "checkmark.seal.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
            .padding(14)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 14))

            // Switcher list: Vue Switch des micros disponibles
            VStack(alignment: .leading, spacing: 8) {
                Text("Changer de micro")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                VStack(spacing: 6) {
                    ForEach(manager.availableDevices) { device in
                        let isSelected = (device.id == manager.activeDevice?.id)
                        Button {
                            manager.switchToDevice(id: device.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: device.transport.iconName)
                                    .font(.system(size: 14))
                                    .foregroundStyle(isSelected ? Color(red: 1.0, green: 0.48, blue: 0.02) : .secondary)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                        .lineLimit(1)

                                    Text("\(device.transport.rawValue) · \(Int(device.sampleRate)) Hz")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if isSelected {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                        Text("ACTIF")
                                            .font(.system(size: 10, weight: .bold))
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color(red: 1.0, green: 0.48, blue: 0.02))
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())
                                } else {
                                    Text("Switch")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color(NSColor.quaternaryLabelColor).opacity(0.1))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                isSelected
                                    ? Color(NSColor.selectedContentBackgroundColor).opacity(0.12)
                                    : Color(NSColor.controlBackgroundColor).opacity(0.4)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(
                                        isSelected ? Color(red: 1.0, green: 0.48, blue: 0.02).opacity(0.4) : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Security Lock Section (Toggle Switch)
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $manager.isLockedToBuiltIn) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Verrouiller sur le micro MacBook Pro")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Empêche le casque Bluetooth de capturer le micro à la connexion.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Footer actions
            HStack {
                Button {
                    manager.switchToBuiltIn()
                } label: {
                    Label("Forcer MacBook Pro", systemImage: "laptopcomputer")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.link)

                Spacer()

                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Réglages Son", systemImage: "gearshape")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.link)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: 340)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
