#!/bin/bash
# Builds CallScribe.app with only the Command Line Tools.
#
#   scripts/build-app.sh               release build, signed with "CallScribe Local" (creates it if needed)
#   scripts/build-app.sh --dev-adhoc   release build, AD-HOC signed (development only: macOS will ask
#                                      for permissions again after every rebuild)
#   scripts/build-app.sh --unsigned    assemble only, no signing (used by the Homebrew formula;
#                                      callscribe-install signs it later)
#
# Output: build/CallScribe.app
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

SIGN_MODE=stable
for arg in "$@"; do
  case "$arg" in
    --dev-adhoc) SIGN_MODE=adhoc ;;
    --unsigned) SIGN_MODE=none ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "==> Compiling (release, arm64)"
swift build -c release --arch arm64 -j 2
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

echo "==> Icon"
if [ ! -f Resources/AppIcon.icns ]; then
  scripts/make-icon.sh Resources/AppIcon.icns
fi

echo "==> Assembling CallScribe.app $VERSION ($BUILD_NUMBER)"
STAGE="$(mktemp -d)"
APP="$STAGE/CallScribe.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CallScribe" "$APP/Contents/MacOS/CallScribe"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

case "$SIGN_MODE" in
  stable)
    scripts/create-cert.sh
    scripts/sign-app.sh "$APP"
    ;;
  adhoc)
    echo "WARNING: ad-hoc signing (development only). Permissions will NOT persist across rebuilds."
    codesign --force --options runtime --entitlements Resources/CallScribe.entitlements --sign - "$APP"
    ;;
  none)
    echo "Not signing (--unsigned)."
    ;;
esac

# Replace the previous build without deleting anything in place: move the old one into the temp dir.
mkdir -p build
if [ -e build/CallScribe.app ]; then
  mv build/CallScribe.app "$STAGE/CallScribe.previous.app"
fi
mv "$APP" build/CallScribe.app
echo "==> Built $ROOT/build/CallScribe.app"
