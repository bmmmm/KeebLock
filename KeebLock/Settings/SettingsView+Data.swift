import AppKit
import Foundation
import SwiftUI

extension SettingsView {
    var cleanmapSection: some View {
        tintedSection("Cleanmap") {
            // The count stores are @ObservationIgnored — subscribe to the
            // reset pulse so a Reset inside the sheet refreshes this row too.
            let _ = controller.statsResetPulse
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accumulated wipe data")
                        .font(fBody)
                    Text("\(controller.overallKeyCounts.values.reduce(0, +)) overall · \(controller.sessionKeyCounts.values.reduce(0, +)) this session · \(controller.overallKeyCounts.count) keys")
                        .font(fCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showCleanmap = true
                } label: {
                    Label("View", systemImage: "chart.bar.fill")
                }
                .buttonStyle(.bordered)
                .disabled(controller.overallKeyCounts.isEmpty && controller.sessionKeyCounts.isEmpty)
            }
        }
    }

    var trailmapSection: some View {
        tintedSection("Trailmap") {
            // Same rationale as cleanmapSection: sessionTrail is
            // @ObservationIgnored, the pulse carries the reset signal.
            let _ = controller.statsResetPulse
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wipe trail visualisation")
                        .font(fBody)
                    Text("\(controller.sessionTrail.count) wipes this session")
                        .font(fCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showTrailmap = true
                } label: {
                    Label("View", systemImage: "scribble.variable")
                }
                .buttonStyle(.bordered)
                .disabled(controller.sessionTrail.isEmpty)
            }
        }
    }

    var historySection: some View {
        tintedSection("Cleaning history") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Past sessions")
                        .font(fBody)
                    if let last = history.lastWipe {
                        Text("Last wipe: \(formatDate(last))")
                            .font(fCaption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No sessions recorded yet")
                            .font(fCaption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    showHistory = true
                } label: {
                    Label("View", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)
                .disabled(history.sessions.isEmpty)
            }
        }
    }

    var aboutSection: some View {
        tintedSection("About") {
            // Header line: icon + name/version + GitHub-link inline.
            HStack(spacing: 12) {
                Image(systemName: "keyboard.fill")
                    .font(.system(size: 22 * uiScale))
                    .foregroundStyle(settings.appTheme.color)
                VStack(alignment: .leading, spacing: 0) {
                    Text("KeebLock").font(scaled(20, .semibold))
                    Text("Version \(appVersion)")
                        .font(fCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link(destination: URL(string: "https://github.com/bmmmm") ?? URL(fileURLWithPath: "/")) {
                    Label("@bmmmm", systemImage: "person.circle")
                        .font(fCallout)
                }
                .buttonStyle(.borderless)
            }

            Text("Swallows keystrokes via macOS Accessibility while you wipe down your keys. Type the codeword (suffix-match) to escape — or click the unlock icon once you're half-way through.")
                .font(fCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Ko-fi support
            Link(destination: URL(string: "https://ko-fi.com/bmabma?utm_source=keeblock&utm_medium=desktop_app") ?? URL(fileURLWithPath: "/")) {
                HStack(spacing: 8) {
                    Image(systemName: "cup.and.saucer.fill")
                        .foregroundStyle(.pink)
                    Text("Support development on Ko-fi")
                        .font(scaled(16, .semibold))
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(fCaption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.pink.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.sm))
            }
            .buttonStyle(.plain)

            // Credits + uninstall folded into a disclosure so the section
            // doesn't dominate the form for the 95 % of opens that don't
            // need them.
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("Summaries & facts:")
                            .foregroundStyle(.secondary)
                        Link("Wikipedia", destination: URL(string: "https://en.wikipedia.org") ?? URL(fileURLWithPath: "/"))
                    }
                    HStack(spacing: 4) {
                        Text("Lead images:")
                            .foregroundStyle(.secondary)
                        Link("Wikimedia Commons", destination: URL(string: "https://commons.wikimedia.org") ?? URL(fileURLWithPath: "/"))
                        Text("(CC-BY-SA)")
                            .foregroundStyle(.secondary)
                    }
                    Divider().padding(.vertical, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                            Text("Uninstall — run either:")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(uninstallCommands, id: \.self) { cmd in
                            HStack(spacing: 6) {
                                Text(cmd)
                                    .font(scaled(14, mono: true))
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.xs))
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(cmd, forType: .string)
                                    copiedCommand = cmd
                                    Task { @MainActor in
                                        try? await Task.sleep(for: .milliseconds(1500))
                                        if copiedCommand == cmd { copiedCommand = nil }
                                    }
                                } label: {
                                    Image(systemName: copiedCommand == cmd ? "checkmark.circle.fill" : "doc.on.doc")
                                        .foregroundStyle(copiedCommand == cmd ? .green : .secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Copy to clipboard")
                            }
                        }
                    }
                }
                .font(fCaption)
                .padding(.top, 4)
            } label: {
                Text("Credits & uninstall")
                    .font(scaled(14, .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    var appVersion: String { Bundle.main.keeblockVersionString }

    var uninstallCommands: [String] {
        [
            "open '/Applications/KeebLock.app/Contents/Resources/'",
            "scripts/uninstall.sh",
        ]
    }

    func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
