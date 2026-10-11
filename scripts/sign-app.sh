#!/bin/bash
# Signs CallScribe.app with the stable "CallScribe Local" identity and an explicit designated requirement,
# so macOS treats every build as the same app and keeps its permissions.
# Never falls back to ad-hoc signing: if the certificate is missing, this fails.
# Usage: scripts/sign-app.sh path/to/CallScribe.app
set -euo pipefail

APP="$1"
NAME="CallScribe Local"
BUNDLE_ID="com.wolfem86.callscribe"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
ENTITLEMENTS="$(cd "$(dirname "$0")/.." && pwd)/Resources/CallScribe.entitlements"

HASH="$(security find-certificate -c "$NAME" -Z "$KEYCHAIN" 2>/dev/null | awk '/SHA-1 hash:/ { print $3; exit }')"
if [ -z "$HASH" ]; then
  echo "ERROR: signing certificate \"$NAME\" not found. Run scripts/create-cert.sh first." >&2
  exit 1
fi

REQUIREMENT="designated => identifier \"$BUNDLE_ID\" and certificate leaf = H\"$HASH\""

# Sign by hash: works with a self-signed certificate that isn't marked as trusted.
codesign --force --options runtime --timestamp=none \
  --entitlements "$ENTITLEMENTS" \
  --identifier "$BUNDLE_ID" \
  --sign "$HASH" \
  -r="$REQUIREMENT" \
  "$APP"

codesign --verify --strict "$APP"
if ! codesign -d -r - "$APP" 2>&1 | grep -qi "certificate leaf = H\"$HASH\""; then
  echo "ERROR: the signed app's designated requirement doesn't match \"$NAME\"." >&2
  codesign -d -r - "$APP" >&2 || true
  exit 1
fi
echo "Signed with \"$NAME\" (leaf $HASH)."
