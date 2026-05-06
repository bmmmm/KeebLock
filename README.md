# KeebLock

Lock the keyboard. Clean it. Type the codeword to unlock.

A small macOS utility that swallows every keystroke until you type a short
randomly-chosen codeword — so you can wipe the keys, dust the chassis, or
swap a switch without overwriting your terminal with `asdfasdfqwer`.

<!-- screenshot placeholder -->
<!-- ![KeebLock launcher](docs/launcher.png) -->
<!-- ![Lock screen](docs/lock-screen.png) -->

## Why

Cleaning a keyboard while it's plugged into a Mac means dragged windows,
trashed text fields, accidental Cmd+Q. KeebLock takes the keyboard offline
without unplugging it: it installs a global event tap, displays a fullscreen
lock card on every monitor, and only releases when you type the chosen
codeword on a clean key (or when the timer runs out).

## Features

- **Random codeword to unlock** — re-rollable; visible on screen so you can
  pick a sequence you can hit even with a cloth between your fingers.
- **Time-boxed lock** — pick a duration; lock auto-releases when it expires.
- **Fullscreen HUD on every monitor** — multi-display setups stay covered,
  including displays parked on a fullscreen app's Space.
- **Heatmap** — see which keys you hit during the lock; per-session +
  cumulative. Useful for spotting which key is sticking.
- **Keyboard layout aware** — DE and US verified, falls back to US for
  non-Latin layouts.
- **Five accent themes + zoom** — tint the whole UI to match your desktop
  mood, scale 0.8×–1.6× for accessibility (⌘+ / ⌘− / ⌘0).
- **Five screen effects** — sparks, rain, matrix, bubbles, snow.
- **Optional sound** — keystroke pops + unlock chime.
- **Build authenticity** — the launcher embeds Team ID + CDHash so you can
  verify the binary against the published release notes.
- **Self-rotating diagnostic log** — bounded by a configurable size cap
  (default 5 MB), so verbose tracing never balloons disk usage.
- **No telemetry, no PII, no network** — everything stays on your Mac.

## Requirements

- macOS (deployment target set in Xcode — see *Build from source*)
- Xcode (for now: source-only distribution)
- Accessibility permission (to install the global event tap that swallows
  keystrokes)

## Install

### From source

```sh
git clone https://github.com/bmmmm/KeebLock.git
cd KeebLock
scripts/build.sh
scripts/install.sh
```

This puts `KeebLock.app` into `/Applications`.

### Pre-built binary

Grab the latest `.zip` from the
[Releases page](https://github.com/bmmmm/KeebLock/releases/latest), unpack
it into `/Applications`, and clear the macOS quarantine flag (the binary is
signed with a Personal Team but not notarised):

```sh
xattr -dr com.apple.quarantine /Applications/KeebLock.app
```

Each release lists Team ID + CDHash so you can verify your copy matches the
intended build via `codesign -dv /Applications/KeebLock.app`.

## First run

1. Open **KeebLock** from `/Applications`.
2. The launcher will show an orange *Accessibility permission required*
   banner. Click **Open System Settings**.
3. In *Privacy & Security → Accessibility*, enable **KeebLock**.
4. Switch back to KeebLock — the banner clears automatically within a
   second.
5. Press the big button (or hit Return) to start the lock.

## Usage

| Shortcut | Action |
|----------|--------|
| `⌘ L` | Start lock |
| `⌘ ⇧ L` | Stop lock (when locked) |
| `⌘ R` | Roll a new codeword |
| `⌘ ,` | Open Settings tab |
| `Return` | Start lock (from launcher) |

While locked, type the codeword to unlock. The HUD shows progress as you
type the right characters in order.

## Privacy

- KeebLock makes **no network requests**.
- The event tap reads key events to count and swallow them — they are
  **not logged, not stored, not exfiltrated**.
- The heatmap stores aggregate hit counts per *physical key code*, not the
  characters you typed. Logs in `~/Library/Logs/KeebLock/` are purely
  diagnostic and never include input.
- Uninstall removes settings, heatmap, and logs — see `scripts/uninstall.sh`.

## Build from source

```sh
scripts/build.sh         # build (filters output to errors/warnings)
scripts/build.sh full    # build with full xcodebuild output
scripts/build.sh analyze # static analyzer
scripts/build.sh clean   # remove build/DerivedData
```

Code-signing uses your *Personal Team* (free Apple Developer account).
Open the project in Xcode once and pick your team under
*Target → Signing & Capabilities* if the build complains about signing.

## Uninstall

```sh
scripts/uninstall.sh
```

Removes the app, its UserDefaults, and log files. The Accessibility entry
in *System Settings → Privacy & Security* must be removed manually — macOS
does not let apps revoke their own TCC entries.

## License

- **Code** is licensed under the [Apache License 2.0](LICENSE).
- **Codeword images** in `KeebLock/Resources/CodewordImages/` are sourced
  from Wikipedia / Wikimedia Commons under their respective licenses.
  Attribution per file is documented in
  `KeebLock/Resources/CodewordImages/CREDITS.md`.

## Support

If KeebLock saved you from a bowl of crumbs, you can buy me a coffee:
[ko-fi.com/bmabma](https://ko-fi.com/bmabma).
