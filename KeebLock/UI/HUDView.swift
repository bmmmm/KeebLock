import Combine
import SwiftUI

struct HUDView: View {
    @ObservedObject var controller: LockController
    @ObservedObject var rendererProxy: RendererProxy
    let screenIndex: Int

    var body: some View {
        VStack(spacing: 28) {
            Text("Cleaning Mode")
                .font(.system(size: 64, weight: .bold))

            Text("Type the codeword to unlock")
                .font(.title2)
                .opacity(0.85)

            Text(controller.currentCodeword.uppercased())
                .font(.system(size: 40, weight: .heavy, design: .monospaced))
                .tracking(4)
                .padding(.horizontal, 36)
                .padding(.vertical, 18)
                .background(.black.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 16))

            HStack(spacing: 48) {
                stat(
                    label: controller.isPaused ? "Paused (no input)" : "Auto-unlock in",
                    value: formatTime(controller.remainingSeconds)
                )
                stat(
                    label: "Stage \(rendererProxy.stage)",
                    value: "\(Int(rendererProxy.wipedFraction * 100))% wiped"
                )
            }
            .padding(.top, 12)

            Button {
                controller.stopLock()
            } label: {
                Label("Unlock now", systemImage: "lock.open.fill")
                    .font(.title3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.25))
            .padding(.top, 24)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 12)
    }

    private func stat(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 32, weight: .semibold, design: .monospaced))
            Text(label)
                .font(.caption)
                .opacity(0.75)
        }
    }

    private func formatTime(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// Bridges an optional WipeRenderer into an ObservableObject owned by LockView
// so HUDView can observe it via @ObservedObject without conditional logic.
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
