import SwiftUI

// US ANSI keyboard layout data
private struct KeyDef: Identifiable {
    let label: String
    let keycode: UInt16
    let widthUnits: CGFloat  // relative to standard 1.0 key

    var id: UInt16 { keycode }
}

private let kUnit: CGFloat = 38  // standard key size in points
private let kGap: CGFloat = 4

private enum KeyboardLayout {
    // Carbon / CGKeyCode constants for US ANSI
    static let rows: [[KeyDef]] = [
        // Function row
        [
            KeyDef(label: "ESC",  keycode: 53,  widthUnits: 1.0),
            KeyDef(label: "F1",   keycode: 122, widthUnits: 1.0),
            KeyDef(label: "F2",   keycode: 120, widthUnits: 1.0),
            KeyDef(label: "F3",   keycode: 99,  widthUnits: 1.0),
            KeyDef(label: "F4",   keycode: 118, widthUnits: 1.0),
            KeyDef(label: "F5",   keycode: 96,  widthUnits: 1.0),
            KeyDef(label: "F6",   keycode: 97,  widthUnits: 1.0),
            KeyDef(label: "F7",   keycode: 98,  widthUnits: 1.0),
            KeyDef(label: "F8",   keycode: 100, widthUnits: 1.0),
            KeyDef(label: "F9",   keycode: 101, widthUnits: 1.0),
            KeyDef(label: "F10",  keycode: 109, widthUnits: 1.0),
            KeyDef(label: "F11",  keycode: 103, widthUnits: 1.0),
            KeyDef(label: "F12",  keycode: 111, widthUnits: 1.0),
        ],
        // Number row
        [
            KeyDef(label: "`",    keycode: 50,  widthUnits: 1.0),
            KeyDef(label: "1",    keycode: 18,  widthUnits: 1.0),
            KeyDef(label: "2",    keycode: 19,  widthUnits: 1.0),
            KeyDef(label: "3",    keycode: 20,  widthUnits: 1.0),
            KeyDef(label: "4",    keycode: 21,  widthUnits: 1.0),
            KeyDef(label: "5",    keycode: 23,  widthUnits: 1.0),
            KeyDef(label: "6",    keycode: 22,  widthUnits: 1.0),
            KeyDef(label: "7",    keycode: 26,  widthUnits: 1.0),
            KeyDef(label: "8",    keycode: 28,  widthUnits: 1.0),
            KeyDef(label: "9",    keycode: 25,  widthUnits: 1.0),
            KeyDef(label: "0",    keycode: 29,  widthUnits: 1.0),
            KeyDef(label: "-",    keycode: 27,  widthUnits: 1.0),
            KeyDef(label: "=",    keycode: 24,  widthUnits: 1.0),
            KeyDef(label: "DEL",  keycode: 51,  widthUnits: 1.5),
        ],
        // QWERTY row
        [
            KeyDef(label: "TAB",  keycode: 48,  widthUnits: 1.5),
            KeyDef(label: "Q",    keycode: 12,  widthUnits: 1.0),
            KeyDef(label: "W",    keycode: 13,  widthUnits: 1.0),
            KeyDef(label: "E",    keycode: 14,  widthUnits: 1.0),
            KeyDef(label: "R",    keycode: 15,  widthUnits: 1.0),
            KeyDef(label: "T",    keycode: 17,  widthUnits: 1.0),
            KeyDef(label: "Y",    keycode: 16,  widthUnits: 1.0),
            KeyDef(label: "U",    keycode: 32,  widthUnits: 1.0),
            KeyDef(label: "I",    keycode: 34,  widthUnits: 1.0),
            KeyDef(label: "O",    keycode: 31,  widthUnits: 1.0),
            KeyDef(label: "P",    keycode: 35,  widthUnits: 1.0),
            KeyDef(label: "[",    keycode: 33,  widthUnits: 1.0),
            KeyDef(label: "]",    keycode: 30,  widthUnits: 1.0),
            KeyDef(label: "\\",   keycode: 42,  widthUnits: 1.0),
        ],
        // Home row
        [
            KeyDef(label: "CAPS", keycode: 57,  widthUnits: 1.75),
            KeyDef(label: "A",    keycode: 0,   widthUnits: 1.0),
            KeyDef(label: "S",    keycode: 1,   widthUnits: 1.0),
            KeyDef(label: "D",    keycode: 2,   widthUnits: 1.0),
            KeyDef(label: "F",    keycode: 3,   widthUnits: 1.0),
            KeyDef(label: "G",    keycode: 5,   widthUnits: 1.0),
            KeyDef(label: "H",    keycode: 4,   widthUnits: 1.0),
            KeyDef(label: "J",    keycode: 38,  widthUnits: 1.0),
            KeyDef(label: "K",    keycode: 40,  widthUnits: 1.0),
            KeyDef(label: "L",    keycode: 37,  widthUnits: 1.0),
            KeyDef(label: ";",    keycode: 41,  widthUnits: 1.0),
            KeyDef(label: "'",    keycode: 39,  widthUnits: 1.0),
            KeyDef(label: "RET",  keycode: 36,  widthUnits: 1.75),
        ],
        // Shift row
        [
            KeyDef(label: "SHIFT", keycode: 56, widthUnits: 2.25),
            KeyDef(label: "Z",    keycode: 6,   widthUnits: 1.0),
            KeyDef(label: "X",    keycode: 7,   widthUnits: 1.0),
            KeyDef(label: "C",    keycode: 8,   widthUnits: 1.0),
            KeyDef(label: "V",    keycode: 9,   widthUnits: 1.0),
            KeyDef(label: "B",    keycode: 11,  widthUnits: 1.0),
            KeyDef(label: "N",    keycode: 45,  widthUnits: 1.0),
            KeyDef(label: "M",    keycode: 46,  widthUnits: 1.0),
            KeyDef(label: ",",    keycode: 43,  widthUnits: 1.0),
            KeyDef(label: ".",    keycode: 47,  widthUnits: 1.0),
            KeyDef(label: "/",    keycode: 44,  widthUnits: 1.0),
            KeyDef(label: "SHIFT", keycode: 60, widthUnits: 2.25),
        ],
        // Bottom row
        [
            KeyDef(label: "fn",   keycode: 63,  widthUnits: 1.0),
            KeyDef(label: "ctrl", keycode: 59,  widthUnits: 1.0),
            KeyDef(label: "opt",  keycode: 58,  widthUnits: 1.0),
            KeyDef(label: "cmd",  keycode: 55,  widthUnits: 1.25),
            KeyDef(label: "SPACE", keycode: 49, widthUnits: 5.75),
            KeyDef(label: "cmd",  keycode: 54,  widthUnits: 1.25),
            KeyDef(label: "opt",  keycode: 61,  widthUnits: 1.0),
            KeyDef(label: "←",    keycode: 123, widthUnits: 1.0),
            KeyDef(label: "↓",    keycode: 125, widthUnits: 1.0),
            KeyDef(label: "↑",    keycode: 126, widthUnits: 1.0),
            KeyDef(label: "→",    keycode: 124, widthUnits: 1.0),
        ],
    ]
}

struct HeatmapView: View {
    @ObservedObject var controller: LockController
    @Environment(\.dismiss) private var dismiss

    private var maxCount: Int { controller.keyCounts.values.max() ?? 1 }
    private var totalSessions: Int { controller.keystrokeCount }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            keyboardGrid
                .padding(24)
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 340)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Keystroke Heatmap")
                    .font(.title2).fontWeight(.semibold)
                Text("\(controller.keyCounts.values.reduce(0, +)) total recorded keystrokes")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            colorLegend
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var colorLegend: some View {
        HStack(spacing: 6) {
            Text("low").font(.caption2).foregroundStyle(.secondary)
            LinearGradient(
                colors: (0...10).map { heatColor(fraction: Double($0) / 10) },
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: 80, height: 10)
            .clipShape(Capsule())
            Text("high").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var keyboardGrid: some View {
        VStack(alignment: .leading, spacing: kGap) {
            ForEach(Array(KeyboardLayout.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: kGap) {
                    ForEach(row) { key in
                        keyCell(key)
                    }
                }
            }
        }
    }

    private func keyCell(_ key: KeyDef) -> some View {
        let count = controller.keyCounts[key.keycode] ?? 0
        let fraction = maxCount > 0 ? Double(count) / Double(maxCount) : 0

        return Text(key.label)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: key.widthUnits * kUnit + (key.widthUnits - 1) * kGap,
                   height: kUnit)
            .background(heatColor(fraction: fraction))
            .foregroundStyle(fraction > 0.5 ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
            .help(count > 0 ? "\(key.label): \(count) press\(count == 1 ? "" : "es")" : key.label)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    // white (0) → light orange → red (1)
    private func heatColor(fraction: Double) -> Color {
        guard fraction > 0 else {
            return Color(nsColor: .controlBackgroundColor)
        }
        let r = 1.0
        let g = 1.0 - fraction * 0.95
        let b = 1.0 - fraction
        return Color(red: r, green: g, blue: b)
    }
}
