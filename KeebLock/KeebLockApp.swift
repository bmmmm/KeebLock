import SwiftUI

@main
struct KeebLockApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var lockController = LockController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(lockController)
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
                     destination: URL(string: "https://ko-fi.com/bmabma?utm_source=keeblock&utm_medium=desktop_app")!)
                Link("Project on GitHub",
                     destination: URL(string: "https://github.com/bmmmm")!)
            }
        }
    }
}
