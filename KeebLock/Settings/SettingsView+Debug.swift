import AppKit
import SwiftUI

extension SettingsView {
    var debugSection: some View {
        tintedSection("Debug") {
            Toggle("Enable debug logging", isOn: $settings.debugLoggingEnabled)

            if settings.debugLoggingEnabled {
                Toggle("Verbose perf sampling (callback latency, p99)", isOn: $settings.verbosePerfEnabled)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Lock-screen overlay")
                        .font(fCallout)
                    Picker("Lock-screen overlay", selection: $settings.lockOverlayDebugLevel) {
                        ForEach(LockOverlayDebugLevel.allCases) { lvl in
                            Text(lvl.label).tag(lvl)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("Border-strip HUD around the lock window. Higher levels add more rows AND dampen the spark/effect intensity so the readout stays readable.")
                        .font(fCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Snapshot includes screen layout, lock state, the name of your frontmost app, and recent keycodes (as numbers, not characters). Review before sharing.")
                    .font(fCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("Save snapshot") {
                        let snap = DebugLog.snapshot()
                        DebugLog.writeForced(snap)
                        showSnapshotMessage("Snapshot appended to log.")
                    }
                    .buttonStyle(.bordered)

                    Button("Copy all debug info") {
                        let snap = DebugLog.snapshot()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(snap, forType: .string)
                        showSnapshotMessage("Copied to clipboard.")
                    }
                    .buttonStyle(.bordered)

                    Button("Open log folder") {
                        DebugLog.revealLogInFinder()
                    }
                    .buttonStyle(.bordered)
                }

                if let snapshotMessage {
                    Text(snapshotMessage)
                        .font(fCaption)
                        .foregroundStyle(.green)
                }

                Text("Log path: ~/Library/Logs/KeebLock/keeblock.log")
                    .font(fCaption)
                    .foregroundStyle(.secondary)

                HStack {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text("Max log file size")
                    Spacer()
                    Stepper(value: $settings.logFileMaxSizeMB, in: 1...100) {
                        Text("\(settings.logFileMaxSizeMB) MB")
                            .font(scaled(17, mono: true))
                    }
                }
                Text("When the log exceeds this, it rotates: current file becomes keeblock.log.old (replacing any previous backup) and a fresh keeblock.log starts.")
                    .font(fCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                DebugInfoPanel(settings: settings, controller: controller)
                    .padding(.top, 8)
                    .id(Self.debugBottomID)
            }
        }
    }

    // MARK: - Actions

    /// Show a transient confirmation under the debug buttons, then auto-clear
    /// it after ~2s. Mirrors the `copiedCommand` pattern; a generation token
    /// guards against an older timer wiping a newer message.
    func showSnapshotMessage(_ message: String) {
        snapshotMessage = message
        snapshotMessageToken += 1
        let token = snapshotMessageToken
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if snapshotMessageToken == token { snapshotMessage = nil }
        }
    }
}
