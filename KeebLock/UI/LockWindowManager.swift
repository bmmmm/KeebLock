import AppKit
import simd
import SwiftUI

// Borderless windows can't become key by default; override so the warning goes away
// and any embedded controls that need first-responder status work normally.
final class LockNSWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class LockWindowManager {
    private var windows: [LockNSWindow] = []
    private var renderers: [WipeRenderer?] = []  // nil if Metal unavailable on a screen
    private var savedPresentationOptions: NSApplication.PresentationOptions = []

    func show(controller: LockController, fixedColor: SIMD4<Float>? = nil, cellsPerAxis: Int) {
        hide()

        savedPresentationOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]

        let screens = NSScreen.screens
        DebugLog.log("show: activating lock on \(screens.count) screen(s), cellsPerAxis=\(cellsPerAxis)")

        for (index, screen) in screens.enumerated() {
            DebugLog.log("show:   screen \(index) frame=\(NSStringFromRect(screen.frame)) scale=\(screen.backingScaleFactor)")

            let renderer = WipeRenderer(
                screen: screen,
                fixedColor: fixedColor,
                cellsPerAxis: cellsPerAxis
            )
            if renderer == nil {
                DebugLog.log("show:   screen \(index) WipeRenderer init failed (no Metal device?)")
            }
            renderers.append(renderer)

            let view = LockView(
                controller: controller,
                renderer: renderer,
                screenIndex: index
            )
            let hosting = NSHostingView(rootView: view)
            hosting.wantsLayer = true

            let window = LockNSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            // CRITICAL: with manual close() we must NOT also let AppKit auto-release
            // the window — otherwise NSHostingView (still holding CADisplayLink callbacks
            // from TimelineView and MTKView) gets freed too early → EXC_BAD_ACCESS.
            window.isReleasedWhenClosed = false
            window.level = .screenSaver
            window.collectionBehavior = [
                .canJoinAllSpaces,
                .stationary,
                .fullScreenAuxiliary,
                .ignoresCycle,
            ]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isMovable = false
            window.animationBehavior = .none
            window.contentView = hosting
            window.ignoresMouseEvents = false
            // Belt-and-braces: explicit setFrame on the screen-anchored coords. macOS
            // sometimes ignores the contentRect for negative-Y screens.
            window.setFrame(screen.frame, display: false)
            windows.append(window)
        }

        // Activate AFTER all windows exist so the foreground promotion is atomic.
        NSApp.activate(ignoringOtherApps: true)
        for window in windows {
            window.orderFrontRegardless()
        }
        windows.first?.makeKey()

        DebugLog.log("show: \(windows.count) window(s) ordered front")
    }

    func hide() {
        DebugLog.log("hide: tearing down \(windows.count) window(s)")

        // 1) Stop Metal display links so draw() stops being scheduled.
        for renderer in renderers { renderer?.stop() }

        // 2) Detach hosting views BEFORE close(). NSHostingView with TimelineView(.animation)
        //    and MTKView both hold CADisplayLink callbacks; nilling contentView releases
        //    them deterministically before close()'s teardown sequence runs.
        for window in windows {
            if let layer = window.contentView?.layer {
                layer.speed = 0
                layer.removeAllAnimations()
            }
            window.contentView = nil
        }

        // 3) Order out and close. With isReleasedWhenClosed=false the windows live until
        //    we drop our `windows` array reference below.
        for window in windows {
            window.animationBehavior = .none
            window.orderOut(nil)
            window.close()
        }

        windows.removeAll()
        renderers.removeAll()
        NSApp.presentationOptions = savedPresentationOptions

        DebugLog.log("hide: teardown complete")
    }

    /// Clears exactly one random pixel on every screen.
    func wipeOnAllScreens() {
        for renderer in renderers {
            renderer?.wipeRandomCell()
        }
    }
}
