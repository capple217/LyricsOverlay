#!/usr/bin/env bash
# Build LyricsOverlay.app.   bash build.sh          → build/LyricsOverlay.app
#                            bash build.sh install  → also copy to ~/Applications and launch
#
# The bundle is assembled and signed in a temp dir outside ~/Documents: files there
# (especially with iCloud Desktop & Documents) pick up Finder/provenance extended
# attributes, which codesign rejects ("resource fork, Finder information, or similar detritus").
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Command Line Tools with: xcode-select --install" >&2
  exit 1
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/lyricsoverlay.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/LyricsOverlay.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat Info.plist > "$APP/Contents/Info.plist"   # cat, not cp: don't carry xattrs over

echo "Compiling…"
xcrun swiftc -O -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework ServiceManagement \
  Sources/LyricsOverlay.swift \
  -o "$APP/Contents/MacOS/LyricsOverlay"

xattr -cr "$APP"
codesign --force --sign - "$APP"
codesign --verify "$APP"
echo "Signed OK"

if [[ "${1:-}" == "install" ]]; then
  pkill -x LyricsOverlay 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/LyricsOverlay.app"
  ditto --norsrc --noextattr "$APP" "$HOME/Applications/LyricsOverlay.app"
  open "$HOME/Applications/LyricsOverlay.app"
  echo "Installed to ~/Applications/LyricsOverlay.app and launched."
else
  rm -rf build/LyricsOverlay.app
  mkdir -p build
  ditto --norsrc --noextattr "$APP" build/LyricsOverlay.app
  echo "Built build/LyricsOverlay.app"
fi
