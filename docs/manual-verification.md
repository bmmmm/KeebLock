# Manual verification

KeebLock has no automated tests — the lock surface, multi-monitor coverage and
the launcher visuals can only be exercised by hand. This file is the checklist
for findings that were fixed but never confirmed on real hardware.

## How to run

```sh
scripts/build.sh release      # or: scripts/install.sh after a build
```

Enable **Settings → Enable debug logging** before the multi-monitor cases so
the rebuild path is observable. Logs go to the macOS Console (filter
`KeebLock`) and to `~/Library/Logs/KeebLock/keeblock.log`.

Tail the log file while testing:

```sh
tail -f ~/Library/Logs/KeebLock/keeblock.log
```

---

## F11 — fullscreen restore survives a mid-lock display change

**What changed:** A display-arrangement change while locked
(`didChangeScreenParametersNotification`, debounced 0.3 s) now rebuilds the
lock windows via `LockWindowManager.show(rebuild: true)`, which preserves the
captured `movedDisplays` instead of re-capturing. Before the fix the re-capture
saw Desktop (displays were already parked off fullscreen), `movedDisplays` went
empty, and at unlock the user was left on Desktop instead of their fullscreen
app.

**Needs:** 2+ monitors.

**Steps:**
1. Put an app into **native fullscreen** on the secondary monitor (e.g. Safari
   or QuickTime → green-button fullscreen, so it owns its own Space).
2. Switch focus back and start KeebLock (⌘S or the launcher button). All
   screens should be covered; the secondary display slides off the fullscreen
   Space onto the lock.
3. **While locked**, change the display arrangement. Any of:
   - unplug or plug a monitor,
   - change a display's resolution in System Settings → Displays,
   - drag the displays to rearrange them.
4. Watch the log for `screen params changed — rebuilding lock surface for N
   screen(s)` followed by `hide: N window(s) (rebuild)`.
5. Confirm the **new** screen set is fully covered — no usable desktop strip
   anywhere.
6. Type the codeword to unlock.

**Pass:** the fullscreen app is restored to its fullscreen Space after unlock.
**Fail (the regression this guards):** unlock drops you onto Desktop and the
app is no longer fullscreen.

---

## F24 — keyboard backdrop / wipe positioning (no-visual-change refactor)

**What changed:** The per-row key-geometry walk was extracted into a single
`KeyboardPositionMap.forEachKey`, shared by the keycode→position table and the
Trailmap backdrop. The math is meant to be **bit-identical** — this is a
regression check, not a behaviour change.

**Steps:**
1. **Trailmap backdrop:** Settings → Trailmap → open the map. Inspect the
   keyboard outline: rows aligned, key widths proportional (Tab/Caps/Shift
   wider, spacebar widest and centred), nothing shifted, clipped or
   overlapping.
2. **Wipe positioning:** start a lock and type across the keyboard. The wipe
   cells must land under the keys pressed — `Q` clears top-left, `P` top-right,
   the spacebar clears bottom-centre, number row along the top.

**Pass:** backdrop and wipe-to-key mapping look exactly as before the refactor.
**Fail:** any key visibly mispositioned or a wipe landing at the wrong cell.

---

## F30 — water-fill meniscus amplitude

**What changed:** `WaterShape` amplitude was `5.5 * max(0, 1 - (frac-0.85)/0.15)`,
which is huge at low fill (~37 px at empty) and only shrinks past 85 %. It is
now `5.5 * min(1, max(0, (1-frac)/0.15))` — constant 5.5 px for most of the
fill, fading to 0 only in the last 15 %.

**Steps:**
1. Trigger the launcher start button's fill animation (press/activate **Start**).
2. Watch the water surface wave as it rises.

**Pass:** the wave amplitude looks steady through most of the rise and only
flattens out as the water tops off.
**Fail (the old bug):** the wave starts large/violent when nearly empty and
calms down as it fills.

---

## F31 — disabled re-check after the fill animation

**What changed:** After the 0.85 s fill, `WaterFillButton` now re-checks
`disabled` before calling `action()`. The button's `disabled` is
`controller.isLocked || !accessibilityGranted`. If that flips true during the
fill, the button resets without firing `action()`.

**Hard to trigger naturally** — it needs the disabled condition to become true
inside the 0.85 s window. Practical checks:
1. **No regression:** normal use — press Start, lock arms correctly every time.
2. **Guard path (best-effort):** start the fill, then within ~0.85 s make the
   button disabled (e.g. trigger the lock through the ⌘S menu shortcut, or
   revoke Accessibility). Confirm there is no double-start and no crash; the
   button should just reset.

**Pass:** no double-start, no crash; normal start still works.
