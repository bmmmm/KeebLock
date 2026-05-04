import Combine
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var controller: LockController
    @State private var showHeatmap = false
    @State private var accessibilityGranted = AccessibilityPermission.isGranted
    // Timer that polls AXIsProcessTrusted() every second while permission is missing
    private let permissionPoller = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView {
            launcherTab
                .tabItem { Label("Launch", systemImage: "lock.fill") }

            SettingsView(settings: settings, controller: controller)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .padding(8)
        .sheet(isPresented: $showHeatmap) {
            HeatmapView(controller: controller)
        }
        .onChange(of: controller.isLocked) { _, isLocked in
            if !isLocked && controller.keystrokeCount > 0 {
                showHeatmap = true
            }
        }
        .onReceive(permissionPoller) { _ in
            let granted = AccessibilityPermission.isGranted
            if granted != accessibilityGranted {
                accessibilityGranted = granted
            }
        }
        // Cmd+Q — quit
        .keyboardShortcut("q", modifiers: .command)
    }

    private var launcherTab: some View {
        VStack(spacing: 24) {
            Image(systemName: "keyboard")
                .font(.system(size: 80))
                .foregroundStyle(accessibilityGranted ? Color.accentColor : .orange)

            Text("KeebLock")
                .font(.system(size: 36, weight: .bold))

            Text("Lock the keyboard. Clean it. Type the codeword to unlock.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)

            if !accessibilityGranted {
                accessibilityBanner
            }

            VStack(spacing: 8) {
                Text("Current codeword")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(settings.codeword.uppercased())
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.tint.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.top, 4)

            // Return key = Start
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
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var accessibilityBanner: some View {
        VStack(spacing: 10) {
            Label("Accessibility permission required", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)

            HStack(spacing: 12) {
                // Open settings and wait — the poller detects when toggle is flipped
                Button("Open System Settings") {
                    AccessibilityPermission.request()
                    AccessibilityPermission.openSystemSettings()
                }
                .keyboardShortcut("o", modifiers: .command)

                // Reset TCC entry + re-request — helps when toggle is stuck
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
        controller.startLock(
            codeword: settings.codeword,
            durationMinutes: settings.durationMinutes
        )
    }
}
