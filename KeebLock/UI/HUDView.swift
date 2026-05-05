import Combine
import SwiftUI

struct HUDView: View {
    @ObservedObject var controller: LockController
    @ObservedObject var rendererProxy: RendererProxy
    @ObservedObject var settings: AppSettings = .shared
    let screenIndex: Int

    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseAlpha: Double = 0.0

    /// Modulo the controller's session-wide rotation tick by the current
    /// fact count. Single source of truth lives in LockController so all
    /// monitors show the same fact in lock-step.
    private var factIndex: Int {
        let count = currentEntry.facts.count
        return count > 0 ? controller.factRotationTick % count : 0
    }

    var body: some View {
        // Spacing trimmed (22 → 16), title & codeword shrunk so the whole
        // column fits on a 13" MBP (982 pt usable) without clipping the
        // unlock button below the bottom margin.
        VStack(spacing: 16) {
            Text("Cleaning Mode")
                .font(.system(size: 42, weight: .bold))

            Text("Type the codeword to unlock")
                .font(.subheadline)
                .opacity(0.85)

            Text(controller.currentCodeword.uppercased())
                .font(.system(size: 30, weight: .heavy, design: .monospaced))
                .tracking(4)
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
                .background(.black.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 14))

            statsRow
            inputBreakdown
            colorIndicators
            knowledgeFooter
            unlockButton
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 12)
    }

    private var currentEntry: CodewordKnowledge {
        CodewordKnowledgeBase.entry(for: controller.currentCodeword)
    }

    @ViewBuilder
    private var statsRow: some View {
        HStack(spacing: 40) {
            stat(label: "Keys", value: "\(controller.keystrokeCount)")
            stat(
                label: "Stage \(rendererProxy.stage)",
                value: "\(Int(rendererProxy.wipedFraction * 100))% wiped"
            )
            if settings.autoUnlockEnabled {
                stat(
                    label: controller.isPaused ? "Paused" : "Auto-unlock in",
                    value: formatTime(controller.remainingSeconds)
                )
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Input breakdown

    private struct InputCategory: Identifiable {
        let id = UUID()
        let label: String
        let count: Int
    }

    private var keyboardCategories: [InputCategory] {
        [
            .init(label: "Letters",  count: controller.letterCount),
            .init(label: "Numbers",  count: controller.numberCount),
            .init(label: "Function", count: controller.fnKeyCount),
            .init(label: "System",   count: controller.systemKeyCount),
            .init(label: "Other",    count: controller.otherKeyCount),
        ]
    }

    private var mouseCategories: [InputCategory] {
        [
            .init(label: "Left",    count: controller.leftClickCount),
            .init(label: "Right",   count: controller.rightClickCount),
            .init(label: "Middle",  count: controller.middleClickCount),
            .init(label: "Back",    count: controller.backClickCount),
            .init(label: "Forward", count: controller.forwardClickCount),
            .init(label: "Scroll",  count: controller.scrollCount),
        ]
    }

    private var gestureCategories: [InputCategory] {
        [
            .init(label: "Swipes", count: controller.gestureAttemptCount),
            .init(label: "Spaces", count: controller.spaceSwitchCount),
        ]
    }

    private var inputBreakdown: some View {
        // Render all three cards from the start, even when every counter is 0.
        // The previous "show only when count > 0" version made the entire HUD
        // shift downward on the very first keystroke (and again whenever a
        // new category appeared), which yanked the knowledge card out from
        // under the user's eye. Constant layout > slightly emptier first
        // second.
        HStack(alignment: .top, spacing: 18) {
            breakdownCard(title: "Keyboard", categories: keyboardCategories)
            breakdownCard(title: "Mouse",    categories: mouseCategories)
            breakdownCard(title: "Gestures", categories: gestureCategories)
        }
        .frame(maxWidth: 980)
    }

    private func breakdownCard(title: String, categories: [InputCategory]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased())
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .tracking(2.4)
                .foregroundStyle(.white.opacity(0.7))
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .leading), count: 3),
                alignment: .leading,
                spacing: 14
            ) {
                // No .filter — render every tile so the card height never
                // changes when a new category gets its first hit.
                ForEach(categories) { cat in
                    breakdownTile(cat)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func breakdownTile(_ cat: InputCategory) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(cat.count)")
                .font(.system(size: 38, weight: .heavy, design: .monospaced))
                .foregroundStyle(cat.count > 0 ? .white : .white.opacity(0.22))
            Text(cat.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(cat.count > 0 ? 0.7 : 0.4))
        }
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
                    LinearGradient(
                        colors: [.pink, .yellow, .green, .blue, .purple],
                        startPoint: .leading, endPoint: .trailing
                    )
                } else {
                    preset.swiftUIColor
                }
            }
            .frame(width: 14, height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(.white.opacity(0.5), lineWidth: 0.5)
            )
            Text(preset.label)
                .font(.caption2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.black.opacity(0.25), in: Capsule())
    }

    // Card width and the body text's reserved line count are intentionally
    // hard-coded so a fact rotating from a 2-line fact to a 5-line fact (or
    // a portrait-aspect bundled image vs. a landscape one) doesn't reflow
    // the entire HUD column under the unlock button. Pick numbers that hold
    // the longest bundled fact at 16-pt body without truncation.
    private static let knowledgeCardWidth: CGFloat = 540
    private static let knowledgeImageHeight: CGFloat = 160
    private static let knowledgeFactLineCount = 4

    @ViewBuilder
    private var knowledgeFooter: some View {
        if settings.showCodewordKnowledge {
            VStack(alignment: .leading, spacing: 0) {
                knowledgeImage
                VStack(alignment: .leading, spacing: 12) {
                    Text(currentEntry.title)
                        .font(.system(size: 24, weight: .heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if !currentEntry.facts.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("DID YOU KNOW?")
                                .font(.system(size: 11, weight: .heavy, design: .rounded))
                                .tracking(2.0)
                                .foregroundStyle(.white.opacity(0.55))
                            Text(currentEntry.facts[factIndex])
                                .font(.body)
                                .opacity(0.92)
                                .multilineTextAlignment(.leading)
                                // reservesSpace keeps the card's vertical
                                // size stable across fact rotations; without
                                // it a 1-line fact next to a 5-line fact
                                // would jolt the whole HUD column.
                                .lineLimit(Self.knowledgeFactLineCount, reservesSpace: true)
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
            .frame(width: Self.knowledgeCardWidth, alignment: .leading)
            .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder
    private var knowledgeImage: some View {
        let topShape = UnevenRoundedRectangle(
            topLeadingRadius: 14,
            topTrailingRadius: 14
        )
        if let image = currentEntry.loadImage() {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                // Fixed (not max-) frame so the image area is the same height
                // for every codeword. With max-frames a portrait JPG would
                // shrink the visible band and the title below would jump up.
                .frame(width: Self.knowledgeCardWidth, height: Self.knowledgeImageHeight)
                .clipped()
                .clipShape(topShape)
        } else {
            // Reserve the same slab so the absence of a bundled image doesn't
            // make the whole card collapse upward.
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: Self.knowledgeCardWidth, height: Self.knowledgeImageHeight)
                .clipShape(topShape)
        }
    }

    private func stat(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
            Text(label)
                .font(.caption)
                .opacity(0.75)
        }
    }

    private func formatTime(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Unlock button

    // Opacity and interactivity scale with how close the typed buffer is to the
    // codeword. Invisible at 0% match, clickable at ≥50%, full brightness never
    // reached (the codeword itself triggers unlock before that).
    private var unlockOpacity: Double {
        let len = controller.currentCodeword.count
        guard len > 0 else { return 0 }
        let p = Double(controller.codewordMatchProgress) / Double(len)
        return p > 0 ? max(0.12, p) : 0
    }

    private var unlockClickable: Bool {
        let len = controller.currentCodeword.count
        guard len > 0 else { return false }
        return controller.codewordMatchProgress >= (len + 1) / 2
    }

    @ViewBuilder
    private var unlockButton: some View {
        // Wrap in a fixed-size container so scaleEffect on the inner button
        // never shifts surrounding layout, regardless of match progress.
        // Frame is sized to hold the button at full scale + a calmer pulse
        // ring without overlapping the knowledge card above.
        ZStack {
            // Expanding pulse ring — calmer magnitude (1.0 → 1.08) so it
            // stays inside the reserved frame and doesn't visually clip
            // into the hero-image card.
            if unlockClickable {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(pulseAlpha), lineWidth: 2.5)
                    .scaleEffect(pulseScale)
                    .padding(-8)
                    .allowsHitTesting(false)
            }

            Button { controller.stopLock() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "lock.open.fill")
                        .font(.system(size: 18, weight: .bold))
                    Text("Unlock now")
                        .font(.system(size: 17, weight: .bold))
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(unlockClickable
                              ? Color.white.opacity(0.93)
                              : Color.white.opacity(unlockOpacity * 0.18))
                        .shadow(
                            color: Color.white.opacity(unlockClickable ? 0.7 : unlockOpacity * 0.2),
                            radius: unlockClickable ? 24 : 8, y: 0
                        )
                )
                .foregroundStyle(unlockClickable ? Color.black.opacity(0.82) : Color.white)
            }
            .buttonStyle(.plain)
            .disabled(!unlockClickable)
            // Grow from 0.85 → 1.0 (was 0.6 → 1.0). Smaller delta = less
            // bounce next to a static-layout hero card right above it.
            .scaleEffect(0.85 + min(unlockOpacity, 1.0) * 0.15)
            .opacity(unlockOpacity)
            .animation(.spring(response: 0.45, dampingFraction: 0.75), value: unlockOpacity)
            .animation(.easeInOut(duration: 0.28), value: unlockClickable)
        }
        .frame(height: 70)
        .padding(.top, 8)
        .task(id: unlockClickable) {
            guard unlockClickable else {
                pulseScale = 1.0
                pulseAlpha = 0.0
                return
            }
            while !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.85)) {
                    pulseScale = 1.08
                    pulseAlpha = 0
                }
                try? await Task.sleep(for: .milliseconds(1000))
                guard !Task.isCancelled else { break }
                withAnimation(.none) {
                    pulseScale = 1.0
                    pulseAlpha = 0.72
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }
}

// Bridges an optional WipeRenderer into an ObservableObject owned by LockView.
final class RendererProxy: ObservableObject {
    @Published var stage: Int = 1
    @Published var wipedFraction: Double = 0

    private var bag = Set<AnyCancellable>()

    init(renderer: WipeRenderer?) {
        guard let renderer else { return }
        renderer.$stage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.stage = $0 }
            .store(in: &bag)
        renderer.$wipedFraction
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.wipedFraction = $0 }
            .store(in: &bag)
    }
}
