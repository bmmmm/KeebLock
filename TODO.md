# KeebLock — open TODOs

> Not committed standalone — fold each item into the feature/fix commit that
> resolves it (per CLAUDE.md).

## Escape & secure-key handling (during an active lock)

- [x] **⌘⌥Esc escape hatch.** The original "pass the combo through to the system
  Force Quit handler" approach did NOT work on hardware (nothing happened): the
  lock swallows the Cmd/Opt `flagsChanged` so WindowServer never sees the chord,
  and the Force Quit window would open behind the full-screen `.screenSaver`-level
  lock anyway. Replaced with detect-and-**unlock**: `handleEvent` recognises
  Escape (keycode 53) with Command+Option held — via both the tracked
  `pressedModifiers` set and the event flags — and calls `stopLock()`, which
  reliably frees the user and tears down the occluding window. Not counted as a
  wipe. **Hardware-verified 2026-06-02:** ⌘⌥Esc unlocks during an active lock.
  Memory `keeblock-threat-model` updated to record the verified escape.

- [x] **Catch the power button — CONCLUDED, not possible.** Hardware spike
  confirmed: a power-button press produces no `sysDefined` event at the session
  tap (no count on press). On Apple Silicon / T2 the button is wired to the SMC
  and handled by `powerd` below any app-level event tap, so it never reaches
  KeebLock. Interception is impossible at the app layer — KeebLock cannot prevent
  the power button from sleeping / locking the Mac. Documented in
  `LockController.handleEvent`; spike logging retained for other hardware.
