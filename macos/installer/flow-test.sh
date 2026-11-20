#!/bin/bash
# install.sh / uninstall.sh flow test on Linux (the build box has no Mac): stub uname, sw_vers, curl, shasum, ditto,
# xattr, plutil and launchctl, a fake Recitbot.app whose binary is a script (enroll reads the code on stdin, adds its
# account to config.dat and prints device=<id>; the agent writes agent.pid), then: install, re-run, add an account to
# a running install of the same version (nothing stopped), update an older app in place (accounts kept), update,
# --no-autostart, self-update copy (detached, deletes itself), hash mismatch, failed update / pairing recovery,
# --update rollback (the new agent never writes update-health.txt), uninstall. Needs perl, tar, sha256sum. Touches only a mktemp folder.
set -eu
[ "$(uname -s)" != Darwin ] || { echo "SKIP flow-test (stubs shadow real macOS tools; run on Linux)"; exit 0; }
for t in perl tar sha256sum setsid; do command -v $t >/dev/null || { echo "SKIP flow-test (no $t)"; exit 0; }; done
here=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d)
fails=0
pass() { echo "PASS flow: $1"; }
bad() { echo "FAIL flow: $1: $2"; fails=$((fails + 1)); }
agents() { ps -eo pid=,args= | awk -v w="$W" 'index($0, w "/home/Applications/Recitbot.app/Contents/MacOS/Recitbot --data") && !/awk/ {print $1}'; }
finish() { for p in $(agents); do kill -9 "$p" 2>/dev/null || true; done; rm -rf "${W:?}"; }
trap finish EXIT

mkdir -p "$W/bin" "$W/pkg/Recitbot.app/Contents/MacOS" "$W/home" "$W/srv" "$W/tmp"
cat >"$W/pkg/Recitbot.app/Contents/MacOS/Recitbot" <<'EOF'
#!/bin/bash
data=""; enroll=0
while [ $# -gt 0 ]; do case "$1" in --data) data=$2; shift 2 ;; --enroll) enroll=1; shift ;; *) shift ;; esac; done
if [ "$enroll" = 1 ]; then
  read -r code
  case "$code" in GOODCODE1234) d=dev_42 ;; OTHERCODE123) d=dev_43 ;; *) exit 5 ;; esac
  [ -f "$data/config.dat" ] || printf 'config_version=2\n' >"$data/config.dat"
  grep -q "device_id=$d\$" "$data/config.dat" || echo "account.$(grep -c 'device_id=' "$data/config.dat").device_id=$d" >>"$data/config.dat"
  echo "device=$d"
  exit 0
fi
[ -f "$data/config.dat" ] || exit 3
echo $$ >"$data/agent.pid"
# The real agent writes this after its first hello (UpdateHealth); a bundle with a "nohealth" file never says hello.
if [ ! -e "$(dirname "$0")/../nohealth" ]; then
  printf 'version=%s\n' "$(sed -n '/<key>CFBundleShortVersionString<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "$(dirname "$0")/../Info.plist")" >"$data/update-health.txt"
fi
trap 'exit 0' TERM
while :; do sleep 0.2; done
EOF
chmod +x "$W/pkg/Recitbot.app/Contents/MacOS/Recitbot"
printf '<plist><dict>\n<key>CFBundleShortVersionString</key>\n<string>0.5.0</string>\n</dict></plist>\n' >"$W/pkg/Recitbot.app/Contents/Info.plist"
echo 'echo uninstall' >"$W/pkg/uninstall.sh"
tar -C "$W/pkg" -cf "$W/srv/Recitbot-mac-0.5.0.zip" Recitbot.app uninstall.sh
cp "$W/srv/Recitbot-mac-0.5.0.zip" "$W/good.zip"
H=$(sha256sum "$W/good.zip" | cut -c1-64)
sed -e "s/__RECORDER_ZIP_SHA256__/$H/" -e 's/__RECORDER_VERSION__/0.5.0/' "$here/install.template.sh" >"$W/install.sh"

printf '#!/bin/bash\necho Darwin\n' >"$W/bin/uname"
printf '#!/bin/bash\necho 15.1\n' >"$W/bin/sw_vers"
printf '#!/bin/bash\nexit 0\n' >"$W/bin/xattr"
# open (the Screen Recording pre-request) and tccutil (uninstall) only record how they were called.
printf '#!/bin/bash\necho "$*" >>"%s/opens"\n' "$W" >"$W/bin/open"
printf '#!/bin/bash\necho "$*" >>"%s/tcc"\n' "$W" >"$W/bin/tccutil"
# plutil -extract <key> raw -o - <file>: the value of <key> in the fake Info.plist; anything else (-lint) passes.
cat >"$W/bin/plutil" <<'EOF'
#!/bin/bash
if [ "$1" = -extract ]; then sed -n "/<key>$2<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}" "$6"; exit 0; fi
exit 0
EOF
printf '#!/bin/bash\nshift 2; sha256sum "$@"\n' >"$W/bin/shasum"
printf '#!/bin/bash\nif [ "$1" = -x ]; then tar -C "$4" -xf "$3"; else cp -R "$1" "$2"; fi\n' >"$W/bin/ditto"
cat >"$W/bin/curl" <<EOF
#!/bin/bash
while [ \$# -gt 0 ]; do case "\$1" in -o) o=\$2; shift 2 ;; --proto|--connect-timeout|--max-time|--retry) shift 2 ;; *) u=\$1; shift ;; esac; done
cp "$W/srv/\${u##*/}" "\$o"
EOF
# launchd spawns jobs with default signal dispositions, in their own session.
cat >"$W/bin/launchctl" <<EOF
#!/bin/bash
echo "\$1" >>"$W/calls"
case "\$1" in
  bootstrap) [ -f "$W/loaded" ] && exit 5; touch "$W/loaded"
    perl -MPOSIX -e '\$SIG{HUP}=\$SIG{TERM}="DEFAULT"; POSIX::setsid(); exec @ARGV' \\
      "$W/home/Applications/Recitbot.app/Contents/MacOS/Recitbot" --data "$W/home/Library/Application Support/Recitbot" </dev/null >/dev/null 2>&1 &
    echo \$! >"$W/jobpid" ;;
  bootout) [ -f "$W/loaded" ] || exit 3; rm -f "$W/loaded"; kill "\$(cat "$W/jobpid")" 2>/dev/null; sleep 0.3 ;;
esac
exit 0
EOF
chmod +x "$W/bin/"*

# run <expected exit> <expected first word of the line> [env...] -- args
out=''
run() {
  local want=$1 rc=0
  shift
  out=$(env PATH="$W/bin:$PATH" HOME="$W/home" TMPDIR="$W/tmp" "$@" </dev/null 2>&1) || rc=$?
  [ "$rc" = "$want" ]
}
count() { agents | wc -l | tr -d ' '; }
calls() { tr '\n' ' ' <"$W/calls" | sed 's/ $//'; }

: >"$W/calls"
if run 0 RECITBOT_PAIRING_CODE=GOODCODE1234 /bin/bash "$W/install.sh" --server https://recitbot.com/ \
  && [ "$out" = 'RECITBOT_INSTALL_OK device=dev_42 version=0.5.0 autostart=logon' ] && [ "$(count)" = 1 ] \
  && [ "$(calls)" = 'bootout bootstrap kickstart' ]; then pass install; else bad install "$out / $(calls) / $(count) agents"; fi
app="$W/home/Applications/Recitbot.app"
[ "$(cat "$W/opens" 2>/dev/null)" = "-n -g -a $app --args --request-screen --data $W/home/Library/Application Support/Recitbot" ] \
  && pass "pairing pre-requests Screen Recording (in the background)" || bad "pre-request" "$(cat "$W/opens" 2>/dev/null)"
plist="$W/home/Library/LaunchAgents/com.recitbot.agent.plist"
for k in '<string>com.recitbot.agent</string>' '<key>RunAtLoad</key>' '<key>Crashed</key>' \
  '<integer>30</integer>' \
  '<string>Interactive</string>' '<key>AbandonProcessGroup</key>' '<string>--data</string>' 'agent.out.log</string>'; do
  grep -qF "$k" "$plist" || bad plist "missing $k"
done
# KeepAlive restarts on a crash only: exit 2 (already running) / 3 (not paired) must not loop every few seconds.
grep -qF '<key>SuccessfulExit</key>' "$plist" && bad plist "KeepAlive SuccessfulExit (restart loop on exit 2/3)"
[ "$(sed -n '/<key>KeepAlive<\/key>/,/<\/dict>/p' "$plist" | tr -d ' \n')" = '<key>KeepAlive</key><dict><key>Crashed</key><true/></dict>' ] \
  && pass "KeepAlive crash only" || bad "KeepAlive crash only" "$(sed -n '/<key>KeepAlive<\/key>/,/<\/dict>/p' "$plist")"
[ -x "$W/home/Library/Application Support/Recitbot/uninstall.sh" ] && pass "uninstall.sh in data folder" || bad "uninstall.sh in data folder" missing
[ "$(stat -c %a "$W/home/Library/Application Support/Recitbot")" = 700 ] && pass "data folder 0700" || bad "data folder 0700" "$(stat -c %a "$W/home/Library/Application Support/Recitbot")"

if run 0 RECITBOT_PAIRING_CODE=GOODCODE1234 /bin/bash "$W/install.sh" --server https://recitbot.com && [ "$(count)" = 1 ] \
  && [ "$(ls -A "$W/home/Applications")" = Recitbot.app ]; then pass "re-run"; else bad "re-run" "$out / $(count) agents"; fi
cfg="$W/home/Library/Application Support/Recitbot/config.dat"
: >"$W/calls"
before=$(agents)
if run 0 RECITBOT_PAIRING_CODE=OTHERCODE123 /bin/bash "$W/install.sh" --server https://recitbot.com --account acct2 \
  && [ "$out" = 'RECITBOT_INSTALL_OK device=dev_43 version=0.5.0 autostart=logon' ] && [ ! -s "$W/calls" ] && [ "$(agents)" = "$before" ] \
  && grep -q 'device_id=dev_42$' "$cfg" && grep -q 'device_id=dev_43$' "$cfg"; then
  pass "add account to a running install of the same version (nothing stopped or replaced)"
else bad "add account" "$out / $(calls) / $(count) agents / $(cat "$cfg")"; fi
run 2 RECITBOT_PAIRING_CODE=OTHERCODE123 /bin/bash "$W/install.sh" --server https://recitbot.com --account 'a;b' \
  && [ "$out" = 'RECITBOT_INSTALL_FAILED: Invalid account.' ] && pass "bad account rejected" || bad "bad account rejected" "$out"
sed -i 's/0\.5\.0/0.4.0/' "$app/Contents/Info.plist"
: >"$W/calls"
if run 0 RECITBOT_PAIRING_CODE=OTHERCODE123 /bin/bash "$W/install.sh" --server https://recitbot.com \
  && [ "$out" = 'RECITBOT_INSTALL_OK device=dev_43 version=0.5.0 autostart=logon' ] && [ "$(calls)" = 'bootout bootstrap kickstart' ] \
  && [ "$(count)" = 1 ] && grep -q '<string>0.5.0</string>' "$app/Contents/Info.plist" && grep -q 'device_id=dev_42$' "$cfg" \
  && grep -q 'device_id=dev_43$' "$cfg"; then
  pass "older app updated in place, accounts kept"
else bad "older app updated in place" "$out / $(calls) / $(cat "$cfg")"; fi
if run 0 /bin/bash "$W/install.sh" -Server https://recitbot.com -Update && [ "$(count)" = 1 ]; then pass "update keeps pairing"; else bad "update keeps pairing" "$out"; fi
: >"$W/opens"
run 0 RECITBOT_PAIRING_CODE=GOODCODE1234 /bin/bash "$W/install.sh" --server https://recitbot.com --update || bad "update with code" "$out"
run 0 RECITBOT_PAIRING_CODE=GOODCODE1234 RECITBOT_NO_SCREEN_REQUEST=1 /bin/bash "$W/install.sh" --server https://recitbot.com || bad "opt-out install" "$out"
[ ! -s "$W/opens" ] && pass "no Screen Recording request on update or opt-out" || bad "no request on update" "$(cat "$W/opens")"
if run 0 /bin/bash "$W/install.sh" --server https://recitbot.com --update --no-autostart \
  && [ "$out" = 'RECITBOT_INSTALL_OK device=dev_42 version=0.5.0 autostart=none' ] && [ "$(count)" = 1 ]; then pass "no autostart"; else bad "no autostart" "$out"; fi
# The directly started copy must stop on the next update (SIGTERM: no inherited ignore).
start=$(date +%s)
if run 0 /bin/bash "$W/install.sh" --server https://recitbot.com --update && [ "$(count)" = 1 ] && [ $(($(date +%s) - start)) -lt 8 ]; then
  pass "direct start stops on SIGTERM"; else bad "direct start stops on SIGTERM" "$out / $(count) agents"; fi

data="$W/home/Library/Application Support/Recitbot"
if [ "$(cat "$data/update-health.txt" 2>/dev/null)" = 'version=0.5.0' ] && [ ! -e "$W/home/Applications/.Recitbot.app.rollback" ] \
  && [ ! -e "$data/update-rollback.txt" ]; then pass "update: healthy new agent, backup removed, no rollback record"
else bad "update healthy" "$(ls -A "$W/home/Applications") / $(cat "$data/update-health.txt" 2>/dev/null)"; fi

# Rollback: the new app (a zip whose agent never says hello) is replaced by the previous one, which starts again.
sed -i 's/0\.5\.0/0.4.0/' "$app/Contents/Info.plist"
touch "$app/Contents/previous"
cfgsum=$(sha256sum "$cfg" | cut -c1-64)
mkdir -p "$W/pkg2" && cp -R "$W/pkg/Recitbot.app" "$W/pkg/uninstall.sh" "$W/pkg2/" && touch "$W/pkg2/Recitbot.app/Contents/nohealth"
tar -C "$W/pkg2" -cf "$W/srv/Recitbot-mac-0.5.0.zip" Recitbot.app uninstall.sh
sed -e "s/__RECORDER_ZIP_SHA256__/$(sha256sum "$W/srv/Recitbot-mac-0.5.0.zip" | cut -c1-64)/" -e 's/__RECORDER_VERSION__/0.5.0/' "$here/install.template.sh" >"$W/install-nohealth.sh"
start=$(date +%s)
if run 6 AGENT_RECORDER_HEALTH_SECONDS=5 /bin/bash "$W/install-nohealth.sh" --server https://recitbot.com --update \
  && [ "$out" = 'RECITBOT_INSTALL_FAILED: The new recorder (0.5.0) did not connect within 5 s. Rolled back to the previous version.' ] \
  && [ $(($(date +%s) - start)) -ge 5 ] && [ -e "$app/Contents/previous" ] && [ ! -e "$app/Contents/nohealth" ] \
  && grep -q '<string>0.4.0</string>' "$app/Contents/Info.plist" && [ "$(cat "$data/update-rollback.txt" 2>/dev/null)" = 'version=0.5.0' ] \
  && [ "$(ls -A "$W/home/Applications")" = Recitbot.app ] && [ "$(count)" = 1 ] && [ "$(sha256sum "$cfg" | cut -c1-64)" = "$cfgsum" ]; then
  pass "update rollback: previous app back and running, attempted version recorded, accounts untouched"
else bad "update rollback" "$out / $(ls -A "$W/home/Applications") / $(cat "$data/update-rollback.txt" 2>/dev/null) / $(count) agents"; fi
cp "$W/good.zip" "$W/srv/Recitbot-mac-0.5.0.zip"
rm -f "$app/Contents/previous" "$data/update-rollback.txt"
sed -i 's/0\.4\.0/0.5.0/' "$app/Contents/Info.plist"

cp "$W/install.sh" "$W/tmp/recitbot-update-0123456789abcdef0123456789abcdef.sh"
: >"$W/calls"
before=$(agents)
if run 0 setsid /bin/bash "$W/tmp/recitbot-update-0123456789abcdef0123456789abcdef.sh" --server https://recitbot.com --update && [ -z "$out" ]; then
  i=0
  while [ $i -lt 40 ] && [ -n "$(ls -A "$W/tmp")" ]; do sleep 0.25; i=$((i + 1)); done
  sleep 0.5
  if [ -z "$(ls -A "$W/tmp")" ] && [ "$(count)" = 1 ] && [ "$(agents)" != "$before" ] && [ "$(calls)" = 'bootout bootstrap kickstart' ]; then
    pass "self-update copy (detached, restarted, deleted itself)"
  else bad "self-update copy" "tmp: $(ls -A "$W/tmp") / $(calls) / $(count) agents"; fi
else bad "self-update copy" "parent: $out"; fi

before=$(agents)
echo x >>"$W/srv/Recitbot-mac-0.5.0.zip"
if run 3 /bin/bash "$W/install.sh" --server https://recitbot.com --update \
  && [ "$out" = 'RECITBOT_INSTALL_FAILED: SHA-256 mismatch for https://recitbot.com/Recitbot-mac-0.5.0.zip - aborting install.' ] \
  && [ "$(agents)" = "$before" ]; then pass "hash mismatch leaves the recorder running"; else bad "hash mismatch" "$out"; fi
cp "$W/good.zip" "$W/srv/Recitbot-mac-0.5.0.zip"

if run 4 RECITBOT_PAIRING_CODE=BADCODE12345 /bin/bash "$W/install.sh" --server https://recitbot.com --update \
  && [ "${out%%:*}" = RECITBOT_INSTALL_FAILED ] && [ "$(count)" = 1 ]; then pass "failed update restarts the recorder"; else bad "failed update recovery" "$out / $(count)"; fi
before=$(agents)
if run 4 RECITBOT_PAIRING_CODE=BADCODE12345 /bin/bash "$W/install.sh" --server https://recitbot.com && [ "$(agents)" = "$before" ] \
  && grep -q 'device_id=dev_43$' "$cfg"; then
  pass "failed pairing keeps the running recorder and its accounts"; else bad "failed pairing keeps the recorder" "$out / $(count)"; fi
case "$out" in *BADCODE*) bad "code never printed" "$out" ;; *) pass "code never printed" ;; esac
sed -i 's/0\.5\.0/0.4.0/' "$app/Contents/Info.plist"
if run 4 RECITBOT_PAIRING_CODE=BADCODE12345 /bin/bash "$W/install.sh" --server https://recitbot.com && [ "$(count)" = 1 ] \
  && grep -q 'device_id=dev_42$' "$cfg"; then
  pass "failed pairing after an in-place update restarts the recorder with its accounts"; else bad "failed pairing after update" "$out / $(count)"; fi
run 0 /bin/bash "$here/uninstall.sh" || bad "uninstall before fresh install" "$out"
if run 4 RECITBOT_PAIRING_CODE=BADCODE12345 /bin/bash "$W/install.sh" --server https://recitbot.com && [ "$(count)" = 0 ]; then
  pass "failed fresh install pairing (no recovery, as ps1)"; else bad "failed fresh install pairing" "$out / $(count)"; fi

run 0 RECITBOT_PAIRING_CODE=GOODCODE1234 /bin/bash "$W/install.sh" --server https://recitbot.com || bad "reinstall" "$out"
rm -f "$W/tcc"
if run 0 /bin/bash "$here/uninstall.sh" && [ "$(count)" = 0 ] && [ ! -e "$plist" ] && [ ! -e "$W/home/Applications/Recitbot.app" ] \
  && [ ! -e "$W/home/Library/Application Support/Recitbot" ]; then pass uninstall; else bad uninstall "$out / $(count)"; fi
[ "$(cat "$W/tcc" 2>/dev/null)" = "reset All com.recitbot.agent" ] && pass "uninstall resets privacy rows" || bad "uninstall tccutil" "$(cat "$W/tcc" 2>/dev/null)"

echo "flow-test: $fails failed"
[ "$fails" = 0 ]
