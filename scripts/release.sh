#!/usr/bin/env bash
# Cut a KeebLock release: tag, build Release, package .zip, publish on Forgejo.
#
# Forgejo's push-mirror takes care of pushing the tag + asset to GitHub.
# Requires `fj` (forgejo-cli) configured for the current repo's remote.
#
# Usage:
#   scripts/release.sh 0.1.0
#   scripts/release.sh 0.1.0 --notes "Custom release notes"
#
# Default release notes include the install instructions for Apple-Silicon
# Macs without notarisation (xattr workaround).

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
shift || true
if [ -z "$VERSION" ]; then
    echo "usage: $(basename "$0") <version> [--notes \"...\"]" >&2
    echo "example: $(basename "$0") 0.1.0" >&2
    exit 2
fi

CUSTOM_NOTES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --notes)
            CUSTOM_NOTES="${2:-}"
            shift 2
            ;;
        *)
            echo "error: unknown argument '$1'" >&2
            exit 2
            ;;
    esac
done

TAG="v$VERSION"
ZIP="KeebLock-$VERSION.zip"

# --- Sanity ------------------------------------------------------------------
if [ -n "$(git status --porcelain)" ]; then
    echo "error: working tree is dirty. commit or stash first." >&2
    exit 1
fi
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
    echo "error: not on main (you're on $BRANCH)" >&2
    exit 1
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "error: tag $TAG already exists locally — pick a different version" >&2
    exit 1
fi
if ! command -v tea >/dev/null 2>&1; then
    echo "error: tea (forgejo/gitea cli) not found — install it first" >&2
    exit 1
fi

# --- Tag + push --------------------------------------------------------------
echo "==> Tagging $TAG"
git tag -a "$TAG" -m "Release $VERSION"
git push origin "$TAG"

# --- Build Release with version pinned ---------------------------------------
echo "==> Building Release $VERSION"
VERSION="$VERSION" scripts/build.sh release

APP="build/DerivedData/Build/Products/Release/KeebLock.app"
if [ ! -d "$APP" ]; then
    echo "error: build did not produce $APP" >&2
    exit 1
fi

# --- Package -----------------------------------------------------------------
echo "==> Packaging $ZIP"
rm -f "$ZIP"
# `ditto -c -k --keepParent` preserves macOS metadata + extended attributes;
# downloaders extracting via Finder/`unzip` get a working signed bundle.
ditto -c -k --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
SIZE_KB="$(du -k "$ZIP" | awk '{print $1}')"

echo "    file:  $ZIP"
echo "    size:  ${SIZE_KB} KB"
echo "    sha:   $SHA"

# --- Code-signature identity -------------------------------------------------
# The (Team ID, CDHash) pair pinned to this build is the actual fake-proof
# anchor — `shasum` of the zip catches transit corruption, but only the OS-
# verified codesign identity proves the binary was produced with bmmmm's
# Apple cert. Both values get embedded in the release notes so users can
# compare them with what `codesign -dv` reports against their installed copy.
CS_OUT="$(codesign -dv --verbose=4 "$APP" 2>&1)"
TEAM_ID="$(printf '%s\n' "$CS_OUT" | awk -F= '/^TeamIdentifier=/ {print $2}')"
CD_HASH="$(printf '%s\n' "$CS_OUT" | awk -F= '/^CDHash=/ {print $2}')"
if [ -z "$TEAM_ID" ] || [ -z "$CD_HASH" ]; then
    echo "error: codesign did not yield TeamIdentifier and/or CDHash for $APP" >&2
    echo "       output was:" >&2
    printf '%s\n' "$CS_OUT" | sed 's/^/         /' >&2
    exit 1
fi
echo "    team:  $TEAM_ID"
echo "    cdh:   $CD_HASH"

AUTHENTICITY_BLOCK="$(cat <<EOF
### Authenticity

This release is signed with bmmmm's Apple Personal Team. To confirm your copy
is genuine (not a re-host), run:

\`\`\`
codesign -dv --verbose=4 /Applications/KeebLock.app 2>&1 | grep -E '^(TeamIdentifier|CDHash)='
\`\`\`

Expected output for **$TAG**:

\`\`\`
TeamIdentifier=$TEAM_ID
CDHash=$CD_HASH
\`\`\`

\`TeamIdentifier\` is constant across every official KeebLock release —
forging it requires bmmmm's Apple signing cert. \`CDHash\` is unique to this
build. Both values are also surfaced in the launcher footer of the app itself
for an in-GUI side-by-side check.
EOF
)"

# --- Release notes -----------------------------------------------------------
if [ -n "$CUSTOM_NOTES" ]; then
    NOTES="$CUSTOM_NOTES

$AUTHENTICITY_BLOCK"
else
    NOTES="$(cat <<EOF
**KeebLock $VERSION** — locks the keyboard while you clean it.

### Install

1. Download \`$ZIP\` and unzip — you get \`KeebLock.app\`.
2. Move \`KeebLock.app\` into \`/Applications\`.
3. The app is signed with a Personal Team certificate (no Apple Developer
   ID Notarisation), so Gatekeeper will refuse to launch it on first try.
   To clear the quarantine flag once:

       xattr -dr com.apple.quarantine /Applications/KeebLock.app

   Then right-click → **Open** → **Open** to confirm. After that the app
   launches normally.
4. Grant Accessibility permission when KeebLock asks (System Settings →
   Privacy & Security → Accessibility).

### Verify download

\`\`\`
shasum -a 256 $ZIP
# $SHA  $ZIP
\`\`\`

$AUTHENTICITY_BLOCK

### Source

- https://github.com/bmmmm/KeebLock (mirror)
- https://git.home/your-org/KeebLock  (origin, internal)
EOF
)"
fi

# --- Publish via Forgejo CLI -------------------------------------------------
# Use `tea` rather than `fj` because (a) tea's auth picks up the API URL
# correctly while fj derives it from the SSH remote and lands on port 2222
# for HTTPS, and (b) tea must run from outside the repo when the repo's
# .git/config has the worktree extension enabled (Claude agent worktrees
# trigger "core.repositoryformatversion does not support extension:
# worktreeconfig"). We invoke tea from $HOME with --repo.
ZIP_ABS="$(pwd)/$ZIP"
echo "==> Publishing release on Forgejo"
( cd "$HOME" && tea releases create "$TAG" \
      --repo your-org/KeebLock \
      --title "KeebLock $VERSION" \
      --note "$NOTES" )
( cd "$HOME" && tea releases assets create "$TAG" "$ZIP_ABS" --repo your-org/KeebLock )

echo
echo "==> Done."
echo "    Forgejo: http://git.home/your-org/KeebLock/releases/tag/$TAG"
echo "    GitHub mirror sync usually within minutes."
