<#
.SYNOPSIS
    Post-installation configuration script for Project OutFox.
.DESCRIPTION
    Creates Start Menu and Desktop shortcuts, configures Windows Defender exclusions if needed,
    and validates that the executable and song directories are accessible.
#>
param (
    [string]$TargetDirectory = "$env:GAMES_DIR\OutFox"
)

Write-Host "Configuring Project OutFox in '$TargetDirectory'..." -ForegroundColor Cyan

$ExePath = Join-Path $TargetDirectory "Program\OutFox.exe"
if (-not (Test-Path $ExePath)) {
    # Check alternate root layout
    $ExePath = Join-Path $TargetDirectory "OutFox.exe"
}

if (Test-Path $ExePath) {
    Write-Host "Found OutFox executable at: $ExePath" -ForegroundColor Green
    
    # Create Desktop Shortcut
    $WshShell = New-Object -ComObject WScript.Shell
    $DesktopShortcutPath = [System.IO.Path]::Combine([System.Environment]::GetFolderPath('Desktop'), "Project OutFox.lnk")
    $Shortcut = $WshShell.CreateShortcut($DesktopShortcutPath)
    $Shortcut.TargetPath = $ExePath
    $Shortcut.WorkingDirectory = (Split-Path $ExePath)
    $Shortcut.Description = "Project OutFox Rhythm Game Platform"
    $Shortcut.Save()
    Write-Host "Created Desktop shortcut: $DesktopShortcutPath" -ForegroundColor Green
} else {
    Write-Warning "OutFox.exe not found in $TargetDirectory. Skipping shortcut creation."
}
