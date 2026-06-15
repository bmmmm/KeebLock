import AppKit

/// Custom About panel — uses macOS's stock NSAboutPanel but feeds it a rich
/// credits string with clickable links for license, image attribution, the
/// project repos, and Ko-fi support. App name + version are pulled from the
/// bundle automatically (CFBundleName / CFBundleShortVersionString /
/// CFBundleVersion), so the auto-versioning build phase keeps these in sync.
enum AboutPanel {

    /// Local-event monitor installed once per show() so a click anywhere in
    /// the about panel closes it. Stored at file scope so the close path
    /// can detach itself without a separate state machine.
    private static var clickMonitor: Any?
    private static var closeObserver: NSObjectProtocol?
    private static weak var trackedPanel: NSWindow?

    /// Single teardown path for both the click monitor and the close
    /// observer. Idempotent. Driven by either a click-to-close or the
    /// panel's willCloseNotification, so dismissing the panel by any means
    /// (⌘W, app deactivation, stoplight button) detaches the monitor —
    /// previously it leaked until the next left-click anywhere.
    private static func teardown() {
        if let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
        if let o = closeObserver {
            NotificationCenter.default.removeObserver(o)
            closeObserver = nil
        }
        trackedPanel = nil
    }

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        // Copyright line comes from Info.plist's NSHumanReadableCopyright,
        // which is wired up by the build settings — keeps a single source of
        // truth and avoids the undocumented .copyright option key.
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
        ])
        // The panel doesn't appear in NSApp.windows until after the current
        // run-loop turn — defer the lookup so we can capture a reference.
        DispatchQueue.main.async { installClickToClose() }
    }

    /// Find the just-shown about panel and arm a local monitor that
    /// closes it on the next mouseDown. Returning the event from the
    /// monitor (rather than nil) keeps clicks on credit-text links live —
    /// the link opens its URL, then the panel dismisses on the next
    /// run-loop tick. A click on the title bar's stoplight buttons closes
    /// via AppKit's own handler before our monitor fires; either way the
    /// monitor self-cleans.
    private static func installClickToClose() {
        // Stock about panel is a private NSPanel subclass — match by
        // class name so we don't snag any other window the app has open.
        guard let panel = NSApp.windows.first(where: { window in
            String(describing: type(of: window)).lowercased().contains("about")
        }) else { return }

        teardown()
        trackedPanel = panel

        // Detach if the panel closes by any path other than our click — the
        // willClose observer is the single teardown trigger in those cases.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { _ in teardown() }

        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let target = trackedPanel, event.window === target else { return event }
            // close() fires willCloseNotification → teardown() detaches us.
            DispatchQueue.main.async { target.close() }
            return event
        }
    }

    // MARK: - Credits

    private static var credits: NSAttributedString {
        let s = NSMutableAttributedString()

        let body      = NSFont.systemFont(ofSize: 11)
        let bodyBold  = NSFont.boldSystemFont(ofSize: 11)
        let primary   = NSColor.labelColor
        let secondary = NSColor.secondaryLabelColor
        let linkColor = NSColor.linkColor

        func text(_ str: String, color: NSColor = primary, font: NSFont = body) {
            s.append(NSAttributedString(string: str, attributes: [
                .font: font,
                .foregroundColor: color,
            ]))
        }

        func link(_ str: String, url: String) {
            s.append(NSAttributedString(string: str, attributes: [
                .font: body,
                .foregroundColor: linkColor,
                .link: URL(string: url) ?? URL(fileURLWithPath: "/"),
            ]))
        }

        func newline() { text("\n") }

        // Tagline
        text("Lock the keyboard. Clean it.\nType the codeword to unlock.\n",
             color: secondary, font: bodyBold)
        newline()

        // Source code license
        text("Source code is licensed under ", color: secondary)
        link("Apache-2.0", url: "https://www.apache.org/licenses/LICENSE-2.0")
        text(".", color: secondary)
        newline()

        // Image attribution
        text("Codeword images are sourced from Wikimedia Commons — each image keeps its original license. ",
             color: secondary)
        link("Per-image attribution", url: "https://github.com/bmmmm/KeebLock/blob/main/KeebLock/Resources/CodewordImages/CREDITS.md")
        text(".", color: secondary)
        newline()
        newline()

        // Project links — only the public GitHub mirror in shipped builds.
        // The Forgejo origin lives on a LAN-only host (git.home), which
        // resolves for the maintainer but DNS-fails for everyone else.
        text("Project: ", color: secondary)
        link("github.com/bmmmm/KeebLock", url: "https://github.com/bmmmm/KeebLock")
        newline()

        // Wikipedia data source
        text("Codeword data fetched from ", color: secondary)
        link("Wikipedia", url: "https://en.wikipedia.org/")
        text(" via the public REST API. No telemetry leaves your Mac.",
             color: secondary)
        newline()
        newline()

        // Support
        text("If KeebLock saved you from a bowl of crumbs: ", color: secondary)
        link("buy me a coffee on Ko-fi", url: "https://ko-fi.com/bmabma?utm_source=keeblock&utm_medium=about_panel")
        text(".", color: secondary)

        return s
    }
}
