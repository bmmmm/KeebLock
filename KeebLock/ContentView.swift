import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let keebLockOpenSettings = Notification.Name("KeebLock.openSettings")
    /// Posted by `LockController.attemptStartLock` after every lock attempt,
    /// from both the launcher's Start button and the ⌘S menu command — lets
    /// the launcher re-sync its AX-permission banner regardless of which
    /// entry point triggered the attempt.
    static let keebLockLockAttempted = Notification.Name("KeebLock.lockAttempted")
}

struct ContentView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(LockController.self) var controller
    @ObservedObject private var inputSource = InputSourceObserver.shared
    @State private var accessibilityGranted = AccessibilityPermission.isGranted
    @State private var selectedTab: Int = 0
    @State private var permissionPollTask: Task<Void, Never>?
    @State private var showVerifyPopover = false
    @State private var isResettingPermission = false
    /// CDHash the user has manually verified against the published values.
    /// Empty until they actively confirm; resets implicitly with every new
    /// release because each build has a fresh CDHash. The shield only glows
    /// green when this matches the running binary — anything else (no entry,
    /// stale entry from a previous build) keeps it orange so the user can't
    /// mistake "merely signed" for "actually checked".
    @AppStorage("KeebLock.verifiedCDHash") private var verifiedCDHash: String = ""

    /// Window-width-driven typography scale (see `UIScale`). All explicit
    /// launcher font sizes are expressed as `base * uiScale` so the text
    /// grows with the window and stays crisp.
    @Environment(\.uiScale) private var uiScale

    var body: some View {
        TabView(selection: $selectedTab) {
            launcherTab
                .tabItem { Label("Launch", systemImage: "lock.fill") }
                .tag(0)

            SettingsView(settings: settings, controller: controller)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(1)
        }
        .padding(8)
        .onAppear { startPermissionPolling() }
        .onDisappear { permissionPollTask?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .keebLockOpenSettings)) { _ in
            selectedTab = 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // AX can be revoked in System Settings while we're backgrounded; the
            // one-shot poller stopped once granted and won't catch that. Re-check
            // on focus regain so the launcher's granted-state UI can't go stale,
            // and re-arm polling if it was revoked.
            let granted = AccessibilityPermission.isGranted
            if granted != accessibilityGranted { accessibilityGranted = granted }
            if !granted { startPermissionPolling() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .keebLockLockAttempted)) { _ in
            resyncAccessibilityState()
        }
    }

    /// Polls the Accessibility permission once per second only while it is
    /// still missing. Cancels itself the moment macOS reports granted, so the
    /// happy-path runs zero background work for the remainder of the session.
    /// Re-revoking from System Settings would also re-show the launcher in
    /// the not-granted state — but that requires a relaunch by design.
    private func startPermissionPolling() {
        guard !accessibilityGranted else { return }
        permissionPollTask?.cancel()
        permissionPollTask = Task { @MainActor in
            while !Task.isCancelled {
                if AccessibilityPermission.isGranted {
                    accessibilityGranted = true
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var launcherTab: some View {
        // No ScrollView: the window is aspect-locked and `uiScale` fits the
        // column into the available space in both dimensions, so the launcher
        // never needs to scroll — it just scales. Centered in whatever space
        // the (proportional) window provides.
        VStack {
            Spacer(minLength: 0)
            VStack(spacing: 18 * uiScale) {
                Image(systemName: "keyboard")
                    .font(.system(size: 72 * uiScale))
                    .foregroundStyle(accessibilityGranted ? settings.appTheme.color : .orange)

                Text("KeebLock")
                    .font(.system(size: 44 * uiScale, weight: .bold))

                Text("Lock the keyboard. Clean it.\nType the codeword to unlock.")
                    .font(.system(size: 19 * uiScale, weight: .regular))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                if !settings.hasSeenIntro {
                    introCard
                }

                if !accessibilityGranted {
                    accessibilityBanner
                }

                VStack(spacing: 6 * uiScale) {
                    Text("Current codeword")
                        .font(.system(size: 14 * uiScale, weight: .semibold))
                        .foregroundStyle(.tint)
                    Button {
                        settings.codeword = Codewords.random()
                    } label: {
                        HStack(spacing: 8 * uiScale) {
                            Text(settings.codeword.uppercased())
                                .font(.system(size: 32 * uiScale, weight: .semibold, design: .monospaced))
                                .tracking(2 * uiScale)
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 18 * uiScale, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 18 * uiScale)
                        .padding(.vertical, 10 * uiScale)
                        .background(.tint.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                    }
                    .buttonStyle(.plain)
                    .help("Click for next codeword")

                    HStack(spacing: 4 * uiScale) {
                        Image(systemName: "keyboard.badge.eye")
                            .font(.system(size: 12 * uiScale))
                            .foregroundStyle(.tint)
                        Text(inputSource.localizedName)
                            .font(.system(size: 12 * uiScale))
                            .foregroundStyle(.secondary)
                    }
                    .help("Active keyboard layout — KeebLock follows your input source")
                }

                if settings.showCodewordKnowledge {
                    CodewordCard(codeword: settings.codeword)
                }

                vibesPanel

                WaterFillButton(
                    action: start,
                    isDisabled: { controller.isLocked || !accessibilityGranted },
                    accent: settings.appTheme.color
                )
                    .keyboardShortcut(.return, modifiers: [])

                shortcutHints
                buildIdentityFooter
            }
            .frame(maxWidth: .infinity)
            .padding(28 * uiScale)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private enum BuildVerification { case verified, needsVerification, invalid }

    private var verificationState: BuildVerification {
        let id = SigningIdentity.current
        guard let cd = id.cdHash, id.teamID != nil else { return .invalid }
        return cd == verifiedCDHash ? .verified : .needsVerification
    }

    /// Shortcut hint row beneath the start button. Mirrors the menu-bar
    /// shortcuts so first-time users see the keyboard handles without
    /// having to crack open the app menu. Symbols-first for a macOS-
    /// native feel; sized for at-a-glance reading from a normal viewing
    /// distance, not whisper-discreet.
    private var shortcutHints: some View {
        HStack(spacing: 18 * uiScale) {
            shortcutBadge(keys: "⌘S",   label: "Start")
            shortcutBadge(keys: "⌘R",   label: "Roll codeword")
            shortcutBadge(keys: "⌘,",   label: "Settings")
            shortcutBadge(keys: "⌘Q",   label: "Quit")
        }
        .font(.system(size: 13 * uiScale))
        .foregroundStyle(.secondary)
        .padding(.top, 4 * uiScale)
    }

    private func shortcutBadge(keys: String, label: String) -> some View {
        HStack(spacing: 7 * uiScale) {
            // Tracking widens the gap between ⌘ and the letter so the
            // sequence reads as two symbols, not the word "cmdS". Apple's
            // own UI uses uppercase letters (⌘S, not ⌘s) — Shift is
            // signalled by an explicit ⇧, never by lowercasing the letter.
            // `.tint` follows the global `.tint(settings.appTheme.color)`
            // applied at the WindowGroup root, so the badge re-colours
            // automatically when the user switches accent theme.
            Text(keys)
                .font(.system(size: 13 * uiScale, weight: .semibold, design: .monospaced))
                .tracking(4 * uiScale)
                .padding(.horizontal, 9 * uiScale)
                .padding(.vertical, 3 * uiScale)
                .background(.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: Radius.sm))
                .foregroundStyle(.tint)
            Text(label)
        }
    }

    private var buildIdentityFooter: some View {
        let id = SigningIdentity.current
        let state = verificationState
        let color = shieldColor(for: state)
        return Button {
            showVerifyPopover.toggle()
        } label: {
            HStack(spacing: 5 * uiScale) {
                Image(systemName: shieldIcon(for: state))
                    .font(.system(size: 11 * uiScale))
                    .foregroundStyle(color)
                    .shadow(color: color.opacity(0.55), radius: 3)
                if let tid = id.teamID {
                    Text("Build identity ")
                        .foregroundStyle(.secondary)
                    Text(tid)
                        .font(.system(size: 11 * uiScale, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not the official build")
                        .font(.system(size: 11 * uiScale, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }
            .font(.system(size: 11 * uiScale))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText(for: state, id: id))
        .popover(isPresented: $showVerifyPopover, arrowEdge: .top) {
            verifyPopover(id, state: state)
                .padding(16)
                .frame(width: 380)
        }
    }

    private func shieldColor(for state: BuildVerification) -> Color {
        switch state {
        case .verified:          return .green
        case .needsVerification: return .orange
        case .invalid:           return .red
        }
    }

    private func shieldIcon(for state: BuildVerification) -> String {
        switch state {
        case .verified:          return "checkmark.shield.fill"
        case .needsVerification: return "exclamationmark.shield.fill"
        case .invalid:           return "xmark.shield.fill"
        }
    }

    private func helpText(for state: BuildVerification, id: SigningIdentity.Info) -> String {
        switch state {
        case .verified:
            return "Verified by you. Click for details."
        case .needsVerification:
            let tid = id.teamID ?? "?"
            return "Signed as \(tid) but not yet verified by you. Click and compare the values with the latest release notes to turn the shield green."
        case .invalid:
            return "This is NOT the official KeebLock build — the binary has no stable Apple Team ID. Could be a local debug build, an ad-hoc copy, or a tampered redistribution. Click for details."
        }
    }

    private var invalidWarningBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("This is not bmmmm's KeebLock")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                Text("The binary has no stable Apple Team ID. That means a local debug build, an ad-hoc-signed copy, or a tampered redistribution — not what bmmmm publishes. Don't trust it for anything sensitive; download a fresh copy from the official releases page below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.sm))
    }

    private func verifyPopover(_ id: SigningIdentity.Info, state: BuildVerification) -> some View {
        let cmd = "codesign -dv --verbose=4 /Applications/KeebLock.app 2>&1 | grep -E '^(TeamIdentifier|CDHash)='"
        return VStack(alignment: .leading, spacing: 12) {
            Text("Verify this build")
                .font(.headline)

            if state == .invalid {
                invalidWarningBanner
            } else {
                Text("Authenticity is anchored to the Apple Team ID — only the original signing cert can produce a binary with this identity. Compare the values below with the release notes at github.com/bmmmm/KeebLock (check the URL in your browser before trusting the values — a re-host can publish matching numbers for its own re-signed copy). Then run the command in Terminal so the OS reads them directly from disk, and mark the build verified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                identityRow(label: "Team ID", value: id.teamID ?? "(missing — not an official build)")
                identityRow(label: "CDHash", value: id.cdHash.map { String($0.prefix(16)) + "…" } ?? "(missing)")
            }

            Divider()

            Text("Run in Terminal:")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 8) {
                Text(cmd)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(cmd, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy verify command")
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.sm))

            if let url = URL(string: "https://github.com/bmmmm/KeebLock/releases/latest") {
                Link(state == .invalid
                     ? "Get the official build from releases →"
                     : "Compare with the latest release notes →",
                     destination: url)
                    .font(.caption)
            }

            if state != .invalid {
                Divider()
                verifyAction(state: state, id: id)
            }
        }
    }

    @ViewBuilder
    private func verifyAction(state: BuildVerification, id: SigningIdentity.Info) -> some View {
        switch state {
        case .verified:
            HStack {
                Label("Verified by you", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Spacer()
                Button("Reset") { verifiedCDHash = "" }
                    .controlSize(.small)
            }
        case .needsVerification:
            Button {
                if let cd = id.cdHash {
                    verifiedCDHash = cd
                }
            } label: {
                Label("I've checked these values — mark verified", systemImage: "checkmark.circle")
                    .font(.caption)
            }
            .controlSize(.small)
        case .invalid:
            EmptyView()
        }
    }

    private func identityRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private var vibesPanel: some View {
        VStack(spacing: 10 * uiScale) {
            Text("vibes")
                .font(.system(size: 11 * uiScale, weight: .semibold))
                .tracking(2 * uiScale)
                .foregroundStyle(.tint)

            HStack(spacing: 10 * uiScale) {
                GameModeToggle(
                    icon: "speaker.wave.2.fill",
                    label: "Sound",
                    activeColor: settings.appTheme.color,
                    isOn: $settings.soundEnabled
                )
                EffectCycleToggle(settings: settings)
                ColorModeToggle(settings: settings)
                WipeModeToggle(settings: settings)
            }
            .frame(maxWidth: 460 * uiScale)
        }
    }

    /// First-run explainer. The core interaction model — codeword-to-unlock,
    /// ⌘⌥Esc as the safety net — otherwise lives only in the README, so a
    /// first-time user who skips straight to Start Cleaning has no in-app clue
    /// how to get back out. Dismissible by hand; also retired automatically
    /// on the first completed unlock (`LockController.stopLock`).
    private var introCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Label("How KeebLock works", systemImage: "info.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(settings.appTheme.color)
                Spacer()
                Button {
                    settings.hasSeenIntro = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            Text("Starting a session locks your keyboard behind a full-screen HUD. Type the codeword shown below to unlock — or press ⌘⌥Esc anytime as the safety net.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(settings.appTheme.color.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.md))
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
                .disabled(isResettingPermission)

                Button {
                    isResettingPermission = true
                    AccessibilityPermission.resetAndRequest {
                        isResettingPermission = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isResettingPermission {
                            ProgressView()
                                .controlSize(.small)
                            Text("Resetting…")
                        } else {
                            Text("Reset & Retry")
                        }
                    }
                }
                // ⇧⌘R, not ⌘R — the app menu's "Roll New Codeword" already
                // owns ⌘R, and two live handlers for the same chord leave
                // the winner up to SwiftUI's resolution order.
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(isResettingPermission)
            }
            .buttonStyle(.bordered)

            Text("After enabling in System Settings, this app detects it automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.md))
    }

    private func start() {
        guard accessibilityGranted else { return }
        controller.attemptStartLock(codeword: settings.codeword, durationMinutes: settings.durationMinutes)
    }

    /// The permission may have been revoked in System Settings since our
    /// poller decided "granted" and stopped — installEventTap would then
    /// have failed silently inside startLock. Re-check synchronously so the
    /// banner reappears and polling resumes instead of pretending we're
    /// ready when we aren't. Runs after every lock attempt via
    /// `.keebLockLockAttempted`, regardless of whether it came from this
    /// view's Start button or the ⌘S menu command.
    private func resyncAccessibilityState() {
        guard !controller.isLocked else { return }
        let nowGranted = AccessibilityPermission.isGranted
        if accessibilityGranted != nowGranted {
            accessibilityGranted = nowGranted
        }
        if !nowGranted { startPermissionPolling() }
    }
}
