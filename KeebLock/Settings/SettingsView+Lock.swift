import SwiftUI

extension SettingsView {
    var codewordSection: some View {
        tintedSection("Codeword") {
            // Animated display/edit card
            ZStack {
                if codewordEditing {
                    TextField("codeword", text: Binding(
                        get: { settings.codeword },
                        set: {
                            let cleaned = sanitizeCodewordInput($0)
                            // Only write back on an actual change so a rejected
                            // character (filtered to a no-op) doesn't churn the
                            // didSet / UserDefaults write on every keystroke.
                            if cleaned != settings.codeword { settings.codeword = cleaned }
                        }
                    ))
                        .font(.system(size: 22 * uiScale, weight: .semibold, design: .monospaced))
                        .tracking(2 * uiScale)
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.plain)
                        .focused($codewordFocused)
                        .onSubmit { commitCodeword() }
                        .onChange(of: codewordFocused) { _, focused in
                            if !focused { commitCodeword() }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.md)
                                .fill(settings.appTheme.color.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: Radius.md)
                                        .strokeBorder(settings.appTheme.color, lineWidth: 1.5)
                                )
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    Button {
                        codewordBeforeEdit = settings.codeword
                        withAnimation(.spring(response: 0.3)) { codewordEditing = true }
                        codewordFocused = true
                    } label: {
                        HStack(spacing: 12) {
                            Text(settings.codeword.uppercased())
                                .font(.system(size: 22 * uiScale, weight: .semibold, design: .monospaced))
                                .tracking(2 * uiScale)
                                .foregroundStyle(.primary)
                            Image(systemName: "pencil")
                                .font(fCaption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.md)
                                .fill(Color.primary.opacity(0.05))
                                .overlay(
                                    RoundedRectangle(cornerRadius: Radius.md)
                                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: codewordEditing)

            if codewordEditing {
                Text("Letters and numbers only")
                    .font(fCaption2)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            HStack {
                Text("Suggestions — geology")
                    .font(fCaption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.35)) {
                        suggestions = Codewords.suggestions()
                    }
                } label: {
                    Label("Roll new", systemImage: "arrow.triangle.2.circlepath")
                        .font(scaled(14, .medium))
                }
                .buttonStyle(.borderless)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 100), spacing: 6)],
                spacing: 6
            ) {
                ForEach(suggestions, id: \.self) { word in
                    Button {
                        settings.codeword = word
                        withAnimation(.spring(response: 0.3)) { codewordEditing = false }
                    } label: {
                        Text(word)
                            .font(scaled(16, mono: true))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                settings.codeword == word
                                ? RoundedRectangle(cornerRadius: Radius.sm).fill(settings.appTheme.color.opacity(0.15))
                                : RoundedRectangle(cornerRadius: Radius.sm).fill(Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.sm)
                                    .strokeBorder(
                                        settings.codeword == word ? settings.appTheme.color.opacity(0.5) : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                            .foregroundStyle(settings.codeword == word ? settings.appTheme.color : .primary)
                    }
                    .buttonStyle(.plain)
                    .animation(.spring(response: 0.25), value: settings.codeword)
                }
            }
        }
    }

    /// Strip anything the keystroke matcher can't receive — it is only ever fed
    /// ASCII letters and digits (non-ASCII input is remapped to its US-layout
    /// ASCII key) — so a stored codeword can never contain a character that makes
    /// it impossible to type during a lock. Case is preserved; matching is
    /// case-insensitive.
    func sanitizeCodewordInput(_ raw: String) -> String {
        String(raw.filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    /// End codeword editing (Return or focus loss). An empty field would arm an
    /// unmatchable lock, so restore the value the user started editing from rather
    /// than persist "" — clearing and bailing out reads as "cancel", not "surprise
    /// me with a random word". Fall back to a fresh suggestion only if the pre-edit
    /// value was itself empty (shouldn't happen — the lock can't arm empty).
    func commitCodeword() {
        if settings.codeword.isEmpty {
            settings.codeword = codewordBeforeEdit.isEmpty ? Codewords.random() : codewordBeforeEdit
        }
        withAnimation(.spring(response: 0.3)) { codewordEditing = false }
    }

    var autoUnlockSection: some View {
        tintedSection("Auto-unlock") {
            Toggle("Enable automatic timeout", isOn: $settings.autoUnlockEnabled)
            if settings.autoUnlockEnabled {
                Picker("Duration", selection: $settings.durationMinutes) {
                    Text("3 minutes").tag(3)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                }
                .pickerStyle(.segmented)
            }
            Text("Off by default. Without this, the lock stays active until you type the codeword or click \"Unlock now\". Force-quit (⌘⌥Esc) is always the safety net.")
                .font(fCaption)
                .foregroundStyle(.secondary)
        }
    }
}
