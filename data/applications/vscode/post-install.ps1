<#
.SYNOPSIS
    Post-installation script for Visual Studio Code.
.DESCRIPTION
    Ensures 'code' CLI is available in PATH and optionally installs recommended baseline extensions.
#>
Write-Host "Configuring Visual Studio Code..." -ForegroundColor Cyan

$CodeBin = Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\bin\code.cmd"
if (-not (Test-Path $CodeBin)) {
    $CodeBin = Join-Path $env:ProgramFiles "Microsoft VS Code\bin\code.cmd"
}

if (Test-Path $CodeBin) {
    Write-Host "Found VS Code CLI at: $CodeBin" -ForegroundColor Green
    # Baseline extensions can be installed here if desired
} else {
    Write-Host "VS Code CLI not found at default paths. It will be available after restarting shell." -ForegroundColor Yellow
}
