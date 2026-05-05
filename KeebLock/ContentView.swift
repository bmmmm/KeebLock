import Combine
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var controller: LockController
    @ObservedObject private var inputSource = InputSourceObserver.shared
    @State private var accessibilityGranted = AccessibilityPermission.isGranted
    private let permissionPoller = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView {
            launcherTab
                .tabItem { Label("Launch", systemImage: "lock.fill") }

            SettingsView(settings: settings, controller: controller)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .padding(8)
        .onReceive(permissionPoller) { _ in
            let granted = AccessibilityPermission.isGranted
            if granted != accessibilityGranted { accessibilityGranted = granted }
        }
    }

    private var launcherTab: some View {
        VStack(spacing: 18) {
            Image(systemName: "keyboard")
                .font(.system(size: 64))
                .foregroundStyle(accessibilityGranted ? Color.accentColor : .orange)

            Text("KeebLock")
                .font(.system(size: 32, weight: .bold))

            Text("Lock the keyboard. Clean it.\nType the codeword to unlock.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if !accessibilityGranted {
                accessibilityBanner
            }

            VStack(spacing: 6) {
                Text("Current codeword")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    settings.codeword = Codewords.random()
                } label: {
                    HStack(spacing: 8) {
                        Text(settings.codeword.uppercased())
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .tracking(2)
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.tint.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Click for next codeword")

                HStack(spacing: 4) {
                    Image(systemName: "keyboard.badge.eye")
                        .font(.caption2)
                    Text(inputSource.localizedName)
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .help("Active keyboard layout — KeebLock follows your input source")
            }

            if settings.showCodewordKnowledge {
                CodewordCard(codeword: settings.codeword)
            }

            vibesPanel

            WaterFillButton(action: start, disabled: controller.isLocked || !accessibilityGranted)
                .keyboardShortcut(.return, modifiers: [])
        }
        .padding(28)
    }

    private var vibesPanel: some View {
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
                EffectCycleToggle(settings: settings)
                ColorModeToggle(settings: settings)
            }
            .frame(maxWidth: 360)
        }
    }

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
