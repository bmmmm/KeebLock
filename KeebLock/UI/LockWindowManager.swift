import AppKit
import SwiftUI

final class LockWindowManager {
    private var windows: [NSWindow] = []

    func show(controller: LockController) {
        hide()
        for (index, screen) in NSScreen.screens.enumerated() {
            let bgColor = randomColor()
            let view = LockView(
                controller: controller,
                screenIndex: index,
                backgroundColor: bgColor
            )
            let hosting = NSHostingView(rootView: view)

            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = .screenSaver
            window.collectionBehavior = [
                .canJoinAllSpaces,
                .stationary,
                .fullScreenAuxiliary,
                .ignoresCycle,
            ]
            window.isOpaque = true
            window.hasShadow = false
            window.isMovable = false
            window.contentView = hosting
            window.ignoresMouseEvents = false
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
    }

    private func randomColor() -> Color {
        Color(
            hue: Double.random(in: 0..<1),
            saturation: Double.random(in: 0.55...0.75),
            brightness: Double.random(in: 0.45...0.6)
        )
    }
}
