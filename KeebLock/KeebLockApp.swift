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
    }
}
