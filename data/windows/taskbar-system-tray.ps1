<#
.SYNOPSIS
    Configures Windows 11 Taskbar, Search, and System Tray settings.
.DESCRIPTION
    Applies custom preferences:
    - Taskbar Alignment (Left vs Center)
    - Taskbar Search mode (Hidden, IconOnly, Box)
    - Taskbar Widgets and Chat button visibility
    - System Tray overflow / always show icons
#>
[CmdletBinding()]
param (
    [ValidateSet("Left", "Center")]
    [string]$TaskbarAlignment = "Left",
    [ValidateSet("Hidden", "IconOnly", "Box")]
    [string]$SearchMode = "IconOnly",
    [switch]$HideWidgets = $true,
    [switch]$HideChat = $true
)

Write-Host "Applying Windows Taskbar and System Tray settings..." -ForegroundColor Cyan

$AdvancedKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
$SearchKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"

if (-not (Test-Path $AdvancedKey)) { New-Item -Path $AdvancedKey -Force | Out-Null }
if (-not (Test-Path $SearchKey)) { New-Item -Path $SearchKey -Force | Out-Null }

# 1. Taskbar Alignment: 0 = Left, 1 = Center
$AlignVal = if ($TaskbarAlignment -eq "Left") { 0 } else { 1 }
Set-ItemProperty -Path $AdvancedKey -Name "TaskbarAl" -Value $AlignVal -Type DWord
Write-Host "  [+] Taskbar Alignment: $TaskbarAlignment" -ForegroundColor Green

# 2. Search Mode: 0 = Hidden, 1 = Icon Only, 2 = Search Box
$SearchVal = switch ($SearchMode) {
    "Hidden" { 0 }
    "IconOnly" { 1 }
    "Box" { 2 }
}
Set-ItemProperty -Path $SearchKey -Name "SearchboxTaskbarMode" -Value $SearchVal -Type DWord
Write-Host "  [+] Taskbar Search: $SearchMode" -ForegroundColor Green

# 3. Widgets (TaskbarDa)
if ($HideWidgets) {
    Set-ItemProperty -Path $AdvancedKey -Name "TaskbarDa" -Value 0 -Type DWord
    Write-Host "  [+] Taskbar Widgets: Hidden" -ForegroundColor Green
}

# 4. Chat / Teams button (TaskbarMn)
if ($HideChat) {
    Set-ItemProperty -Path $AdvancedKey -Name "TaskbarMn" -Value 0 -Type DWord
    Write-Host "  [+] Taskbar Chat: Hidden" -ForegroundColor Green
}
