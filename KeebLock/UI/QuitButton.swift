import AppKit
import SwiftUI

// SF Symbols 4+ ships "bubbles.and.sparkles" — fits the cleaning theme. Falls back
// quietly to "xmark.circle.fill" if the symbol can't resolve.
struct QuitButton: View {
    var body: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            Label("Quit", systemImage: "bubbles.and.sparkles")
        }
        .controlSize(.regular)
        .buttonStyle(.bordered)
        .help("Quit KeebLock")
    }
}
