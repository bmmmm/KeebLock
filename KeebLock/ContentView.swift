import SwiftUI

struct ContentView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var controller: LockController
    @State private var showAccessibilityHint = false

    var body: some View {
        TabView {
            launcherTab
                .tabItem { Label("Launch", systemImage: "lock.fill") }

            SettingsView(settings: settings)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .padding(8)
        .alert(
            "Accessibility access required",
            isPresented: $showAccessibilityHint
        ) {
            Button("Open System Settings") {
                AccessibilityPermission.openSystemSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("KeebLock needs Accessibility access to swallow keystrokes. Enable it in System Settings → Privacy & Security → Accessibility, then return here and click Start.")
        }
    }

    private var launcherTab: some View {
        VStack(spacing: 24) {
            Image(systemName: "keyboard")
                .font(.system(size: 80))
                .foregroundStyle(.tint)

            Text("KeebLock")
                .font(.system(size: 36, weight: .bold))

            Text("Lock the keyboard. Clean it. Type the codeword to unlock.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)

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

            Button {
                start()
            } label: {
                Label("Start cleaning", systemImage: "lock.fill")
                    .frame(minWidth: 200)
            }
            .controlSize(.extraLarge)
            .buttonStyle(.borderedProminent)
            .disabled(controller.isLocked)

            Text("Auto-unlock after \(settings.durationMinutes) minutes")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func start() {
        guard AccessibilityPermission.isGranted else {
            AccessibilityPermission.request()
            showAccessibilityHint = true
            return
        }
        controller.startLock(
            codeword: settings.codeword,
            durationMinutes: settings.durationMinutes
        )
    }
}
