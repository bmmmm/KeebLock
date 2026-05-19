import Carbon
import Combine
import SwiftUI

// Visual keyboard + mouse cleanmap. Tile-grid keyboard at the top (each key
// positioned at its real ANSI Mac coordinates, tinted by wipe count), mouse
// breakdown below, and the legacy sortable table at the bottom for users
// who want exact numbers per key.
struct CleanmapView: View {
    var controller: LockController
    @ObservedObject private var inputSource = InputSourceObserver.shared
    @Environment(\.dismiss) private var dismiss

    enum Scope: String, CaseIterable, Identifiable {
        case session = "Current session"
        case overall = "Overall"
        var id: String { rawValue }
    }

    @State private var scope: Scope = .session

    /// The dictionary the rest of the view reads from. Switches between
    /// per-session (cleared on each lock start) and persistent overall
    /// (accumulates across sessions, saved to UserDefaults on stopLock).
    private var keyCounts: [UInt16: Int] {
        switch scope {
        case .session: return controller.sessionKeyCounts
        case .overall: return controller.overallKeyCounts
        }
    }

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
        keyCounts
            .map { KeyStat(keycode: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    private var maxCount: Int { rows.first?.count ?? 1 }
    private var totalWipes: Int { keyCounts.values.reduce(0, +) }
    private var distinctKeys: Int { keyCounts.count }

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
    private func resolvedLabel(for key: KeyboardKey) -> String {
        if let code = key.code, let dyn = dynamicLabels[code] { return dyn }
        return key.label
    }

    /// Walk all tile keycodes once, ask UCKeyTranslate for the layout-correct
    /// label, cache. Cheap (~50 calls) and only fires on view show / layout
    /// switch — not on each wipe.
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
                Text("Cleanmap")
                    .font(.title2).fontWeight(.semibold)
                Text("\(distinctKeys) distinct keys · \(totalWipes) total wipes")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $scope) {
                ForEach(Scope.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No wipes recorded yet.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }

    private var footer: some View {
        HStack {
            Button(role: .destructive) {
                switch scope {
                case .session: controller.resetSessionCleanmap()
                case .overall: controller.resetOverallCleanmap()
                }
            } label: {
                Label("Reset \(scope.rawValue.lowercased()) cleanmap", systemImage: "arrow.counterclockwise")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(rows.isEmpty)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("w", modifiers: .command)
                .keyboardShortcut(.cancelAction)
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
                                count: key.code.map { tileCount(for: $0) } ?? 0,
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

    /// Count for a canonical layout tile: direct hits + any aliased keycode hits.
    /// Merges e.g. Stage Manager (176) into the F3 tile (99) so the grid reflects
    /// the physical key regardless of which keycode the hardware emits.
    private func tileCount(for code: UInt16) -> Int {
        let direct = keyCounts[code] ?? 0
        let aliased = KeyboardPositionMap.aliasedKeycodes(for: code)
            .reduce(0) { $0 + (keyCounts[$1] ?? 0) }
        return direct + aliased
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .tracking(2.0)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Tile + supporting views

private struct KeyTile: View {
    let key: KeyboardKey
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
        160: "Globe",
        176: "Stage", 177: "Search", 178: "Mic", 179: "Focus",
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
