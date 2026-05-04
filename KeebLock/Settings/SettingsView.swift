import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var suggestions: [String] = Codewords.suggestions()
    @State private var snapshotMessage: String?

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

            Section("Pixel size") {
                HStack(spacing: 12) {
                    Image(systemName: "square.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(settings.pixelFineness) },
                            set: { settings.pixelFineness = Int($0.rounded()) }
                        ),
                        in: 1...10,
                        step: 1
                    )
                    Image(systemName: "square.grid.4x3.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("\(settings.pixelFineness)")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 22, alignment: .trailing)
                }
                Text("Lower = bigger pixel blocks, faster stages. Higher = smaller pixels, longer stages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Debug") {
                Toggle("Enable debug logging", isOn: $settings.debugLoggingEnabled)

                HStack(spacing: 10) {
                    Button("Save diagnostic snapshot") {
                        let snap = DebugLog.snapshot()
                        DebugLog.writeForced(snap)
                        snapshotMessage = "Snapshot appended."
                    }
                    .buttonStyle(.bordered)

                    Button("Reveal log in Finder") {
                        DebugLog.revealLogInFinder()
                    }
                    .buttonStyle(.bordered)
                }

                if let snapshotMessage {
                    Text(snapshotMessage)
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                Text("Log path: ~/Library/Logs/KeebLock/keeblock.log\nWith logging on, lock lifecycle, screen activation and teardown events are recorded. Snapshot captures one full system dump regardless of toggle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("About") {
                Text("KeebLock swallows keystrokes via macOS Accessibility while you wipe down your keys. Type your codeword (substring match) or click \"Unlock now\" to exit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 620)
    }
}
