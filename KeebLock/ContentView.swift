import Combine
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var controller: LockController
    @State private var accessibilityGranted = AccessibilityPermission.isGranted
    private let permissionPoller = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView {
            launcherTab
                .tabItem { Label("Launch", systemImage: "lock.fill") }

            SettingsView(settings: settings)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .padding(8)
        .onReceive(permissionPoller) { _ in
            let granted = AccessibilityPermission.isGranted
            if granted != accessibilityGranted { accessibilityGranted = granted }
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var launcherTab: some View {
        VStack(spacing: 20) {
            Image(systemName: "keyboard")
                .font(.system(size: 72))
                .foregroundStyle(accessibilityGranted ? Color.accentColor : .orange)

            Text("KeebLock")
                .font(.system(size: 34, weight: .bold))

            Text("Lock the keyboard. Clean it. Type the codeword to unlock.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 340)

            if !accessibilityGranted {
                accessibilityBanner
            }

            VStack(spacing: 6) {
                Text("Current codeword")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(settings.codeword.uppercased())
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.tint.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            gameModePanel

            Button {
                start()
            } label: {
                Label("Start cleaning", systemImage: "lock.fill")
                    .frame(minWidth: 200)
            }
            .controlSize(.extraLarge)
            .buttonStyle(.borderedProminent)
            .disabled(controller.isLocked || !accessibilityGranted)
            .keyboardShortcut(.return, modifiers: [])

            Text("Auto-unlock after \(settings.durationMinutes) minutes")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Game Mode Panel

    private var gameModePanel: some View {
        VStack(spacing: 10) {
            Text("vibes")
                .font(.caption2.weight(.semibold))
                .tracking(2)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                GameModeToggle(
                    icon: "speaker.wave.2.fill",
                    label: "Sound",
                    activeColor: Color(red: 1.0, green: 0.60, blue: 0.72),
                    isOn: $settings.soundEnabled
                )
                GameModeToggle(
                    icon: "sparkles",
                    label: "Sparks",
                    activeColor: Color(red: 0.73, green: 0.60, blue: 0.98),
                    isOn: $settings.sparksEnabled
                )
                ColorModeToggle(settings: settings)
            }
            .frame(maxWidth: 360)
        }
    }

    // MARK: - Accessibility Banner

    private var accessibilityBanner: some View {
        VStack(spacing: 10) {
            Label("Accessibility permission required", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)

            HStack(spacing: 12) {
                Button("Open System Settings") {
                    AccessibilityPermission.request()
                    AccessibilityPermission.openSystemSettings()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Reset & Retry") {
                    AccessibilityPermission.resetAndRequest()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            .buttonStyle(.bordered)

            Text("After enabling in System Settings, this app detects it automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func start() {
        guard accessibilityGranted else { return }
        controller.startLock(codeword: settings.codeword, durationMinutes: settings.durationMinutes)
    }
}

// MARK: - GameModeToggle

private struct GameModeToggle: View {
    let icon: String
    let label: String
    let activeColor: Color
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
                isOn.toggle()
            }
        } label: {
            VStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .symbolEffect(.bounce, value: isOn)
                Text(label)
                    .font(.caption.weight(.bold))
                    .tracking(0.3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isOn ? activeColor : Color.primary.opacity(0.06))
                    .shadow(color: isOn ? activeColor.opacity(0.45) : .clear, radius: 10, y: 5)
            }
            .foregroundStyle(isOn ? .white : Color.secondary)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(isOn ? 1.0 : 0.96)
        .animation(.spring(response: 0.28, dampingFraction: 0.58), value: isOn)
    }
}

// MARK: - ColorModeToggle

private struct ColorModeToggle: View {
    @ObservedObject var settings: AppSettings
    @State private var showSwatches = false

    static let presets: [(name: String, rgb: [Double])] = [
        ("Rose",     [1.00, 0.71, 0.76]),
        ("Lavender", [0.73, 0.60, 0.98]),
        ("Mint",     [0.62, 0.96, 0.78]),
        ("Sky",      [0.60, 0.85, 1.00]),
        ("Peach",    [1.00, 0.78, 0.60]),
        ("Lemon",    [1.00, 0.96, 0.52]),
        ("Coral",    [1.00, 0.60, 0.60]),
        ("Lilac",    [0.82, 0.65, 1.00]),
    ]

    private var isOn: Bool { settings.customScreenColorRGB != nil }

    private var activeColor: Color { settings.customSwiftUIColor }

    var body: some View {
        Button {
            if isOn {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
                    settings.customScreenColorRGB = nil
                }
            } else {
                showSwatches = true
            }
        } label: {
            VStack(spacing: 9) {
                if isOn {
                    Circle()
                        .fill(activeColor)
                        .frame(width: 26, height: 26)
                        .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1.5))
                } else {
                    Image(systemName: "paintpalette.fill")
                        .font(.system(size: 24, weight: .medium))
                }
                Text("Color")
                    .font(.caption.weight(.bold))
                    .tracking(0.3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isOn ? activeColor : Color.primary.opacity(0.06))
                    .shadow(color: isOn ? activeColor.opacity(0.45) : .clear, radius: 10, y: 5)
            }
            .foregroundStyle(isOn ? .white : Color.secondary)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(isOn ? 1.0 : 0.96)
        .animation(.spring(response: 0.28, dampingFraction: 0.58), value: isOn)
        .popover(isPresented: $showSwatches, arrowEdge: .bottom) {
            swatchGrid
        }
    }

    private var swatchGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Screen Color")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40)), count: 4), spacing: 10) {
                ForEach(Self.presets, id: \.name) { preset in
                    let color = Color(red: preset.rgb[0], green: preset.rgb[1], blue: preset.rgb[2])
                    let selected = settings.customScreenColorRGB == preset.rgb
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                            settings.customScreenColorRGB = preset.rgb
                        }
                        showSwatches = false
                    } label: {
                        Circle()
                            .fill(color)
                            .frame(width: 36, height: 36)
                            .overlay {
                                if selected {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .shadow(color: color.opacity(0.4), radius: 4, y: 2)
                            .scaleEffect(selected ? 1.1 : 1.0)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
    }
}
