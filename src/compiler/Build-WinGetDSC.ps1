<#
.SYNOPSIS
    WinGet DSC Configuration Manifest Generator for Reglaze.
.DESCRIPTION
    Compiles declarative application requirements from reglaze.yaml and the application catalog
    into a valid Microsoft.WinGet.DSC configuration manifest (configuration.dsc.yaml) for non-interactive
    system-wide application deployment.
#>
[CmdletBinding()]
param()

$CompilerRoot = $PSScriptRoot
$CommonRoot = Join-Path (Split-Path -Parent $CompilerRoot) "common"
. (Join-Path $CommonRoot "Catalog.ps1")

function Build-WinGetDSCManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Blueprint,

        [Parameter(Mandatory=$false)]
        [string]$RepoRoot = $null,

        [Parameter(Mandatory=$false)]
        [string]$UserConfigDir = $null,

        [Parameter(Mandatory=$true)]
        [string]$OutputPath
    )

    if (-not $RepoRoot) {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }

    $PackagesToInstall = [System.Collections.Generic.List[PSCustomObject]]::new()
    $UserPackagesToInstall = [System.Collections.Generic.List[PSCustomObject]]::new()
    $SeenPackageIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # 1. Inspect Applications section in blueprint
    if ($Blueprint.applications) {
        $AppProperties = @($Blueprint.applications.PSObject.Properties)
        foreach ($Prop in $AppProperties) {
            $AppId = $Prop.Name
            if ($AppId -eq "custom") { continue }
            $AppConfig = $Prop.Value

            # If user explicitly disabled installation for this app
            if ($null -ne $AppConfig.install -and ($AppConfig.install -eq $false -or $AppConfig.install.enabled -eq $false)) {
                continue
            }

            $PackageId = $null
            $Source = "winget"
            $AppName = $AppId
            $Scope = "machine"

            # Look up in application catalog (built-in + user applications.json)
            $CatalogApp = Get-ReglazeApplicationById -AppId $AppId -RepoRoot $RepoRoot -UserConfigDir $UserConfigDir
            if ($CatalogApp) {
                if ($CatalogApp.name) { $AppName = $CatalogApp.name }
                if ($CatalogApp.install -and $CatalogApp.install.scope) {
                    $Scope = [string]$CatalogApp.install.scope
                } elseif ($CatalogApp.install -and $CatalogApp.install.default_target_directory -match '^%(LOCALAPPDATA|APPDATA|USERPROFILE)%') {
                    $Scope = "user"
                }
            }
            if ($AppConfig.install -and $AppConfig.install.scope) {
                $Scope = [string]$AppConfig.install.scope
            }

            # Check if explicit install info in blueprint
            $ExplicitPkgId = if ($AppConfig.install -and $AppConfig.install.package_id) {
                [string]$AppConfig.install.package_id
            } elseif ($AppConfig.install -and $AppConfig.install.winget_id) {
                [string]$AppConfig.install.winget_id
            } else {
                $null
            }

            if ($ExplicitPkgId) {
                if (-not $AppConfig.install.method -or $AppConfig.install.method -eq "winget") {
                    $PackageId = $ExplicitPkgId
                    if ($AppConfig.install.source) {
                        $Source = [string]$AppConfig.install.source
                    }
                }
            } elseif ($AppConfig.install -and $AppConfig.install.method -and $AppConfig.install.method -ne "winget") {
                # Non-winget install method explicitly declared (e.g. steam, manual)
                continue
            } elseif ($CatalogApp) {
                $Method = if ($CatalogApp.install -and $CatalogApp.install.method) { $CatalogApp.install.method } else { "winget" }
                if ($Method -eq "winget" -and $CatalogApp.install) {
                    if ($CatalogApp.install.winget_id) {
                        $PackageId = [string]$CatalogApp.install.winget_id
                    } elseif ($CatalogApp.install.package_id) {
                        $PackageId = [string]$CatalogApp.install.package_id
                    }
                }
            }

            if ($PackageId) {
                # Automatic source detection for Microsoft Store product IDs (e.g., XP8CLZL93F5Z4P, 9WZDNCRFJ3TJ)
                if ($Source -eq "winget" -and ($PackageId -notmatch '\.' -and $PackageId -match '^[A-Z0-9]{10,15}$')) {
                    $Source = "msstore"
                }

                if (-not $SeenPackageIds.Contains($PackageId)) {
                    $SeenPackageIds.Add($PackageId) | Out-Null
                    $CleanResourceId = ($PackageId -replace '[^a-zA-Z0-9_]', '_')
                    $PkgEntry = [PSCustomObject]@{
                        AppId      = $AppId
                        AppName    = $AppName
                        PackageId  = $PackageId
                        ResourceId = "WinGetPackage_$CleanResourceId"
                        Source     = $Source
                        Scope      = $Scope
                    }
                    if ($Scope -ieq "user") {
                        $UserPackagesToInstall.Add($PkgEntry)
                    } else {
                        $PackagesToInstall.Add($PkgEntry)
                    }
                }
            }
        }
    }

    # 2. Inspect Custom Applications section (both applications.custom and top-level custom)
    $CombinedCustomApps = @()
    if ($Blueprint.applications -and $Blueprint.applications.custom -and ($Blueprint.applications.custom -is [System.Collections.IEnumerable]) -and -not ($Blueprint.applications.custom -is [string])) {
        $CombinedCustomApps += @($Blueprint.applications.custom)
    }
    if ($Blueprint.custom -and ($Blueprint.custom -is [System.Collections.IEnumerable]) -and -not ($Blueprint.custom -is [string])) {
        $CombinedCustomApps += @($Blueprint.custom)
    }
    foreach ($CustomApp in $CombinedCustomApps) {
        if ($null -ne $CustomApp.install -and ($CustomApp.install -eq $false -or $CustomApp.install.enabled -eq $false)) {
            continue
        }
        $CustPkgId = if ($CustomApp.install -and $CustomApp.install.package_id) {
            [string]$CustomApp.install.package_id
        } elseif ($CustomApp.install -and $CustomApp.install.winget_id) {
            [string]$CustomApp.install.winget_id
        } elseif ($CustomApp.winget_id) {
            [string]$CustomApp.winget_id
        } else {
            $null
        }
        if ($CustPkgId) {
            $Method = if ($CustomApp.install -and $CustomApp.install.method) { $CustomApp.install.method } else { "winget" }
            if ($Method -eq "winget") {
                $PackageId = $CustPkgId
                $Source = if ($CustomApp.install -and $CustomApp.install.source) { [string]$CustomApp.install.source } else { "winget" }
                $CustScope = if ($CustomApp.install -and $CustomApp.install.scope) {
                    [string]$CustomApp.install.scope
                } elseif ($CustomApp.scope) {
                    [string]$CustomApp.scope
                } else {
                    "machine"
                }
                if ($Source -eq "winget" -and ($PackageId -match '^[A-Z0-9]{12}$' -or $PackageId -match '^9[A-Z0-9]{11}$' -or ($PackageId -notmatch '\.' -and $PackageId -match '^[A-Z0-9]{10,15}$'))) {
                    $Source = "msstore"
                }

                if (-not $SeenPackageIds.Contains($PackageId)) {
                    $SeenPackageIds.Add($PackageId) | Out-Null
                    $CleanResourceId = ($PackageId -replace '[^a-zA-Z0-9_]', '_')
                    $CustomName = if ($CustomApp.name) { $CustomApp.name } else { $PackageId }
                    $CustEntry = [PSCustomObject]@{
                        AppId      = "custom"
                        AppName    = $CustomName
                        PackageId  = $PackageId
                        ResourceId = "WinGetPackage_$CleanResourceId"
                        Source     = $Source
                        Scope      = $CustScope
                    }
                    if ($CustScope -ieq "user") {
                        $UserPackagesToInstall.Add($CustEntry)
                    } else {
                        $PackagesToInstall.Add($CustEntry)
                    }
                }
            }
        }
    }

    # 2b. Auto-include Google Drive for Desktop if cloud streaming or sync uses Google Drive
    $UsesGoogleDrive = (
        ($Blueprint.storage -and $Blueprint.storage.streaming -and $Blueprint.storage.streaming.cloud_provider -eq "google-drive") -or
        ($Blueprint.storage -and $Blueprint.storage.sync -and $Blueprint.storage.sync.provider -eq "google-drive-sync")
    )
    $GDriveExplicitlyDisabled = (
        $Blueprint.applications -and
        $Blueprint.applications.google_drive -and
        $null -ne $Blueprint.applications.google_drive.install -and
        ($Blueprint.applications.google_drive.install -eq $false -or $Blueprint.applications.google_drive.install.enabled -eq $false)
    )
    if ($UsesGoogleDrive -and -not $GDriveExplicitlyDisabled -and -not $SeenPackageIds.Contains("Google.GoogleDrive")) {
        $SeenPackageIds.Add("Google.GoogleDrive") | Out-Null
        $PackagesToInstall.Add([PSCustomObject]@{
            AppId      = "google_drive"
            AppName    = "Google Drive"
            PackageId  = "Google.GoogleDrive"
            ResourceId = "WinGetPackage_Google_GoogleDrive"
            Source     = "winget"
        })
    }

    # 3. Format WinGet DSC YAML (Schema 0.2)
    $YamlLines = [System.Collections.Generic.List[string]]::new()
    $YamlLines.Add("# yaml-language-server: `$schema=https://aka.ms/configuration-dsc-schema/0.2")
    $YamlLines.Add("properties:")
    $YamlLines.Add("  configurationVersion: 0.2.0")
    $YamlLines.Add("  resources:")

    if ($PackagesToInstall.Count -eq 0) {
        $YamlLines.Add("    []")
    } else {
        foreach ($Pkg in $PackagesToInstall) {
            $YamlLines.Add("    - resource: Microsoft.WinGet.DSC/WinGetPackage")
            $YamlLines.Add("      id: $($Pkg.ResourceId)")
            $YamlLines.Add("      directives:")
            $YamlLines.Add("        description: Install $($Pkg.AppName)")
            $YamlLines.Add("        allowPrerelease: true")
            $YamlLines.Add("        securityContext: elevated")
            $YamlLines.Add("      settings:")
            $YamlLines.Add("        id: `"$($Pkg.PackageId)`"")
            $YamlLines.Add("        source: $($Pkg.Source)")
        }
    }

    $OutDir = Split-Path -Parent $OutputPath
    if ($OutDir -and -not (Test-Path $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }

    $YamlContent = $YamlLines -join "`n"
    $YamlContent | Set-Content -Path $OutputPath -Encoding UTF8

    return [PSCustomObject]@{
        OutputPath        = $OutputPath
        PackageCount      = $PackagesToInstall.Count
        Packages          = $PackagesToInstall.ToArray()
        UserPackageCount  = $UserPackagesToInstall.Count
        UserPackages      = $UserPackagesToInstall.ToArray()
    }
}
