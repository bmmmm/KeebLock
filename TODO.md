# KeebLock — open TODOs

> Not committed standalone — fold each item into the feature/fix commit that
> resolves it (per CLAUDE.md).

## Escape & secure-key handling (during an active lock)

- [x] **Verify & fix the ⌘⌥Esc force-quit escape hatch.** Done — `handleEvent`
  now detects Escape (keycode 53) carrying `.maskCommand | .maskAlternate` at the
  top of the `.keyDown` branch and passes the event through (`passUnretained`)
  instead of swallowing it, so the system Force Quit handler fires. The combo is
  not counted as a wipe. The `KeebLockApp.swift` comment is now accurate.
  **Pending hardware verification:** confirm the Force Quit dialog actually opens
  during an active lock, then update memory `keeblock-threat-model`.

- [~] **Catch the power button so the Mac doesn't sleep / hit the lock screen
  on press during a session.** Spike instrumented, not yet concluded. The
  non-subtype-8 `NX_SYSDEFINED` branch now logs the subtype under verbose perf
  (`sysDefined subtype=N (passed through)`), so a power-button press during a
  verbose-perf session is observable in the snapshot. **Needs a hardware run:**
  enable verbose perf, lock, press the power button, take a snapshot, and check
  whether any `sysDefined` line appears.
    - If nothing logs → the press never reaches the session tap (SMC/powerd path
      below us). That's the expected result on Apple Silicon / T2: hard platform
      limit, interception impossible at the app layer. Document and close.
    - If a subtype logs → evaluate whether swallowing it (returning `nil`)
      actually prevents the sleep, or whether powerd acts regardless.
  Note: `IOPMAssertionCreateWithName` (`kIOPMAssertionTypePreventUserIdleSystemSleep`)
  only blocks *idle* sleep, never a user-initiated power-button press — not a
  solution either way.
