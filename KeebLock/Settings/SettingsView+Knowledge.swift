import SwiftUI

extension SettingsView {
    var knowledgeSection: some View {
        tintedSection("Codeword knowledge") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Show on launcher and lock screen", isOn: $settings.showCodewordKnowledge)
                Text("Curated geology summary plus hand-picked facts per codeword. Hover the ghost icons on the launcher, or read the did-you-know snippets rotating in the lock screen.")
                    .font(fCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Tint codeword in theme color as you type it", isOn: $settings.showCodewordProgress)
                Text("Off skips a per-wipe HUD redraw — turn off if you hear sound stutter under sustained typing.")
                    .font(fCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
