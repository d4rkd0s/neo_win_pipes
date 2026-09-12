# Screenshots a running process's main window to a PNG file, using
# PrintWindow (not a screen-region grab) so it works even when the window
# isn't in the foreground/visible on screen — needed for this project's
# background/CI-style verification runs, where SetForegroundWindow-style
# focus tricks are unreliable. See docs/DEVELOPMENT.md and
# scripts/verify.sh for how this fits into the empirical verification
# contract.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts/capture_window.ps1 -ProcessName pipes-settings -OutFile artifacts/verify/shot.png

param(
    [Parameter(Mandatory = $true)][string]$ProcessName,
    [Parameter(Mandatory = $true)][string]$OutFile
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class NeoWinPipesWindowCapture {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
    public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

$proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) {
    Write-Error "No running process named '$ProcessName'."
    exit 1
}
if ($proc.MainWindowHandle -eq [IntPtr]::Zero) {
    Write-Error "Process '$ProcessName' (PID $($proc.Id)) has no main window yet."
    exit 1
}

$handle = $proc.MainWindowHandle
$rect = New-Object NeoWinPipesWindowCapture+RECT
[void][NeoWinPipesWindowCapture]::GetWindowRect($handle, [ref]$rect)
$width = $rect.Right - $rect.Left
$height = $rect.Bottom - $rect.Top
if ($width -le 0 -or $height -le 0) {
    Write-Error "Window reported invalid dimensions (${width}x${height})."
    exit 1
}

$bitmap = New-Object System.Drawing.Bitmap $width, $height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$hdc = $graphics.GetHdc()
# flags=2 is PW_RENDERFULLCONTENT — required for hardware-accelerated
# (wgpu/D3D12) content; the default PW_CLIENTONLY-style capture (flags=0)
# reliably comes back blank for GPU-rendered windows.
[void][NeoWinPipesWindowCapture]::PrintWindow($handle, $hdc, 2)
$graphics.ReleaseHdc($hdc)

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null
$bitmap.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose()
$bitmap.Dispose()

Write-Output "Saved ${width}x${height} screenshot of '$ProcessName' to $OutFile"
