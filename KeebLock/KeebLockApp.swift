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
/// makes AppKit constrain live corner-drags to the ratio.
///
/// It also owns the window size for the ⌘+/⌘−/⌘0 zoom: `zoom` maps to a
/// content size of `ratio * zoom`. A coordinator remembers the last applied
/// zoom and only calls `setContentSize` when `zoom` actually changes — so a
/// manual corner-drag (which leaves `zoom` untouched) is never fought. On
/// every pass it still nudges the current size back onto the exact ratio,
/// covering the initial layout at launch.
struct WindowAspectLock: NSViewRepresentable {
    let ratio: CGSize
    let minSize: CGSize
    let zoom: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastZoom: Double?
    }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.contentAspectRatio = ratio
            window.contentMinSize = minSize

            if context.coordinator.lastZoom != zoom {
                context.coordinator.lastZoom = zoom
                window.setContentSize(CGSize(width: ratio.width * zoom,
                                             height: ratio.height * zoom))
                return
            }

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
                        minSize: CGSize(width: 460, height: 460 * UIScale.referenceHeight / UIScale.referenceWidth),
                        zoom: settings.appZoom
                    ))
            }
            .frame(
                minWidth: 460,
                idealWidth: UIScale.referenceWidth,
                minHeight: 460 * UIScale.referenceHeight / UIScale.referenceWidth,
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
                    lockController.startLock(
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

            // View — app-zoom shortcuts. ⌘+ / ⌘− step the visual zoom by
            // 10 %, ⌘0 resets to 100 %. Affects launcher AND settings.
            CommandGroup(after: .toolbar) {
                Button("Zoom In") {
                    let next = (settings.appZoom * 100 + 10).rounded() / 100
                    settings.appZoom = min(1.60, next)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out") {
                    let next = (settings.appZoom * 100 - 10).rounded() / 100
                    settings.appZoom = max(0.80, next)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    settings.appZoom = 1.0
                }
                .keyboardShortcut("0", modifiers: .command)
            }

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
