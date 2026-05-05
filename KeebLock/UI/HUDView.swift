import Combine
import SwiftUI

struct HUDView: View {
    @ObservedObject var controller: LockController
    @ObservedObject var rendererProxy: RendererProxy
    @ObservedObject var settings: AppSettings = .shared
    let screenIndex: Int

    @State private var factIndex = 0
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseAlpha: Double = 0.0
    private let factTimer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 22) {
            Text("Cleaning Mode")
                .font(.system(size: 56, weight: .bold))

            Text("Type the codeword to unlock")
                .font(.title3)
                .opacity(0.85)

            Text(controller.currentCodeword.uppercased())
                .font(.system(size: 36, weight: .heavy, design: .monospaced))
                .tracking(4)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
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
        .onReceive(factTimer) { _ in
            let count = max(1, currentEntry.facts.count)
            factIndex = (factIndex + 1) % count
        }
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
            .init(label: "System",   count: controller.mediaKeyCount),
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

    @ViewBuilder
    private var inputBreakdown: some View {
        let kbTotal = keyboardCategories.reduce(0) { $0 + $1.count }
        let msTotal = mouseCategories.reduce(0) { $0 + $1.count }
        let gsTotal = gestureCategories.reduce(0) { $0 + $1.count }
        if kbTotal > 0 || msTotal > 0 || gsTotal > 0 {
            HStack(alignment: .top, spacing: 18) {
                if kbTotal > 0 {
                    breakdownCard(title: "Keyboard", categories: keyboardCategories)
                }
                if msTotal > 0 {
                    breakdownCard(title: "Mouse", categories: mouseCategories)
                }
                if gsTotal > 0 {
                    breakdownCard(title: "Gestures", categories: gestureCategories)
                }
            }
            .frame(maxWidth: 980)
        }
    }

    private func breakdownCard(title: String, categories: [InputCategory]) -> some View {
        let visible = categories.filter { $0.count > 0 }
        return VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased())
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .tracking(2.4)
                .foregroundStyle(.white.opacity(0.7))
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .leading), count: 3),
                alignment: .leading,
                spacing: 14
            ) {
                ForEach(visible) { cat in
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
                .foregroundStyle(.white)
            Text(cat.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
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

    @ViewBuilder
    private var knowledgeFooter: some View {
        if settings.showCodewordKnowledge {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: currentEntry.iconSymbol)
                        .foregroundStyle(.white.opacity(0.85))
                    Text(currentEntry.word.capitalized)
                        .font(.headline)
                    Spacer()
                }
                Text(currentEntry.summary)
                    .font(.callout)
                    .opacity(0.9)
                if !currentEntry.facts.isEmpty {
                    Text(currentEntry.facts[factIndex % currentEntry.facts.count])
                        .font(.body)
                        .opacity(0.75)
                        .multilineTextAlignment(.leading)
                        .id(factIndex)   // re-render on rotation
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: 540, alignment: .leading)
            .padding(18)
            .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 14))
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
        ZStack {
            // Expanding pulse ring — animates outward and fades when clickable
            if unlockClickable {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(pulseAlpha), lineWidth: 2.5)
                    .scaleEffect(pulseScale)
                    .padding(-12)
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
            .scaleEffect(0.6 + min(unlockOpacity, 1.0) * 0.4)
            .opacity(unlockOpacity)
            .animation(.spring(response: 0.45, dampingFraction: 0.60), value: unlockOpacity)
            .animation(.easeInOut(duration: 0.28), value: unlockClickable)
        }
        .padding(.top, 14)
        .task(id: unlockClickable) {
            guard unlockClickable else {
                pulseScale = 1.0
                pulseAlpha = 0.0
                return
            }
            while !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.85)) {
                    pulseScale = 1.22
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
