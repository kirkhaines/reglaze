<#
.SYNOPSIS
    Semantic and safety validation engine for Reglaze blueprints.
.DESCRIPTION
    Validates reglaze.yaml structure, verifies safe_for_stream rules against the catalog,
    ensures mandatory directory mappings exist, checks variable token resolution, and
    verifies target OS disk isolation.
#>
[CmdletBinding()]
param(
    [string]$ConfigFile = $null,
    [string]$RepoRoot = $null
)

if (-not $RepoRoot) {
    $RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    if (-not (Test-Path (Join-Path $RepoRoot "data\applications"))) {
        $RepoRoot = (Get-Location).Path
    }
}

. (Join-Path $RepoRoot "src\common\Logging.ps1")
. (Join-Path $RepoRoot "src\common\ConfigResolver.ps1")
. (Join-Path $RepoRoot "src\common\Catalog.ps1")
. (Join-Path $RepoRoot "src\common\YamlParser.ps1")
. (Join-Path $RepoRoot "src\compiler\Resolve-Variables.ps1")

function Test-ReglazeBlueprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [string]$RepoRoot = $null
    )

    $Errors = [System.Collections.Generic.List[string]]::new()
    $Warnings = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Path $Path)) {
        $Errors.Add("Blueprint file not found at: $Path")
        return [PSCustomObject]@{
            IsValid   = $false
            Errors    = $Errors.ToArray()
            Warnings  = $Warnings.ToArray()
            Blueprint = $null
        }
    }

    # 1. Parse YAML Blueprint
    $Blueprint = $null
    try {
        $Blueprint = Get-ReglazeBlueprintObject -Path $Path
    } catch {
        $Errors.Add("Failed to parse blueprint YAML: $($_.Exception.Message)")
        return [PSCustomObject]@{
            IsValid   = $false
            Errors    = $Errors.ToArray()
            Warnings  = $Warnings.ToArray()
            Blueprint = $null
        }
    }

    # 2. Check Top-Level Structure
    if (-not $Blueprint.version) { $Errors.Add("Missing required root property 'version'.") }
    if (-not $Blueprint.system) { $Errors.Add("Missing required root section 'system'.") }
    if (-not $Blueprint.disks) { $Errors.Add("Missing required root section 'disks'.") }
    if (-not $Blueprint.storage) { $Errors.Add("Missing required root section 'storage'.") }

    # 3. Check Users
    if ($Blueprint.system -and $Blueprint.system.users) {
        if (-not $Blueprint.system.users.local_admin -or -not $Blueprint.system.users.local_admin.username) {
            $Errors.Add("Missing required user 'local_admin.username'.")
        }
        if (-not $Blueprint.system.users.primary_user -or -not $Blueprint.system.users.primary_user.username) {
            $Errors.Add("Missing required user 'primary_user.username'.")
        }
    } else {
        $Errors.Add("Missing required section 'system.users'.")
    }

    # 4. Check Disks & Target OS Isolation
    $OsDiskId = $null
    if ($Blueprint.disks.target_os_disk) {
        $OsDiskId = $Blueprint.disks.target_os_disk.disk_id
        if ($null -eq $OsDiskId -and -not $Blueprint.disks.target_os_disk.serial_number) {
            $Errors.Add("Target OS disk must specify either 'disk_id' or 'serial_number'.")
        }
    } else {
        $Errors.Add("Missing required section 'disks.target_os_disk'.")
    }

    if ($Blueprint.disks.preserved_disks) {
        foreach ($PDisk in $Blueprint.disks.preserved_disks) {
            if ($null -ne $OsDiskId -and $PDisk.disk_id -eq $OsDiskId) {
                $Errors.Add("Disk conflict: Preserved disk ID $($PDisk.disk_id) matches Target OS disk ID $($OsDiskId).")
            }
        }
    }

    # 5. Extract & Test Variable Resolution Map
    $VarMap = $null
    try {
        $VarMap = Get-BlueprintVariables -Blueprint $Blueprint
    } catch {
        $Errors.Add("Error building variable resolution map: $($_.Exception.Message)")
    }

    # 6. Safety & Application Catalog Validation
    $Catalog = Get-ReglazeCatalog -RepoRoot $RepoRoot

    if ($Blueprint.applications) {
        $AppProps = @($Blueprint.applications.PSObject.Properties)
        foreach ($Prop in $AppProps) {
            $AppId = $Prop.Name
            $AppConfig = $Prop.Value
            $CatalogApp = $Catalog | Where-Object { $_.app_id -eq $AppId } | Select-Object -First 1

            if (-not $CatalogApp) {
                $Warnings.Add("Application '$AppId' is declared in blueprint but not found in Reglaze catalog (treated as custom application).")
                continue
            }

            if ($CatalogApp.directories) {
                foreach ($Dir in $CatalogApp.directories) {
                    $ConfiguredTarget = $null
                    if ($AppConfig.directories -and $AppConfig.directories.$($Dir.id)) {
                        $ConfiguredTarget = $AppConfig.directories.$($Dir.id).target
                    }

                    # Check mandatory mapping
                    if ($Dir.needs_mapping -and [string]::IsNullOrWhiteSpace($ConfiguredTarget)) {
                        $Warnings.Add("Application '$AppId' has directory '$($Dir.id)' with needs_mapping: true, but no target is configured in blueprint.")
                    }

                    # Check safe_for_stream rule
                    if ($ConfiguredTarget) {
                        $ResolvedTarget = Resolve-VariableString -InputString $ConfiguredTarget -VariableMap $VarMap
                        $StreamRoot = if ($VarMap.ContainsKey("STREAM")) { $VarMap["STREAM"] } else { "" }

                        $IsStreaming = ($ConfiguredTarget -like "*%STREAM%*" -or ($StreamRoot -and $ResolvedTarget.StartsWith($StreamRoot, [System.StringComparison]::OrdinalIgnoreCase)))

                        if (-not $Dir.safe_for_stream -and $IsStreaming) {
                            $ForceOverride = ($AppConfig.directories.$($Dir.id).override -and $AppConfig.directories.$($Dir.id).override.action -eq "force_stream")
                            if (-not $ForceOverride) {
                                $Errors.Add("Safety Violation in app '$AppId', directory '$($Dir.id)': Catalog specifies safe_for_stream: false (notes: $($Dir.notes)), but target resolves to streaming storage: '$ConfiguredTarget'. Must use a local sync root or explicit override.")
                            }
                        }

                        # Check for unresolved tokens
                        $Unresolved = Test-UnresolvedTokens -InputString $ResolvedTarget
                        if ($Unresolved.Count -gt 0) {
                            $Errors.Add("Unresolvable variable token(s) in app '$AppId', directory '$($Dir.id)': $($Unresolved -join ', ')")
                        }
                    }
                }
            }
        }
    }

    return [PSCustomObject]@{
        IsValid   = ($Errors.Count -eq 0)
        Errors    = $Errors.ToArray()
        Warnings  = $Warnings.ToArray()
        Blueprint = $Blueprint
    }
}

# Standalone execution support
if ($ConfigFile -or $MyInvocation.InvocationName -ne '.') {
    $TargetFile = if ($ConfigFile) { $ConfigFile } else { Resolve-ReglazeConfigFile }
    if ($TargetFile) {
        $Result = Test-ReglazeBlueprint -Path $TargetFile -RepoRoot $RepoRoot
        if ($Result.Warnings.Count -gt 0) {
            foreach ($Warn in $Result.Warnings) {
                Write-ReglazeWarning $Warn
            }
        }
        if (-not $Result.IsValid) {
            foreach ($Err in $Result.Errors) {
                Write-ReglazeError $Err
            }
            Write-ReglazeError "Blueprint validation failed with $($Result.Errors.Count) error(s)."
            exit 1
        } else {
            Write-ReglazeSuccess "Blueprint validated successfully: $TargetFile"
        }
    }
}
