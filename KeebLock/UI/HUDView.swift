import AppKit
import SwiftUI

struct HUDView: View {
    /// LockController is @Observable; SwiftUI tracks the specific properties
    /// the body reads automatically — no @ObservedObject wrapper needed,
    /// and unrelated mutations (e.g. heatmap dictionary writes that no view
    /// in this hierarchy reads) no longer invalidate this view.
    var controller: LockController
    @ObservedObject var renderer: WipeRenderer
    @ObservedObject var settings: AppSettings = .shared

    var body: some View {
        // Spacing trimmed (22 → 16), title & codeword shrunk so the whole
        // column fits on a 13" MBP (982 pt usable) without clipping the
        // unlock button below the bottom margin.
        //
        // body() here only reads `controller.currentCodeword` (via the
        // CodewordDisplayView parameter), which changes once per session
        // start. Stats, breakdown cards, and the knowledge footer are
        // separate subviews that hold their own observation scopes — so
        // a typed character invalidates only the subview whose counter
        // moved, not this whole VStack.
        VStack(spacing: 16) {
            Text("Cleaning Mode")
                .font(.system(size: 42, weight: .bold))

            Text("Type the codeword to unlock")
                .font(.subheadline)
                .opacity(0.85)

            HStack(alignment: .center, spacing: 12) {
                CodewordDisplayView(
                    codeword: controller.currentCodeword,
                    controller: controller,
                    settings: settings
                )
                CompactUnlockButton(controller: controller)
            }

            HUDStatsRow(controller: controller, renderer: renderer)
            inputBreakdown
            colorIndicators
            HUDKnowledgeFooter(controller: controller)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 12)
    }

    // MARK: - Input breakdown

    private var inputBreakdown: some View {
        // Render all three cards from the start, even when every counter is 0.
        // The previous "show only when count > 0" version made the entire HUD
        // shift downward on the very first keystroke (and again whenever a
        // new category appeared), which yanked the knowledge card out from
        // under the user's eye. Constant layout > slightly emptier first
        // second.
        //
        // Each card is its own View struct so SwiftUI Observation only
        // invalidates the card whose counters actually changed: typing
        // doesn't re-render the Mouse + Gesture cards, mousing doesn't
        // re-render Keyboard + Gesture, etc. Cuts HUDView body re-render
        // cost by ~3× on the typing hot path.
        HStack(alignment: .top, spacing: 18) {
            KeyboardBreakdownCard(controller: controller)
            MouseBreakdownCard(controller: controller)
            GestureBreakdownCard(controller: controller)
        }
        .frame(maxWidth: 980)
    }

    private var colorIndicators: some View {
        HStack(spacing: 18) {
            colorPill(label: "BG", preset: settings.backgroundColor)
            colorPill(label: "PX", preset: settings.pixelColor)
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.85))
    }

    private func colorPill(label: String, preset: ColorPreset) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            ZStack {
                if preset == .transparent {
                    // Checkerboard hint
                    Rectangle()
                        .fill(Color.white.opacity(0.25))
                        .overlay(
                            Path { p in
                                p.move(to: .init(x: 0, y: 0))
                                p.addLine(to: .init(x: 14, y: 14))
                            }
                            .stroke(Color.white.opacity(0.6), lineWidth: 1)
                        )
                } else if preset == .random {
                    LinearGradient.presetRainbow
                } else {
                    preset.swiftUIColor
                }
            }
            .frame(width: 14, height: 14)
            .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.xs)
                    .strokeBorder(.white.opacity(0.5), lineWidth: 0.5)
            )
            Text(preset.label)
                .font(.caption2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.black.opacity(0.25), in: Capsule())
    }

}

// MARK: - Stats row
//
// Lifted out of HUDView so the body() that reads keystrokeCount /
// renderer.stage / wipedFraction / isPaused / remainingSeconds
// invalidates ONLY this strip — typing no longer re-evaluates the
// breakdown cards or the knowledge footer just because a counter ticked.
private struct HUDStatsRow: View {
    var controller: LockController
    @ObservedObject var renderer: WipeRenderer
    @ObservedObject var settings: AppSettings = .shared

    var body: some View {
        // Subscribe to the throttled displayTick (10-30 Hz CADisplayLink)
        // so the row refreshes when @ObservationIgnored counters
        // (keystrokeCount etc.) move. The raw counters don't fire
        // observation tracking themselves.
        let _ = controller.displayTick
        HStack(spacing: 40) {
            HUDStat(label: "Wipes", value: "\(controller.keystrokeCount)")
            HUDStat(
                label: "Stage \(renderer.stage)",
                value: "\(Int(renderer.wipedFraction * 100))% wiped"
            )
            if settings.autoUnlockEnabled {
                HUDStat(
                    label: controller.isPaused ? "Paused" : "Auto-unlock in",
                    value: formatTime(controller.remainingSeconds)
                )
            }
        }
        .padding(.top, 4)
    }

    private func formatTime(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct HUDStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
            Text(label)
                .font(.caption)
                .opacity(0.75)
        }
    }
}

// MARK: - Knowledge footer
//
// Owns its own cachedEntry/cachedImage @State and the factRotationTick
// read. Lifted out of HUDView so the rotation tick (every 30 keystrokes)
// invalidates only this card, not the whole HUD column.
private struct HUDKnowledgeFooter: View {
    var controller: LockController
    @ObservedObject var settings: AppSettings = .shared

    @State private var cachedEntry: CodewordKnowledge?
    @State private var cachedImage: NSImage?

    // Card width and the body text's reserved line count are intentionally
    // hard-coded so a fact rotating from a 2-line fact to a 5-line fact (or
    // a portrait-aspect bundled image vs. a landscape one) doesn't reflow
    // the entire HUD column under the unlock button. Pick numbers that hold
    // the longest bundled fact at 16-pt body without truncation.
    private static let cardWidth: CGFloat = 540
    private static let imageHeight: CGFloat = 160
    private static let factLineCount = 6

    private var currentEntry: CodewordKnowledge {
        cachedEntry ?? CodewordKnowledgeBase.entry(for: controller.currentCodeword)
    }

    /// Prefer the hand-curated "Did you know?" snippets — they are short
    /// and pace well on the HUD card — and fall back to the long-form
    /// `facts` paragraphs when the bundle entry doesn't carry DYK output
    /// (older corpora, stub fallback).
    private var displayFacts: [String] {
        let dyk = currentEntry.didYouKnow
        return !dyk.isEmpty ? dyk : currentEntry.facts
    }

    /// Modulo the controller's session-wide rotation tick by the current
    /// fact count. Single source of truth lives in LockController so all
    /// monitors show the same fact in lock-step.
    private var factIndex: Int {
        let count = displayFacts.count
        return count > 0 ? controller.factRotationTick % count : 0
    }

    var body: some View {
        if settings.showCodewordKnowledge {
            VStack(alignment: .leading, spacing: 0) {
                knowledgeImage
                VStack(alignment: .leading, spacing: 12) {
                    Text(currentEntry.title)
                        .font(.system(size: 24, weight: .heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if !displayFacts.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionEyebrow("DID YOU KNOW?")
                            Text(displayFacts[factIndex])
                                .font(.body)
                                .opacity(0.92)
                                .multilineTextAlignment(.leading)
                                // reservesSpace keeps the card's vertical
                                // size stable across fact rotations; without
                                // it a 1-line fact next to a 5-line fact
                                // would jolt the whole HUD column.
                                .lineLimit(Self.factLineCount, reservesSpace: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(factIndex)
                                .transition(.opacity)
                        }
                    }
                }
                .padding(20)
            }
            // Fixed width — not maxWidth — so a smaller bundled image (or no
            // image at all) doesn't pull the card narrower than its sibling
            // sections.
            .frame(width: Self.cardWidth, alignment: .leading)
            .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: Radius.md))
            .onAppear { refreshEntry(for: controller.currentCodeword) }
            .onChange(of: controller.currentCodeword) { _, new in
                refreshEntry(for: new)
            }
        }
    }

    @ViewBuilder
    private var knowledgeImage: some View {
        let topShape = UnevenRoundedRectangle(
            topLeadingRadius: 14,
            topTrailingRadius: 14
        )
        if let image = cachedImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                // Fixed (not max-) frame so the image area is the same height
                // for every codeword. With max-frames a portrait JPG would
                // shrink the visible band and the title below would jump up.
                .frame(width: Self.cardWidth, height: Self.imageHeight)
                .clipped()
                .clipShape(topShape)
        } else {
            // Reserve the same slab so the absence of a bundled image doesn't
            // make the whole card collapse upward.
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: Self.cardWidth, height: Self.imageHeight)
                .clipShape(topShape)
        }
    }

    private func refreshEntry(for codeword: String) {
        let entry = CodewordKnowledgeBase.entry(for: codeword)
        cachedEntry = entry
        cachedImage = entry.loadImage()
    }
}

// MARK: - Codeword display

/// Lifts the per-character green-tint render out of HUDView's body so a
/// match-progress bump only invalidates this small subview, not the entire
/// HUD. When `settings.showCodewordProgress` is off, `codewordMatchProgress`
/// is never read here — Observation tracks reads at body-evaluation time,
/// so toggling it off severs the dependency entirely and a typing burst
/// causes zero HUD redraws beyond the keystroke counter.
private struct CodewordDisplayView: View {
    let codeword: String
    var controller: LockController
    @ObservedObject var settings: AppSettings

    var body: some View {
        let chars = Array(codeword.uppercased())
        let total = max(1, chars.count)
        // Guard read of `codewordMatchProgress` behind the toggle. With
        // showCodewordProgress=false the property is never accessed during
        // body evaluation, so SwiftUI Observation doesn't subscribe — match
        // updates publish freely without invalidating this view.
        let progress = settings.showCodewordProgress ? controller.codewordMatchProgress : 0
        return HStack(spacing: 6) {
            ForEach(Array(chars.enumerated()), id: \.offset) { i, c in
                Text(String(c))
                    .foregroundStyle(charTint(index: i, progress: progress, total: total))
            }
        }
        .font(.system(size: 30, weight: .heavy, design: .monospaced))
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }

    /// White until matched, then fade into the active app theme so the
    /// progress visual ties back to the same accent the user picked in
    /// settings. Earlier letters lerp from white toward the theme color
    /// so the leading typed character stays readable on the dark HUD
    /// while the trailing one sits at full saturation.
    private func charTint(index i: Int, progress: Int, total: Int) -> Color {
        guard i < progress else { return .white }
        let t = total > 1 ? Double(i) / Double(total - 1) : 1.0
        // Mix .white → settings.appTheme.color across the codeword.
        // 0.35 floor keeps even the first matched letter visibly tinted,
        // not just "slightly off-white".
        let mixed = Color.white.mix(with: settings.appTheme.color, by: 0.35 + 0.55 * t)
        // The HUD background is .black.opacity(~0.4) — anything below
        // ~0.65 HSB brightness reads as dark-on-dark. Coffee and Sleepy
        // accents in light mode otherwise turn the trailing character
        // into brown-on-black. Lift toward white only when needed; bright
        // themes (Day, Sakura, Bath) pass through untouched.
        return Self.liftToMinBrightness(mixed, floor: 0.65)
    }

    /// Lerp `color` toward white until its HSB brightness reaches `floor`.
    /// No-op when the color is already bright enough.
    private static func liftToMinBrightness(_ color: Color, floor: Double) -> Color {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .white
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        nsColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        guard Double(b) < floor else { return color }
        let lift = (floor - Double(b)) / max(0.001, 1.0 - Double(b))
        return color.mix(with: .white, by: lift)
    }
}

// MARK: - Unlock button

/// Compact icon-only unlock button rendered next to the codeword. Replaces
/// an earlier full-width button with a 1 Hz pulse animation that ran a
/// `task(id:)`-driven `withAnimation` loop on the MainActor — that loop
/// + a spring-animated opacity binding fired on every codeword match
/// update, stacking animation transactions and starving the audio HALC
/// scheduler under sustained typing.
///
/// Now: pure binary visibility, single eased opacity transition, no
/// pulse, no spring, no scale animation, no `task(id:)`.
private struct CompactUnlockButton: View {
    var controller: LockController

    private var unlockClickable: Bool {
        let len = controller.currentCodeword.count
        guard len > 0 else { return false }
        return controller.codewordMatchProgress >= (len + 1) / 2
    }

    var body: some View {
        Button { controller.stopLock() } label: {
            Image(systemName: "lock.open.fill")
                .font(.system(size: 20, weight: .bold))
                .frame(width: 52, height: 52)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.92))
                        .shadow(color: Color.white.opacity(0.45), radius: 14, y: 0)
                )
                .foregroundStyle(Color.black.opacity(0.82))
        }
        .buttonStyle(.plain)
        .disabled(!unlockClickable)
        .opacity(unlockClickable ? 1.0 : 0.0)
        .allowsHitTesting(unlockClickable)
        .animation(.easeInOut(duration: 0.25), value: unlockClickable)
        .accessibilityLabel("Unlock now")
    }
}

// MARK: - Per-bucket breakdown cards
//
// Each card reads only its own counters from the @Observable controller,
// so SwiftUI Observation re-invalidates a card only when its bucket
// actually changes. Layout matches the previous unified breakdown.

private struct HUDInputCategory: Identifiable {
    /// Stable id (label) so ForEach diffs structurally instead of treating
    /// every recomputation as a fresh row — the previous `id = UUID()`
    /// regenerated on every body() and defeated SwiftUI's structural
    /// reuse for the tile views.
    var id: String { label }
    let label: String
    let count: Int
}

private struct InputBreakdownCard: View {
    let title: String
    let categories: [HUDInputCategory]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionEyebrow(title, color: .muted)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .leading), count: 3),
                alignment: .leading,
                spacing: 14
            ) {
                ForEach(categories) { cat in
                    HUDBreakdownTile(category: cat)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: Radius.lg))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HUDBreakdownTile: View {
    let category: HUDInputCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(category.count)")
                .font(.system(size: 38, weight: .heavy, design: .monospaced))
                .foregroundStyle(category.count > 0 ? .white : .white.opacity(0.22))
            Text(category.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(category.count > 0 ? 0.7 : 0.4))
        }
    }
}

private struct KeyboardBreakdownCard: View {
    var controller: LockController
    var body: some View {
        let _ = controller.displayTick
        InputBreakdownCard(title: "Keyboard", categories: [
            .init(label: "Letters",  count: controller.letterCount),
            .init(label: "Numbers",  count: controller.numberCount),
            .init(label: "Symbols",  count: controller.symbolCount),
            .init(label: "Control",  count: controller.controlKeyCount),
            .init(label: "Function", count: controller.functionKeyCount),
            .init(label: "Media",    count: controller.mediaKeyCount),
        ])
    }
}

private struct MouseBreakdownCard: View {
    var controller: LockController
    var body: some View {
        let _ = controller.displayTick
        InputBreakdownCard(title: "Mouse", categories: [
            .init(label: "Left",    count: controller.leftClickCount),
            .init(label: "Right",   count: controller.rightClickCount),
            .init(label: "Middle",  count: controller.middleClickCount),
            .init(label: "Back",    count: controller.backClickCount),
            .init(label: "Forward", count: controller.forwardClickCount),
            .init(label: "Scroll",  count: controller.scrollCount),
        ])
    }
}

private struct GestureBreakdownCard: View {
    var controller: LockController
    var body: some View {
        let _ = controller.displayTick
        InputBreakdownCard(title: "Gestures", categories: [
            .init(label: "Swipes", count: controller.swipeCount),
            .init(label: "Pinch",  count: controller.pinchCount),
            .init(label: "Rotate", count: controller.rotateCount),
        ])
    }
}

