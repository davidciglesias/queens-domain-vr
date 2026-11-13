# fakevr.ps1 on|off|status - switch SteamVR between the qdfake test driver and the real headset.
# on : backs up steamvr.vrsettings once (backup\steamvr.vrsettings.orig, never overwritten),
#      registers driver\qdfake with vrpathreg, sets steamvr.forcedDriver="qdfake" and
#      steamvr.activateMultipleDrivers=true (previous values saved in backup\fakevr_state.json).
# off: restores those two keys (or removes them) and unregisters the driver.
# Refuses to touch settings while SteamVR runs (it rewrites steamvr.vrsettings on exit).
param([Parameter(Position = 0)][ValidateSet('on', 'off', 'status')][string]$Cmd = 'status')
$ErrorActionPreference = 'Stop'

$Here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$SteamVR   = if ($env:QD_STEAMVR) { $env:QD_STEAMVR } else { 'F:\Steam\steamapps\common\SteamVR' }
$Settings  = if ($env:QD_VRSETTINGS) { $env:QD_VRSETTINGS } else { 'F:\Steam\config\steamvr.vrsettings' }
$DriverDir = Join-Path $Here 'driver\qdfake'
$BackupDir = Join-Path $Here 'backup'
$StateFile = Join-Path $BackupDir 'fakevr_state.json'
$VrPathReg = Join-Path $SteamVR 'bin\win64\vrpathreg.exe'
$Tool      = Join-Path $Here 'vrsettings_tool.py'
$VrPaths   = Join-Path $env:LOCALAPPDATA 'openvr\openvrpaths.vrpath'

function Get-VRProcs { Get-Process -Name vrserver, vrmonitor, vrcompositor, vrdashboard, vrwebhelper -ErrorAction SilentlyContinue }

function Test-Registered {
    if (-not (Test-Path $VrPaths)) { return $false }
    $j = Get-Content -Raw $VrPaths | ConvertFrom-Json
    foreach ($d in @($j.external_drivers)) { if ($d -and ((Resolve-Path -LiteralPath $d -ErrorAction SilentlyContinue).Path -eq (Resolve-Path $DriverDir).Path)) { return $true } }
    return $false
}

function Assert-NotRunning {
    $p = Get-VRProcs
    if ($p) { throw "SteamVR is running ($(($p.Name | Sort-Object -Unique) -join ', ')). Close it first; it rewrites steamvr.vrsettings on exit." }
}

function Invoke-Tool([string]$Mode) {
    & python -I $Tool $Mode $Settings $StateFile
    if ($LASTEXITCODE -ne 0) { throw "vrsettings_tool.py $Mode failed ($LASTEXITCODE)" }
}

switch ($Cmd) {
    'status' {
        $procs = Get-VRProcs
        "SteamVR running : $(if ($procs) { ($procs.Name | Sort-Object -Unique) -join ', ' } else { 'no' })"
        "driver built    : $(Test-Path (Join-Path $DriverDir 'bin\win64\driver_qdfake.dll'))"
        "registered      : $(Test-Registered)  ($DriverDir)"
        "settings backup : $(if (Test-Path (Join-Path $BackupDir 'steamvr.vrsettings.orig')) { 'yes' } else { 'no' })"
        Invoke-Tool 'status'
    }
    'on' {
        Assert-NotRunning
        if (-not (Test-Path (Join-Path $DriverDir 'bin\win64\driver_qdfake.dll'))) { throw 'driver not built: run driver\build.cmd' }
        New-Item -ItemType Directory -Force $BackupDir | Out-Null
        $bak = Join-Path $BackupDir 'steamvr.vrsettings.orig'
        if (Test-Path $bak) { "settings backup exists (kept): $bak" } else { Copy-Item -LiteralPath $Settings -Destination $bak; "settings backed up: $bak" }
        if (Test-Registered) { 'driver already registered' } else {
            & $VrPathReg adddriver $DriverDir | Out-Null
            if (-not (Test-Registered)) { throw 'vrpathreg adddriver did not register the driver' }
            "driver registered: $DriverDir"
        }
        Invoke-Tool 'on'
        'fake mode ON (start SteamVR to use qdfake; run "fakevr.ps1 off" to return to the real headset)'
    }
    'off' {
        Assert-NotRunning
        Invoke-Tool 'off'
        if (Test-Registered) {
            & $VrPathReg removedriver $DriverDir | Out-Null
            if (Test-Registered) { throw 'vrpathreg removedriver failed' }
            'driver unregistered'
        } else { 'driver was not registered' }
        'fake mode OFF'
    }
}
