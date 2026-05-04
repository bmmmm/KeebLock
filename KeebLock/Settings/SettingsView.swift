import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var suggestions: [String] = Codewords.suggestions()

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

            Section("Feedback") {
                Toggle("Sound on keystroke", isOn: $settings.soundEnabled)
            }

            Section("About") {
                Text("KeebLock swallows keystrokes via macOS Accessibility while you wipe down your keys. Type your codeword (substring match) or click \"Unlock now\" to exit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 540)
    }
}
