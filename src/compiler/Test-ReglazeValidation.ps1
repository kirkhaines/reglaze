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

    # 7. Check dev_repos variable tokens
    if ($Blueprint.dev_repos -and $Blueprint.dev_repos.root) {
        $ResolvedDevRoot = Resolve-VariableString -InputString $Blueprint.dev_repos.root -VariableMap $VarMap
        $DevUnresolved = Test-UnresolvedTokens -InputString $ResolvedDevRoot
        if ($DevUnresolved.Count -gt 0) {
            $Errors.Add("Unresolvable variable token(s) in dev_repos.root '$($Blueprint.dev_repos.root)': $($DevUnresolved -join ', ')")
        }
    }

    # 8. Directory Junction Integrity & Filesystem Rules Validation
    # Enforces Windows NTFS Reparse Point constraints, filesystem rules, target drive existence,
    # UNC rejection, circular loop prevention, and parent/child nesting prevention.
    $AllowedTargetDrives = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $AllowedTargetDrives.Add("C:") | Out-Null
    if ($Blueprint.storage -and $Blueprint.storage.streaming -and $Blueprint.storage.streaming.mount_point) {
        $StreamDrive = ([System.IO.Path]::GetPathRoot($Blueprint.storage.streaming.mount_point)).TrimEnd('\')
        if ($StreamDrive) { $AllowedTargetDrives.Add($StreamDrive) | Out-Null }
    }
    if ($Blueprint.disks -and $Blueprint.disks.preserved_disks) {
        foreach ($PDisk in $Blueprint.disks.preserved_disks) {
            if ($PDisk.expected_mount) {
                $PDrive = ([System.IO.Path]::GetPathRoot($PDisk.expected_mount)).TrimEnd('\')
                if ($PDrive) { $AllowedTargetDrives.Add($PDrive) | Out-Null }
            }
        }
    }
    if ($Blueprint.storage -and $Blueprint.storage.sync -and $Blueprint.storage.sync.directories) {
        $SyncDirs = $Blueprint.storage.sync.directories
        $DirProps = if ($SyncDirs -is [System.Collections.IDictionary]) { $SyncDirs.Keys } else { $SyncDirs.PSObject.Properties.Name }
        foreach ($Prop in $DirProps) {
            $DirObj = if ($SyncDirs -is [System.Collections.IDictionary]) { $SyncDirs[$Prop] } else { $SyncDirs.$Prop }
            if ($DirObj.local_path) {
                $ResolvedSyncPath = Resolve-VariableString -InputString $DirObj.local_path -VariableMap $VarMap
                $SyncDrive = ([System.IO.Path]::GetPathRoot($ResolvedSyncPath)).TrimEnd('\')
                if ($SyncDrive) { $AllowedTargetDrives.Add($SyncDrive) | Out-Null }
            }
        }
    }

    $AllJunctions = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Collect from applications
    if ($Blueprint.applications) {
        $AppProps = @($Blueprint.applications.PSObject.Properties)
        foreach ($Prop in $AppProps) {
            $AppId = $Prop.Name
            $AppConfig = $Prop.Value
            $CatalogApp = $Catalog | Where-Object { $_.app_id -eq $AppId } | Select-Object -First 1

            if ($CatalogApp -and $CatalogApp.directories) {
                foreach ($Dir in $CatalogApp.directories) {
                    $ConfiguredTarget = $null
                    $ConfiguredLink = $null
                    $IsOmitted = $false

                    if ($AppConfig.directories -and $AppConfig.directories.$($Dir.id)) {
                        $DirConf = $AppConfig.directories.$($Dir.id)
                        $ConfiguredTarget = $DirConf.target
                        if ($DirConf.link) { $ConfiguredLink = $DirConf.link }
                        if ($DirConf.override -and $DirConf.override.action -eq "omit") { $IsOmitted = $true }
                    }

                    if ($IsOmitted) { continue }
                    if (-not $ConfiguredLink) { $ConfiguredLink = $Dir.default_path }

                    if ($ConfiguredTarget) {
                        $ResolvedLink = Resolve-VariableString -InputString $ConfiguredLink -VariableMap $VarMap
                        $ResolvedTarget = Resolve-VariableString -InputString $ConfiguredTarget -VariableMap $VarMap

                        $AllJunctions.Add([PSCustomObject]@{
                            AppId            = $AppId
                            DirectoryId      = $Dir.id
                            Link             = $ResolvedLink
                            Target           = $ResolvedTarget
                            RawTarget        = $ConfiguredTarget
                            RawLink          = $ConfiguredLink
                            SafeForStream    = [bool]$Dir.safe_for_stream
                        })
                    }
                }
            }
        }
    }

    # Collect from custom
    if ($Blueprint.custom -and $Blueprint.custom -is [System.Collections.IEnumerable]) {
        foreach ($CustomApp in $Blueprint.custom) {
            if ($CustomApp.directories) {
                foreach ($CustDir in $CustomApp.directories) {
                    if ($CustDir.link -and $CustDir.target) {
                        $ResolvedLink = Resolve-VariableString -InputString $CustDir.link -VariableMap $VarMap
                        $ResolvedTarget = Resolve-VariableString -InputString $CustDir.target -VariableMap $VarMap

                        $AllJunctions.Add([PSCustomObject]@{
                            AppId            = "custom"
                            DirectoryId      = if ($CustDir.name) { $CustDir.name } else { "custom" }
                            Link             = $ResolvedLink
                            Target           = $ResolvedTarget
                            RawTarget        = $CustDir.target
                            RawLink          = $CustDir.link
                            SafeForStream    = $true
                        })
                    }
                }
            }
        }
    }

    # Validate individual junction rules
    foreach ($Junc in $AllJunctions) {
        $AppId = $Junc.AppId
        $DirId = $Junc.DirectoryId
        $Link = $Junc.Link
        $Target = $Junc.Target

        # 1. Unresolved tokens
        $LinkUnresolved = Test-UnresolvedTokens -InputString $Link
        if ($LinkUnresolved.Count -gt 0) {
            $Errors.Add("Unresolvable variable token(s) in junction link for app '$AppId', directory '$DirId': $($LinkUnresolved -join ', ')")
        }
        $TargetUnresolved = Test-UnresolvedTokens -InputString $Target
        if ($TargetUnresolved.Count -gt 0) {
            $Errors.Add("Unresolvable variable token(s) in junction target for app '$AppId', directory '$DirId': $($TargetUnresolved -join ', ')")
        }

        # 2. Syntax & Absolute Path Rules
        if ($Link -notmatch '^[a-zA-Z]:\\') {
            $Errors.Add("Junction link (source) for app '$AppId', directory '$DirId' must be an absolute path with a drive letter: '$Link'")
        }
        if ($Target -notmatch '^[a-zA-Z]:\\') {
            # Check if network UNC path
            if ($Junc.RawTarget -like "\\\\*" -or $Target -like "\\\\*") {
                $Errors.Add("Junction target for app '$AppId', directory '$DirId' points to a network UNC path: '$Target'. Windows NTFS directory junctions strictly require local drive letter paths and do not support UNC network targets.")
            } else {
                $Errors.Add("Junction target (destination) for app '$AppId', directory '$DirId' must be an absolute path with a drive letter: '$Target'")
            }
        }

        # 3. Bare drive root check
        if ($Link -match '^[a-zA-Z]:\\?$') {
            $Errors.Add("Junction link (source) cannot replace an entire drive root: '$Link'")
        }
        if ($Target -match '^[a-zA-Z]:\\?$') {
            $Errors.Add("Junction target (destination) cannot point to an entire drive root: '$Target'")
        }

        # 4. Source and target identical check
        if ($Link.TrimEnd('\').Equals($Target.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
            $Errors.Add("Junction source (Link) and destination (Target) cannot be the same path for app '$AppId', directory '$DirId': '$Link'")
        }

        # 5. Target drive existence check
        $TargetDrive = ([System.IO.Path]::GetPathRoot($Target)).TrimEnd('\')
        if ($TargetDrive -and -not $AllowedTargetDrives.Contains($TargetDrive)) {
            $Errors.Add("Junction target drive '$TargetDrive' for app '$AppId', directory '$DirId' ('$Target') is not declared in blueprint storage topology (target_os_disk, preserved_disks, or streaming mount).")
        }

        # 6. Circular reference check
        $LinkDrive = ([System.IO.Path]::GetPathRoot($Link)).TrimEnd('\')
        if ($LinkDrive -and $TargetDrive -and $LinkDrive.Equals($TargetDrive, [System.StringComparison]::OrdinalIgnoreCase)) {
            $NormLink = $Link.TrimEnd('\') + "\"
            $NormTarget = $Target.TrimEnd('\') + "\"
            if ($NormTarget.StartsWith($NormLink, [System.StringComparison]::OrdinalIgnoreCase) -or $NormLink.StartsWith($NormTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
                $Errors.Add("Circular loop detected: Junction link '$Link' and target '$Target' are nested within each other on the same drive '$LinkDrive'.")
            }
        }
    }

    # Cross-junction collision and nesting validation
    for ($i = 0; $i -lt $AllJunctions.Count; $i++) {
        for ($j = $i + 1; $j -lt $AllJunctions.Count; $j++) {
            $JuncA = $AllJunctions[$i]
            $JuncB = $AllJunctions[$j]
            $NormLinkA = $JuncA.Link.TrimEnd('\')
            $NormLinkB = $JuncB.Link.TrimEnd('\')

            # Duplicate Link collision
            if ($NormLinkA.Equals($NormLinkB, [System.StringComparison]::OrdinalIgnoreCase)) {
                $Errors.Add("Duplicate junction link collision: App '$($JuncA.AppId)' and App '$($JuncB.AppId)' both define the same link path: '$NormLinkA'")
            }

            # Parent-Child Nesting
            if ($NormLinkB.StartsWith($NormLinkA + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
                $Errors.Add("Nested junction collision: Link '$NormLinkB' (App '$($JuncB.AppId)', Dir '$($JuncB.DirectoryId)') is nested inside parent link '$NormLinkA' (App '$($JuncA.AppId)', Dir '$($JuncA.DirectoryId)'). Windows directory junctions cannot be created inside another junction. Omit the child directory with override.action: 'omit' or map to a parent.")
            } elseif ($NormLinkA.StartsWith($NormLinkB + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
                $Errors.Add("Nested junction collision: Link '$NormLinkA' (App '$($JuncA.AppId)', Dir '$($JuncA.DirectoryId)') is nested inside parent link '$NormLinkB' (App '$($JuncB.AppId)', Dir '$($JuncB.DirectoryId)'). Windows directory junctions cannot be created inside another junction. Omit the child directory with override.action: 'omit' or map to a parent.")
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
