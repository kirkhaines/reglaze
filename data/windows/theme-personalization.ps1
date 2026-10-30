<#
.SYNOPSIS
    Configures Windows 11 Theme (Dark/Light mode), Transparency, Accent Color, and Desktop Wallpaper.
.DESCRIPTION
    Applies user personalization preferences from windows_settings.theme in reglaze.yaml.
#>
[CmdletBinding()]
param (
    [ValidateSet("Dark", "Light")]
    [string]$AppsMode = "Dark",
    [ValidateSet("Dark", "Light")]
    [string]$SystemMode = "Dark",
    [bool]$Transparency = $true,
    [string]$AccentColor = $null,
    [bool]$AccentOnTaskbar = $false,
    [bool]$AccentOnTitlebars = $false,
    [string]$WallpaperPath = $null,
    [int]$WallpaperStyle = 10
)

Write-Host "Applying Windows Theme, Accent Color, and Wallpaper settings..." -ForegroundColor Cyan

$PersKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
$DwmKey  = "HKCU:\Software\Microsoft\Windows\DWM"
$DeskKey = "HKCU:\Control Panel\Desktop"

if (-not (Test-Path $PersKey)) { New-Item -Path $PersKey -Force | Out-Null }
if (-not (Test-Path $DwmKey))  { New-Item -Path $DwmKey -Force | Out-Null }

# 1. Dark / Light Mode & Transparency
Set-ItemProperty -Path $PersKey -Name "AppsUseLightTheme" -Value $(if ($AppsMode -eq "Light") { 1 } else { 0 }) -Type DWord
Set-ItemProperty -Path $PersKey -Name "SystemUsesLightTheme" -Value $(if ($SystemMode -eq "Light") { 1 } else { 0 }) -Type DWord
Set-ItemProperty -Path $PersKey -Name "EnableTransparency" -Value $(if ($Transparency) { 1 } else { 0 }) -Type DWord
Set-ItemProperty -Path $PersKey -Name "ColorPrevalence" -Value $(if ($AccentOnTaskbar) { 1 } else { 0 }) -Type DWord
Write-Host "  [+] Theme Mode: Apps=$AppsMode, System=$SystemMode, Transparency=$Transparency" -ForegroundColor Green

# 2. Accent Color & Titlebars
if (-not [string]::IsNullOrWhiteSpace($AccentColor)) {
    try {
        $HexClean = $AccentColor.Trim() -replace '^0x', '' -replace '^#', ''
        $ColorVal = [Convert]::ToUInt32($HexClean, 16)
        Set-ItemProperty -Path $DwmKey -Name "AccentColor" -Value $ColorVal -Type DWord
        Write-Host "  [+] Accent Color: $AccentColor" -ForegroundColor Green
    } catch {}
}
Set-ItemProperty -Path $DwmKey -Name "ColorPrevalence" -Value $(if ($AccentOnTitlebars) { 1 } else { 0 }) -Type DWord

# 3. Desktop Wallpaper
if (-not [string]::IsNullOrWhiteSpace($WallpaperPath) -and (Test-Path -LiteralPath $WallpaperPath)) {
    Set-ItemProperty -Path $DeskKey -Name "WallPaper" -Value $WallpaperPath -Type String
    Set-ItemProperty -Path $DeskKey -Name "WallpaperStyle" -Value "$WallpaperStyle" -Type String
    Set-ItemProperty -Path $DeskKey -Name "TileWallpaper" -Value "0" -Type String

    if (-not ("Reglaze.DesktopWallpaperNative" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Reglaze {
    public static class DesktopWallpaperNative {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, string pvParam, uint fWinIni);
    }
}
'@ -ErrorAction SilentlyContinue
    }
    if ("Reglaze.DesktopWallpaperNative" -as [type]) {
        [void][Reglaze.DesktopWallpaperNative]::SystemParametersInfo(0x0014, 0, $WallpaperPath, 0x01 -bor 0x02)
    }
    Write-Host "  [+] Desktop Wallpaper: $WallpaperPath" -ForegroundColor Green
}

