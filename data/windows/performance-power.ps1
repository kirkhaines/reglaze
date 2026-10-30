<#
.SYNOPSIS
    Configures Windows Power Plan, sleep/display timeouts, and developer system ergonomics.
.DESCRIPTION
    Sets active power plan (High Performance / Balanced / Ultimate Performance), adjusts standby
    and display timeouts on AC power, and configures Clipboard History, LongPathsEnabled,
    OpenSSH Agent service startup, and Default Terminal application.
#>
[CmdletBinding()]
param (
    [ValidateSet("HighPerformance", "Balanced", "UltimatePerformance")]
    [string]$PowerPlan = "HighPerformance",
    [int]$AcSleepTimeoutMinutes = 0,
    [int]$AcDisplayTimeoutMinutes = 30,
    [Nullable[bool]]$ClipboardHistoryEnabled = $null,
    [Nullable[bool]]$LongPathsEnabled = $null,
    [string]$SshAgentStartup = $null,
    [string]$DefaultTerminal = $null
)

Write-Host "Configuring Windows Power, Performance, and Developer Ergonomics..." -ForegroundColor Cyan

$HighPerfGuid = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
$BalancedGuid = "381b4222-f694-41f0-9685-ff5bb260df2e"
$UltimateGuid = "e9a42b02-d5df-448d-aa00-03f14749eb61"

if ($PowerPlan -eq "UltimatePerformance") {
    $Null = powercfg -duplicatescheme $UltimateGuid 2>$null
    powercfg /setactive $UltimateGuid 2>$null
    Write-Host "  [+] Set Power Plan to: Ultimate Performance" -ForegroundColor Green
} elseif ($PowerPlan -eq "HighPerformance") {
    powercfg /setactive $HighPerfGuid 2>$null
    Write-Host "  [+] Set Power Plan to: High Performance" -ForegroundColor Green
} elseif ($PowerPlan -eq "Balanced") {
    powercfg /setactive $BalancedGuid 2>$null
    Write-Host "  [+] Set Power Plan to: Balanced" -ForegroundColor Green
}

# Standby and Display timeouts on AC power
powercfg /change standby-timeout-ac $AcSleepTimeoutMinutes
powercfg /change monitor-timeout-ac $AcDisplayTimeoutMinutes
Write-Host "  [+] AC Sleep Timeout: $AcSleepTimeoutMinutes minutes (0 = Never)" -ForegroundColor Green
Write-Host "  [+] AC Display Timeout: $AcDisplayTimeoutMinutes minutes" -ForegroundColor Green

# System Ergonomics: Clipboard History (Win+V)
if ($null -ne $ClipboardHistoryEnabled) {
    $ClipKey = "HKCU:\Software\Microsoft\Clipboard"
    if (-not (Test-Path $ClipKey)) { New-Item -Path $ClipKey -Force | Out-Null }
    Set-ItemProperty -Path $ClipKey -Name "EnableClipboardHistory" -Value $(if ($ClipboardHistoryEnabled) { 1 } else { 0 }) -Type DWord
    Write-Host "  [+] Clipboard History (Win+V): $(if ($ClipboardHistoryEnabled) { 'Enabled' } else { 'Disabled' })" -ForegroundColor Green
}

# System Ergonomics: Win32 Long Paths
if ($null -ne $LongPathsEnabled) {
    $FsKey = "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"
    if (Test-Path $FsKey) {
        Set-ItemProperty -Path $FsKey -Name "LongPathsEnabled" -Value $(if ($LongPathsEnabled) { 1 } else { 0 }) -Type DWord -ErrorAction SilentlyContinue
        Write-Host "  [+] Win32 Long Paths: $(if ($LongPathsEnabled) { 'Enabled' } else { 'Disabled' })" -ForegroundColor Green
    }
}

# System Ergonomics: OpenSSH Authentication Agent service startup
if (-not [string]::IsNullOrWhiteSpace($SshAgentStartup) -and $SshAgentStartup -in @("Automatic", "Manual", "Disabled")) {
    $SshSvc = Get-Service -Name "ssh-agent" -ErrorAction SilentlyContinue
    if ($SshSvc) {
        Set-Service -Name "ssh-agent" -StartupType $SshAgentStartup -ErrorAction SilentlyContinue
        if ($SshAgentStartup -eq "Automatic") {
            Start-Service -Name "ssh-agent" -ErrorAction SilentlyContinue
        }
        Write-Host "  [+] ssh-agent Service Startup: $SshAgentStartup" -ForegroundColor Green
    }
}

# System Ergonomics: Default Terminal Application (Windows Terminal vs Conhost)
if ($DefaultTerminal -eq "WindowsTerminal") {
    $StartupKey = "HKCU:\Console\%%Startup"
    if (-not (Test-Path -LiteralPath $StartupKey)) {
        New-Item -Path $StartupKey -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $StartupKey -Name "DelegationConsole" -Value "{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}" -Type String
    Set-ItemProperty -LiteralPath $StartupKey -Name "DelegationTerminal" -Value "{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}" -Type String
    Write-Host "  [+] Default Terminal: Windows Terminal" -ForegroundColor Green
}
