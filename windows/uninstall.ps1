# Agent Recorder uninstaller: stops the agent, removes the per-user scheduled task and the install folder.
param(
  [string]$InstallDir = $(if ($env:AGENT_RECORDER_INSTALL_DIR) { $env:AGENT_RECORDER_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'AgentRecorder' })
)
$ErrorActionPreference = 'Stop'
$pidFile = Join-Path $InstallDir 'agent.pid'
if (Test-Path $pidFile) {
  $p = Get-Process -Id ([int](Get-Content $pidFile)) -ErrorAction SilentlyContinue
  if ($p -and $p.ProcessName -eq 'AgentRecorder') { Stop-Process -Id $p.Id -Force; $p.WaitForExit(5000) | Out-Null }
}
# ffmpeg runs in a kill-on-close job with the agent; also stop any stray started from this install.
Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like "*$InstallDir*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
if (Get-ScheduledTask -TaskName 'AgentRecorder' -ErrorAction SilentlyContinue) {
  Unregister-ScheduledTask -TaskName 'AgentRecorder' -Confirm:$false
}
if (Test-Path $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force }
Write-Output 'Agent Recorder removed. Revoke the device on the server by pairing a new one or rotating keys (see README).'
