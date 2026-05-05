import Combine
import SwiftUI

// Simple sortable table — no rendered keyboard, layout-agnostic. Shows raw key
// labels (looked up by keycode) with their counts and a relative bar.
struct HeatmapView: View {
    @ObservedObject var controller: LockController
    @Environment(\.dismiss) private var dismiss

    private var rows: [KeyStat] {
        controller.keyCounts
            .map { KeyStat(keycode: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    private var maxCount: Int { rows.first?.count ?? 1 }
    private var totalPresses: Int { controller.keyCounts.values.reduce(0, +) }
    private var distinctKeys: Int { controller.keyCounts.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if rows.isEmpty {
                empty
            } else {
                table
            }
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 480)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Keystroke Heatmap")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var table: some View {
        Table(rows) {
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
                    .frame(height: 14)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(role: .destructive) {
                controller.resetKeyCounts()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .disabled(rows.isEmpty)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
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
        // green (low) → orange (mid) → red (high)
        let r = min(1, fraction * 1.6)
        let g = min(1, max(0, 1 - fraction * 0.8))
        return Color(red: r, green: g, blue: 0.25)
    }
}

// Best-effort keycode → human label. Letters/digits printed via UCKeyTranslate fall
// back to Apple's US ANSI default if the user's layout lookup isn't available; named
// constants for non-printables.
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
