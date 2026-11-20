#!/bin/bash
# Makes the fixed dev signing identity build-app.sh uses: a self-signed code-signing certificate ("Recitbot Dev Signing",
# 10 years) and its key in signing/recitbot-dev.keychain-db, a keychain file of its own with a random password kept only
# in signing/recitbot-dev.keychain-pass (0600). Never touches the login keychain: the user's keychain search list is put
# back exactly as it was (security create-keychain appends to it), and codesign is pointed at the file with --keychain.
# The key may be used by codesign without a prompt (partition list apple-tool:,apple:,codesign:). Refuses to overwrite.
set -euo pipefail
cd "$(dirname "$0")"
KC="$(pwd)/recitbot-dev.keychain-db"
PASSF="$(pwd)/recitbot-dev.keychain-pass"
NAME="Recitbot Dev Signing"
[ ! -e "$KC" ] || { echo "$KC exists; not replacing it" >&2; exit 1; }
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

openssl rand -hex 24 >"$PASSF"
chmod 600 "$PASSF"
PASS=$(cat "$PASSF")
P12PASS=$(openssl rand -hex 16)

cat >"$work/req.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
O = Recitbot
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
/usr/bin/openssl req -new -x509 -days 3650 -newkey rsa:2048 -nodes -keyout "$work/key.pem" -out "$work/cert.pem" \
  -config "$work/req.cnf" -sha256 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$NAME" -out "$work/id.p12" \
  -passout "pass:$P12PASS" 2>/dev/null

before=$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')
restore() {
  # shellcheck disable=SC2086
  local IFS=$'\n'
  security list-keychains -d user -s $before
}
security create-keychain -p "$PASS" "$KC"
restore
security set-keychain-settings "$KC"            # no auto-lock timeout; build-app.sh unlocks and locks it
security unlock-keychain -p "$PASS" "$KC"
security import "$work/id.p12" -k "$KC" -P "$P12PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null
security lock-keychain "$KC"
after=$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')
[ "$before" = "$after" ] || { echo "keychain search list changed: $after" >&2; exit 1; }
security find-certificate -c "$NAME" -Z "$KC" | sed -n 's/^SHA-1 hash: /SHA-1 /p'
echo "identity \"$NAME\" in $KC (search list unchanged)"
