#!/bin/bash
# Sanity checks for the installer scripts; runs anywhere bash runs (Linux box or Mac, no network, touches nothing):
# bash -n on every script, shellcheck when installed, the template placeholders, a rendered copy, and install.sh's
# argument checks (they fail with exit 2 before anything macOS-specific runs).
set -eu
cd "$(dirname "$0")"
fails=0
pass() { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fails=$((fails + 1)); }

for f in install.template.sh uninstall.sh package.sh check.sh flow-test.sh; do
  if bash -n "$f" 2>/tmp/recitbot-check.$$; then pass "bash -n $f"; else bad "bash -n $f" "$(cat /tmp/recitbot-check.$$)"; fi
done
rm -f /tmp/recitbot-check.$$
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -s bash -S warning install.template.sh uninstall.sh package.sh; then pass shellcheck; else bad shellcheck "see above"; fi
else
  echo "SKIP shellcheck (not installed)"
fi

for p in __RECORDER_ZIP_SHA256__ __RECORDER_VERSION__; do
  if grep -q "'$p'" install.template.sh; then pass "placeholder $p"; else bad "placeholder $p" missing; fi
done
if grep -q '__FFMPEG' install.template.sh; then bad "no ffmpeg placeholders" "found"; else pass "no ffmpeg placeholders"; fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sed -e "s/__RECORDER_ZIP_SHA256__/$(printf 'a%.0s' $(seq 64))/" -e 's/__RECORDER_VERSION__/0.5.0/' install.template.sh >"$work/install.sh"
if bash -n "$work/install.sh" && ! grep -q '__RECORDER' "$work/install.sh"; then pass "rendered install.sh"; else bad "rendered install.sh" "placeholders left or syntax"; fi

# expect <name> <exit> <line> -- args...: runs the rendered script with HOME in the scratch folder.
expect() {
  local name=$1 want=$2 line=$3 out rc
  shift 3
  rc=0
  out=$(HOME="$work/home" AGENT_RECORDER_INSTALL_DIR="$work/data" RECITBOT_PAIRING_CODE="${CODE_ENV:-}" /bin/bash "$work/install.sh" "$@" 2>&1) || rc=$?
  if [ "$rc" = "$want" ] && [ "$out" = "$line" ]; then pass "$name"; else bad "$name" "exit $rc, output: $out"; fi
}
mkdir -p "$work/home"
expect "no server" 2 'RECITBOT_INSTALL_FAILED: Missing -Server.'
expect "http server" 2 'RECITBOT_INSTALL_FAILED: Server must be https.' --server http://example.com --code ABCDEFGHIJ12
expect "http loopback lookalike" 2 'RECITBOT_INSTALL_FAILED: Server must be https.' --server http://localhost.example.com --code ABCDEFGHIJ12
expect "bad server chars" 2 'RECITBOT_INSTALL_FAILED: Invalid URI: The format of the URI could not be determined.' --server 'https://a b' --code ABCDEFGHIJ12
expect "userinfo" 2 'RECITBOT_INSTALL_FAILED: Invalid URI: The format of the URI could not be determined.' --server 'https://u@recitbot.com' --code ABCDEFGHIJ12
expect "no scheme" 2 'RECITBOT_INSTALL_FAILED: Invalid URI: The format of the URI could not be determined.' --server recitbot.com --code ABCDEFGHIJ12
expect "short code" 2 'RECITBOT_INSTALL_FAILED: Invalid pairing code.' --server https://recitbot.com --code ABC
expect "code chars" 2 'RECITBOT_INSTALL_FAILED: Invalid pairing code.' -Server https://recitbot.com -Code 'ABCDEFGHIJ;1'
expect "missing code" 2 'RECITBOT_INSTALL_FAILED: Missing pairing code. Call get_installer for a new command.' --server https://recitbot.com
expect "update without install" 2 "RECITBOT_INSTALL_FAILED: No paired recorder in $work/data to update. Call get_installer for a new command." --server https://recitbot.com/ --update
expect "-Update without install" 2 "RECITBOT_INSTALL_FAILED: No paired recorder in $work/data to update. Call get_installer for a new command." -Server https://recitbot.com -Update
expect "unknown argument" 2 'RECITBOT_INSTALL_FAILED: Unknown argument: --bogus' --server https://recitbot.com --bogus
expect "missing value" 2 'RECITBOT_INSTALL_FAILED: Missing value for --server.' --server
expect "bad account" 2 'RECITBOT_INSTALL_FAILED: Invalid account.' --server https://recitbot.com --code ABCDEFGHIJ12 --account 'a b'
expect "missing account value" 2 'RECITBOT_INSTALL_FAILED: Missing value for -Account.' -Server https://recitbot.com -Account
if [ "$(uname -s)" != Darwin ]; then
  expect "not macOS (args ok)" 5 'RECITBOT_INSTALL_FAILED: This installer is for macOS.' --server https://recitbot.com --code ABCDEFGHIJ12
  expect "loopback http ok" 5 'RECITBOT_INSTALL_FAILED: This installer is for macOS.' --server http://127.0.0.1:8787 --code ABCDEFGHIJ12
  expect "ipv6 loopback ok" 5 'RECITBOT_INSTALL_FAILED: This installer is for macOS.' --server 'http://[::1]:8787/' --code ABCDEFGHIJ12
  CODE_ENV=ABCDEFGHIJ12 expect "code from env" 5 'RECITBOT_INSTALL_FAILED: This installer is for macOS.' --server https://recitbot.com
  CODE_ENV='ABC;' expect "bad code from env" 2 'RECITBOT_INSTALL_FAILED: Invalid pairing code.' --server https://recitbot.com
fi
if [ -e "$work/home/Applications" ] || [ -e "$work/data" ]; then bad "argument failures touch nothing" "files created"; else pass "argument failures touch nothing"; fi

# install.sh's update health block on its own (parity: AgentRecorder.cs UpdateHealth.Decide, same table as its selftest).
uh=$(sed -n '/^# --- update health/,/^# --- end update health/p' install.template.sh)
if [ -n "$uh" ] && ( eval "$uh"
  printf 'version=0.7.0\n' >"$work/marker"; printf 'version=0.7.0x\n' >"$work/bad"
  [ "$(marker_version "$work/marker")" = 0.7.0 ] && [ -z "$(marker_version "$work/bad")" ] && [ -z "$(marker_version "$work/none")" ] \
  && [ "$(update_health 0.7.0 0.7.0 1 10 90)" = healthy ] && [ "$(update_health 0.7.0 0.7.0 0 95 90)" = healthy ] \
  && [ "$(update_health '' 0.7.0 1 0 90)" = wait ] && [ "$(update_health '' 0.7.0 1 89 90)" = wait ] \
  && [ "$(update_health '' 0.7.0 1 90 90)" = rollback ] && [ "$(update_health 0.6.1 0.7.0 1 95 90)" = rollback ] \
  && [ "$(update_health '' 0.7.0 0 3 90)" = rollback ] && write_rollback "$work" 0.7.0 && [ "$(cat "$work/update-rollback.txt")" = 'version=0.7.0' ] ); then
  pass "update health decision and rollback record"
else bad "update health decision and rollback record" "block missing or a case differs"; fi

if [ "$(uname -s)" != Darwin ]; then bash flow-test.sh || fails=$((fails + 1)); fi
echo "check: $fails failed"
[ "$fails" = 0 ]
