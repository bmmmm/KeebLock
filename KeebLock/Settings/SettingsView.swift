import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: LockController
    @State private var suggestions: [String] = Codewords.suggestions()
    @State private var showResetConfirm = false

    var body: some View {
        Form {
            Section("Codeword") {
                TextField("Codeword", text: $settings.codeword)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                HStack {
                    Text("Suggestions (geology)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Roll new") {
                        suggestions = Codewords.suggestions()
                    }
                    .buttonStyle(.borderless)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 110), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(suggestions, id: \.self) { word in
                        Button(word) {
                            settings.codeword = word
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            Section("Auto-unlock") {
                Picker("Duration", selection: $settings.durationMinutes) {
                    Text("3 minutes").tag(3)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                }
                .pickerStyle(.segmented)
            }

            Section("Heatmap") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accumulated data")
                            .font(.body)
                        Text("\(controller.keyCounts.values.reduce(0, +)) keystrokes recorded across all sessions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reset stats", role: .destructive) {
                        showResetConfirm = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.keyCounts.isEmpty)
                }
            }

            Section("About") {
                Text("KeebLock swallows keystrokes via macOS Accessibility while you wipe down your keys. Type your codeword (substring match) or click \"Unlock now\" to exit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 540)
        .confirmationDialog(
            "Reset all heatmap data?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { controller.resetKeyCounts() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently clears all accumulated keystroke counts.")
        }
    }
}
