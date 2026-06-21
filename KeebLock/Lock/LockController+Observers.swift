import AppKit

extension LockController {
    // MARK: - Space (Desktop) observer

    /// Watch for macOS Space switches (4-finger swipe, Ctrl+Arrow, Mission
    /// Control). The notification fires regardless of how the switch was
    /// triggered, so we get a reliable count even if the gesture itself never
    /// reaches our event tap.
    func installSpaceObserver() {
        let center = NSWorkspace.shared.notificationCenter
        spaceObserver = center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // queue: .main guarantees the closure runs on the main thread,
            // but the Notification API surface is nonisolated so the
            // compiler can't see that. assumeIsolated lets us call into
            // @MainActor APIs (windowManager / PerfMetrics / mutations on
            // self) without an async hop that would defer the recovery
            // beyond the next frame.
            MainActor.assumeIsolated {
                guard let self, self.isLocked else { return }
                // Re-promote our windows on the (possibly newly created) space.
                // canJoinAllSpaces should handle this automatically, but a manual
                // orderFront covers edge cases like spaces created via Mission
                // Control's "+" while we're already locked. This must run even
                // during warmup — it's the recovery path, not user-attributed.
                self.windowManager.refreshSpaceCoverage()
                // The notification can fire from AppKit's own window-promotion
                // path during lock startup; ignore those so the user doesn't see
                // a phantom swipe on a clean start.
                guard !self.isInWarmup else { return }
                // Space changes are how 4-finger swipes manifest on macOS 26+
                // (the OS dispatches the gesture above our event tap). Map
                // them onto swipeCount with a debounce so a `.swipe` (31) and
                // its follow-up activeSpaceDidChange don't double-count.
                let now = Date()
                if self.lastSwipeAt == nil || now.timeIntervalSince(self.lastSwipeAt!) > 0.4 {
                    self.swipeCount += 1
                    PerfMetrics.shared.recordEvent("swipe (space)")
                    self.triggerInputFeedback()
                }
                self.lastSwipeAt = now
            }
        }
    }

    /// True for the first `warmupGracePeriod` seconds after a successful
    /// `startLock`. The event tap still swallows everything during this
    /// window — we just refrain from counting / sounding / sparking on
    /// non-keyboard events to absorb the burst that the lock-window
    /// activation itself produces (Magic Mouse `.gesture` stream, AppKit-
    /// induced `activeSpaceDidChange`, etc.). Keyboard is exempt elsewhere
    /// so the user can start typing the codeword immediately.
    var isInWarmup: Bool {
        guard let started = lockStartedAt else { return false }
        return Date().timeIntervalSince(started) < warmupGracePeriod
    }

    func removeSpaceObserver() {
        if let token = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        spaceObserver = nil
    }

    // MARK: - Screen arrangement observer

    /// Rebuild the lock surface when the display arrangement changes. Without
    /// this, a monitor hot-plugged mid-session has no lock window — leaving a
    /// usable desktop next to the lock — and the CADisplayLink stays anchored
    /// to the screen that was `NSScreen.main` at lock start, so it can stall
    /// (freezing the HUD counter) when the primary display changes.
    func installScreenObserver() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isLocked else { return }
                // Coalesce the burst of notifications a single arrangement
                // change emits; rebuild once, shortly after it settles.
                self.screenChangeWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isLocked else { return }
                    self.rebuildLockSurface()
                }
                self.screenChangeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        }
    }

    func removeScreenObserver() {
        screenChangeWork?.cancel()
        screenChangeWork = nil
        if let token = screenObserver {
            NotificationCenter.default.removeObserver(token)
        }
        screenObserver = nil
    }

    /// Re-create the lock windows for the current screen set and re-anchor the
    /// display link. The per-cell wipe progress resets (the renderers are
    /// rebuilt) — acceptable for the rare hot-plug event, and far simpler than
    /// migrating live Metal mask state across a window rebuild.
    func rebuildLockSurface() {
        guard isLocked else { return }
        DebugLog.log("screen params changed — rebuilding lock surface for \(NSScreen.screens.count) screen(s)")
        windowManager.show(
            controller: self,
            fixedBg: AppSettings.shared.backgroundSIMD,
            fixedPixel: AppSettings.shared.pixelSIMD,
            cellsPerAxis: AppSettings.shared.cellsPerAxis,
            stageThreshold: AppSettings.shared.stageAdvanceThreshold,
            rebuild: true
        )
        // Re-anchor the display link to the (possibly new) main screen.
        stopDisplayLink()
        startDisplayLink()
    }
}
