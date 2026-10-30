<#
.SYNOPSIS
    Catalog loader and lookup service for Reglaze applications.
#>

. (Join-Path $PSScriptRoot "ConfigResolver.ps1")

function Get-ReglazeCatalog {
    param (
        [string]$RepoRoot = $null,
        [string]$UserConfigDir = $null,
        [string]$UserCatalogPath = $null
    )

    if (-not $RepoRoot) {
        $RepoRoot = Get-ReglazeRootDirectory
    }

    $CatalogMap = [ordered]@{}
    $ModularDir = Join-Path $RepoRoot "data\applications"

    if (Test-Path $ModularDir) {
        $AppFolders = Get-ChildItem -Directory -Path $ModularDir | Where-Object { $_.Name -notlike "_*" }
        foreach ($Folder in $AppFolders) {
            $ManifestFile = Join-Path $Folder.FullName "app.json"
            if (Test-Path $ManifestFile) {
                try {
                    $Content = Get-Content -Raw -Path $ManifestFile -Encoding UTF8 | ConvertFrom-Json
                    if ($Content -and $Content.app_id) {
                        Add-Member -InputObject $Content -MemberType NoteProperty -Name "_CatalogFolder" -Value $Folder.FullName -Force
                        Add-Member -InputObject $Content -MemberType NoteProperty -Name "_CatalogSource" -Value "builtin" -Force
                        $CatalogMap[$Content.app_id] = $Content
                    }
                } catch {
                    Write-Warning "Failed to parse application manifest: $ManifestFile ($($_.Exception.Message))"
                }
            }
        }
    }

    # Fallback to monolithic applications.json if modular catalog is empty
    $BuiltinMonolithicFile = Join-Path $RepoRoot "data\applications.json"
    if ($CatalogMap.Count -eq 0 -and (Test-Path $BuiltinMonolithicFile)) {
        try {
            $BuiltinList = Get-Content -Raw -Path $BuiltinMonolithicFile -Encoding UTF8 | ConvertFrom-Json
            foreach ($Item in @($BuiltinList)) {
                if ($Item -and $Item.app_id) {
                    Add-Member -InputObject $Item -MemberType NoteProperty -Name "_CatalogFolder" -Value (Split-Path -Parent $BuiltinMonolithicFile) -Force
                    Add-Member -InputObject $Item -MemberType NoteProperty -Name "_CatalogSource" -Value "builtin" -Force
                    $CatalogMap[$Item.app_id] = $Item
                }
            }
        } catch {
            Write-Warning "Failed to parse built-in applications.json: $($_.Exception.Message)"
        }
    }

    # Resolve optional user applications.json in user's Reglaze config/output directory
    $ResolvedUserCatalog = $null
    if (-not [string]::IsNullOrWhiteSpace($UserCatalogPath) -and (Test-Path -LiteralPath $UserCatalogPath)) {
        $ResolvedUserCatalog = (Resolve-Path -LiteralPath $UserCatalogPath).Path
    } elseif (-not [string]::IsNullOrWhiteSpace($UserConfigDir)) {
        $Candidate = Join-Path $UserConfigDir "applications.json"
        if (Test-Path -LiteralPath $Candidate) {
            $ResolvedUserCatalog = (Resolve-Path -LiteralPath $Candidate).Path
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($env:REGLAZE_DIR)) {
        $Candidate = Join-Path $env:REGLAZE_DIR "applications.json"
        if (Test-Path -LiteralPath $Candidate) {
            $ResolvedUserCatalog = (Resolve-Path -LiteralPath $Candidate).Path
        }
    }

    # Ensure we don't accidentally treat the repo's own data\applications.json as a user catalog
    if ($ResolvedUserCatalog -and (Test-Path -LiteralPath $BuiltinMonolithicFile)) {
        $BuiltinResolved = (Resolve-Path -LiteralPath $BuiltinMonolithicFile).Path
        if ($ResolvedUserCatalog -ieq $BuiltinResolved) {
            $ResolvedUserCatalog = $null
        }
    }

    if ($ResolvedUserCatalog -and (Test-Path -LiteralPath $ResolvedUserCatalog)) {
        try {
            $UserRaw = Get-Content -Raw -LiteralPath $ResolvedUserCatalog -Encoding UTF8 | ConvertFrom-Json
            $UserEntries = @()
            if ($UserRaw -is [System.Collections.IEnumerable] -and -not ($UserRaw -is [string])) {
                $UserEntries = @($UserRaw)
            } elseif ($UserRaw -and $UserRaw.applications -and ($UserRaw.applications -is [System.Collections.IEnumerable])) {
                $UserEntries = @($UserRaw.applications)
            } elseif ($UserRaw -and $UserRaw.app_id) {
                $UserEntries = @($UserRaw)
            }

            $UserFolder = Split-Path -Parent $ResolvedUserCatalog
            foreach ($UApp in $UserEntries) {
                if ($UApp -and $UApp.app_id) {
                    if ($null -eq $UApp.PSObject.Properties['directories'] -or $null -eq $UApp.directories) {
                        Add-Member -InputObject $UApp -MemberType NoteProperty -Name "directories" -Value @() -Force
                    }
                    Add-Member -InputObject $UApp -MemberType NoteProperty -Name "_CatalogFolder" -Value $UserFolder -Force
                    Add-Member -InputObject $UApp -MemberType NoteProperty -Name "_CatalogSource" -Value "user" -Force
                    $CatalogMap[$UApp.app_id] = $UApp
                }
            }
        } catch {
            Write-Warning "Failed to parse user applications.json at '$ResolvedUserCatalog': $($_.Exception.Message)"
        }
    }

    return @($CatalogMap.Values)
}

function Get-ReglazeApplicationById {
    param (
        [Parameter(Mandatory=$true)]
        [string]$AppId,
        [string]$RepoRoot = $null,
        [string]$UserConfigDir = $null,
        [string]$UserCatalogPath = $null
    )

    $Catalog = Get-ReglazeCatalog -RepoRoot $RepoRoot -UserConfigDir $UserConfigDir -UserCatalogPath $UserCatalogPath
    return ($Catalog | Where-Object { $_.app_id -eq $AppId } | Select-Object -First 1)
}
