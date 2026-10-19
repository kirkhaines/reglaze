<#
.SYNOPSIS
    Catalog loader and lookup service for Reglaze applications.
#>

. (Join-Path $PSScriptRoot "ConfigResolver.ps1")

function Get-ReglazeCatalog {
    param (
        [string]$RepoRoot = $null
    )

    if (-not $RepoRoot) {
        $RepoRoot = Get-ReglazeRootDirectory
    }

    $Catalog = @()
    $ModularDir = Join-Path $RepoRoot "data\applications"

    if (Test-Path $ModularDir) {
        $AppFolders = Get-ChildItem -Directory -Path $ModularDir | Where-Object { $_.Name -notlike "_*" }
        foreach ($Folder in $AppFolders) {
            $ManifestFile = Join-Path $Folder.FullName "app.json"
            if (Test-Path $ManifestFile) {
                try {
                    $Content = Get-Content -Raw -Path $ManifestFile | ConvertFrom-Json
                    # Store path to app folder on object for reference to support scripts
                    Add-Member -InputObject $Content -MemberType NoteProperty -Name "_CatalogFolder" -Value $Folder.FullName -Force
                    $Catalog += $Content
                } catch {
                    Write-Warning "Failed to parse application manifest: $ManifestFile ($($_.Exception.Message))"
                }
            }
        }
    }

    # Fallback to monolithic applications.json if modular catalog is empty
    if ($Catalog.Count -eq 0) {
        $MonolithicFile = Join-Path $RepoRoot "data\applications.json"
        if (Test-Path $MonolithicFile) {
            $Catalog = Get-Content -Raw -Path $MonolithicFile | ConvertFrom-Json
        }
    }

    return $Catalog
}

function Get-ReglazeApplicationById {
    param (
        [Parameter(Mandatory=$true)]
        [string]$AppId,
        [string]$RepoRoot = $null
    )

    $Catalog = Get-ReglazeCatalog -RepoRoot $RepoRoot
    return ($Catalog | Where-Object { $_.app_id -eq $AppId } | Select-Object -First 1)
}
