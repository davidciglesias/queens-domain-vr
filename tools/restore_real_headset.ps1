# restore_real_headset.ps1 - undo the fake test headset so SteamVR uses the real one again.
# Closes SteamVR (it rewrites its settings on exit), then runs fakevr.ps1 off
# (removes forcedDriver=qdfake / activateMultipleDrivers and unregisters the fake driver).
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$names = 'vrmonitor', 'vrdashboard', 'vrcompositor', 'vrwebhelper', 'vrserver', 'vrstartup'
$p = Get-Process -Name $names -ErrorAction SilentlyContinue
if ($p) {
    'Closing SteamVR...'
    $p | Stop-Process -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 30 -and (Get-Process -Name $names -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
}
& (Join-Path $Here 'fakevr\fakevr.ps1') off
& (Join-Path $Here 'fakevr\fakevr.ps1') status
'Done: start SteamVR normally with the real headset.'
