import SwiftUI

@main
struct KeebLockApp: App {
    @StateObject private var settings = AppSettings.shared
    // LockController is now @Observable (Swift Observation), so @State holds
    // the singleton and .environment(_:) propagates it for child reads via
    // @Environment(LockController.self). AppSettings stays ObservableObject
    // for now, hence the mixed environmentObject + environment below.
    @State private var lockController = LockController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environment(lockController)
                .frame(minWidth: 520, minHeight: 640)
        }
        .windowResizability(.contentSize)
        .commands {
            // Application menu (replaces the default "About" item)
            CommandGroup(replacing: .appInfo) {
                Button("About KeebLock") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }

            // ⌘, opens the Settings tab inside the launcher window. We
            // post a notification because Scene-level commands can't directly
            // mutate ContentView state.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .keebLockOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // Lock-related actions in their own top-level menu
            CommandMenu("Lock") {
                Button("Start Lock") {
                    lockController.startLock(
                        codeword: settings.codeword,
                        durationMinutes: settings.durationMinutes
                    )
                }
                .keyboardShortcut("l", modifiers: [.command])
                .disabled(lockController.isLocked)

                Button("Stop Lock") {
                    lockController.stopLock()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!lockController.isLocked)

                Divider()

                Button("Roll New Codeword") {
                    settings.codeword = Codewords.random()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }

            // Help
            CommandGroup(replacing: .help) {
                Button("Open Log Folder") {
                    DebugLog.revealLogInFinder()
                }
                Divider()
                Link("Support on Ko-fi",
                     destination: URL(string: "https://ko-fi.com/bmabma?utm_source=keeblock&utm_medium=desktop_app") ?? URL(fileURLWithPath: "/"))
                Link("Project on GitHub",
                     destination: URL(string: "https://github.com/bmmmm") ?? URL(fileURLWithPath: "/"))
            }
        }
    }
}
