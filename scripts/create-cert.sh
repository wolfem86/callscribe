#!/bin/bash
# Creates (or restores) the self-signed "CallScribe Local" code-signing certificate in the login keychain.
# No admin rights needed. Idempotent: does nothing if the certificate is already there.
#
# - New certificate: RSA 2048, 10 years, codeSigning EKU, made with /usr/bin/openssl (LibreSSL).
# - A password-protected .p12 backup is kept in ~/Library/Application Support/CallScribe/Signing/,
#   and its random password is stored in the login keychain (service com.wolfem86.callscribe.p12).
# - If the certificate goes missing from the keychain, it's restored from that backup, so the
#   signing identity (and with it every macOS permission) stays the same.
set -euo pipefail

NAME="CallScribe Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
BACKUP_DIR="$HOME/Library/Application Support/CallScribe/Signing"
P12="$BACKUP_DIR/CallScribe-Local.p12"
SERVICE="com.wolfem86.callscribe.p12"
ACCOUNT="callscribe"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Signing certificate \"$NAME\" is already in the login keychain."
  exit 0
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

import_p12() {
  local password="$1"
  security import "$P12" -k "$KEYCHAIN" -f pkcs12 -P "$password" -T /usr/bin/codesign >/dev/null
}

if [ -f "$P12" ]; then
  echo "Restoring \"$NAME\" from the backup in $BACKUP_DIR…"
  PASSWORD="$(security find-generic-password -s "$SERVICE" -a "$ACCOUNT" -w "$KEYCHAIN" 2>/dev/null || true)"
  if [ -z "$PASSWORD" ]; then
    echo "ERROR: the backup's password is missing from the keychain, so the backup can't be restored." >&2
    echo "Move $P12 aside and run this again to create a new certificate (you'll need to re-grant permissions once)." >&2
    exit 1
  fi
  import_p12 "$PASSWORD"
  echo "Restored."
  exit 0
fi

echo "Creating the \"$NAME\" code-signing certificate (valid 10 years)…"
WORK="$(mktemp -d)"
cleanup() { rm -f "$WORK/key.pem" "$WORK/cert.pem" "$WORK/cert.cnf"; rmdir "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

cat > "$WORK/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = CallScribe Local
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null

PASSWORD="$(/usr/bin/openssl rand -hex 24)"
P12PASS="$PASSWORD" /usr/bin/openssl pkcs12 -export -name "$NAME" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$P12" -passout env:P12PASS
chmod 600 "$P12"

security add-generic-password -U -s "$SERVICE" -a "$ACCOUNT" -l "CallScribe signing backup" -w "$PASSWORD" "$KEYCHAIN"
import_p12 "$PASSWORD"

echo "Created \"$NAME\" and saved a backup to $P12."
echo "The first time codesign uses it, macOS may ask for your login keychain password — choose \"Always Allow\"."
