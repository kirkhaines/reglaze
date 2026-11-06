<#
.SYNOPSIS
    Pre-install data migration planner and high-throughput staging engine for Reglaze.
.DESCRIPTION
    Provides two complementary pre-install workflows for users onboarding an existing
    Windows installation to Reglaze (where local application directories are not yet
    NTFS junctions):
      1. New-ReglazeMigrationPlan ('reglaze migration-plan'):
         Reads the edited reglaze.yaml, audit-reference.json, and application catalog
         to emit a human-editable draft manifest (migration-manifest.yaml) with measured
         directory sizes, file counts, and storage tier breakdowns.
      2. Invoke-ReglazePreInstallMigration ('reglaze migrate'):
         Reads the (optionally edited) migration-manifest.yaml, creates all required
         sync roots and target directories (%STREAM%, %SYNC_*%, %DATA_DRIVE%), and
         copies existing user data into the target folders using multi-threaded
         robocopy.exe (/MT:16 /E /XO) so all targets are populated before OS installation.
#>
[CmdletBinding()]
param()

$LinkingRoot = $PSScriptRoot
$SrcRoot = Split-Path -Parent $LinkingRoot
$RepoRoot = Split-Path -Parent $SrcRoot
$CommonRoot = Join-Path $SrcRoot "common"
$CompilerRoot = Join-Path $SrcRoot "compiler"

. (Join-Path $CommonRoot "Logging.ps1")
. (Join-Path $CommonRoot "ConfigResolver.ps1")
. (Join-Path $CommonRoot "Catalog.ps1")
. (Join-Path $CommonRoot "YamlParser.ps1")
. (Join-Path $CompilerRoot "Resolve-Variables.ps1")
. (Join-Path $LinkingRoot "Test-ReparsePoint.ps1")

function Format-ReglazeByteSize {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [int64]$Bytes
    )

    if ($Bytes -le 0) { return "0 B" }
    if ($Bytes -lt 1024) { return "$Bytes B" }
    if ($Bytes -lt 1048576) { return ("{0:N1} KB" -f ($Bytes / 1024.0)) }
    if ($Bytes -lt 1073741824) { return ("{0:N1} MB" -f ($Bytes / 1048576.0)) }
    return ("{0:N2} GB" -f ($Bytes / 1073741824.0))
}

function Format-RobocopyExitDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [int]$ExitCode
    )

    $Parts = [System.Collections.Generic.List[string]]::new()
    if ($ExitCode -eq 0) {
        $Parts.Add("No files copied; destination already up to date")
    }
    if ($ExitCode -band 1) {
        $Parts.Add("Files copied successfully")
    }
    if ($ExitCode -band 2) {
        $Parts.Add("Extra files exist in destination not in source")
    }
    if ($ExitCode -band 4) {
        $Parts.Add("Mismatched files or attributes detected")
    }
    if ($ExitCode -band 8) {
        $Parts.Add("Some files could not be copied (likely locked by running application)")
    }
    if ($ExitCode -band 16) {
        $Parts.Add("Fatal error (access denied, path invalid, or disk full)")
    }

    if ($Parts.Count -eq 0) { return "Code $ExitCode" }
    return ($Parts -join "; ")
}

function Get-ReglazePathStats {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    $Result = [PSCustomObject]@{
        Exists          = $false
        ItemType        = "directory"
        IsJunction      = $false
        JunctionTarget  = $null
        FileCount       = 0
        SizeBytes       = [int64]0
        SizeDisplay     = "0 B"
    }

    if (-not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        return $Result
    }

    try {
        $Item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if (-not $Item) { return $Result }

        $Result.Exists = $true

        # Check if reparse point / junction
        $ReparseInfo = Get-ReparsePointInfo -Path $Path
        if ($ReparseInfo -and $ReparseInfo.IsReparsePoint) {
            $Result.IsJunction = $true
            $Result.JunctionTarget = $ReparseInfo.Target
        }

        if ($Item -is [System.IO.FileInfo]) {
            $Result.ItemType = "file"
            $Result.FileCount = 1
            $Result.SizeBytes = [int64]$Item.Length
            $Result.SizeDisplay = "$(Format-ReglazeByteSize -Bytes $Result.SizeBytes) (1 file)"
            return $Result
        }

        # Directory size & file count traversal using fast .NET EnumerateFiles with safe per-directory recursion
        $TotalBytes = [int64]0
        $TotalFiles = 0
        $DirStack = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
        $DirStack.Push([System.IO.DirectoryInfo]::new($Item.FullName))

        while ($DirStack.Count -gt 0) {
            $CurrentDir = $DirStack.Pop()
            try {
                foreach ($FileInfo in $CurrentDir.EnumerateFiles()) {
                    $TotalFiles++
                    $TotalBytes += $FileInfo.Length
                }
            } catch {}

            try {
                foreach ($SubDir in $CurrentDir.EnumerateDirectories()) {
                    # Do not recurse into nested reparse points to avoid loops
                    if (($SubDir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                        $DirStack.Push($SubDir)
                    }
                }
            } catch {}
        }

        $Result.FileCount = $TotalFiles
        $Result.SizeBytes = $TotalBytes
        $Result.SizeDisplay = "$(Format-ReglazeByteSize -Bytes $TotalBytes) ($TotalFiles file$(if ($TotalFiles -ne 1) { 's' }))"
    } catch {}

    return $Result
}

function Escape-ReglazeManifestYamlString {
    param([string]$Val)
    if ([string]::IsNullOrEmpty($Val)) { return "" }
    $Clean = ($Val -replace "[\r\n\0]", "").Trim()
    return ($Clean -replace '\\', '\\' -replace '"', '\"')
}

function New-ReglazeMigrationPlan {
    [CmdletBinding()]
    param(
        [Alias("ConfigDir", "Config", "c")]
        [string]$ConfigFile = $null,
        [string]$AuditReferencePath = $null,
        [string]$OutputManifestPath = $null,
        [string]$RepoRoot = $null,
        [switch]$Force = $false
    )

    if (-not $RepoRoot) {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }

    Write-ReglazeBanner "REGLAZE PRE-INSTALL MIGRATION PLANNER"

    # 1. Resolve Blueprint
    $BlueprintFile = if ($ConfigFile) { $ConfigFile } else { Resolve-ReglazeConfigFile }
    if (-not $BlueprintFile -or -not (Test-Path -LiteralPath $BlueprintFile)) {
        Write-ReglazeError "Blueprint file not found. Specify via -Config or set `$env:REGLAZE_DIR."
        throw "Blueprint file not found: $BlueprintFile"
    }
    $BlueprintFile = (Resolve-Path -LiteralPath $BlueprintFile).Path
    $BlueprintDir = Split-Path -Parent $BlueprintFile
    Write-ReglazeInfo "Blueprint Source: $BlueprintFile"

    # 2. Resolve Audit Reference
    $AuditPath = $null
    if ($AuditReferencePath -and (Test-Path -LiteralPath $AuditReferencePath)) {
        $AuditPath = (Resolve-Path -LiteralPath $AuditReferencePath).Path
    } else {
        $SiblingAudit = Join-Path $BlueprintDir "audit-reference.json"
        if (Test-Path -LiteralPath $SiblingAudit) {
            $AuditPath = $SiblingAudit
        }
    }

    $AuditReference = $null
    if ($AuditPath -and (Test-Path -LiteralPath $AuditPath)) {
        Write-ReglazeInfo "Audit Reference:  $AuditPath"
        try {
            $AuditReference = Get-Content -Raw -LiteralPath $AuditPath -Encoding UTF8 | ConvertFrom-Json
        } catch {}
    }

    # 3. Parse Blueprint & Catalog
    $Blueprint = Get-ReglazeBlueprintObject -Path $BlueprintFile
    $Catalog = Get-ReglazeCatalog -RepoRoot $RepoRoot -UserConfigDir $BlueprintDir

    # 4. Build Variable Map (with Audit Reference fallbacks for Steam libraries and User Shell Folders)
    $VarMap = Get-BlueprintVariables -Blueprint $Blueprint

    # If STEAM_DIR was not explicitly declared in Blueprint.variables, check audit-reference.json detected_game_libraries
    $ExplicitSteamVar = ($Blueprint.variables -and ($Blueprint.variables.PSObject.Properties.Name -contains "STEAM_DIR"))
    if (-not $ExplicitSteamVar -and $AuditReference -and $AuditReference.detected_game_libraries) {
        $FirstAuditSteamLib = $AuditReference.detected_game_libraries |
            Where-Object { $_.manager -eq "steam" -and $_.path } |
            Select-Object -First 1
        if ($FirstAuditSteamLib) {
            $VarMap["STEAM_DIR"] = $FirstAuditSteamLib.path.TrimEnd('\')
            $VarMap["STEAM_LIBRARY"] = $VarMap["STEAM_DIR"]
        }
    }

    # Build a lookup of per-app Steam library paths from audit-reference.json
    $AppSteamLibMap = @{}
    if ($AuditReference -and $AuditReference.detected_game_libraries) {
        foreach ($Lib in $AuditReference.detected_game_libraries) {
            if ($Lib.manager -eq "steam" -and $Lib.path -and $Lib.games) {
                foreach ($G in $Lib.games) {
                    if ($G.matched_app_id) {
                        $AppSteamLibMap[$G.matched_app_id] = $Lib.path.TrimEnd('\')
                    }
                }
            }
        }
    }

    # 5. Collect Sync Roots (storage.sync.directories)
    $SyncRoots = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ($Blueprint.storage -and $Blueprint.storage.sync -and $Blueprint.storage.sync.directories) {
        $SyncDirsObj = $Blueprint.storage.sync.directories
        $SyncProps = if ($SyncDirsObj -is [System.Collections.IDictionary]) { $SyncDirsObj.Keys } else { $SyncDirsObj.PSObject.Properties.Name }
        foreach ($SKey in $SyncProps) {
            $SDir = if ($SyncDirsObj -is [System.Collections.IDictionary]) { $SyncDirsObj[$SKey] } else { $SyncDirsObj.$SKey }
            if ($SDir -and $SDir.local_path) {
                $ResolvedSyncLocal = Resolve-VariableString -InputString ([string]$SDir.local_path) -VariableMap $VarMap
                $SyncRoots.Add([PSCustomObject]@{
                    Id           = [string]$SKey
                    SyncVariable = if ($SDir.sync_variable) { [string]$SDir.sync_variable } else { "SYNC_$($SKey.ToUpperInvariant())" }
                    LocalPath    = $ResolvedSyncLocal
                    CloudFolder  = if ($SDir.cloud_folder) { [string]$SDir.cloud_folder } else { [string]$SKey }
                })
            }
        }
    }

    # 6. Collect Migration Items
    $MigrationItems = [System.Collections.Generic.List[PSCustomObject]]::new()

    # 6a. Relocated User Shell Folders (only if target differs from current/default %USER_DIR%\<Folder>)
    if ($Blueprint.storage -and $Blueprint.storage.user_shell_folders) {
        $UsfObj = $Blueprint.storage.user_shell_folders
        $UsfProps = if ($UsfObj -is [System.Collections.IDictionary]) { $UsfObj.Keys } else { $UsfObj.PSObject.Properties.Name }
        $FolderCapMap = @{
            desktop   = "Desktop"
            documents = "Documents"
            downloads = "Downloads"
            pictures  = "Pictures"
            music     = "Music"
            videos    = "Videos"
        }
        foreach ($UKey in $UsfProps) {
            $RawTargetUsf = if ($UsfObj -is [System.Collections.IDictionary]) { [string]$UsfObj[$UKey] } else { [string]$UsfObj.$UKey }
            if ([string]::IsNullOrWhiteSpace($RawTargetUsf)) { continue }

            $ResolvedTargetUsf = (Resolve-VariableString -InputString $RawTargetUsf -VariableMap $VarMap).TrimEnd('\')
            $SubFolderName = if ($FolderCapMap.ContainsKey($UKey.ToLowerInvariant())) { $FolderCapMap[$UKey.ToLowerInvariant()] } else { $UKey }
            $DefaultUserPath = (Join-Path $VarMap["USERPROFILE"] $SubFolderName).TrimEnd('\')

            $CurrentSourceUsf = $DefaultUserPath
            if ($AuditReference -and $AuditReference.storage_providers -and $AuditReference.storage_providers.user_shell_folders) {
                $AuditUsfVal = $AuditReference.storage_providers.user_shell_folders.$UKey
                if (-not [string]::IsNullOrWhiteSpace([string]$AuditUsfVal)) {
                    $CurrentSourceUsf = ([string]$AuditUsfVal).TrimEnd('\')
                }
            }

            if (-not $ResolvedTargetUsf.Equals($CurrentSourceUsf, [System.StringComparison]::OrdinalIgnoreCase) -and
                -not $ResolvedTargetUsf.Equals($DefaultUserPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                $Stats = Get-ReglazePathStats -Path $CurrentSourceUsf
                $AlreadyLinked = ($Stats.IsJunction -and $Stats.JunctionTarget -and $Stats.JunctionTarget.TrimEnd('\').Equals($ResolvedTargetUsf, [System.StringComparison]::OrdinalIgnoreCase))
                $StatusStr = if ($AlreadyLinked) { "already_junction" } elseif ($Stats.Exists) { "ready" } else { "pending_source_host" }

                $MigrationItems.Add([PSCustomObject]@{
                    Id          = "user_shell_folders.$UKey"
                    AppId       = "user_shell_folders"
                    DirectoryId = $UKey
                    Description = "Relocated Windows User Shell Folder ($SubFolderName)"
                    Enabled     = (-not $AlreadyLinked)
                    StorageType = "local_preserved"
                    ItemType    = $Stats.ItemType
                    Source      = $CurrentSourceUsf
                    Target      = $ResolvedTargetUsf
                    Status      = $StatusStr
                    FileCount   = $Stats.FileCount
                    SizeBytes   = $Stats.SizeBytes
                    SizeDisplay = if ($Stats.Exists) { $Stats.SizeDisplay } else { "unmeasured (not on current host)" }
                })
            }
        }
    }

    # 6b. Catalog Application Directory Mappings
    if ($Blueprint.applications) {
        foreach ($Prop in @($Blueprint.applications.PSObject.Properties)) {
            $AppId = $Prop.Name
            if ($AppId -eq "custom") { continue }
            $AppConfig = $Prop.Value
            if (-not $AppConfig -or -not $AppConfig.directories) { continue }

            $CatalogApp = $Catalog | Where-Object { $_.app_id -ieq $AppId } | Select-Object -First 1

            # Create per-app variable map if this Steam game lives in a specific detected library
            $AppVarMap = $VarMap
            if (-not $ExplicitSteamVar -and $AppSteamLibMap.ContainsKey($AppId)) {
                $AppVarMap = [System.Collections.Generic.Dictionary[string, string]]::new($VarMap, [System.StringComparer]::OrdinalIgnoreCase)
                $AppVarMap["STEAM_DIR"] = $AppSteamLibMap[$AppId]
                $AppVarMap["STEAM_LIBRARY"] = $AppSteamLibMap[$AppId]
            }

            $DirProps = if ($AppConfig.directories -is [System.Collections.IDictionary]) {
                $AppConfig.directories.Keys
            } elseif ($AppConfig.directories.PSObject) {
                $AppConfig.directories.PSObject.Properties.Name
            } else { @() }

            foreach ($DirId in $DirProps) {
                $DirConf = if ($AppConfig.directories -is [System.Collections.IDictionary]) { $AppConfig.directories[$DirId] } else { $AppConfig.directories.$DirId }
                if (-not $DirConf) { continue }
                if ($DirConf.override -and $DirConf.override.action -eq "omit") { continue }
                if ([string]::IsNullOrWhiteSpace([string]$DirConf.target)) { continue }

                $CatalogDir = if ($CatalogApp -and $CatalogApp.directories) {
                    $CatalogApp.directories | Where-Object { $_.id -ieq $DirId } | Select-Object -First 1
                } else { $null }

                $RawSource = if ($DirConf.link) { [string]$DirConf.link } elseif ($CatalogDir -and $CatalogDir.default_path) { [string]$CatalogDir.default_path } else { $null }
                if ([string]::IsNullOrWhiteSpace($RawSource)) { continue }

                $RawTarget = [string]$DirConf.target
                $ResolvedSource = Resolve-VariableString -InputString $RawSource -VariableMap $AppVarMap
                $ResolvedTarget = Resolve-VariableString -InputString $RawTarget -VariableMap $AppVarMap

                $StorageType = if ($CatalogDir -and $CatalogDir.recommended_storage) {
                    [string]$CatalogDir.recommended_storage
                } elseif ($RawTarget -like "*%STREAM%*") {
                    "streaming"
                } elseif ($RawTarget -like "*%SYNC_*") {
                    "sync"
                } else {
                    "local_preserved"
                }

                # Infer storage tier from actual target path if overridden by user
                if ($RawTarget -like "*%STREAM%*") { $StorageType = "streaming" }
                elseif ($RawTarget -like "*%SYNC_*") { $StorageType = "sync" }
                elseif ($RawTarget -like "*%DATA_*") { $StorageType = "local_preserved" }

                $Desc = if ($CatalogDir -and $CatalogDir.description) { [string]$CatalogDir.description } else { "$AppId ($DirId)" }
                $Stats = Get-ReglazePathStats -Path $ResolvedSource
                $AlreadyLinked = ($Stats.IsJunction -and $Stats.JunctionTarget -and $Stats.JunctionTarget.TrimEnd('\').Equals($ResolvedTarget.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase))
                $StatusStr = if ($AlreadyLinked) { "already_junction" } elseif ($Stats.Exists) { "ready" } else { "pending_source_host" }
                $ItemType = if ($CatalogDir -and $CatalogDir.item_type) { [string]$CatalogDir.item_type } elseif ($Stats.ItemType) { $Stats.ItemType } else { "directory" }

                $MigrationItems.Add([PSCustomObject]@{
                    Id          = "$AppId.$DirId"
                    AppId       = $AppId
                    DirectoryId = $DirId
                    Description = $Desc
                    Enabled     = (-not $AlreadyLinked)
                    StorageType = $StorageType
                    ItemType    = $ItemType
                    Source      = $ResolvedSource
                    Target      = $ResolvedTarget
                    Status      = $StatusStr
                    FileCount   = $Stats.FileCount
                    SizeBytes   = $Stats.SizeBytes
                    SizeDisplay = if ($Stats.Exists) { $Stats.SizeDisplay } else { "unmeasured (not on current host)" }
                })
            }
        }
    }

    # 6c. Custom Application Directory Mappings (applications.custom & top-level custom)
    $CombinedCustom = @()
    if ($Blueprint.applications -and $Blueprint.applications.custom -and ($Blueprint.applications.custom -is [System.Collections.IEnumerable]) -and -not ($Blueprint.applications.custom -is [string])) {
        $CombinedCustom += @($Blueprint.applications.custom)
    }
    if ($Blueprint.custom -and ($Blueprint.custom -is [System.Collections.IEnumerable]) -and -not ($Blueprint.custom -is [string])) {
        $CombinedCustom += @($Blueprint.custom)
    }

    foreach ($CustApp in $CombinedCustom) {
        if (-not $CustApp -or -not $CustApp.directories) { continue }
        $CustAppName = if ($CustApp.name) { [string]$CustApp.name } else { "custom" }
        $CustAppSlug = ($CustAppName -replace '[^a-zA-Z0-9_]', '_').ToLowerInvariant()

        foreach ($CDir in $CustApp.directories) {
            if (-not $CDir -or [string]::IsNullOrWhiteSpace([string]$CDir.link) -or [string]::IsNullOrWhiteSpace([string]$CDir.target)) {
                continue
            }
            $CDirName = if ($CDir.name) { [string]$CDir.name } else { "custom_dir" }
            $CDirSlug = ($CDirName -replace '[^a-zA-Z0-9_]', '_').ToLowerInvariant()

            $ResolvedSource = Resolve-VariableString -InputString ([string]$CDir.link) -VariableMap $VarMap
            $ResolvedTarget = Resolve-VariableString -InputString ([string]$CDir.target) -VariableMap $VarMap

            $StorageType = if ($CDir.storage_type) {
                [string]$CDir.storage_type
            } elseif ($CDir.target -like "*%STREAM%*") {
                "streaming"
            } elseif ($CDir.target -like "*%SYNC_*") {
                "sync"
            } else {
                "local_preserved"
            }

            $Stats = Get-ReglazePathStats -Path $ResolvedSource
            $AlreadyLinked = ($Stats.IsJunction -and $Stats.JunctionTarget -and $Stats.JunctionTarget.TrimEnd('\').Equals($ResolvedTarget.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase))
            $StatusStr = if ($AlreadyLinked) { "already_junction" } elseif ($Stats.Exists) { "ready" } else { "pending_source_host" }
            $CustItemType = if ($CDir.item_type) { [string]$CDir.item_type } elseif ($Stats.ItemType) { $Stats.ItemType } else { "directory" }

            $MigrationItems.Add([PSCustomObject]@{
                Id          = "custom.$CustAppSlug.$CDirSlug"
                AppId       = $CustAppName
                DirectoryId = $CDirSlug
                Description = $CDirName
                Enabled     = (-not $AlreadyLinked)
                StorageType = $StorageType
                ItemType    = $CustItemType
                Source      = $ResolvedSource
                Target      = $ResolvedTarget
                Status      = $StatusStr
                FileCount   = $Stats.FileCount
                SizeBytes   = $Stats.SizeBytes
                SizeDisplay = if ($Stats.Exists) { $Stats.SizeDisplay } else { "unmeasured (not on current host)" }
            })
        }
    }

    # 7. Resolve Output Manifest Path & Archive Existing if Needed
    $ManifestPath = if ($OutputManifestPath) {
        if (Test-Path -LiteralPath $OutputManifestPath -PathType Container -ErrorAction SilentlyContinue) {
            Join-Path $OutputManifestPath "migration-manifest.yaml"
        } else {
            $OutputManifestPath
        }
    } else {
        Join-Path $BlueprintDir "migration-manifest.yaml"
    }

    if ((Test-Path -LiteralPath $ManifestPath) -and -not $Force) {
        $Stamp = (Get-Date).ToString("yyyy-MM-ddTHH-mm-ss")
        $ArchiveName = "migration-manifest.$Stamp.yaml"
        $ArchivePath = Join-Path (Split-Path -Parent $ManifestPath) $ArchiveName
        Copy-Item -LiteralPath $ManifestPath -Destination $ArchivePath -Force
        Write-ReglazeInfo "Archived existing migration manifest to: $ArchiveName"
    }

    # 8. Compute Storage Tier Totals
    $StreamBytes = [int64]0
    $SyncBytes = [int64]0
    $LocalBytes = [int64]0
    foreach ($Item in $MigrationItems) {
        if (-not $Item.Enabled) { continue }
        switch ($Item.StorageType) {
            "streaming" { $StreamBytes += $Item.SizeBytes }
            "sync"      { $SyncBytes += $Item.SizeBytes }
            default     { $LocalBytes += $Item.SizeBytes }
        }
    }
    $TotalCloudBytes = $StreamBytes + $SyncBytes

    $ProfileName = if ($Blueprint.profile) { [string]$Blueprint.profile } else { "workstation" }
    $SourceComp = if ($Blueprint.storage -and $Blueprint.storage.sync -and $Blueprint.storage.sync.source_computer) {
        [string]$Blueprint.storage.sync.source_computer
    } elseif ($Blueprint.system -and $Blueprint.system.computer_name) {
        [string]$Blueprint.system.computer_name
    } else {
        $env:COMPUTERNAME
    }
    $GeneratedAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")

    # 9. Emit migration-manifest.yaml
    $Lines = [System.Collections.Generic.List[string]]::new()
    @(
        '# =============================================================================',
        '# Reglaze Pre-Install Data Migration & Sync Staging Manifest',
        '# =============================================================================',
        "# Blueprint:       $BlueprintFile",
        "# Profile:         $ProfileName (Source Computer: $SourceComp)",
        "# Generated:       $GeneratedAt",
        '#',
        '# MEASURED SIZE SUMMARY (on current machine):',
        "#   Cloud Streaming (%STREAM%):      $(Format-ReglazeByteSize -Bytes $StreamBytes)",
        "#   Cloud Two-Way Sync (%SYNC_*%):   $(Format-ReglazeByteSize -Bytes $SyncBytes)",
        "#   Total Cloud Footprint:           $(Format-ReglazeByteSize -Bytes $TotalCloudBytes)",
        "#   Local Preserved Disk (%DATA_*%): $(Format-ReglazeByteSize -Bytes $LocalBytes)",
        '#',
        '# INSTRUCTIONS:',
        '#   1. Review the items below before wiping/reinstalling Windows.',
        '#   2. To skip migrating any directory, either:',
        '#      - Change `enabled: true` to `enabled: false`, OR',
        '#      - Comment out / delete that item block.',
        "#   3. Run ``pwsh ./bin/reglaze.ps1 migrate -Config `"$BlueprintFile`"``",
        '#      to create all target directories and copy files via multi-threaded Robocopy.',
        '# =============================================================================',
        '',
        'version: "1.0"',
        "profile: `"$(Escape-ReglazeManifestYamlString $ProfileName)`"",
        "source_computer: `"$(Escape-ReglazeManifestYamlString $SourceComp)`"",
        "generated_at: `"$GeneratedAt`"",
        ''
    ) | ForEach-Object { $Lines.Add($_) }

    if ($SyncRoots.Count -gt 0) {
        $Lines.Add('sync_roots:')
        foreach ($Sr in $SyncRoots) {
            $Lines.Add("  - id: `"$(Escape-ReglazeManifestYamlString $Sr.Id)`"")
            $Lines.Add("    sync_variable: `"$(Escape-ReglazeManifestYamlString $Sr.SyncVariable)`"")
            $Lines.Add("    local_path: `"$(Escape-ReglazeManifestYamlString $Sr.LocalPath)`"")
            $Lines.Add("    cloud_folder: `"$(Escape-ReglazeManifestYamlString $Sr.CloudFolder)`"")
        }
    } else {
        $Lines.Add('sync_roots: []')
    }

    $Lines.Add('')
    if ($MigrationItems.Count -gt 0) {
        $Lines.Add('items:')
        foreach ($MItem in $MigrationItems) {
            $Lines.Add("  - id: `"$(Escape-ReglazeManifestYamlString $MItem.Id)`"")
            $Lines.Add("    app_id: `"$(Escape-ReglazeManifestYamlString $MItem.AppId)`"")
            $Lines.Add("    directory_id: `"$(Escape-ReglazeManifestYamlString $MItem.DirectoryId)`"")
            $Lines.Add("    description: `"$(Escape-ReglazeManifestYamlString $MItem.Description)`"")
            $Lines.Add("    enabled: $(if ($MItem.Enabled) { 'true' } else { 'false' })")
            $Lines.Add("    storage_type: `"$(Escape-ReglazeManifestYamlString $MItem.StorageType)`"")
            $Lines.Add("    item_type: `"$(Escape-ReglazeManifestYamlString $MItem.ItemType)`"")
            $Lines.Add("    source: `"$(Escape-ReglazeManifestYamlString $MItem.Source)`"")
            $Lines.Add("    target: `"$(Escape-ReglazeManifestYamlString $MItem.Target)`"")
            $Lines.Add("    status: `"$(Escape-ReglazeManifestYamlString $MItem.Status)`"")
            $Lines.Add("    file_count: $($MItem.FileCount)")
            $Lines.Add("    size_bytes: $($MItem.SizeBytes)")
            $Lines.Add("    size_display: `"$(Escape-ReglazeManifestYamlString $MItem.SizeDisplay)`"")
            $Lines.Add('')
        }
    } else {
        $Lines.Add('items: []')
    }

    $ManifestDir = Split-Path -Parent $ManifestPath
    if ($ManifestDir -and -not (Test-Path -LiteralPath $ManifestDir)) {
        New-Item -ItemType Directory -Path $ManifestDir -Force | Out-Null
    }
    [System.IO.File]::WriteAllLines($ManifestPath, $Lines.ToArray(), (New-Object System.Text.UTF8Encoding($false)))

    Write-ReglazeSuccess "Generated draft pre-install migration manifest: $ManifestPath"
    Write-Host ""
    Write-Host "  MIGRATION PLAN SUMMARY ($($MigrationItems.Count) item(s)):" -ForegroundColor Cyan
    foreach ($MItem in $MigrationItems) {
        $StateTag = if (-not $MItem.Enabled) { "[DISABLED/$($MItem.Status)]" } else { "[ENABLED/$($MItem.StorageType)]" }
        $Color = if (-not $MItem.Enabled) { "DarkGray" } elseif ($MItem.StorageType -eq "local_preserved") { "Green" } else { "Yellow" }
        Write-Host ("    - {0,-42} {1,-26} {2}" -f $MItem.Id, $StateTag, $MItem.SizeDisplay) -ForegroundColor $Color
        Write-Host ("        Source: {0}" -f $MItem.Source) -ForegroundColor Gray
        Write-Host ("        Target: {0}" -f $MItem.Target) -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "  Cloud Footprint (Measured Local): $(Format-ReglazeByteSize -Bytes $TotalCloudBytes) (Streaming: $(Format-ReglazeByteSize -Bytes $StreamBytes), Sync: $(Format-ReglazeByteSize -Bytes $SyncBytes))" -ForegroundColor Cyan
    Write-Host "  Preserved Disk Footprint:         $(Format-ReglazeByteSize -Bytes $LocalBytes)" -ForegroundColor Cyan
    Write-Host ""
    Write-ReglazeInfo "Review/edit '$ManifestPath', then run: pwsh ./bin/reglaze.ps1 migrate -Config `"$BlueprintFile`""

    return [PSCustomObject]@{
        ManifestPath    = $ManifestPath
        ItemCount       = $MigrationItems.Count
        EnabledCount    = @($MigrationItems | Where-Object { $_.Enabled }).Count
        SyncRootCount   = $SyncRoots.Count
        StreamBytes     = $StreamBytes
        SyncBytes       = $SyncBytes
        LocalBytes      = $LocalBytes
        TotalCloudBytes = $TotalCloudBytes
        Items           = $MigrationItems.ToArray()
        SyncRoots       = $SyncRoots.ToArray()
    }
}

function Invoke-ReglazePreInstallMigration {
    [CmdletBinding()]
    param(
        [string]$ManifestPath = $null,
        [Alias("ConfigDir", "Config", "c")]
        [string]$ConfigFile = $null,
        [int]$Threads = 2,
        [switch]$Simulation = $false,
        [switch]$Force = $false
    )

    Write-ReglazeBanner "REGLAZE PRE-INSTALL DATA MIGRATION & STAGING"

    if ($Simulation) {
        Write-ReglazeWarning "Running in SIMULATION (Dry-Run) mode. No directories will be created or files copied."
    }

    # 1. Resolve Manifest Path
    $ResolvedManifest = $null
    if ($ManifestPath) {
        if (Test-Path -LiteralPath $ManifestPath -PathType Container -ErrorAction SilentlyContinue) {
            $CandidateYaml = Join-Path $ManifestPath "migration-manifest.yaml"
            $CandidateJson = Join-Path $ManifestPath "migration-manifest.json"
            if (Test-Path -LiteralPath $CandidateYaml) { $ResolvedManifest = $CandidateYaml }
            elseif (Test-Path -LiteralPath $CandidateJson) { $ResolvedManifest = $CandidateJson }
        } elseif (Test-Path -LiteralPath $ManifestPath) {
            $ResolvedManifest = (Resolve-Path -LiteralPath $ManifestPath).Path
        }
    }

    if (-not $ResolvedManifest) {
        $BlueprintFile = if ($ConfigFile) { Resolve-ReglazeConfigFile $ConfigFile } else { Resolve-ReglazeConfigFile }
        if ($BlueprintFile -and (Test-Path -LiteralPath $BlueprintFile)) {
            $BpDir = if (Test-Path -LiteralPath $BlueprintFile -PathType Container) {
                $BlueprintFile
            } else {
                Split-Path -Parent (Resolve-Path -LiteralPath $BlueprintFile).Path
            }
            $CandidateYaml = Join-Path $BpDir "migration-manifest.yaml"
            $CandidateJson = Join-Path $BpDir "migration-manifest.json"
            if (Test-Path -LiteralPath $CandidateYaml) {
                $ResolvedManifest = $CandidateYaml
            } elseif (Test-Path -LiteralPath $CandidateJson) {
                $ResolvedManifest = $CandidateJson
            } elseif ($Force) {
                Write-ReglazeInfo "No migration-manifest.yaml found; generating draft manifest first (-Force)..."
                $PlanRes = New-ReglazeMigrationPlan -ConfigFile $BlueprintFile -Force
                $ResolvedManifest = $PlanRes.ManifestPath
            }
        }
    }

    if (-not $ResolvedManifest -or -not (Test-Path -LiteralPath $ResolvedManifest)) {
        Write-ReglazeError "Migration manifest not found. Run 'reglaze migration-plan' first to generate 'migration-manifest.yaml', or specify -Manifest <path>."
        throw "Migration manifest not found."
    }

    Write-ReglazeInfo "Using Migration Manifest: $ResolvedManifest"

    # 2. Parse Manifest (YAML or JSON)
    $ManifestObj = if ($ResolvedManifest -like "*.json") {
        Get-Content -Raw -LiteralPath $ResolvedManifest -Encoding UTF8 | ConvertFrom-Json
    } else {
        Get-ReglazeBlueprintObject -Path $ResolvedManifest
    }

    # 3. Create Sync Roots (storage.sync.directories)
    $SyncRootsCreated = 0
    if ($ManifestObj.sync_roots -and ($ManifestObj.sync_roots -is [System.Collections.IEnumerable]) -and -not ($ManifestObj.sync_roots -is [string])) {
        Write-ReglazeStep "Ensuring Local Cloud Sync Root Directories Exist..."
        foreach ($Sr in $ManifestObj.sync_roots) {
            if (-not $Sr -or [string]::IsNullOrWhiteSpace([string]$Sr.local_path)) { continue }
            $SyncLocalPath = ([string]$Sr.local_path -replace '\\{2,}', '\').Trim()
            $SyncDrive = ([System.IO.Path]::GetPathRoot($SyncLocalPath)).TrimEnd('\')
            if ($SyncDrive -and -not (Test-Path -LiteralPath "$SyncDrive\" -ErrorAction SilentlyContinue)) {
                Write-ReglazeWarning "Sync root drive '$SyncDrive' is not mounted for '$SyncLocalPath'. Skipping sync root creation."
                continue
            }

            if ($Simulation) {
                Write-ReglazeInfo "[SIMULATION] Would ensure sync root directory exists: $SyncLocalPath (Cloud Folder: $($Sr.cloud_folder))"
                $SyncRootsCreated++
            } else {
                if (-not (Test-Path -LiteralPath $SyncLocalPath)) {
                    New-Item -ItemType Directory -Path $SyncLocalPath -Force | Out-Null
                    Write-ReglazeSuccess "Created sync root directory: $SyncLocalPath"
                } else {
                    Write-ReglazeInfo "Sync root directory already exists: $SyncLocalPath"
                }
                $SyncRootsCreated++
            }
        }
    }

    # 4. Process Migration Items via Multi-Threaded Robocopy
    $RawItems = if ($ManifestObj.items -and ($ManifestObj.items -is [System.Collections.IEnumerable]) -and -not ($ManifestObj.items -is [string])) {
        @($ManifestObj.items)
    } else {
        @()
    }

    Write-ReglazeStep "Staging Application & User Data into Target Directories ($($RawItems.Count) total manifest item(s))..."

    # Check for active applications that commonly hold locks on AppData / user files
    $LockingProcessNames = @("Steam", "steamservice", "NVIDIA*", "nvcontainer", "chrome", "msedge", "brave", "Code")
    $RunningLockingProcs = Get-Process -Name $LockingProcessNames -ErrorAction SilentlyContinue
    if ($RunningLockingProcs) {
        $UniqueProcNames = @($RunningLockingProcs | Select-Object -ExpandProperty ProcessName -Unique)
        Write-ReglazeWarning "Active applications detected that may lock files in target directories: $($UniqueProcNames -join ', '). If file lock errors occur, close these applications and re-run migration."
    }

    $CopiedCount = 0
    $SkippedDisabled = 0
    $SkippedMissingSource = 0
    $SkippedAlreadyLinked = 0
    $SkippedUnmountedDrive = 0
    $FailedCount = 0
    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $SafeThreads = [Math]::Max(1, [Math]::Min(128, $Threads))

    foreach ($Item in $RawItems) {
        if (-not $Item) { continue }
        $ItemId = if ($Item.id) { [string]$Item.id } else { "$($Item.app_id).$($Item.directory_id)" }

        $IsEnabled = if ($null -ne $Item.enabled) { [bool]$Item.enabled } else { $true }
        if (-not $IsEnabled) {
            Write-ReglazeInfo "[SKIP-DISABLED] $ItemId (enabled: false)"
            $SkippedDisabled++
            continue
        }

        $SourcePath = ([string]$Item.source -replace '\\{2,}', '\').Trim()
        $TargetPath = ([string]$Item.target -replace '\\{2,}', '\').Trim()

        if ([string]::IsNullOrWhiteSpace($SourcePath) -or [string]::IsNullOrWhiteSpace($TargetPath)) {
            Write-ReglazeWarning "[SKIP] $ItemId has empty source or target path."
            $SkippedDisabled++
            continue
        }

        if ($SourcePath.TrimEnd('\').Equals($TargetPath.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-ReglazeInfo "[SKIP] ${ItemId}: Source and target paths are identical ($SourcePath)."
            $SkippedAlreadyLinked++
            continue
        }

        if (-not (Test-Path -LiteralPath $SourcePath -ErrorAction SilentlyContinue)) {
            Write-ReglazeWarning "[SKIP-MISSING-SOURCE] ${ItemId}: Source path does not exist on this machine ($SourcePath)."
            $SkippedMissingSource++
            continue
        }

        # Check if source is already an NTFS junction pointing to target
        $ReparseCheck = Get-ReparsePointInfo -Path $SourcePath
        if ($ReparseCheck -and $ReparseCheck.IsReparsePoint) {
            if ($ReparseCheck.Target -and $ReparseCheck.Target.TrimEnd('\').Equals($TargetPath.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-ReglazeInfo "[SKIP-ALREADY-JUNCTION] ${ItemId}: Source '$SourcePath' is already a junction pointing to '$TargetPath'."
                $SkippedAlreadyLinked++
                continue
            }
        }

        # Check target drive availability
        $TargetDrive = ([System.IO.Path]::GetPathRoot($TargetPath)).TrimEnd('\')
        if (-not $Simulation -and $TargetDrive -and -not (Test-Path -LiteralPath "$TargetDrive\" -ErrorAction SilentlyContinue)) {
            Write-ReglazeWarning "[SKIP-UNMOUNTED-DRIVE] ${ItemId}: Target drive '$TargetDrive' is not currently mounted for '$TargetPath'. Ensure Google Drive or external disk is mounted."
            $SkippedUnmountedDrive++
            continue
        }

        $SourceItem = Get-Item -LiteralPath $SourcePath -Force -ErrorAction SilentlyContinue
        $IsSingleFile = ($SourceItem -is [System.IO.FileInfo])

        if ($Simulation) {
            if ($IsSingleFile) {
                $SrcParent = $SourceItem.DirectoryName
                $SrcLeaf = $SourceItem.Name
                Write-ReglazeInfo "[SIMULATION] Would copy file via robocopy: `"$SrcParent`" -> `"$TargetPath`" (File: `"$SrcLeaf`")"
            } else {
                Write-ReglazeInfo "[SIMULATION] Would copy directory via robocopy (/MT:$SafeThreads /E /XO): `"$SourcePath`" -> `"$TargetPath`""
            }
            $CopiedCount++
            continue
        }

        # Live execution: Ensure target directory exists and invoke robocopy.exe
        try {
            if (-not (Test-Path -LiteralPath $TargetPath)) {
                New-Item -ItemType Directory -Path $TargetPath -Force | Out-Null
            }

            if ($IsSingleFile) {
                $SrcParent = $SourceItem.DirectoryName
                $SrcLeaf = $SourceItem.Name
                Write-ReglazeInfo "Copying file [$ItemId]: $SourcePath -> $TargetPath\$SrcLeaf"
                $RoboArgs = @(
                    $SrcParent,
                    $TargetPath,
                    $SrcLeaf,
                    "/COPY:DAT",
                    "/XO",
                    "/R:2",
                    "/W:1",
                    "/NP",
                    "/NJH",
                    "/NJS"
                )
                $RoboLines = & robocopy.exe @RoboArgs
                $RoboExit = $LASTEXITCODE
            } else {
                Write-ReglazeInfo "Syncing directory [$ItemId] (robocopy /MT:$SafeThreads): $SourcePath -> $TargetPath"
                $RoboArgs = @(
                    $SourcePath,
                    $TargetPath,
                    "/E",
                    "/COPY:DAT",
                    "/DCOPY:DAT",
                    "/XO",
                    "/MT:$SafeThreads",
                    "/R:2",
                    "/W:1",
                    "/XJ",
                    "/NP",
                    "/NJH",
                    "/NJS"
                )
                $RoboLines = & robocopy.exe @RoboArgs
                $RoboExit = $LASTEXITCODE
            }

            # Robocopy exit codes: 0-7 indicate success (bit flags: 1=copied, 2=extra files in dest, 4=mismatches); >=8 indicates errors
            $ExitDesc = Format-RobocopyExitDetails -ExitCode $RoboExit
            if ($RoboExit -lt 8) {
                Write-ReglazeSuccess "Staged [$ItemId] -> $TargetPath (code $($RoboExit): $ExitDesc)"
                $CopiedCount++
            } else {
                Write-ReglazeError "Robocopy failed for [$ItemId] with exit code $($RoboExit): $ExitDesc (Source: '$SourcePath', Target: '$TargetPath')."
                $ErrorLines = @($RoboLines | Where-Object { $_ -match '(?i)(ERROR\s+\d+|Access is denied|used by another process|cannot find the|failed)' })
                if ($ErrorLines.Count -gt 0) {
                    Write-Host "    Failed items / error details:" -ForegroundColor Yellow
                    foreach ($ErrLine in ($ErrorLines | Select-Object -First 10)) {
                        Write-Host "      $ErrLine" -ForegroundColor Red
                    }
                    if ($ErrorLines.Count -gt 10) {
                        Write-Host "      ... and $($ErrorLines.Count - 10) more error(s)." -ForegroundColor DarkGray
                    }
                }
                if ($RoboExit -band 8) {
                    Write-ReglazeWarning "Some files could not be copied because they are locked by running software. Please close related applications and retry 'reglaze migrate'."
                }
                $FailedCount++
            }
        } catch {
            Write-ReglazeError "Failed to stage [$ItemId]: $($_.Exception.Message)"
            $FailedCount++
        }
    }

    $Stopwatch.Stop()
    $ElapsedSec = ("{0:N2}s" -f $Stopwatch.Elapsed.TotalSeconds)

    Write-Host ""
    Write-ReglazeBanner "PRE-INSTALL MIGRATION SUMMARY"
    Write-Host "  Sync Roots Ensured:      $SyncRootsCreated" -ForegroundColor Cyan
    Write-Host "  Items Staged / Copied:   $CopiedCount" -ForegroundColor Green
    Write-Host "  Skipped (Disabled):      $SkippedDisabled" -ForegroundColor Gray
    Write-Host "  Skipped (Already Linked):$SkippedAlreadyLinked" -ForegroundColor Gray
    Write-Host "  Skipped (Missing Src):   $SkippedMissingSource" -ForegroundColor Yellow
    Write-Host "  Skipped (Unmounted Drv): $SkippedUnmountedDrive" -ForegroundColor Yellow
    Write-Host "  Failed Transfers:        $FailedCount" -ForegroundColor $(if ($FailedCount -gt 0) { "Red" } else { "Green" })
    Write-Host "  Elapsed Time:            $ElapsedSec" -ForegroundColor Cyan
    Write-Host ""

    return [PSCustomObject]@{
        Status                = if ($FailedCount -eq 0) { "Success" } else { "PartialFailure" }
        ManifestPath          = $ResolvedManifest
        SyncRootsCreated      = $SyncRootsCreated
        CopiedCount           = $CopiedCount
        SkippedDisabled       = $SkippedDisabled
        SkippedAlreadyLinked  = $SkippedAlreadyLinked
        SkippedMissingSource  = $SkippedMissingSource
        SkippedUnmountedDrive = $SkippedUnmountedDrive
        FailedCount           = $FailedCount
        Simulation            = [bool]$Simulation
    }
}
