import SwiftUI

/// Quits the app when the last (and only) window closes — matches the
/// "close = quit" semantic the user expects for a single-window utility,
/// instead of the macOS default where the app keeps running invisibly.
final class KeebLockAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // In perf-test mode the WindowGroup spawns and is immediately
        // closed by applicationDidFinishLaunching below. We DO NOT want
        // that close to terminate the app — the runner needs to keep the
        // process alive long enough to install the lock and run the test.
        // The runner calls NSApp.terminate explicitly on completion.
        #if DEBUG
        if PerfTestArgs.fromCommandLine() != nil { return false }
        #endif
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        guard let args = PerfTestArgs.fromCommandLine() else { return }
        // Close any window the WindowGroup auto-spawned so the test runs
        // headless. The runner shows the lock window on top of the
        // (now-closed) launcher via LockController.startLock anyway.
        for window in NSApplication.shared.windows {
            window.close()
        }
        Task { @MainActor in
            await PerfTestRunner.run(args: args)
        }
        #endif
    }
}

/// Pins the launcher window to a fixed width:height proportion so the
/// auto-fit typography keeps a constant aspect — resizing scales the whole
/// launcher up/down without ever needing to scroll. `contentAspectRatio`
/// makes AppKit constrain live corner-drags to the ratio; `contentMinSize`
/// is the floor below which the window can't be dragged, so the launcher
/// never clips and the text never collapses to unreadable. The only way to
/// resize is dragging the window edge — there is no separate zoom control.
struct WindowAspectLock: NSViewRepresentable {
    let ratio: CGSize
    let minSize: CGSize

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.contentAspectRatio = ratio
            window.contentMinSize = minSize

            // Keep the current (possibly user-dragged) size exactly on-ratio.
            let size = window.contentLayoutRect.size
            let targetH = size.width * ratio.height / ratio.width
            if abs(targetH - size.height) > 0.5 {
                window.setContentSize(CGSize(width: size.width, height: targetH))
            }
        }
    }
}

@main
struct KeebLockApp: App {
    @NSApplicationDelegateAdaptor(KeebLockAppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings.shared
    // LockController is now @Observable (Swift Observation), so @State holds
    // the singleton and .environment(_:) propagates it for child reads via
    // @Environment(LockController.self). AppSettings stays ObservableObject
    // for now, hence the mixed environmentObject + environment below.
    @State private var lockController = LockController.shared

    var body: some Scene {
        WindowGroup {
            // Aspect-locked, auto-fitting window. A GeometryReader reads the
            // live content size and turns it into a continuous `uiScale` via
            // `UIScale.fit`, which sizes the launcher to fill BOTH dimensions
            // without overflowing — so the launcher never scrolls, it just
            // scales. The window is pinned to the launcher's aspect ratio
            // (WindowAspectLock) so the proportion stays constant as the user
            // resizes. All type is re-rendered at true point sizes (no
            // scaleEffect magnification) so it stays sharp at any size. The
            // Settings form, which is taller, scrolls within the same window.
            GeometryReader { proxy in
                let scale = UIScale.fit(in: proxy.size)
                ContentView()
                    .environmentObject(settings)
                    .environment(lockController)
                    .environment(\.uiScale, scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tint(settings.appTheme.color)
                    .background(WindowAspectLock(
                        ratio: UIScale.aspectRatio,
                        minSize: UIScale.minContentSize
                    ))
            }
            .frame(
                minWidth: UIScale.minContentSize.width,
                idealWidth: UIScale.referenceWidth,
                minHeight: UIScale.minContentSize.height,
                idealHeight: UIScale.referenceHeight
            )
        }
        // .contentMinSize: the window can't be dragged below the content's
        // minimum (so text never clips at the floor); WindowAspectLock keeps
        // every larger size on the fixed proportion.
        .windowResizability(.contentMinSize)
        .commands {
            // Application menu (replaces the default "About" item)
            CommandGroup(replacing: .appInfo) {
                Button("About KeebLock") {
                    AboutPanel.show()
                }
            }

            // App menu (under "KeebLock"): Settings + the Cleaning verbs
            // live here so the menubar stays slim — no separate Cleaning /
            // Lock submenu. Start has ⌘S; Stop is in the menu but without
            // a shortcut (an accidental ⌘⇧S during a session was easy to
            // hit and would defeat the whole point of the app). Roll
            // codeword keeps ⌘R because it's harmless.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .keebLockOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)

                Divider()

                Button("Start Cleaning") {
                    // Routed through attemptStartLock (not startLock directly) so
                    // this path re-syncs the launcher's AX banner exactly like the
                    // Start button does — startLock itself already refuses to arm
                    // the tap without permission, but without the shared helper
                    // this menu path would leave the banner stale if AX was
                    // revoked while the app stayed foregrounded.
                    lockController.attemptStartLock(
                        codeword: settings.codeword,
                        durationMinutes: settings.durationMinutes
                    )
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(lockController.isLocked)

                // Stop Cleaning intentionally absent: the only way out of
                // a session is the codeword (or ⌘⌥Esc force-quit). Putting
                // a one-click stop in the menu defeats the discipline the
                // app exists to enforce.

                Button("Roll New Codeword") {
                    settings.codeword = Codewords.random()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }

            // Strip File-menu defaults: WindowGroup auto-adds "New Window"
            // (⌘N), which a single-window utility doesn't need. Replacing
            // .newItem with an empty group removes it cleanly.
            CommandGroup(replacing: .newItem) {}

            // Help — repo first (issues + source), then diagnostics, then
            // Ko-fi. Ordered by what someone reaching for Help most likely
            // needs: file a bug → check log → support.
            CommandGroup(replacing: .help) {
                Link("Report an Issue",
                     destination: URL(string: "https://github.com/bmmmm/KeebLock/issues") ?? URL(fileURLWithPath: "/"))
                Link("Project Repository",
                     destination: URL(string: "https://github.com/bmmmm/KeebLock") ?? URL(fileURLWithPath: "/"))
                Divider()
                Button("Open Log Folder") {
                    DebugLog.revealLogInFinder()
                }
                Divider()
                Link("Support on Ko-fi",
                     destination: URL(string: "https://ko-fi.com/bmabma?utm_source=keeblock&utm_medium=desktop_app") ?? URL(fileURLWithPath: "/"))
            }
        }
    }
}
