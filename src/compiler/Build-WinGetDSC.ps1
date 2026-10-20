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

        [Parameter(Mandatory=$true)]
        [string]$OutputPath
    )

    if (-not $RepoRoot) {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }

    $PackagesToInstall = [System.Collections.Generic.List[PSCustomObject]]::new()
    $SeenPackageIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # 1. Inspect Applications section in blueprint
    if ($Blueprint.applications) {
        $AppProperties = @($Blueprint.applications.PSObject.Properties)
        foreach ($Prop in $AppProperties) {
            $AppId = $Prop.Name
            $AppConfig = $Prop.Value

            # If user explicitly disabled installation for this app
            if ($null -ne $AppConfig.install -and ($AppConfig.install -eq $false -or $AppConfig.install.enabled -eq $false)) {
                continue
            }

            $PackageId = $null
            $Source = "winget"
            $AppName = $AppId

            # Check if explicit install info in blueprint
            if ($AppConfig.install -and $AppConfig.install.package_id) {
                if (-not $AppConfig.install.method -or $AppConfig.install.method -eq "winget") {
                    $PackageId = [string]$AppConfig.install.package_id
                    if ($AppConfig.install.source) {
                        $Source = [string]$AppConfig.install.source
                    }
                }
            } elseif ($AppConfig.install -and $AppConfig.install.method -and $AppConfig.install.method -ne "winget") {
                # Non-winget install method explicitly declared (e.g. steam, manual)
                continue
            } else {
                # Look up in application catalog
                $CatalogApp = Get-ReglazeApplicationById -AppId $AppId -RepoRoot $RepoRoot
                if ($CatalogApp) {
                    $AppName = if ($CatalogApp.name) { $CatalogApp.name } else { $AppId }
                    $Method = if ($CatalogApp.install -and $CatalogApp.install.method) { $CatalogApp.install.method } else { "winget" }
                    if ($Method -eq "winget" -and $CatalogApp.install -and $CatalogApp.install.winget_id) {
                        $PackageId = [string]$CatalogApp.install.winget_id
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
                    $PackagesToInstall.Add([PSCustomObject]@{
                        AppId      = $AppId
                        AppName    = $AppName
                        PackageId  = $PackageId
                        ResourceId = "WinGetPackage_$CleanResourceId"
                        Source     = $Source
                    })
                }
            }
        }
    }

    # 2. Inspect Custom Applications section
    if ($Blueprint.custom -and $Blueprint.custom -is [System.Collections.IEnumerable]) {
        foreach ($CustomApp in $Blueprint.custom) {
            if ($CustomApp.install -and $CustomApp.install.package_id) {
                $Method = if ($CustomApp.install.method) { $CustomApp.install.method } else { "winget" }
                if ($Method -eq "winget") {
                    $PackageId = [string]$CustomApp.install.package_id
                    $Source = if ($CustomApp.install.source) { [string]$CustomApp.install.source } else { "winget" }
                    if ($Source -eq "winget" -and ($PackageId -match '^[A-Z0-9]{12}$' -or $PackageId -match '^9[A-Z0-9]{11}$')) {
                        $Source = "msstore"
                    }

                    if (-not $SeenPackageIds.Contains($PackageId)) {
                        $SeenPackageIds.Add($PackageId) | Out-Null
                        $CleanResourceId = ($PackageId -replace '[^a-zA-Z0-9_]', '_')
                        $CustomName = if ($CustomApp.name) { $CustomApp.name } else { $PackageId }
                        $PackagesToInstall.Add([PSCustomObject]@{
                            AppId      = "custom"
                            AppName    = $CustomName
                            PackageId  = $PackageId
                            ResourceId = "WinGetPackage_$CleanResourceId"
                            Source     = $Source
                        })
                    }
                }
            }
        }
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
        OutputPath   = $OutputPath
        PackageCount = $PackagesToInstall.Count
        Packages     = $PackagesToInstall.ToArray()
    }
}
