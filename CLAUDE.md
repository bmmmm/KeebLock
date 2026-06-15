# KeebLock — Claude working notes

A macOS SwiftUI utility that swallows every keystroke until the user types a
codeword. Kernel of the lock is a `CGEventTap` global keyboard hook;
everything around it is HUD UI, telemetry, and codeword data.

## Build & run

```sh
scripts/build.sh           # Debug build (filtered output)
scripts/build.sh full      # Debug build with full xcodebuild log
scripts/build.sh release   # Release configuration
scripts/build.sh analyze   # static analyzer
scripts/build.sh clean     # wipe build/DerivedData

scripts/install.sh         # copy KeebLock.app to /Applications
scripts/uninstall.sh       # full removal incl. UserDefaults + logs
```

The build uses a project-local `build/DerivedData` so it works inside the
sandboxed Bash tool without `dangerouslyDisableSandbox`. Don't switch to
Xcode's default DerivedData unless you have a reason.

**xcodebuild signing — read this before debugging cert errors.** The
script passes `-allowProvisioningUpdates`. Without it xcodebuild caches a
stale `(Team ID, Cert Serial)` pair in the build state and reports
"Signing certificate is invalid" even when the keychain has a fresh,
valid Personal-Team cert (`security find-identity -v -p codesigning`
shows the right one). The flag forces xcodebuild to re-resolve the
identity against Xcode's account state on every build. **Also: from
Claude Code, builds need `dangerouslyDisableSandbox: true`** — the
default sandbox blocks xcodebuild from reading Xcode's account state and
re-emits the same "is not valid for code signing" error against the
stale cached serial. Manual Xcode builds (⌘B in the IDE) work without
either workaround because Xcode itself owns the account session; only
the CLI needs both.

**Auto-versioning:** `scripts/build.sh` derives `MARKETING_VERSION` from the
latest git tag (`v0.1.0` → `0.1.0`) and `CFBundleVersion` from
`git rev-list --count HEAD`. Both are passed to `xcodebuild` as command-line
settings — pbxproj stays untouched. Override with `VERSION=… BUILD=…` env
vars (release.sh does that to pin a build to a tag exactly). Without git,
falls back to `0.0.0-dev` / `1`. **Don't bump the version in pbxproj
manually** — let the script do it.

There are no automated tests yet. Verify the lock by building, installing,
and exercising it manually — single-monitor and multi-monitor.

## Releasing

```sh
scripts/release.sh 0.1.0
```

What it does:
1. Sanity-check working tree (clean, on `main`).
2. Tag `v0.1.0` and push to Forgejo.
3. Run Release build with the version pinned.
4. Package `KeebLock.app` into `KeebLock-0.1.0.zip` (preserves codesign).
5. `tea releases create` on Forgejo with the .zip as asset, default install
   notes (incl. `xattr` quarantine workaround for non-notarised binaries).
6. Forgejo's push mirror syncs the tag + release to GitHub within minutes.

Pass `--notes "..."` to override the default release notes.

## Project layout

```
KeebLock/                       # Swift sources
├── KeebLockApp.swift           # @main, command menus, scene
├── ContentView.swift           # launcher tab + accessibility-permission gate
├── Lock/
│   ├── LockController.swift    # @Observable singleton; event tap lifecycle
│   ├── CodewordMatcher.swift   # progress-tracker for the unlock keystroke stream
│   └── Permissions.swift       # AX permission queries + System Settings deeplink
├── UI/                         # HUD, lock window mgmt, sparks, heatmap, toggles
├── Settings/                   # AppSettings (UserDefaults), Codewords, layout observer
├── Resources/
│   ├── codeword_data.json      # 103 entries — title/summary/facts/DYK/attribution
│   └── CodewordImages/         # JPGs + auto-generated CREDITS.md
└── KeebLock.entitlements       # app-sandbox = false (required for CGEventTap)

scripts/                        # build / install / data-pipeline tooling
```

## Data pipeline (run in this order)

1. **`scripts/fetch_codeword_data.py`** — Wikipedia summary/facts + Commons
   image + Commons license metadata for each codeword in `WORDS_BY_THEME`.
   Default run is incremental; `--force` rebuilds from scratch; `--only foo`
   targets a subset. Cleanup pass drops manifest entries no longer in
   `WORDS_BY_THEME`, so simply remove a word from the list and re-run.
2. **`scripts/build_dyk.py`** — heuristic generator (5 snippets/codeword, ≤280
   chars) that sentence-extracts from `facts`. **The shipped corpus is NOT this
   script's output** — it's agent-authored: 6 richer, grounded snippets/codeword
   (~360 chars), regenerated 2026-06 via a per-word Sonnet workflow. Re-running
   build_dyk.py overwrites that with thin fragments — it's only an offline/no-API
   fallback. The HUD card (`HUDView` factLineCount) is sized to the longer snippets.
3. **`scripts/build_credits.py`** — render
   `KeebLock/Resources/CodewordImages/CREDITS.md` from `image_attribution`.
   Idempotent. **Do not edit `CREDITS.md` by hand** — re-run the script.

If you replace a codeword (e.g. one where Wikipedia has too little
substance), update both `WORDS_BY_THEME` and `SLUG_OVERRIDES` in
`fetch_codeword_data.py`. The cleanup pass takes care of obsolete entries.

## Code signing — non-obvious

`CODE_SIGN_STYLE = Automatic` + Personal Team. **Don't switch to Manual
without setting `CODE_SIGN_IDENTITY`** — Xcode silently falls back to ad-hoc
signing, which mints a new CDHash on every build. macOS keys Accessibility
permission off `(Team ID, Bundle ID)` for proper certs and off `CDHash` for
ad-hoc; ad-hoc therefore makes the user re-grant permission after every
build. Personal Team gives a stable identity so the grant survives.

Hardened Runtime is on. App Sandbox is **off** (required for `CGEventTap`
global hooks; entitlements file makes this explicit).

## Conventions

- Swift: `@Observable` for new controllers; `ObservableObject`/
  `@StateObject` only where existing code already uses them.
- Comments: only when the *why* isn't obvious from the code. No "what" comments,
  no docstrings on trivial helpers. Existing files follow this — match the
  surrounding style.
- All in-code text (comments, identifiers, log messages, commit messages) is
  English. User-facing strings stay English too — no localisation yet.
- No emojis in source files unless explicitly requested.

## Distribution

- Code: Apache-2.0 (`LICENSE`).
- Codeword images: each retains its original Wikimedia license — see
  `KeebLock/Resources/CodewordImages/CREDITS.md`. 63 are share-alike, so any
  redistribution must include attribution. The credits file is the
  compliance artifact; keep it in sync with `image_attribution`.
- Source-of-truth remote is Forgejo at `https://forgejo.example.com/your-org/KeebLock`
  (HTTPS-with-token). A push-mirror auto-syncs to `github.com/bmmmm/KeebLock` — push to
  Forgejo, GitHub follows. Don't push to GitHub directly.

## Pitfalls

- The HTML parser in `fetch_codeword_data.py` strips superscript tags, so
  exponents like `6×10⁵` end up as `6×10` in `facts`. If a downstream LLM
  fabricates plausible exponents, that's the source — fix the parser, then
  regenerate.
- `Resources/CodewordImages/` JPGs are resized in place by `sips`; running
  `fetch_codeword_data.py --force` will rewrite them all and produce a
  large-but-content-empty diff.
- The `build/` directory is gitignored but Xcode's xcuserdata sometimes
  recreates it under odd paths after a project move. Re-run `scripts/build.sh
  clean` if a build behaves weirdly after relocating the repo.
- SourceKit's live diagnostics cascade into false "Cannot find <Type> in
  scope" / "'main' attribute cannot be used…" errors across the whole module
  mid-edit — even for symbols that plainly exist (`AppSettings`, `Radius`,
  `UIScale`). They're noise; `scripts/build.sh` is the only source of truth.
