#!/bin/bash
# Builds Recitbot.app in the package root and signs it (hardened runtime + entitlements). Does NOT launch the app.
#
# Signing identity: when $RECITBOT_SIGNING_DIR (default ./signing) holds recitbot-dev.keychain-db (made by
# signing/make-identity.sh, which writes next to itself; password in recitbot-dev.keychain-pass, 0600), the app is signed with the self-signed "Recitbot Dev Signing" certificate
# in that keychain (passed with --keychain; never added to the keychain search list, the login keychain is not used).
# A fixed identity gives the app a stable designated requirement, so a Screen Recording grant survives rebuilds and
# updates. Without that keychain: ad-hoc (-), whose requirement is the cdhash (every build needs a fresh grant).
set -euo pipefail
cd "$(dirname "$0")"

nice -n 10 swift build -c release
BIN="$(swift build -c release --show-bin-path)/Recitbot"
[ -x "$BIN" ] || { echo "binary not found: $BIN" >&2; exit 1; }

APP="Recitbot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Recitbot"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

SIGNING_DIR="${RECITBOT_SIGNING_DIR:-$(pwd)/signing}"
KC="$SIGNING_DIR/recitbot-dev.keychain-db"
KCPASS="$SIGNING_DIR/recitbot-dev.keychain-pass"
IDENTITY="Recitbot Dev Signing"
if [ -f "$KC" ] && [ -f "$KCPASS" ]; then
  security unlock-keychain -p "$(cat "$KCPASS")" "$KC"
  # By SHA-1: the self-signed certificate is not trusted for code signing, and a name lookup only sees valid identities.
  SHA1=$(security find-certificate -c "$IDENTITY" -Z "$KC" | sed -n 's/^SHA-1 hash: //p' | head -n 1)
  [ -n "$SHA1" ] || { echo "no \"$IDENTITY\" certificate in $KC" >&2; exit 1; }
  echo "--- signing with \"$IDENTITY\" ($SHA1) from $KC"
  codesign --force --keychain "$KC" -s "$SHA1" --identifier com.recitbot.agent --options runtime --timestamp=none \
    --entitlements Recitbot.entitlements "$APP"
  security lock-keychain "$KC"
else
  echo "--- signing ad-hoc (no $KC)"
  codesign --force -s - --options runtime --entitlements Recitbot.entitlements "$APP"
fi

echo "--- plutil"
plutil -lint "$APP/Contents/Info.plist"
plutil -lint Recitbot.entitlements
echo "--- codesign -dv"
codesign -dv --verbose=2 "$APP" 2>&1
echo "--- designated requirement"
codesign -d -r- "$APP" 2>&1
echo "--- entitlements"
codesign -d --entitlements - "$APP" 2>&1
echo "--- verify"
codesign --verify --strict --verbose=2 "$APP" 2>&1

echo "Built: $(pwd)/$APP (not launched)"
