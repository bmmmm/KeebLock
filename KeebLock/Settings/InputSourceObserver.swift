import Carbon
import Combine
import Foundation

/// Watches the macOS keyboard input source so the launcher can show "we see
/// your layout" feedback. Updates live when the user switches via ⌃⌥Space or
/// the menu-bar input switcher.
final class InputSourceObserver: ObservableObject {
    static let shared = InputSourceObserver()

    @Published private(set) var localizedName: String = "?"
    @Published private(set) var sourceID: String = ""

    private init() {
        refresh()
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        let name = property(src, key: kTISPropertyLocalizedName) ?? "?"
        let id   = property(src, key: kTISPropertyInputSourceID) ?? ""
        localizedName = name
        sourceID = id
    }

    private func property(_ src: TISInputSource, key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
