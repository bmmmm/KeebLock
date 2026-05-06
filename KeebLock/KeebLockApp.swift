import SwiftUI

/// Quits the app when the last (and only) window closes — matches the
/// "close = quit" semantic the user expects for a single-window utility,
/// instead of the macOS default where the app keeps running invisibly.
final class KeebLockAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Forces the hosting NSWindow's content area to a given size whenever
/// the size prop changes. We need this because `scaleEffect` is render-only
/// — chained `.frame(...)` after it doesn't propagate the scaled size to
/// SwiftUI's content-size machinery. Worse, the inner layout `.frame(...)`
/// becomes a *floor* in SwiftUI's eyes, so a `setContentSize` to anything
/// smaller (e.g. zoom < 1.0) gets clamped right back up by AppKit on the
/// next layout pass.
///
/// Locking `contentMinSize` AND `contentMaxSize` to the target size pins
/// the window to exactly that size — both growing past it (SwiftUI floor)
/// and shrinking below it (manual resize) are blocked. The `setContentSize`
/// call applies the change immediately rather than waiting for the next
/// layout cycle.
struct WindowSizer: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // Defer one runloop tick so the view is attached to a window.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.contentMinSize = size
            window.contentMaxSize = size
            if window.contentLayoutRect.size != size {
                window.setContentSize(size)
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
            // App-wide visual zoom — scaleEffect renders the layout 1.3x,
            // and a WindowSizer drives the AppKit window's contentSize to
            // match. Why not just chain a .frame() after scaleEffect:
            // scaleEffect is render-only, the post-scale frame doesn't
            // reach `windowResizability(.contentSize)` reliably — the
            // window stayed at the unscaled inner layout width even at
            // 130 %, clipping rendered content. setContentSize on the
            // NSWindow IS reliable.
            //
            //   inner .frame(560 × 800): the "natural" layout container.
            //
            //   .scaleEffect(zoom, anchor: .center): visual zoom around
            //   the centre — content scales toward / from the midpoint.
            //   .topLeading would jam content into the upper-left corner
            //   when zoomed out; .center distributes any leftover space
            //   symmetrically.
            //
            //   outer .frame(560*zoom × 800*zoom, alignment: .center):
            //   visible window region tracks the scaled content exactly.
            //   No "minimum natural size" floor — at <100 % the window
            //   shrinks with the content, at >100 % it grows. Visual
            //   breathing room comes from the content's own .padding,
            //   which scales together with everything else.
            //
            //   .background(WindowSizer(...)): pushes the same target
            //   size into NSWindow.contentMin/MaxSize/setContentSize so
            //   the AppKit window matches exactly.
            let zoom = settings.appZoom
            let windowW = 560 * zoom
            let windowH = 800 * zoom
            ContentView()
                .environmentObject(settings)
                .environment(lockController)
                .frame(width: 560, height: 800)
                .scaleEffect(zoom, anchor: .center)
                .frame(width: windowW, height: windowH, alignment: .center)
                .background(WindowSizer(size: CGSize(
                    width: windowW,
                    height: windowH
                )))
                .tint(settings.appTheme.color)
        }
        // .automatic instead of .contentSize: WindowSizer drives the
        // exact size via NSWindow.contentMinSize/MaxSize; .contentSize
        // would fight that with SwiftUI's own content-driven sizing pass.
        .windowResizability(.automatic)
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
