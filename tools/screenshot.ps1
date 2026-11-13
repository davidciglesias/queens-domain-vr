# Captures a window (default: the game) to a downscaled JPEG for quick visual checks.
# Usage: powershell -ExecutionPolicy Bypass -File tools\screenshot.ps1 [-Out path.jpg] [-Process QueensDomain-Win64-Shipping] [-Title text] [-Width 960] [-Crop x,y,w,h (fractions 0..1)]
param(
    [string]$Out = "$env:TEMP\qd_shot.jpg",
    [string]$Process = "QueensDomain-Win64-Shipping",
    [string]$Title = "",
    [int]$Width = 960,
    [string]$Crop = ""
)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class QdWin {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
"@
$h = [IntPtr]::Zero
if ($Title -ne "") {
    $p = Get-Process | Where-Object { $_.MainWindowTitle -like "*$Title*" } | Select-Object -First 1
} else {
    $p = Get-Process -Name $Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
}
if ($null -eq $p) { Write-Output "no window"; exit 1 }
$h = $p.MainWindowHandle
if ([QdWin]::IsIconic($h)) { [void][QdWin]::ShowWindow($h, 9) }
$r = New-Object QdWin+RECT
[void][QdWin]::GetClientRect($h, [ref]$r)
$w = $r.R - $r.L; $hh = $r.B - $r.T
if ($w -le 0 -or $hh -le 0) { Write-Output "empty client rect"; exit 1 }
$bmp = New-Object System.Drawing.Bitmap $w, $hh
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
$ok = [QdWin]::PrintWindow($h, $hdc, 3)  # PW_CLIENTONLY | PW_RENDERFULLCONTENT
$g.ReleaseHdc($hdc)
if (-not $ok) {
    $pt = New-Object QdWin+POINT
    [void][QdWin]::ClientToScreen($h, [ref]$pt)
    $g.CopyFromScreen($pt.X, $pt.Y, 0, 0, (New-Object System.Drawing.Size $w, $hh))
}
$g.Dispose()
$src = $bmp
if ($Crop -ne "") {
    $c = $Crop.Split(",") | ForEach-Object { [double]$_ }
    $rect = New-Object System.Drawing.Rectangle ([int]($c[0] * $w)), ([int]($c[1] * $hh)), ([int]($c[2] * $w)), ([int]($c[3] * $hh))
    $src = $bmp.Clone($rect, $bmp.PixelFormat)
}
$scale = [Math]::Min(1.0, $Width / $src.Width)
$ow = [int]($src.Width * $scale); $oh = [int]($src.Height * $scale)
$outBmp = New-Object System.Drawing.Bitmap $ow, $oh
$g2 = [System.Drawing.Graphics]::FromImage($outBmp)
$g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g2.DrawImage($src, 0, 0, $ow, $oh)
$g2.Dispose()
$enc = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq "image/jpeg" }
$ep = New-Object System.Drawing.Imaging.EncoderParameters 1
$ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), 80L
$outBmp.Save($Out, $enc, $ep)
Write-Output ("saved {0} {1}x{2} (window {3}x{4}, printwindow={5})" -f $Out, $ow, $oh, $w, $hh, $ok)
