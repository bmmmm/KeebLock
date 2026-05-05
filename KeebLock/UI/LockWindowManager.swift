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

    var windowCount: Int { windows.count }

    func show(
        controller: LockController,
        fixedBg: SIMD4<Float>? = nil,
        fixedPixel: SIMD4<Float>? = nil,
        cellsPerAxis: Int
    ) {
        hide()

        savedPresentationOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]

        let screens = NSScreen.screens
        let screenSummary = screens.enumerated().map { i, s in
            "[\(i)] \(Int(s.frame.width))×\(Int(s.frame.height))@\(s.backingScaleFactor)x"
        }.joined(separator: " ")
        DebugLog.log("show: \(screens.count) screen(s) \(screenSummary), cellsPerAxis=\(cellsPerAxis)")

        for (index, screen) in screens.enumerated() {
            let renderer = WipeRenderer(
                screen: screen,
                fixedBg: fixedBg,
                fixedPixel: fixedPixel,
                cellsPerAxis: cellsPerAxis
            )
            if renderer == nil {
                DebugLog.log("show: screen \(index) WipeRenderer init failed (no Metal device)")
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
            // .screenSaver (1000) + .stationary + .canJoinAllSpaces is the
            // empirically-best combo: macOS swallows Mission Control and
            // 4-finger Space swipes against this level, and the .stationary
            // flag pins the window to the current Space animation reliably.
            // Tried CGShieldingWindowLevel — it sits *above* system gesture
            // handlers and lets gestures fall through, which is worse.
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
        // Two-step: activate the process, then promote the windows AND make one
        // key. makeKeyAndOrderFront on the main-screen window pulls focus to us
        // even if the user was just typing in another app. Trailing
        // orderFrontRegardless on every window covers the secondary screens.
        NSApp.activate(ignoringOtherApps: true)
        let mainScreen = NSScreen.main
        let primary = windows.first { $0.screen == mainScreen } ?? windows.first
        primary?.makeKeyAndOrderFront(nil)
        for window in windows where window !== primary {
            window.orderFrontRegardless()
        }

        DebugLog.log("show: \(windows.count) window(s) ordered front (level=screenSaver, key=screen[\(mainScreen.flatMap(NSScreen.screens.firstIndex(of:)) ?? -1)])")
    }

    func hide() {
        DebugLog.log("hide: \(windows.count) window(s)")

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
    }

    /// Re-promote all lock windows to the foreground. Called after a Space
    /// (Desktop) switch — canJoinAllSpaces is best-effort and can miss spaces
    /// created via Mission Control while the lock is already active.
    func refreshSpaceCoverage() {
        for window in windows {
            window.orderFrontRegardless()
        }
    }

    /// Clears exactly one random pixel on every screen.
    func wipeOnAllScreens() {
        for renderer in renderers {
            renderer?.wipeRandomCell()
        }
    }

    /// Highest stage reached across all screens.
    var maxStage: Int {
        renderers.compactMap { $0?.stage }.max() ?? 1
    }
}
