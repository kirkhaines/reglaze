<#
.SYNOPSIS
    Post-installation script template for application customization.
.PARAMETER TargetDirectory
    The resolved installation path of the application.
#>
param (
    [string]$TargetDirectory
)

Write-Host "Running post-install configuration for application..." -ForegroundColor Cyan
# Add registry keys, copy baseline settings, or create shortcuts here
