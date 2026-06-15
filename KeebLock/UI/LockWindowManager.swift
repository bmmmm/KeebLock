import AppKit
import simd
import SwiftUI

// MARK: - Private CGS API for cross-space window placement
//
// macOS' public `.canJoinAllSpaces` collection behavior covers classic
// user spaces but stops working reliably on macOS 26 once a display is
// in "Displays have separate Spaces" mode AND another app holds a
// fullscreen space — our lock window sits on Desktop 1 of that display,
// invisible from the active fullscreen space. Private CGS APIs let us
// explicitly add a window to every space across every display, which
// is the same approach yabai / Rectangle / Stay have used stably for
// years. Resolution is deferred to runtime via dlsym: if Apple ever
// renames or removes a symbol in a future macOS, the resolver returns
// nil and we fall back to `.canJoinAllSpaces` only (degraded but
// non-crashing). `@_silgen_name` would have terminated the process at
// launch via dyld bind failure — exactly the mode this comment used to
// claim wouldn't happen.

private typealias CGSConnectionID = Int32

private enum CGS {
    typealias MainConnectionIDFn = @convention(c) () -> CGSConnectionID
    typealias CopyManagedDisplaySpacesFn = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
    typealias AddWindowsToSpacesFn = @convention(c) (CGSConnectionID, CFArray, CFArray) -> Void
    typealias ManagedDisplaySetCurrentSpaceFn = @convention(c) (CGSConnectionID, CFString, UInt64) -> Void

    static let mainConnectionID: MainConnectionIDFn? = lookup("CGSMainConnectionID")
    static let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn? = lookup("CGSCopyManagedDisplaySpaces")
    static let addWindowsToSpaces: AddWindowsToSpacesFn? = lookup("CGSAddWindowsToSpaces")
    static let managedDisplaySetCurrentSpace: ManagedDisplaySetCurrentSpaceFn? = lookup("CGSManagedDisplaySetCurrentSpace")

    /// RTLD_DEFAULT (-2) — search every loaded image in default order.
    /// SkyLight.framework is loaded into every macOS graphical process,
    /// so the four CGS symbols are reachable without an explicit dlopen.
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

    private static func lookup<T>(_ name: String) -> T? {
        guard let sym = dlsym(rtldDefault, name) else {
            NSLog("[KeebLock] CGS: dlsym(%@) failed — private API unavailable on this macOS", name)
            return nil
        }
        return unsafeBitCast(sym, to: T.self)
    }
}

/// Snapshot of the macOS Spaces topology at a point in time. Used both
/// for the brute-force "add window to all spaces" and for the user-
/// facing debug log.
struct SpacesSnapshot {
    struct Space {
        let id: UInt64
        /// 0 = user (regular desktop), 4 = fullscreen app, others = system / tiled.
        let type: Int
        var label: String {
            switch type {
            case 0: return "Desktop"
            case 4: return "Fullscreen"
            default: return "Type\(type)"
            }
        }
    }
    struct Display {
        /// macOS-internal display UUID string (matches CGSManagedDisplay).
        let displayUUID: String
        let spaces: [Space]
        let currentSpaceID: UInt64
    }
    let displays: [Display]
    let allSpaceIDs: [UInt64]

    static func capture() -> SpacesSnapshot {
        guard let mainCid = CGS.mainConnectionID,
              let copyFn = CGS.copyManagedDisplaySpaces else {
            return SpacesSnapshot(displays: [], allSpaceIDs: [])
        }
        let cid = mainCid()
        guard let unmanaged = copyFn(cid) else {
            return SpacesSnapshot(displays: [], allSpaceIDs: [])
        }
        // takeRetainedValue() balances the +1 retain from the "Copy"-named
        // API; without it every show() would leak the array of dictionaries.
        let array = unmanaged.takeRetainedValue() as? [[String: Any]] ?? []
        var displays: [Display] = []
        var ids: [UInt64] = []
        for d in array {
            guard let uuid = d["Display Identifier"] as? String,
                  let spacesArray = d["Spaces"] as? [[String: Any]],
                  let currentSpaceDict = d["Current Space"] as? [String: Any],
                  let currentSpaceID = (currentSpaceDict["id64"] as? NSNumber)?.uint64Value
            else { continue }
            let spaces: [Space] = spacesArray.compactMap { s in
                // NSNumber.intValue is robust across Int32/Int64 boxing —
                // `as? Int` can fail on macOS revisions that hand the number
                // back as a typed-32-bit NSNumber on a 64-bit build.
                guard let id = (s["id64"] as? NSNumber)?.uint64Value,
                      let type = (s["type"] as? NSNumber)?.intValue else { return nil }
                ids.append(id)
                return Space(id: id, type: type)
            }
            displays.append(Display(displayUUID: uuid, spaces: spaces, currentSpaceID: currentSpaceID))
        }
        return SpacesSnapshot(displays: displays, allSpaceIDs: ids)
    }
}

/// Pin the given window to every space on every display, including
/// fullscreen spaces. Belt-and-braces companion to .canJoinAllSpaces
/// for macOS 26+ where the public flag stops covering fullscreen.
private func addWindowToAllSpaces(_ window: NSWindow, snapshot: SpacesSnapshot) {
    guard !snapshot.allSpaceIDs.isEmpty,
          let mainCid = CGS.mainConnectionID,
          let addFn = CGS.addWindowsToSpaces,
          window.windowNumber > 0 else { return }
    let cid = mainCid()
    let wid = NSNumber(value: window.windowNumber)
    let wids = [wid] as CFArray
    let sids = snapshot.allSpaceIDs.map { NSNumber(value: $0) } as CFArray
    addFn(cid, wids, sids)
}

// Borderless windows can't become key by default; override so the warning goes away
// and any embedded controls that need first-responder status work normally.
final class LockNSWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class LockWindowManager {
    private var windows: [LockNSWindow] = []
    private var renderers: [WipeRenderer] = []  // placeholder instance if Metal unavailable
    private var savedPresentationOptions: NSApplication.PresentationOptions = []
    /// Displays we yanked off a fullscreen Space at lock start. On hide()
    /// we switch them back to where the user was — without this they'd
    /// be stranded on Desktop 1 of that display after unlock.
    private var movedDisplays: [(displayUUID: String, originalSpaceID: UInt64)] = []

    var windowCount: Int { windows.count }

    func show(
        controller: LockController,
        fixedBg: SIMD4<Float>? = nil,
        fixedPixel: SIMD4<Float>? = nil,
        cellsPerAxis: Int,
        stageThreshold: Double
    ) {
        hide()

        savedPresentationOptions = NSApp.presentationOptions
        // .disableProcessSwitching blocks the ⌘-Tab app switcher so the lock
        // can't be sidestepped by bringing another app forward. Force-quit
        // (⌘⌥Esc) is deliberately left enabled: KeebLock is a keyboard-cleaning
        // aid, not a lockdown/kiosk tool, so the user must always keep a manual
        // escape hatch if the codeword path ever wedges.
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching]

        let screens = NSScreen.screens
        let screenSummary = screens.enumerated().map { i, s in
            "[\(i)] \(Int(s.frame.width))×\(Int(s.frame.height))@\(s.backingScaleFactor)x"
        }.joined(separator: " ")
        DebugLog.log("show: \(screens.count) screen(s) \(screenSummary), cellsPerAxis=\(cellsPerAxis), stageThreshold=\(String(format: "%.2f", stageThreshold))")

        for (index, screen) in screens.enumerated() {
            let renderer = WipeRenderer(
                screen: screen,
                fixedBg: fixedBg,
                fixedPixel: fixedPixel,
                cellsPerAxis: cellsPerAxis,
                stageThreshold: stageThreshold
            )
            if renderer.isPlaceholder {
                DebugLog.log("show: screen \(index) WipeRenderer in placeholder mode (no Metal device)")
            }
            renderers.append(renderer)

            let view = LockView(
                controller: controller,
                renderer: renderer
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
            // the window — otherwise NSHostingView (still holding the MTKView's
            // CVDisplayLink callbacks plus TimelineView's animation hooks) gets
            // freed too early → EXC_BAD_ACCESS.
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

        // Brute-force: pin every lock window to every space across every
        // display via private CGS API. .canJoinAllSpaces alone misses
        // fullscreen spaces on macOS 26 dual-display setups — this is
        // how user-space tools like yabai compose lock-style behaviour.
        let snapshot = SpacesSnapshot.capture()
        for window in windows {
            addWindowToAllSpaces(window, snapshot: snapshot)
        }

        // For any display currently showing an app's fullscreen space,
        // drag it back to a regular Desktop so the lock window is
        // actually visible. Without this, the lock IS technically on
        // the fullscreen space too (via the call above), but macOS
        // composites the fullscreen primary on top — user sees Xcode,
        // not the lock. Switching the display's active space animates
        // the view change exactly like ⌃← would. Capture the originals
        // so `hide()` can restore the user back to where they were.
        movedDisplays = switchDisplaysOutOfFullscreen(snapshot)

        DebugLog.log("show: \(windows.count) window(s) ordered front (level=screenSaver, key=screen[\(mainScreen.flatMap(NSScreen.screens.firstIndex(of:)) ?? -1)])")
        logSpacesDiagnostic(snapshot)
        logFullscreenApps()
    }

    func hide() {
        DebugLog.log("hide: \(windows.count) window(s)")

        // 0) Symmetric counterpart to switchDisplaysOutOfFullscreen — put
        // each display we yanked off a fullscreen back on the original
        // space. Done before window teardown so the macOS-driven Space
        // animation slides the lock window off as the user returns,
        // instead of flashing an empty Desktop after the lock vanishes.
        restoreMovedDisplays()

        // 1) Stop Metal display links so draw() stops being scheduled.
        for renderer in renderers { renderer.stop() }

        // 2) Detach hosting views BEFORE close(). NSHostingView with TimelineView(.animation)
        //    holds animation hooks and MTKView holds a CVDisplayLink (CADisplayLink is
        //    iOS-only — macOS MTKView ticks via CVDisplayLink). Nilling contentView drops
        //    both deterministically before close()'s teardown sequence runs.
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
    /// Re-captures the topology so newly-created spaces (post lock-start)
    /// get pinned too — without this the show() snapshot would go stale
    /// and a fresh Mission Control "+" Desktop would be uncovered.
    func refreshSpaceCoverage() {
        let snapshot = SpacesSnapshot.capture()
        for window in windows {
            window.orderFrontRegardless()
            addWindowToAllSpaces(window, snapshot: snapshot)
        }
        // A display moved into an app's fullscreen space *after* lock-start
        // would composite the fullscreen primary over the lock (invisible
        // there) — the same case show() handles once at startup. Yank any
        // such display back to Desktop reactively too. Merge only displays we
        // aren't already tracking, so restoreMovedDisplays() still returns the
        // user to their true pre-lock space rather than a mid-lock one.
        let newlyMoved = switchDisplaysOutOfFullscreen(snapshot)
        for moved in newlyMoved where !movedDisplays.contains(where: { $0.displayUUID == moved.displayUUID }) {
            movedDisplays.append(moved)
        }
    }

    /// Clears one or more pixels on every screen. With `bounds` nil
    /// the random-mode wipe runs (single random cell per screen).
    /// With `bounds` provided, each screen wipes up to `count` cells
    /// inside the key's bounding rectangle (positional mode) — the
    /// rectangle is the same on every monitor (relative coordinates),
    /// so big keys clear bigger areas regardless of screen size.
    func wipeOnAllScreens(at position: CGPoint? = nil,
                          count: Int = 1,
                          bounds: CGRect? = nil) {
        for renderer in renderers {
            if let position, let bounds {
                renderer.wipeAtNormalizedPosition(position, count: count, bounds: bounds)
            } else {
                renderer.wipeRandomCell()
            }
        }
    }

    /// Highest stage reached across all screens.
    var maxStage: Int {
        renderers.map(\.stage).max() ?? 1
    }

    /// Per-renderer mask state for the diagnostic log. Empty when no
    /// lock is active (renderers are torn down on `hide()`).
    func screenStates() -> [WipeRenderer.State] {
        renderers.map { $0.snapshotState() }
    }

    // MARK: - Diagnostics

    /// Log the Spaces topology at lock start so the user can correlate
    /// "lock window not visible on display X" with which space is
    /// currently active there. Particularly useful when an app holds a
    /// fullscreen space on a secondary display — the lock surface
    /// otherwise lands on Desktop 1 of that display, invisible from
    /// the fullscreen space.
    private func logSpacesDiagnostic(_ snapshot: SpacesSnapshot) {
        guard !snapshot.displays.isEmpty else {
            DebugLog.log("spaces: CGS query returned no displays (private API unavailable?)")
            return
        }
        for (idx, display) in snapshot.displays.enumerated() {
            let spacesDesc = display.spaces.map { space in
                let marker = space.id == display.currentSpaceID ? "★" : " "
                return "\(marker)#\(space.id)/\(space.label)"
            }.joined(separator: " ")
            DebugLog.log("spaces: display[\(idx)] uuid=\(display.displayUUID) currentSpace=\(display.currentSpaceID)  spaces=[\(spacesDesc)]")
        }
        if snapshot.allSpaceIDs.isEmpty {
            DebugLog.log("spaces: no space IDs enumerable — windows fall back to .canJoinAllSpaces")
        } else {
            DebugLog.log("spaces: total=\(snapshot.allSpaceIDs.count) — lock windows added to all of them")
        }
    }

    /// For every display whose active space is a fullscreen space (an
    /// app holds it), switch the display back to a regular Desktop.
    /// Lock window is already pinned to that desktop via
    /// CGSAddWindowsToSpaces, so the user lands directly on the lock
    /// surface instead of the fullscreen app's masked-out backdrop.
    private func switchDisplaysOutOfFullscreen(_ snapshot: SpacesSnapshot) -> [(displayUUID: String, originalSpaceID: UInt64)] {
        var moved: [(displayUUID: String, originalSpaceID: UInt64)] = []
        guard let mainCid = CGS.mainConnectionID,
              let switchFn = CGS.managedDisplaySetCurrentSpace else { return moved }
        let cid = mainCid()
        for display in snapshot.displays {
            guard let current = display.spaces.first(where: { $0.id == display.currentSpaceID }),
                  current.type != 0 else { continue }  // already on Desktop, nothing to do
            guard let target = display.spaces.first(where: { $0.type == 0 }) else {
                // Display has no regular Desktop at all — skip rather than
                // pick another fullscreen space which would just keep the
                // user in someone else's fullscreen view.
                DebugLog.log("spaces: display \(display.displayUUID) has no regular Desktop — leaving on space #\(display.currentSpaceID)")
                continue
            }
            switchFn(cid, display.displayUUID as CFString, target.id)
            moved.append((displayUUID: display.displayUUID, originalSpaceID: current.id))
            DebugLog.log("spaces: switched display \(display.displayUUID) from space #\(current.id)/\(current.label) → #\(target.id)/Desktop")
        }
        return moved
    }

    /// Reverse of `switchDisplaysOutOfFullscreen` — switch each display we
    /// yanked back to the space it was on at lock start. Called from the
    /// top of `hide()` so the user lands where they left off.
    private func restoreMovedDisplays() {
        guard !movedDisplays.isEmpty else { return }
        guard let mainCid = CGS.mainConnectionID,
              let switchFn = CGS.managedDisplaySetCurrentSpace else {
            movedDisplays.removeAll()
            return
        }
        let cid = mainCid()
        for moved in movedDisplays {
            switchFn(cid, moved.displayUUID as CFString, moved.originalSpaceID)
            DebugLog.log("spaces: restored display \(moved.displayUUID) → space #\(moved.originalSpaceID)")
        }
        movedDisplays.removeAll()
    }

    /// Log running apps that the user might be looking at full-screen,
    /// so the snapshot in keeblock.log shows "Xcode is fullscreen,
    /// that's where the lock seemed to disappear into." Public API
    /// can't tell us per-display fullscreen ownership directly; we log
    /// frontmost + every regular-policy app as best-effort context.
    private func logFullscreenApps() {
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        DebugLog.log("apps:   frontmost=\(frontmost)")
        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden
        }
        let names = candidates.compactMap { $0.localizedName }.sorted()
        DebugLog.log("apps:   visible regular-policy apps = [\(names.joined(separator: ", "))]")
    }
}
