import AppKit
import simd
import SwiftUI

final class LockWindowManager {
    private var windows: [NSWindow] = []
    private var renderers: [WipeRenderer?] = []  // nil if Metal unavailable on a screen

    func show(controller: LockController, fixedColor: SIMD4<Float>? = nil) {
        hide()
        for (index, screen) in NSScreen.screens.enumerated() {
            let renderer = WipeRenderer(screen: screen, fixedColor: fixedColor)
            renderers.append(renderer)

            let view = LockView(
                controller: controller,
                renderer: renderer,
                screenIndex: index,
                screenFrame: screen.frame
            )
            let hosting = NSHostingView(rootView: view)
            hosting.wantsLayer = true

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
            // Transparent so wiped areas reveal the desktop below
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isMovable = false
            window.contentView = hosting
            window.ignoresMouseEvents = false
            window.orderFront(nil)
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        // Stop Metal rendering before closing windows — prevents draw(in:) from
        // firing on a teardown drawable and crashing during window release.
        for renderer in renderers { renderer?.stop() }
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        renderers.removeAll()
    }

    // Finds which screen the cursor is on and calls wipe() on its renderer.
    func wipeAtCurrentMouse() {
        let mouse = NSEvent.mouseLocation
        for (index, screen) in NSScreen.screens.enumerated() {
            guard screen.frame.contains(mouse) else { continue }
            let local = CGPoint(
                x: mouse.x - screen.frame.minX,
                y: mouse.y - screen.frame.minY
            )
            if index < renderers.count {
                renderers[index]?.wipe(at: local, radius: 60)
            }
            break
        }
    }
}
