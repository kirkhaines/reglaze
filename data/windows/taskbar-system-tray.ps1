<#
.SYNOPSIS
    Configures Windows 11 Taskbar, Search, System Tray, Clock Seconds/Format, and Developer End-Task settings.
.DESCRIPTION
    Applies custom preferences:
    - Taskbar Alignment (Left vs Center)
    - Taskbar Search mode (Hidden, IconOnly, Box)
    - Taskbar Widgets and Chat button visibility
    - Show seconds in taskbar clock & 12h/24h regional clock/date format
    - Enable "End task" on taskbar right-click
    - System Tray promoted (always visible) icons
#>
[CmdletBinding()]
param (
    [ValidateSet("Left", "Center")]
    [string]$TaskbarAlignment = "Left",
    [ValidateSet("Hidden", "IconOnly", "Box")]
    [string]$SearchMode = "IconOnly",
    [switch]$HideWidgets = $true,
    [switch]$HideChat = $true,
    [switch]$ShowSecondsInClock = $false,
    [switch]$EndTaskEnabled = $false,
    [string]$ShortTimeFormat = $null,
    [string]$LongTimeFormat = $null,
    [string]$ShortDateFormat = $null,
    [Nullable[bool]]$Use24HourClock = $null,
    [string[]]$PromotedTrayIcons = @()
)

Write-Host "Applying Windows Taskbar, Clock, and System Tray settings..." -ForegroundColor Cyan

$AdvancedKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
$SearchKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
$DevKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings"

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
Set-ItemProperty -Path $AdvancedKey -Name "TaskbarDa" -Value $(if ($HideWidgets) { 0 } else { 1 }) -Type DWord -ErrorAction SilentlyContinue
Write-Host "  [+] Taskbar Widgets: $(if ($HideWidgets) { 'Hidden' } else { 'Visible' })" -ForegroundColor Green

# 4. Chat / Teams button (TaskbarMn)
Set-ItemProperty -Path $AdvancedKey -Name "TaskbarMn" -Value $(if ($HideChat) { 0 } else { 1 }) -Type DWord -ErrorAction SilentlyContinue
Write-Host "  [+] Taskbar Chat: $(if ($HideChat) { 'Hidden' } else { 'Visible' })" -ForegroundColor Green

# 5. Show Seconds in Taskbar Clock
Set-ItemProperty -Path $AdvancedKey -Name "ShowSecondsInSystemClock" -Value $(if ($ShowSecondsInClock) { 1 } else { 0 }) -Type DWord
Write-Host "  [+] Taskbar Clock Seconds: $(if ($ShowSecondsInClock) { 'Shown' } else { 'Hidden' })" -ForegroundColor Green

# 6. Taskbar Right-Click "End task" option
if (-not (Test-Path $DevKey)) { New-Item -Path $DevKey -Force | Out-Null }
Set-ItemProperty -Path $DevKey -Name "TaskbarEndTask" -Value $(if ($EndTaskEnabled) { 1 } else { 0 }) -Type DWord
Write-Host "  [+] Taskbar 'End task' option: $(if ($EndTaskEnabled) { 'Enabled' } else { 'Disabled' })" -ForegroundColor Green

# 7. Regional Clock & Date Format
$IntlKey = "HKCU:\Control Panel\International"
if (Test-Path $IntlKey) {
    if (-not [string]::IsNullOrWhiteSpace($ShortTimeFormat)) {
        Set-ItemProperty -Path $IntlKey -Name "sShortTime" -Value $ShortTimeFormat -Type String
    }
    if (-not [string]::IsNullOrWhiteSpace($LongTimeFormat)) {
        Set-ItemProperty -Path $IntlKey -Name "sTimeFormat" -Value $LongTimeFormat -Type String
    }
    if (-not [string]::IsNullOrWhiteSpace($ShortDateFormat)) {
        Set-ItemProperty -Path $IntlKey -Name "sShortDate" -Value $ShortDateFormat -Type String
    }
    if ($null -ne $Use24HourClock) {
        Set-ItemProperty -Path $IntlKey -Name "iTime" -Value $(if ($Use24HourClock) { "1" } else { "0" }) -Type String
    }
}

# 8. Promoted System Tray Icons (Windows 11 NotifyIconSettings)
if ($PromotedTrayIcons -and $PromotedTrayIcons.Count -gt 0) {
    $NotifyRoot = "HKCU:\Control Panel\NotifyIconSettings"
    if (Test-Path -LiteralPath $NotifyRoot) {
        foreach ($SubKey in (Get-ChildItem -LiteralPath $NotifyRoot -ErrorAction SilentlyContinue)) {
            $Props = Get-ItemProperty -LiteralPath $SubKey.PSPath -ErrorAction SilentlyContinue
            if ($Props -and $Props.ExecutablePath) {
                $ExeLeaf = Split-Path -Leaf $Props.ExecutablePath
                foreach ($TargetIcon in $PromotedTrayIcons) {
                    if ($ExeLeaf -ieq $TargetIcon -or $Props.ExecutablePath -like "*$TargetIcon") {
                        Set-ItemProperty -LiteralPath $SubKey.PSPath -Name "IsPromoted" -Value 1 -Type DWord
                        Write-Host "  [+] System Tray Icon Promoted: $ExeLeaf" -ForegroundColor Green
                        break
                    }
                }
            }
        }
    }
}
