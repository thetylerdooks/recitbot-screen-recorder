# Agent Recorder installer (per-user, no admin, no prompts). Served by the Worker; its SHA-256 is pinned in the command
# get_installer returns and in signed recorder update commands. Every download below is verified by pinned SHA-256.
# One install serves several Recitbot accounts. With -Code on a PC whose recorder is this version or newer, it only pairs
# that account with the installed recorder (nothing is stopped, replaced or wiped; the running recorder picks the new
# account up). Otherwise (no install, an older one, or -Update) it stops the recorder, swaps the files in place (config.dat
# and its paired accounts stay), pairs -Code's account (added next to the others, or refreshed), re-registers autostart
# and restarts it. A failed pairing leaves the recorder running with the accounts it already had. -Account names the
# account the code is for, so a re-pair sends that account's own device token. The AgentRecorder logon task is only
# registered when it does not exist or already starts this install's exe: a task of another copy is never re-pointed or
# removed.
# install-options.txt next to the exe records autostart (logon|none) and -DeviceName for the recorder's self-update,
# which passes -NoAutostart / -DeviceName back.
# Prints one line: `RECITBOT_INSTALL_OK device=<id> version=<v> autostart=<logon|none>`, or
# `RECITBOT_INSTALL_FAILED: <reason>` with exit code 2 (arguments, or -Update without an install), 3 (download or hash
# check), 4 (pairing), 5 (the recorder did not start) or 6 (-Update rolled back).
# -Update keeps the files it replaces in update-backup\ until the new recorder writes update-health.txt naming the new
# version (after its first hello, within AGENT_RECORDER_HEALTH_SECONDS, default 90). If it does not (or a start fails
# after the swap), the previous files go back, update-rollback.txt records the attempted version and the previous
# recorder starts again; it reports "rolled_back" on its next connect. config.dat is never part of the backup or the swap.
# -DeviceName (or AGENT_RECORDER_DEVICE_NAME) pairs under that name instead of the computer name. Test and throwaway
# installs must pass -InstallDir, -NoAutostart and -DeviceName so they never share a name with the real PC: the server's
# token-less re-pair replaces an active device with the same name and public IP.
param(
  [Parameter(Mandatory = $true)][string]$Server,
  [string]$Code,
  [switch]$Update,
  [string]$InstallDir = $(if ($env:AGENT_RECORDER_INSTALL_DIR) { $env:AGENT_RECORDER_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'AgentRecorder' }),
  [switch]$UseSystemTools = $($env:AGENT_RECORDER_USE_SYSTEM_TOOLS -eq '1'),
  [switch]$NoAutostart = $($env:AGENT_RECORDER_NO_AUTOSTART -eq '1'),
  [string]$DeviceName = $env:AGENT_RECORDER_DEVICE_NAME,
  [string]$Account = $env:RECITBOT_ACCOUNT_ID
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$RecorderZipSha256 = '__RECORDER_ZIP_SHA256__'
$RecorderVersion = '__RECORDER_VERSION__'
$FfmpegUrl = '__FFMPEG_URL__'
$FfmpegSha256 = '__FFMPEG_SHA256__'

function Get-Verified([string]$Url, [string]$Sha256, [string]$OutFile) {
  Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $OutFile
  $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutFile).Hash
  if ($actual -ne $Sha256) {
    Remove-Item -LiteralPath $OutFile -Force
    throw "SHA-256 mismatch for $Url - aborting install."
  }
}

# The recorder running from this install (by its pid file, and by path).
function Get-Recorder {
  $found = @()
  $pidFile = Join-Path $InstallDir 'agent.pid'
  if (Test-Path -LiteralPath $pidFile) {
    $p = Get-Process -Id ([int](Get-Content -LiteralPath $pidFile)) -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -eq 'AgentRecorder') { $found += $p }
  }
  $found += @(Get-Process -Name AgentRecorder -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
  $found | Sort-Object Id -Unique
}

function Stop-Recorder {
  foreach ($p in @(Get-Recorder)) {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    $p.WaitForExit(10000) | Out-Null
  }
}

# The recorder writes agent.pid once it holds its single-instance lock and has read its pairing.
function Wait-Recorder {
  $pidFile = Join-Path $InstallDir 'agent.pid'
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    if (Test-Path -LiteralPath $pidFile) {
      $p = Get-Process -Id ([int](Get-Content -LiteralPath $pidFile)) -ErrorAction SilentlyContinue
      if ($p -and $p.ProcessName -eq 'AgentRecorder') { return $true }
    }
  }
  $false
}

# --- autostart: the recorder's selftest loads this block (up to the end marker) and runs it against throwaway task
# names, so keep it free of anything but function definitions.
function Resolve-Exe([string]$p) {
  if ([string]::IsNullOrEmpty($p)) { return $null }
  try {
    $p = [Environment]::ExpandEnvironmentVariables($p).Trim().Trim('"')
    if ($p.Length -eq 0 -or -not [IO.Path]::IsPathRooted($p)) { return $null }
    return [IO.Path]::GetFullPath($p).TrimEnd('\')
  } catch { return $null }
}

# 'none' when there is no task of that name, 'ours' when every action of every such task runs $Exe (full paths,
# case-insensitive), else 'foreign': another copy's task (e.g. the real install's, seen from a throwaway).
function Get-TaskOwner([string]$TaskName, [string]$Exe) {
  $tasks = @(Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
  if ($tasks.Count -eq 0) { return 'none' }
  $self = Resolve-Exe $Exe
  foreach ($t in $tasks) {
    $acts = @($t.Actions)
    if ($acts.Count -eq 0) { return 'foreign' }
    foreach ($a in $acts) {
      $p = Resolve-Exe $a.Execute
      if (-not $p -or -not [string]::Equals($p, $self, [StringComparison]::OrdinalIgnoreCase)) { return 'foreign' }
    }
  }
  'ours'
}

# Registers the logon task for $Exe and returns 'logon', or returns 'none'. -NoAutostart never touches the task. A
# task of that name that starts another exe is never re-pointed, overwritten or removed. A failed register only cleans
# up a task that runs $Exe.
function Set-Autostart([bool]$NoAutostart, [string]$TaskName, [string]$Exe, [string]$Dir) {
  if ($NoAutostart) { return 'none' }
  if ((Get-TaskOwner $TaskName $Exe) -eq 'foreign') { return 'none' }
  try {
    $action = New-ScheduledTaskAction -Execute $Exe -Argument "--data `"$Dir`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
    return 'logon'
  } catch {
    # No task (policy, restricted shell): the recorder still runs now, it just won't start by itself at logon.
    if ((Get-TaskOwner $TaskName $Exe) -eq 'ours') { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue }
    return 'none'
  }
}
# --- end autostart

# --- add account: the recorder's selftest loads this block (up to the end marker) and runs it against copies of its own
# exe in %TEMP%, so keep it free of anything but function definitions.
# The installed recorder's version (x.y.z of its assembly version), $null when there is none or it cannot be read.
function Get-InstalledVersion([string]$Exe) {
  if (-not $Exe -or -not (Test-Path -LiteralPath $Exe)) { return $null }
  try {
    $v = [Reflection.AssemblyName]::GetAssemblyName($Exe).Version
    return "$($v.Major).$($v.Minor).$($v.Build)"
  } catch { return $null }
}

# A pairing code only adds its account when the installed recorder is this version or newer; -Update always reinstalls.
function Test-AddAccountOnly([string]$Installed, [string]$Version, [bool]$Update) {
  if ($Update -or -not $Installed) { return $false }
  try { return ([version]$Installed) -ge ([version]$Version) } catch { return $false }
}
# --- end add account

# --- update health: the recorder's selftest loads this block (up to the end marker) and runs it against throwaway
# folders in %TEMP%, so keep it free of anything but function definitions. parity: AgentRecorder.cs UpdateHealth
# What recorder.zip installs (scripts/build-recorder-zip.mjs): the files an update replaces and a rollback restores.
function Get-Payload { @('AgentRecorder.exe', 'AgentRecorder.exe.config', 'uninstall.ps1') }

# The x.y.z of the first version= line of a health marker or rollback record, $null when there is none.
function Get-MarkerVersion([string]$Path) {
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
  try { $line = @(Get-Content -LiteralPath $Path -ErrorAction Stop | Where-Object { $_ -like 'version=*' } | Select-Object -First 1) } catch { return $null }
  if ($line.Count -eq 0) { return $null }
  $v = ([string]$line[0] -replace '^version=', '').Trim()
  if ($v -match '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$') { return $v }
  $null
}

# 'healthy' when the marker names the new version; 'rollback' once the window is over or the new recorder is gone;
# else 'wait'. parity: AgentRecorder.cs UpdateHealth.Decide
function Get-UpdateHealth([string]$MarkerVersion, [string]$Version, [bool]$Running, [double]$Elapsed, [double]$Window) {
  if ($Version -and $MarkerVersion -eq $Version) { return 'healthy' }
  if (-not $Running -or $Elapsed -ge $Window) { return 'rollback' }
  'wait'
}

# Copies the payload files that exist in $Dir to a fresh $Backup; returns how many. Never config.dat.
function Backup-Install([string]$Dir, [string]$Backup) {
  if (Test-Path -LiteralPath $Backup) { Remove-Item -LiteralPath $Backup -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $Backup | Out-Null
  $n = 0
  foreach ($f in Get-Payload) {
    $src = Join-Path $Dir $f
    if (Test-Path -LiteralPath $src -PathType Leaf) { Copy-Item -LiteralPath $src -Destination (Join-Path $Backup $f) -Force; $n++ }
  }
  $n
}

# Puts the backed-up payload files back over $Dir; returns how many.
function Restore-Install([string]$Dir, [string]$Backup) {
  $n = 0
  foreach ($f in Get-Payload) {
    $src = Join-Path $Backup $f
    if (Test-Path -LiteralPath $src -PathType Leaf) { Copy-Item -LiteralPath $src -Destination (Join-Path $Dir $f) -Force; $n++ }
  }
  $n
}

# The attempted version, for the restored recorder's "rolled_back" report.
function Write-Rollback([string]$Dir, [string]$Version) {
  [IO.File]::WriteAllText((Join-Path $Dir 'update-rollback.txt'), "version=$Version`r`n")
}
# --- end update health

# Starts the recorder outside the caller's process tree, so it outlives the shell (and sandbox) that ran this script:
# through the logon task when this install registered it, else (or when the task did not start it) through WMI.
# -NoAutostart (dev, e2e, throwaway installs) starts it as a child instead.
function Start-Recorder {
  Remove-Item -LiteralPath (Join-Path $InstallDir 'agent.pid') -Force -ErrorAction SilentlyContinue
  if ($NoAutostart) {
    Start-Process -FilePath $exe -ArgumentList '--data', "`"$InstallDir`"" -WindowStyle Hidden
    if (Wait-Recorder) { return }
  } else {
    if ($autostart -eq 'logon' -and (Get-TaskOwner $TaskName $exe) -eq 'ours') {
      Start-ScheduledTask -TaskName $TaskName
      if (Wait-Recorder) { return }
    }
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "`"$exe`" --data `"$InstallDir`"" }
    if ($r.ReturnValue -eq 0 -and (Wait-Recorder)) { return }
  }
  throw "The recorder did not start. See $InstallDir\agent.log."
}

# After an -Update swap: polls update-health.txt until Get-UpdateHealth decides.
function Wait-UpdateHealth {
  $marker = Join-Path $InstallDir 'update-health.txt'
  $clock = [Diagnostics.Stopwatch]::StartNew()
  while ($true) {
    $h = Get-UpdateHealth (Get-MarkerVersion $marker) $RecorderVersion ([bool]@(Get-Recorder).Count) $clock.Elapsed.TotalSeconds $HealthSeconds
    if ($h -ne 'wait') { return $h }
    Start-Sleep -Milliseconds 500
  }
}

$TaskName = 'AgentRecorder'
$exitCode = 2
$autostart = 'none'
$exe = $null
$tmp = $null
$swapped = $false
$hadAccounts = $false
$addOnly = $false
$device = ''
$installed = $RecorderVersion
$backup = $null
$backedUp = $false
$HealthSeconds = 90
if ([string]$env:AGENT_RECORDER_HEALTH_SECONDS -match '^[0-9]{1,3}$' -and [int]$env:AGENT_RECORDER_HEALTH_SECONDS -ge 5) { $HealthSeconds = [int]$env:AGENT_RECORDER_HEALTH_SECONDS }
try {
  $uri = [Uri]$Server
  if ($uri.Scheme -ne 'https' -and -not $uri.IsLoopback) { throw 'Server must be https.' }
  $Server = $Server.TrimEnd('/')
  $InstallDir = [IO.Path]::GetFullPath($InstallDir)
  $exe = Join-Path $InstallDir 'AgentRecorder.exe'
  $config = Join-Path $InstallDir 'config.dat'
  $options = Join-Path $InstallDir 'install-options.txt'
  # The name recorded by an earlier install (a self-update passes it back; this keeps it when one does not).
  if (-not $DeviceName -and (Test-Path -LiteralPath $options)) {
    $DeviceName = (Get-Content -LiteralPath $options | Where-Object { $_ -like 'device_name=*' } | Select-Object -First 1) -replace '^device_name=', ''
  }
  $DeviceName = ([string]$DeviceName -replace '[\x00-\x1f"]', '').Trim()
  if ($Code) {
    if ($Code -notmatch '^[A-Za-z0-9]{10,40}$') { throw 'Invalid pairing code.' }
  } elseif (-not $Update) {
    throw 'Missing pairing code. Call get_installer for a new command.'
  } elseif (-not (Test-Path -LiteralPath $config)) {
    throw "No paired recorder in $InstallDir to update. Call get_installer for a new command."
  }
  if ($Account -and $Account -notmatch '^[A-Za-z0-9]{1,64}$') { throw 'Invalid account.' }
  $hadAccounts = Test-Path -LiteralPath $config
  # A pairing code and this version (or newer) already installed: only the account is added (nothing downloaded,
  # stopped or replaced).
  $current = Get-InstalledVersion $exe
  $addOnly = $Code -and (Test-AddAccountOnly $current $RecorderVersion ([bool]$Update))
  if ($addOnly) { $installed = $current }

  if (-not $addOnly) {
  $exitCode = 3
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  $tmp = Join-Path $env:TEMP ('agent-recorder-' + [guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $zip = Join-Path $tmp 'recorder.zip'
  Get-Verified "$Server/recorder.zip" $RecorderZipSha256 $zip

  # ffmpeg: system copy if requested or present on PATH, else the pinned build.
  $ffmpeg = $null
  $sys = Get-Command ffmpeg -ErrorAction SilentlyContinue
  if ($sys) { $ffmpeg = $sys.Source }
  elseif ($UseSystemTools) { throw 'UseSystemTools set but ffmpeg is not on PATH.' }
  else {
    $ffmpeg = Join-Path $InstallDir 'ffmpeg\ffmpeg.exe'
    if (-not (Test-Path $ffmpeg)) {
      $ffZip = Join-Path $tmp 'ffmpeg.zip'
      Get-Verified $FfmpegUrl $FfmpegSha256 $ffZip
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      $archive = [IO.Compression.ZipFile]::OpenRead($ffZip)
      try {
        $entry = $archive.Entries | Where-Object { $_.FullName -match '/bin/ffmpeg\.exe$' } | Select-Object -First 1
        if (-not $entry) { throw 'ffmpeg.exe not found in archive.' }
        New-Item -ItemType Directory -Force -Path (Split-Path $ffmpeg) | Out-Null
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $ffmpeg, $true)
      } finally { $archive.Dispose() }
    }
  }

  # -Update: the files about to be replaced are kept until the new recorder reports healthy (before anything stops).
  if ($Update -and (Test-Path -LiteralPath $exe)) {
    $backup = Join-Path $InstallDir 'update-backup'
    $backedUp = (Backup-Install $InstallDir $backup) -gt 0
  }
  # Everything is downloaded and verified: only now stop the running recorder (an update leaves it running until here).
  Stop-Recorder
  $swapped = $true
  Expand-Archive -LiteralPath $zip -DestinationPath $InstallDir -Force
  }

  if ($Code) {
    # Enroll: the pairing code goes over stdin, never on a command line. The account is added next to the ones already
    # paired (or its entry refreshed); the recorder prints the paired device id. Adding to a running install keeps its
    # ffmpeg.
    $exitCode = 4
    $psi = New-Object Diagnostics.ProcessStartInfo $exe
    $psi.Arguments = "--enroll --server `"$Server`" --data `"$InstallDir`""
    if (-not $addOnly) { $psi.Arguments += " --ffmpeg `"$ffmpeg`"" }
    if ($DeviceName) { $psi.Arguments += " --name `"$($DeviceName -replace '"', '')`"" }
    if ($Account) { $psi.Arguments += " --account $Account" }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.WriteLine($Code)
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw "Pairing failed (exit $($p.ExitCode)): the code is wrong, used or expired. Call get_installer for a new command. See $InstallDir\agent.log." }
    $device = (@($out -split "`r?`n") | Where-Object { $_ -like 'device=*' } | Select-Object -First 1) -replace '^device=', ''
  }

  if ($addOnly -and @(Get-Recorder).Count) {
    # The running recorder connects the new account by itself (it watches config.dat).
    $recorded = $null
    if (Test-Path -LiteralPath $options) {
      $recorded = (Get-Content -LiteralPath $options | Where-Object { $_ -like 'autostart=*' } | Select-Object -First 1) -replace '^autostart=', ''
    }
    $autostart = if (-not $NoAutostart -and $recorded -eq 'logon') { 'logon' } else { 'none' }
    Write-Output "RECITBOT_INSTALL_OK device=$device version=$installed autostart=$autostart"
    exit 0
  }

  $exitCode = 5
  # A task named AgentRecorder that starts another copy's exe (the real install, seen from a throwaway) is left alone.
  $autostart = Set-Autostart ([bool]$NoAutostart) $TaskName $exe $InstallDir
  # For the recorder's self-update: whether this install starts at logon, and the name it was paired under.
  try {
    $opts = "autostart=$autostart`r`n"
    if ($DeviceName) { $opts += "device_name=$DeviceName`r`n" }
    [IO.File]::WriteAllText($options, $opts)
  } catch { }
  if ($backedUp) { Remove-Item -LiteralPath (Join-Path $InstallDir 'update-health.txt') -Force -ErrorAction SilentlyContinue }
  Start-Recorder
  if ($backedUp) {
    if ((Wait-UpdateHealth) -ne 'healthy') { throw "The new recorder ($RecorderVersion) did not connect within $HealthSeconds s." }
    Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
  }
  # -Update without a code: the first paired account's device (a v1 file: device_id).
  if (-not $device) {
    $device = (Get-Content -LiteralPath $config | Where-Object { $_ -like 'account.0.device_id=*' -or $_ -like 'device_id=*' } | Select-Object -First 1) -replace '^(account\.0\.)?device_id=', ''
  }
  Write-Output "RECITBOT_INSTALL_OK device=$device version=$installed autostart=$autostart"
  exit 0
} catch {
  $reason = $_.Exception.Message
  if ($backedUp -and $swapped -and $exitCode -ne 4) {
    # -Update after the swap (files, start or health): the previous version goes back and starts again; it reports
    # "rolled_back" for $RecorderVersion on its next connect. A failed pairing keeps the new files (the update worked).
    try {
      Stop-Recorder
      Restore-Install $InstallDir $backup | Out-Null
      Write-Rollback $InstallDir $RecorderVersion
      Start-Recorder
      Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
      $reason = "$reason Rolled back to the previous version."
    } catch { $reason = "$reason Rollback failed: $($_.Exception.Message)" }
    $exitCode = 6
  }
  # A failed update, or a failed pairing on a PC that already had paired accounts, must not leave the PC without its
  # recorder: start whatever is installed if it is not running.
  elseif (($Update -or $hadAccounts) -and $swapped -and $exe -and (Test-Path -LiteralPath $exe) -and -not @(Get-Recorder).Count) {
    try { Start-Recorder } catch { }
  }
  # Not rolled back (e.g. a failed pairing): the backup is not needed. A failed rollback keeps it.
  if ($backedUp -and $exitCode -ne 6) { Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue }
  Write-Output "RECITBOT_INSTALL_FAILED: $reason"
  exit $exitCode
} finally {
  if ($tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  # The recorder's self-update runs this script from a copy in %TEMP%.
  if ($Update -and $PSCommandPath -and (Split-Path -Leaf $PSCommandPath) -like 'recitbot-update-*.ps1') {
    Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
  }
}
