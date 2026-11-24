# Self-test launch: SteamVR (fake headset if tools\fakevr is on) -> game via Steam -> UEVR injection.
# Usage: powershell -ExecutionPolicy Bypass -File tools\selftest_launch.ps1 [-NoSteamVR] [-NoInject]
# Stop everything: powershell -File tools\selftest_launch.ps1 -Stop
param([switch]$NoSteamVR, [switch]$NoInject, [switch]$Stop)
$game = "QueensDomain-Win64-Shipping"
# Paths come from environment variables (see README.md, "Dev tools"):
#   QD_UEVR_DIR  folder holding UEVRInjector.exe (required unless -NoInject)
#   QD_STEAM     Steam root (default: registry SteamPath, else %ProgramFiles(x86)%\Steam)
#   QD_STEAMVR   SteamVR folder (default: <Steam root>\steamapps\common\SteamVR)
$SteamRoot = if ($env:QD_STEAM) { $env:QD_STEAM } else { $r = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath; if ($r) { $r } else { Join-Path ${env:ProgramFiles(x86)} 'Steam' } }
$vrDir = if ($env:QD_STEAMVR) { $env:QD_STEAMVR } else { Join-Path $SteamRoot 'steamapps\common\SteamVR' }
$vrstartup = Join-Path $vrDir 'bin\win64\vrstartup.exe'
$uevr = if ($env:QD_UEVR_DIR) { Join-Path $env:QD_UEVR_DIR 'UEVRInjector.exe' } else { $null }
if (-not $NoInject -and -not $uevr -and -not $Stop) { Write-Output 'Set QD_UEVR_DIR to the folder that holds UEVRInjector.exe (or pass -NoInject)'; exit 1 }

if ($Stop) {
    Get-Process -Name $game -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 3
    foreach ($n in "UEVRInjector", "vrmonitor", "vrdashboard", "vrwebhelper", "vrcompositor", "vrserver", "vrstartup") {
        Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force
    }
    Write-Output "stopped game + SteamVR"
    exit 0
}

if (-not $NoSteamVR -and -not (Get-Process -Name vrserver -ErrorAction SilentlyContinue)) {
    Start-Process explorer.exe -ArgumentList $vrstartup  # non-elevated: an elevated SteamVR breaks client IPC (see tools/fakevr/README.md)
    $t = 0
    while (-not (Get-Process -Name vrcompositor -ErrorAction SilentlyContinue) -and $t -lt 60) { Start-Sleep -Seconds 1; $t++ }
    Start-Sleep -Seconds 5
    Write-Output ("SteamVR up after {0}s" -f $t)
}

if (-not (Get-Process -Name $game -ErrorAction SilentlyContinue)) {
    Start-Process explorer.exe -ArgumentList "steam://rungameid/1799840"
    $t = 0
    while (-not (Get-Process -Name $game -ErrorAction SilentlyContinue) -and $t -lt 90) { Start-Sleep -Seconds 1; $t++ }
    if (-not (Get-Process -Name $game -ErrorAction SilentlyContinue)) { Write-Output "game did not start"; exit 1 }
    Write-Output ("game process after {0}s" -f $t)
    Start-Sleep -Seconds 8
}

if (-not $NoInject) {
    $p = Get-Process -Name $game | Select-Object -First 1
    $loaded = $p.Modules | Where-Object { $_.ModuleName -eq "UEVRBackend.dll" }
    if ($loaded) { Write-Output "UEVR already injected" }
    else {
        Get-Process -Name UEVRInjector -ErrorAction SilentlyContinue | Stop-Process -Force  # only ever one injector
        $env:__COMPAT_LAYER = "RunAsInvoker"  # user flags the injector RUNASADMIN; non-elevated works, no UAC
        Start-Process $uevr -ArgumentList "--attach=$game.exe" -WorkingDirectory (Split-Path $uevr)
        $t = 0
        while ($t -lt 60) {
            Start-Sleep -Seconds 1; $t++
            $p = Get-Process -Name $game -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($p -and ($p.Modules | Where-Object { $_.ModuleName -eq "UEVRBackend.dll" })) { break }
        }
        Write-Output ("UEVR backend loaded after {0}s: {1}" -f $t, [bool]($p.Modules | Where-Object { $_.ModuleName -eq "UEVRBackend.dll" }))
    }
}
