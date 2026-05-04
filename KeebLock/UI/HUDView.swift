import SwiftUI

struct HUDView: View {
    @ObservedObject var controller: LockController
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
                stat(label: "Keystrokes", value: "\(controller.keystrokeCount)")
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
        .shadow(color: .black.opacity(0.35), radius: 10)
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
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
