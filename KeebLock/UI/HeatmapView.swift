import Carbon
import Combine
import SwiftUI

// Visual keyboard + mouse heatmap. Tile-grid keyboard at the top (each key
// positioned at its real ANSI Mac coordinates, tinted by press count), mouse
// breakdown below, and the legacy sortable table at the bottom for users
// who want exact numbers per key.
struct HeatmapView: View {
    var controller: LockController
    @ObservedObject private var inputSource = InputSourceObserver.shared
    @Environment(\.dismiss) private var dismiss

    /// Layout-translated labels per keycode. Recomputed when the active TIS
    /// source changes (e.g. user switches German ↔ U.S. via ⌃⌥Space).
    @State private var dynamicLabels: [UInt16: String] = [:]

    /// Modifier/special keycodes whose labels stay as their hard-coded
    /// glyphs. UCKeyTranslate would either return control chars or yield
    /// the same letter on every layout, so static is more useful.
    private static let staticLabelKeycodes: Set<UInt16> = [
        53,                                                        // esc
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,    // F1–F12
        51, 48, 57, 36,                                            // delete tab caps return
        56, 60,                                                    // shift
        63, 59, 62, 58, 61, 55, 54, 49,                            // fn ctrl opt cmd space
        123, 124, 125, 126,                                        // arrows
    ]

    private var rows: [KeyStat] {
        controller.keyCounts
            .map { KeyStat(keycode: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    private var maxCount: Int { rows.first?.count ?? 1 }
    private var totalPresses: Int { controller.keyCounts.values.reduce(0, +) }
    private var distinctKeys: Int { controller.keyCounts.count }

    /// Highest single mouse counter — drives heat scaling for the mouse panel
    /// independent of keyboard scale (keyboards rack up much bigger numbers).
    private var maxMouseCount: Int {
        max(controller.leftClickCount, controller.rightClickCount,
            controller.middleClickCount, controller.backClickCount,
            controller.forwardClickCount, controller.scrollCount, 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    keyboardSection
                    Divider()
                    mouseSection
                    Divider()
                    if !rows.isEmpty {
                        topKeysTable
                    } else {
                        empty
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 620)
        .onAppear { rebuildDynamicLabels() }
        .onChange(of: inputSource.sourceID) { _, _ in rebuildDynamicLabels() }
    }

    /// Per-tile label: dynamic translation when available, otherwise the
    /// hard-coded fallback (modifier glyphs, F-keys, special keys).
    private func resolvedLabel(for key: KbKey) -> String {
        if let code = key.code, let dyn = dynamicLabels[code] { return dyn }
        return key.label
    }

    /// Walk all tile keycodes once, ask UCKeyTranslate for the layout-correct
    /// label, cache. Cheap (~50 calls) and only fires on view show / layout
    /// switch — not on each keystroke.
    private func rebuildDynamicLabels() {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        var map: [UInt16: String] = [:]
        for row in KeyboardLayout.rows {
            for key in row {
                guard let code = key.code,
                      !Self.staticLabelKeycodes.contains(code) else { continue }
                if let label = KeyboardLayoutLookup.translate(keycode: code, source: src) {
                    map[code] = label
                }
            }
        }
        dynamicLabels = map
    }

    // MARK: - Header / Footer

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Heatmap")
                    .font(.title2).fontWeight(.semibold)
                Text("\(distinctKeys) distinct keys · \(totalPresses) total presses")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No keystrokes recorded yet.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }

    private var footer: some View {
        HStack {
            Button(role: .destructive) {
                controller.resetKeyCounts()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(rows.isEmpty)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Keyboard

    private var keyboardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("KEYBOARD")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(KeyboardLayout.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 4) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, key in
                            KeyTile(
                                key: key,
                                resolvedLabel: resolvedLabel(for: key),
                                count: key.code.map { controller.keyCounts[$0] ?? 0 } ?? 0,
                                maxCount: maxCount
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Mouse

    private var mouseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("MOUSE & SCROLL")
            HStack(spacing: 10) {
                mouseTile("Left",    controller.leftClickCount,    icon: "cursorarrow")
                mouseTile("Right",   controller.rightClickCount,   icon: "cursorarrow.click")
                mouseTile("Middle",  controller.middleClickCount,  icon: "circle.dotted")
                mouseTile("Back",    controller.backClickCount,    icon: "arrow.uturn.backward")
                mouseTile("Forward", controller.forwardClickCount, icon: "arrow.uturn.forward")
                mouseTile("Scroll",  controller.scrollCount,       icon: "arrow.up.arrow.down")
            }
        }
    }

    private func mouseTile(_ label: String, _ count: Int, icon: String) -> some View {
        let frac = Double(count) / Double(maxMouseCount)
        return VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(count > 0 ? .primary : .secondary)
            Text("\(count)")
                .font(.system(size: 22, weight: .heavy, design: .monospaced))
                .foregroundStyle(count > 0 ? .primary : .secondary)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity, minHeight: 88)
        .background(heatBackground(fraction: frac), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - Top keys table (legacy detail)

    private var topKeysTable: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("TOP KEYS")
            Table(rows.prefix(20).map { $0 }) {
                TableColumn("Key") { row in
                    Text(row.label)
                        .font(.system(.body, design: .monospaced))
                }
                .width(min: 80, ideal: 100)

                TableColumn("Count") { row in
                    Text("\(row.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 80)

                TableColumn("") { row in
                    HeatBar(fraction: Double(row.count) / Double(self.maxCount))
                        .frame(height: 12)
                }
            }
            .frame(minHeight: 240, maxHeight: 320)
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .tracking(2.0)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Keyboard layout data

private struct KbKey {
    let code: UInt16?       // nil = decorative spacer (no count lookup)
    let label: String
    let width: CGFloat      // width units (1.0 = standard alphanumeric key)
}

private enum KeyboardLayout {
    /// Compact ANSI Mac layout. Coordinates are eyeballed but produce a
    /// recognisable keyboard at a glance — the goal is "where do my hits
    /// cluster", not pixel-perfect Apple geometry.
    static let rows: [[KbKey]] = [
        // F-row
        [
            KbKey(code: 53,  label: "esc",  width: 1.25),
            KbKey(code: 122, label: "F1",   width: 1),
            KbKey(code: 120, label: "F2",   width: 1),
            KbKey(code: 99,  label: "F3",   width: 1),
            KbKey(code: 118, label: "F4",   width: 1),
            KbKey(code: 96,  label: "F5",   width: 1),
            KbKey(code: 97,  label: "F6",   width: 1),
            KbKey(code: 98,  label: "F7",   width: 1),
            KbKey(code: 100, label: "F8",   width: 1),
            KbKey(code: 101, label: "F9",   width: 1),
            KbKey(code: 109, label: "F10",  width: 1),
            KbKey(code: 103, label: "F11",  width: 1),
            KbKey(code: 111, label: "F12",  width: 1),
        ],
        // Number row
        [
            KbKey(code: 50,  label: "`",    width: 1),
            KbKey(code: 18,  label: "1",    width: 1),
            KbKey(code: 19,  label: "2",    width: 1),
            KbKey(code: 20,  label: "3",    width: 1),
            KbKey(code: 21,  label: "4",    width: 1),
            KbKey(code: 23,  label: "5",    width: 1),
            KbKey(code: 22,  label: "6",    width: 1),
            KbKey(code: 26,  label: "7",    width: 1),
            KbKey(code: 28,  label: "8",    width: 1),
            KbKey(code: 25,  label: "9",    width: 1),
            KbKey(code: 29,  label: "0",    width: 1),
            KbKey(code: 27,  label: "-",    width: 1),
            KbKey(code: 24,  label: "=",    width: 1),
            KbKey(code: 51,  label: "⌫",   width: 1.25),
        ],
        // QWERTY row
        [
            KbKey(code: 48,  label: "⇥",   width: 1.5),
            KbKey(code: 12,  label: "Q",    width: 1),
            KbKey(code: 13,  label: "W",    width: 1),
            KbKey(code: 14,  label: "E",    width: 1),
            KbKey(code: 15,  label: "R",    width: 1),
            KbKey(code: 17,  label: "T",    width: 1),
            KbKey(code: 16,  label: "Y",    width: 1),
            KbKey(code: 32,  label: "U",    width: 1),
            KbKey(code: 34,  label: "I",    width: 1),
            KbKey(code: 31,  label: "O",    width: 1),
            KbKey(code: 35,  label: "P",    width: 1),
            KbKey(code: 33,  label: "[",    width: 1),
            KbKey(code: 30,  label: "]",    width: 1),
            KbKey(code: 42,  label: "\\",   width: 1),
        ],
        // Home row
        [
            KbKey(code: 57,  label: "⇪",   width: 1.75),
            KbKey(code: 0,   label: "A",    width: 1),
            KbKey(code: 1,   label: "S",    width: 1),
            KbKey(code: 2,   label: "D",    width: 1),
            KbKey(code: 3,   label: "F",    width: 1),
            KbKey(code: 5,   label: "G",    width: 1),
            KbKey(code: 4,   label: "H",    width: 1),
            KbKey(code: 38,  label: "J",    width: 1),
            KbKey(code: 40,  label: "K",    width: 1),
            KbKey(code: 37,  label: "L",    width: 1),
            KbKey(code: 41,  label: ";",    width: 1),
            KbKey(code: 39,  label: "'",    width: 1),
            KbKey(code: 36,  label: "↩",   width: 1.75),
        ],
        // Shift row
        [
            KbKey(code: 56,  label: "⇧",   width: 2.25),
            KbKey(code: 6,   label: "Z",    width: 1),
            KbKey(code: 7,   label: "X",    width: 1),
            KbKey(code: 8,   label: "C",    width: 1),
            KbKey(code: 9,   label: "V",    width: 1),
            KbKey(code: 11,  label: "B",    width: 1),
            KbKey(code: 45,  label: "N",    width: 1),
            KbKey(code: 46,  label: "M",    width: 1),
            KbKey(code: 43,  label: ",",    width: 1),
            KbKey(code: 47,  label: ".",    width: 1),
            KbKey(code: 44,  label: "/",    width: 1),
            KbKey(code: 60,  label: "⇧",   width: 2),
        ],
        // Modifier row
        [
            KbKey(code: 63,  label: "fn",   width: 1),
            KbKey(code: 59,  label: "⌃",   width: 1),
            KbKey(code: 58,  label: "⌥",   width: 1),
            KbKey(code: 55,  label: "⌘",   width: 1.25),
            KbKey(code: 49,  label: "space", width: 5),
            KbKey(code: 54,  label: "⌘",   width: 1.25),
            KbKey(code: 61,  label: "⌥",   width: 1),
            KbKey(code: 123, label: "◀",   width: 1),
            KbKey(code: 126, label: "▲",   width: 1),
            KbKey(code: 125, label: "▼",   width: 1),
            KbKey(code: 124, label: "▶",   width: 1),
        ],
    ]
}

// MARK: - Tile + supporting views

private struct KeyTile: View {
    let key: KbKey
    let resolvedLabel: String
    let count: Int
    let maxCount: Int

    private static let unitSize: CGFloat = 36

    var body: some View {
        let frac = maxCount > 0 ? Double(count) / Double(maxCount) : 0
        VStack(spacing: 1) {
            Text(resolvedLabel)
                .font(.system(size: resolvedLabel.count > 2 ? 9 : 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(count > 0 ? .primary : .secondary)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.unitSize * key.width, height: Self.unitSize)
        .background(heatBackground(fraction: frac), in: RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(.secondary.opacity(count > 0 ? 0.25 : 0.12), lineWidth: 1)
        )
    }
}

/// Cool→hot heat tint with opacity proportional to use, so unused keys
/// stay visually quiet and the cluster of hot keys jumps out.
private func heatBackground(fraction: Double) -> Color {
    if fraction <= 0 { return Color.secondary.opacity(0.05) }
    // Lerp green → orange → red as fraction goes 0 → 1
    let r = min(1, 0.4 + fraction * 1.4)
    let g = max(0.2, 0.85 - fraction * 0.65)
    let b = 0.25
    let alpha = 0.18 + fraction * 0.55
    return Color(red: r, green: g, blue: b, opacity: alpha)
}

private struct KeyStat: Identifiable {
    let keycode: UInt16
    let count: Int
    var id: UInt16 { keycode }
    var label: String { KeycodeNames.label(for: keycode) }
}

private struct HeatBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.06))
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: geo.size.width * fraction)
            }
        }
    }
    private var color: Color {
        let r = min(1, fraction * 1.6)
        let g = min(1, max(0, 1 - fraction * 0.8))
        return Color(red: r, green: g, blue: 0.25)
    }
}

/// Best-effort keycode → human label for the legacy table.
enum KeycodeNames {
    static func label(for keycode: UInt16) -> String {
        if let named = specials[keycode] { return named }
        if let ch = printableChar(for: keycode) { return String(ch).uppercased() }
        return String(format: "0x%02X", keycode)
    }

    private static let specials: [UInt16: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        54: "Cmd", 55: "Cmd", 56: "Shift", 57: "Caps", 58: "Opt", 59: "Ctrl",
        60: "Shift", 61: "Opt", 62: "Ctrl", 63: "Fn",
        76: "Enter",
        96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11", 105: "F13",
        107: "F14", 109: "F10", 111: "F12",
        113: "F15", 114: "Help", 115: "Home", 116: "PgUp",
        117: "Fwd Del", 118: "F4", 119: "End", 120: "F2",
        121: "PgDn", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    private static let asciiMap: [UInt16: Character] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
        8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
        16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p",
        37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 50: "`",
    ]

    private static func printableChar(for keycode: UInt16) -> Character? {
        asciiMap[keycode]
    }
}
