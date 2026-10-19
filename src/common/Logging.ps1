<#
.SYNOPSIS
    Shared console logging functions for Reglaze CLI.
#>

function Write-ReglazeBanner {
    param ([string]$Title = "REGLAZE")
    Write-Host ""
    Write-Host "  ================================================================" -ForegroundColor Cyan
    Write-Host "    $Title - Disposable Windows Workstation Engine" -ForegroundColor White
    Write-Host "  ================================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-ReglazeInfo {
    param ([string]$Message)
    Write-Host "  [i] $Message" -ForegroundColor Gray
}

function Write-ReglazeStep {
    param ([string]$StepName)
    Write-Host ""
    Write-Host "  ==> $StepName" -ForegroundColor Cyan
}

function Write-ReglazeSuccess {
    param ([string]$Message)
    Write-Host "  [+] $Message" -ForegroundColor Green
}

function Write-ReglazeWarning {
    param ([string]$Message)
    Write-Host "  [!] WARNING: $Message" -ForegroundColor Yellow
}

function Write-ReglazeError {
    param ([string]$Message)
    Write-Host "  [x] ERROR: $Message" -ForegroundColor Red
}
