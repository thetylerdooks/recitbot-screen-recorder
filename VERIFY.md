# Verifying a build

Every release lists SHA-256 hashes (`SHA256SUMS`, written by `scripts/sha256sums.sh`) for the artifacts built from
the tagged source.

## Windows

The Windows build is reproducible: same source + pinned compiler (`Microsoft.Net.Compilers.Toolset` 4.14.0) + pinned
.NET Framework 4.8 reference assemblies, compiled with `-deterministic -pathmap:<repo>=/src`, gives the same bytes on
any machine and any checkout path.

```sh
git checkout v0.6.1
node build/build-windows.mjs      # on Linux/macOS: needs a .NET 9 runtime (`dotnet`, or DOTNET=/path/to/dotnet)
cat dist/hashes.json              # agent_recorder_exe_sha256, recorder_zip_sha256, install_ps1_sha256
```

Compare:

- `agent_recorder_exe_sha256` with the hash of `AgentRecorder.exe` inside the published `recorder.zip`;
- `recorder_zip_sha256` with the published `recorder.zip`;
- `install_ps1_sha256` with the installer the server serves (`install.ps1`), which is also the hash the install command
  checks before running it.

The Windows exe is currently not Authenticode-signed, so the hashes compare directly.

## macOS

`macos/build-app.sh` builds with path prefix maps (no absolute build paths in the binary), zeroed object timestamps
and single-threaded code generation. Given the same Swift toolchain and SDK (recorded in the release notes:
`swift --version`, `xcrun --show-sdk-version`), the unsigned Mach-O is byte-identical **when the checkout's absolute
path has the same length** as the release build's: Swift bakes the length of each source file's path (not the path
itself) into a few runtime checks. The release notes give the length of the release build's `macos` folder path;
check out at a path of that length (for example pad a folder name) to reproduce it exactly. At another length only
those few instructions, the UUID and the linker signature differ. The shipped app is code-signed, so compare after
removing the signature from a copy:

```sh
cp -R /path/to/shipped/Recitbot.app /tmp/shipped.app
codesign --remove-signature /tmp/shipped.app/Contents/MacOS/Recitbot
shasum -a 256 /tmp/shipped.app/Contents/MacOS/Recitbot macos/.build/release/Recitbot
```

The zip (`Recitbot-mac-<version>.zip`) and the rendered `install.sh` hashes are in `macos/dist/hashes.txt` after
`installer/package.sh`.
