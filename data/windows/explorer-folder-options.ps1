<#
.SYNOPSIS
    Configures Windows File Explorer preferences and folder options.
.DESCRIPTION
    Applies developer-friendly Explorer settings:
    - Show hidden files and folders
    - Show file name extensions
    - Open File Explorer to "This PC" instead of "Home / Quick Access"
    - Hide frequent folders / recent files from Quick Access
    - Expand to open folder in navigation pane
#>
[CmdletBinding()]
param (
    [switch]$ShowHiddenFiles = $true,
    [switch]$ShowFileExtensions = $true,
    [ValidateSet("ThisPC", "QuickAccess")]
    [string]$LaunchTo = "ThisPC",
    [switch]$HideRecentFromQuickAccess = $true
)

Write-Host "Applying Windows Explorer folder options..." -ForegroundColor Cyan

$AdvancedKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
if (-not (Test-Path $AdvancedKey)) {
    New-Item -Path $AdvancedKey -Force | Out-Null
}

# 1. Show hidden files, folders, and drives
if ($ShowHiddenFiles) {
    Set-ItemProperty -Path $AdvancedKey -Name "Hidden" -Value 1 -Type DWord
    Set-ItemProperty -Path $AdvancedKey -Name "ShowSuperHidden" -Value 0 -Type DWord # 0 = don't hide protected OS files unless needed
    Write-Host "  [+] Hidden files: Visible" -ForegroundColor Green
}

# 2. Show file name extensions
if ($ShowFileExtensions) {
    Set-ItemProperty -Path $AdvancedKey -Name "HideFileExt" -Value 0 -Type DWord
    Write-Host "  [+] File extensions: Visible" -ForegroundColor Green
}

# 3. Open Explorer to "This PC" (1) or "Quick Access / Home" (2)
$LaunchVal = if ($LaunchTo -eq "ThisPC") { 1 } else { 2 }
Set-ItemProperty -Path $AdvancedKey -Name "LaunchTo" -Value $LaunchVal -Type DWord
Write-Host "  [+] Launch Explorer to: $LaunchTo" -ForegroundColor Green

# 4. Hide recent files and frequent folders in Quick Access
if ($HideRecentFromQuickAccess) {
    Set-ItemProperty -Path $AdvancedKey -Name "Start_TrackDocs" -Value 0 -Type DWord
    Set-ItemProperty -Path $AdvancedKey -Name "ShowRecent" -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $AdvancedKey -Name "ShowFrequent" -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Write-Host "  [+] Quick Access tracking: Disabled" -ForegroundColor Green
}

# Restart Explorer to apply changes immediately if running interactively
if (Get-Process "explorer" -ErrorAction SilentlyContinue) {
    Stop-Process -Name "explorer" -Force
}
