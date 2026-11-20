#!/bin/bash
# Writes or checks SHA256SUMS for release artifacts.
#
#   scripts/sha256sums.sh [DIR...]          write DIR/SHA256SUMS for every regular file in DIR (default: dist macos/dist)
#   scripts/sha256sums.sh --check [DIR...]  verify DIR/SHA256SUMS (exit 1 on any mismatch or missing file)
#
# Format is the standard `sha256sum` one ("<lower-case hex>  <name>", sorted by name, LF), so a user can verify a
# download with `sha256sum -c SHA256SUMS` (Linux/Git Bash), `shasum -a 256 -c SHA256SUMS` (macOS) or compare
# `Get-FileHash -Algorithm SHA256 <file>` (PowerShell) by hand. Release notes and signed tags carry the same lines.
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v sha256sum >/dev/null 2>&1; then
  SUM=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
  SUM=(shasum -a 256)
else
  echo "need sha256sum or shasum" >&2
  exit 1
fi

check=0
if [ "${1:-}" = "--check" ]; then
  check=1
  shift
fi
[ "$#" -gt 0 ] || set -- dist macos/dist

status=0
for dir in "$@"; do
  if [ ! -d "$dir" ]; then
    echo "skip: $dir (not built)" >&2
    continue
  fi
  if [ "$check" = 1 ]; then
    [ -f "$dir/SHA256SUMS" ] || { echo "$dir/SHA256SUMS missing" >&2; status=1; continue; }
    (cd "$dir" && "${SUM[@]}" -c SHA256SUMS) || status=1
  else
    tmp=$(mktemp)
    (
      cd "$dir"
      find . -maxdepth 1 -type f ! -name SHA256SUMS -print | sed 's|^\./||' | LC_ALL=C sort |
        while IFS= read -r f; do "${SUM[@]}" "$f"; done
    ) >"$tmp"
    mv "$tmp" "$dir/SHA256SUMS"
    echo "$dir/SHA256SUMS:"
    cat "$dir/SHA256SUMS"
  fi
done
exit "$status"
