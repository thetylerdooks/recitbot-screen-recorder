#!/bin/bash
# Packages the Mac recorder for the Worker (twin of kit-install scripts/build-recorder-zip.mjs). Run on a Mac after
# build-app.sh. Writes into OUT (default dist/):
#   Recitbot-mac-<version>.zip  Recitbot.app + uninstall.sh (ditto, keeps the bundle's signature intact)
#   install.sh                  install.template.sh with __RECORDER_ZIP_SHA256__ / __RECORDER_VERSION__ filled in
#   uninstall.sh                as is
#   hashes.txt                  INSTALL_SH_SHA256 / RECORDER_MAC_ZIP_SHA256 / RECORDER_VERSION (upper-case hex)
# Usage: installer/package.sh [OUT]
set -eu
cd "$(dirname "$0")/.."
OUT=${1:-dist}
APP=Recitbot.app
[ -x "$APP/Contents/MacOS/Recitbot" ] || { echo "build $APP first (./build-app.sh)" >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
core=$(sed -n 's/.*public static let version = "\([0-9.]*\)".*/\1/p' Sources/RecitbotCore/Program.swift)
[ "$version" = "$core" ] || { echo "Info.plist version $version != Program.version $core" >&2; exit 1; }
"$APP/Contents/MacOS/Recitbot" --selftest | tail -n 1
codesign --verify --strict "$APP"

mkdir -p "$OUT"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$APP" "$stage/$APP"
cp installer/uninstall.sh "$stage/uninstall.sh"
zip="$OUT/Recitbot-mac-$version.zip"
rm -f "$zip"
# Without --keepParent: Recitbot.app/ and uninstall.sh at the root of the archive (install.sh expects exactly that).
ditto -c -k --norsrc "$stage" "$zip"
zipHash=$(shasum -a 256 "$zip" | cut -c1-64 | tr 'a-f' 'A-F')

sed -e "s/__RECORDER_ZIP_SHA256__/$zipHash/g" -e "s/__RECORDER_VERSION__/$version/g" installer/install.template.sh >"$OUT/install.sh"
cp installer/uninstall.sh "$OUT/uninstall.sh"
bash -n "$OUT/install.sh"
installHash=$(shasum -a 256 "$OUT/install.sh" | cut -c1-64 | tr 'a-f' 'A-F')
printf 'INSTALL_SH_SHA256=%s\nRECORDER_MAC_ZIP_SHA256=%s\nRECORDER_VERSION=%s\n' "$installHash" "$zipHash" "$version" >"$OUT/hashes.txt"
echo "$(basename "$zip") $(wc -c <"$zip" | tr -d ' ') bytes sha256=$zipHash"
echo "install.sh sha256=$installHash recorder $version"
