<#
.SYNOPSIS
    Configures Windows Power Plan and performance options.
.DESCRIPTION
    Sets active power plan (High Performance / Ultimate Performance) and adjusts standby/sleep timeouts.
#>
[CmdletBinding()]
param (
    [ValidateSet("HighPerformance", "Balanced", "UltimatePerformance")]
    [string]$PowerPlan = "HighPerformance",
    [int]$AcSleepTimeoutMinutes = 0, # 0 = Never sleep on AC power
    [int]$AcDisplayTimeoutMinutes = 30
)

Write-Host "Configuring Windows Power and Performance settings..." -ForegroundColor Cyan

# Find High Performance GUID
$PowerPlans = powercfg /list
$HighPerfGuid = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c" # Standard High Performance GUID
$UltimateGuid = "e9a42b02-d5df-448d-aa00-03f14749eb61" # Ultimate Performance GUID

if ($PowerPlan -eq "UltimatePerformance") {
    # Check if duplicate scheme exists or create it
    $Null = powercfg -duplicatescheme $UltimateGuid 2>$null
    powercfg /setactive $UltimateGuid 2>$null
    Write-Host "  [+] Set Power Plan to: Ultimate Performance" -ForegroundColor Green
} elseif ($PowerPlan -eq "HighPerformance") {
    powercfg /setactive $HighPerfGuid 2>$null
    Write-Host "  [+] Set Power Plan to: High Performance" -ForegroundColor Green
}

# Standby and Display timeouts on AC power
powercfg /change standby-timeout-ac $AcSleepTimeoutMinutes
powercfg /change monitor-timeout-ac $AcDisplayTimeoutMinutes
Write-Host "  [+] AC Sleep Timeout: $AcSleepTimeoutMinutes minutes (0 = Never)" -ForegroundColor Green
Write-Host "  [+] AC Display Timeout: $AcDisplayTimeoutMinutes minutes" -ForegroundColor Green
