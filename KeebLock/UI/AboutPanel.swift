import AppKit

/// Custom About panel — uses macOS's stock NSAboutPanel but feeds it a rich
/// credits string with clickable links for license, image attribution, the
/// project repos, and Ko-fi support. App name + version are pulled from the
/// bundle automatically (CFBundleName / CFBundleShortVersionString /
/// CFBundleVersion), so the auto-versioning build phase keeps these in sync.
enum AboutPanel {

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        // Copyright line comes from Info.plist's NSHumanReadableCopyright,
        // which is wired up by the build settings — keeps a single source of
        // truth and avoids the undocumented .copyright option key.
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
        ])
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

        // Project links
        text("Project: ", color: secondary)
        link("Forgejo", url: "https://git.home/bsz/KeebLock")
        text("  ·  ", color: secondary)
        link("GitHub", url: "https://github.com/bmmmm/KeebLock")
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
