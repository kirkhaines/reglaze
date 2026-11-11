<#
.SYNOPSIS
    Payload artifact generator and assembler for Reglaze.
.DESCRIPTION
    Compiles and generates the complete media payload directory:
    - bitlocker-keys.json: Extracted BitLocker recovery keys for secondary/preserved volumes
    - junctions-manifest.json: Pre-computed junction mapping table with collision backup rules
    - bootstrap.ps1 & bootstrap-helpers.ps1: Phase 4 machine bootstrap orchestrator and helper subscript
      running under LocalAdmin (via Build-BootstrapScript.ps1)
    - hydrate.ps1 & hydrate-helpers.ps1: Phase 5 interactive user hydration orchestrator and helper
      subscript with state checkpoints and Browser/Password Manager Auth Bootstrap (via Build-HydrateScript.ps1)
    - setup-wsl.sh: Non-interactive WSL2 provisioning script (via Build-HydrateScript.ps1)
    - configuration.dsc.yaml & user-packages.json: WinGet DSC manifest and user-scope package queue
    - applications.json: Cached reference catalog
#>
[CmdletBinding()]
param()

$CompilerRoot = $PSScriptRoot
$CommonRoot = Join-Path (Split-Path -Parent $CompilerRoot) "common"
. (Join-Path $CommonRoot "Logging.ps1")
. (Join-Path $CommonRoot "Catalog.ps1")
. (Join-Path $CompilerRoot "Resolve-Variables.ps1")
. (Join-Path $CompilerRoot "Build-WinGetDSC.ps1")
. (Join-Path $CompilerRoot "Build-BootstrapScript.ps1")
. (Join-Path $CompilerRoot "Build-HydrateScript.ps1")

function Build-ReglazePayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Blueprint,

        [Parameter(Mandatory=$false)]
        [PSCustomObject]$AuditReference = $null,

        [Parameter(Mandatory=$false)]
        [string]$RepoRoot = $null,

        [Parameter(Mandatory=$true)]
        [string]$PayloadDir,

        [Parameter(Mandatory=$false)]
        [string]$BlueprintFile = $null,

        [Parameter(Mandatory=$false)]
        [string]$BuildTag = $null
    )

    if (-not $RepoRoot) {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }

    if (-not (Test-Path $PayloadDir)) {
        New-Item -ItemType Directory -Path $PayloadDir -Force | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($BuildTag)) {
        $BuildTag | Set-Content -Path (Join-Path $PayloadDir "reglaze.tag") -Encoding UTF8 -NoNewline -Force
        $ParentReglazeDir = Split-Path -Parent $PayloadDir
        if ($ParentReglazeDir -and (Test-Path $ParentReglazeDir)) {
            $BuildTag | Set-Content -Path (Join-Path $ParentReglazeDir "reglaze.tag") -Encoding UTF8 -NoNewline -Force
        }
    }

    # Stage linking, drive letter reconciliation, and Steam shortcut helpers into payload
    $LinkingDir = Join-Path $RepoRoot "src\linking"
    if (Test-Path $LinkingDir) {
        foreach ($LinkScript in @("Set-ReglazeDriveLetters.ps1", "Unlock-BitLockerVolumes.ps1", "New-DirectoryJunction.ps1", "Test-ReparsePoint.ps1", "Backup-CollisionFolder.ps1")) {
            $SrcScript = Join-Path $LinkingDir $LinkScript
            if (Test-Path $SrcScript) {
                Copy-Item -Path $SrcScript -Destination (Join-Path $PayloadDir $LinkScript) -Force
            }
        }
    }
    $GameLibScript = Join-Path $RepoRoot "src\common\GameLibraries.ps1"
    if (Test-Path $GameLibScript) {
        Copy-Item -Path $GameLibScript -Destination (Join-Path $PayloadDir "GameLibraries.ps1") -Force
    }

    # Stage modular Windows settings scripts
    $WindowsDataDir = Join-Path $RepoRoot "data\windows"
    $PayloadWindowsDir = Join-Path $PayloadDir "windows"
    if (Test-Path $WindowsDataDir) {
        if (-not (Test-Path $PayloadWindowsDir)) {
            New-Item -ItemType Directory -Path $PayloadWindowsDir -Force | Out-Null
        }
        Copy-Item -Path (Join-Path $WindowsDataDir "*") -Destination $PayloadWindowsDir -Force
    }

    $VarMap = Get-BlueprintVariables -Blueprint $Blueprint
    $PrimaryUser = if ($Blueprint.system.users.primary_user.username) { $Blueprint.system.users.primary_user.username } else { "User" }

    # Add standard user environment variables to resolution map for pre-computing paths
    $VarMap["USERPROFILE"] = "C:\Users\$PrimaryUser"
    $VarMap["USER_DIR"] = "C:\Users\$PrimaryUser"
    $VarMap["APPDATA"] = "C:\Users\$PrimaryUser\AppData\Roaming"
    $VarMap["LOCALAPPDATA"] = "C:\Users\$PrimaryUser\AppData\Local"
    $VarMap["PROGRAMFILES"] = "C:\Program Files"
    $VarMap["PROGRAMFILES(X86)"] = "C:\Program Files (x86)"
    $VarMap["PROGRAMDATA"] = "C:\ProgramData"

    $UserConfigDir = if ($BlueprintFile) { Split-Path -Parent $BlueprintFile } else { $null }
    $FullCatalog = Get-ReglazeCatalog -RepoRoot $RepoRoot -UserConfigDir $UserConfigDir

    # Extract & compile Windows settings, Network, Shell Folders, Steam Libraries, and App PATH entries
    $WinSettings = $null
    if ($Blueprint.windows_settings) {
        $WinSettings = $Blueprint.windows_settings | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    } elseif ($Blueprint.system -and $Blueprint.system.windows_settings) {
        $WinSettings = $Blueprint.system.windows_settings | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    } elseif ($AuditReference -and $AuditReference.detected_windows_settings) {
        $WinSettings = $AuditReference.detected_windows_settings | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    } else {
        $WinSettings = [PSCustomObject]@{
            explorer = [PSCustomObject]@{
                show_hidden_files    = $true
                show_file_extensions = $true
                launch_to            = "ThisPC"
            }
            taskbar = [PSCustomObject]@{
                alignment       = "Left"
                search_mode     = "IconOnly"
                widgets_visible = $false
                chat_visible    = $false
            }
            power = [PSCustomObject]@{
                active_scheme_name = "High Performance"
                ac_sleep_minutes   = 0
                ac_display_minutes = 30
            }
        }
    }

    # Resolve path variables inside Windows settings lists
    if ($WinSettings.explorer -and $WinSettings.explorer.quick_access_pins) {
        $WinSettings.explorer.quick_access_pins = @(
            $WinSettings.explorer.quick_access_pins | ForEach-Object { Resolve-VariableString -InputString ([string]$_) -VariableMap $VarMap }
        )
    }
    if ($WinSettings.taskbar -and $WinSettings.taskbar.pinned_apps) {
        $WinSettings.taskbar.pinned_apps = @(
            $WinSettings.taskbar.pinned_apps | ForEach-Object { Resolve-VariableString -InputString ([string]$_) -VariableMap $VarMap }
        )
    }
    if ($WinSettings.start_menu -and $WinSettings.start_menu.pinned_apps) {
        $WinSettings.start_menu.pinned_apps = @(
            $WinSettings.start_menu.pinned_apps | ForEach-Object { Resolve-VariableString -InputString ([string]$_) -VariableMap $VarMap }
        )
    }
    if ($WinSettings.theme -and $WinSettings.theme.wallpaper_path) {
        $WinSettings.theme.wallpaper_path = Resolve-VariableString -InputString ([string]$WinSettings.theme.wallpaper_path) -VariableMap $VarMap
    }

    # Attach resolved user_shell_folders
    if ($Blueprint.storage -and $Blueprint.storage.user_shell_folders) {
        $ResolvedUsf = [ordered]@{}
        $UsfObj = $Blueprint.storage.user_shell_folders
        $UsfProps = if ($UsfObj -is [System.Collections.IDictionary]) { $UsfObj.Keys } else { $UsfObj.PSObject.Properties.Name }
        foreach ($UKey in $UsfProps) {
            $UVal = if ($UsfObj -is [System.Collections.IDictionary]) { $UsfObj[$UKey] } else { $UsfObj.$UKey }
            if (-not [string]::IsNullOrWhiteSpace([string]$UVal)) {
                $ResolvedUsf[$UKey] = Resolve-VariableString -InputString ([string]$UVal) -VariableMap $VarMap
            }
        }
        Add-Member -InputObject $WinSettings -MemberType NoteProperty -Name "user_shell_folders" -Value ([PSCustomObject]$ResolvedUsf) -Force
    }

    # Attach resolved preserved Steam library folders
    if ($Blueprint.storage -and $Blueprint.storage.steam_libraries) {
        $ResolvedSteamLibs = @(
            $Blueprint.storage.steam_libraries | ForEach-Object { Resolve-VariableString -InputString ([string]$_) -VariableMap $VarMap }
        )
        Add-Member -InputObject $WinSettings -MemberType NoteProperty -Name "steam_libraries" -Value $ResolvedSteamLibs -Force
    }

    # Attach network & firewall configuration with resolved program paths
    if ($Blueprint.network) {
        $NetCopy = $Blueprint.network | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        if ($NetCopy.firewall_rules) {
            foreach ($Fw in $NetCopy.firewall_rules) {
                if ($Fw.program -and $Fw.program -ne "Any") {
                    $Fw.program = Resolve-VariableString -InputString ([string]$Fw.program) -VariableMap $VarMap
                }
            }
        }
        Add-Member -InputObject $WinSettings -MemberType NoteProperty -Name "network" -Value $NetCopy -Force
    }

    # Collect per-application path_entries from catalog and blueprint
    $CollectedPathEntries = [System.Collections.Generic.List[string]]::new()
    if ($Blueprint.applications) {
        foreach ($Prop in @($Blueprint.applications.PSObject.Properties)) {
            if ($Prop.Name -eq "custom") { continue }
            $AppId = $Prop.Name
            $AppCfg = $Prop.Value
            $CatApp = $FullCatalog | Where-Object { $_.app_id -ieq $AppId } | Select-Object -First 1
            $RawPaths = @()
            if ($AppCfg -and $AppCfg.PSObject.Properties["path_entries"] -and $AppCfg.path_entries) {
                $RawPaths += @($AppCfg.path_entries)
            } elseif ($CatApp -and $CatApp.PSObject.Properties["path_entries"] -and $CatApp.path_entries) {
                $RawPaths += @($CatApp.path_entries)
            }
            foreach ($PItem in $RawPaths) {
                if (-not [string]::IsNullOrWhiteSpace([string]$PItem)) {
                    $ResolvedP = Resolve-VariableString -InputString ([string]$PItem) -VariableMap $VarMap
                    if (-not $CollectedPathEntries.Contains($ResolvedP)) {
                        $CollectedPathEntries.Add($ResolvedP)
                    }
                }
            }
        }
        if ($Blueprint.applications.custom -and ($Blueprint.applications.custom -is [System.Collections.IEnumerable]) -and -not ($Blueprint.applications.custom -is [string])) {
            foreach ($CApp in $Blueprint.applications.custom) {
                if ($CApp.PSObject.Properties["path_entries"] -and $CApp.path_entries) {
                    foreach ($PItem in $CApp.path_entries) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$PItem)) {
                            $ResolvedP = Resolve-VariableString -InputString ([string]$PItem) -VariableMap $VarMap
                            if (-not $CollectedPathEntries.Contains($ResolvedP)) {
                                $CollectedPathEntries.Add($ResolvedP)
                            }
                        }
                    }
                }
            }
        }
    }
    Add-Member -InputObject $WinSettings -MemberType NoteProperty -Name "app_path_entries" -Value $CollectedPathEntries.ToArray() -Force

    $WinSettingsPath = Join-Path $PayloadDir "windows-settings.json"
    $WinSettings | ConvertTo-Json -Depth 8 | Set-Content -Path $WinSettingsPath -Encoding UTF8

    # =========================================================================
    # 1. Generate WinGet DSC Manifest (configuration.dsc.yaml) & User Packages Queue (user-packages.json)
    # =========================================================================
    $DscPath = Join-Path $PayloadDir "configuration.dsc.yaml"
    $DscResult = Build-WinGetDSCManifest -Blueprint $Blueprint -RepoRoot $RepoRoot -UserConfigDir $UserConfigDir -OutputPath $DscPath
    $UserPackagesPath = Join-Path $PayloadDir "user-packages.json"
    $UserPackagesList = if ($DscResult -and $DscResult.UserPackages) { @($DscResult.UserPackages) } else { @() }
    $UserPackagesJson = if ($UserPackagesList.Count -eq 0) { "[]" } else { ConvertTo-Json -InputObject $UserPackagesList -Depth 4 }
    $UserPackagesJson | Set-Content -Path $UserPackagesPath -Encoding UTF8

    # =========================================================================
    # 2. Generate Preserved Disk & Drive Letter Reconciliation Config (disk-config.json)
    # =========================================================================
    $ReferencedLetterSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    [void]$ReferencedLetterSet.Add("C")

    $AddReferencedDrive = {
        param([string]$PathStr)
        if ([string]::IsNullOrWhiteSpace($PathStr)) { return }
        $Resolved = Resolve-VariableString -InputString $PathStr -VariableMap $VarMap
        if ($Resolved -match '^([a-zA-Z]):') {
            [void]$ReferencedLetterSet.Add($Matches[1].ToUpperInvariant())
        }
    }

    $StreamMountPoint = if ($Blueprint.storage -and $Blueprint.storage.streaming -and $Blueprint.storage.streaming.mount_point) {
        ([System.IO.Path]::GetPathRoot($Blueprint.storage.streaming.mount_point)).TrimEnd('\')
    } elseif ($VarMap.ContainsKey("STREAM")) {
        ([System.IO.Path]::GetPathRoot($VarMap["STREAM"])).TrimEnd('\')
    } else {
        "E:"
    }
    $StreamDriveLetter = $StreamMountPoint.TrimEnd(':').ToUpperInvariant()

    $SyncRootPaths = [System.Collections.Generic.List[string]]::new()
    if ($Blueprint.storage -and $Blueprint.storage.sync -and $Blueprint.storage.sync.directories) {
        $SyncDirsObj = $Blueprint.storage.sync.directories
        $SyncDirProps = if ($SyncDirsObj -is [System.Collections.IDictionary]) { $SyncDirsObj.Keys } else { $SyncDirsObj.PSObject.Properties.Name }
        foreach ($SProp in $SyncDirProps) {
            $SDir = if ($SyncDirsObj -is [System.Collections.IDictionary]) { $SyncDirsObj[$SProp] } else { $SyncDirsObj.$SProp }
            if ($SDir.local_path) {
                & $AddReferencedDrive $SDir.local_path
                $ResolvedSPath = Resolve-VariableString -InputString $SDir.local_path -VariableMap $VarMap
                $SyncRootPaths.Add($ResolvedSPath.TrimEnd('\'))
            }
        }
    }

    if ($Blueprint.storage -and $Blueprint.storage.user_shell_folders) {
        $USFObj = $Blueprint.storage.user_shell_folders
        $USFProps = if ($USFObj -is [System.Collections.IDictionary]) { $USFObj.Keys } else { $USFObj.PSObject.Properties.Name }
        foreach ($UProp in $USFProps) {
            $UVal = if ($USFObj -is [System.Collections.IDictionary]) { $USFObj[$UProp] } else { $USFObj.$UProp }
            if ($UVal) { & $AddReferencedDrive $UVal }
        }
    }

    if ($Blueprint.dev_repos -and $Blueprint.dev_repos.root) {
        & $AddReferencedDrive $Blueprint.dev_repos.root
    }

    if ($Blueprint.applications) {
        foreach ($Prop in @($Blueprint.applications.PSObject.Properties)) {
            if ($Prop.Name -eq "custom") { continue }
            $AppCfg = $Prop.Value
            if ($AppCfg.install -and $AppCfg.install.target_directory) {
                & $AddReferencedDrive $AppCfg.install.target_directory
            }
            if ($AppCfg.directories) {
                foreach ($DProp in @($AppCfg.directories.PSObject.Properties)) {
                    $DCfg = $DProp.Value
                    if ($DCfg.target) { & $AddReferencedDrive $DCfg.target }
                    if ($DCfg.link) { & $AddReferencedDrive $DCfg.link }
                }
            }
        }
    }

    $CombinedCustomApps = @()
    if ($Blueprint.applications -and $Blueprint.applications.custom -and ($Blueprint.applications.custom -is [System.Collections.IEnumerable]) -and -not ($Blueprint.applications.custom -is [string])) {
        $CombinedCustomApps += @($Blueprint.applications.custom)
    }
    if ($Blueprint.custom -and ($Blueprint.custom -is [System.Collections.IEnumerable]) -and -not ($Blueprint.custom -is [string])) {
        $CombinedCustomApps += @($Blueprint.custom)
    }
    foreach ($CustApp in $CombinedCustomApps) {
        if ($CustApp.directories) {
            foreach ($CDir in $CustApp.directories) {
                if ($CDir.target) { & $AddReferencedDrive $CDir.target }
                if ($CDir.link) { & $AddReferencedDrive $CDir.link }
            }
        }
    }

    $AuditDisks = if ($AuditReference -and $AuditReference.storage_topology -and $AuditReference.storage_topology.disks) {
        @($AuditReference.storage_topology.disks)
    } else { @() }

    $PreservedDiskSpecs = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ($Blueprint.disks -and $Blueprint.disks.preserved_disks) {
        foreach ($PDisk in $Blueprint.disks.preserved_disks) {
            $PSerial = if ($PDisk.serial_number) { $PDisk.serial_number.Trim() } else { "" }
            $PDiskId = $PDisk.disk_id
            $PMount = if ($PDisk.expected_mount) { ([System.IO.Path]::GetPathRoot($PDisk.expected_mount)).TrimEnd('\') } else { $null }
            $PLetter = if ($PMount) { $PMount.TrimEnd(':').ToUpperInvariant() } else { $null }

            # Enrich from audit-reference.json if available
            $AuditDiskMatch = $null
            if ($PSerial -and $AuditDisks.Count -gt 0) {
                $AuditDiskMatch = $AuditDisks | Where-Object { $_.serial_number -and $_.serial_number.Trim() -ieq $PSerial } | Select-Object -First 1
            }
            if (-not $AuditDiskMatch -and $null -ne $PDiskId -and $AuditDisks.Count -gt 0) {
                $AuditDiskMatch = $AuditDisks | Where-Object { $_.disk_number -eq $PDiskId } | Select-Object -First 1
            }

            $AuditPartMatch = $null
            if ($AuditDiskMatch -and $AuditDiskMatch.partitions) {
                if ($PMount) {
                    $AuditPartMatch = $AuditDiskMatch.partitions | Where-Object { $_.mount_point -ieq $PMount } | Select-Object -First 1
                }
                if (-not $AuditPartMatch) {
                    $AuditPartMatch = $AuditDiskMatch.partitions | Where-Object { $_.mount_point } | Select-Object -First 1
                }
            }

            $ResolvedBusType = if ($PDisk.bus_type) { $PDisk.bus_type } elseif ($AuditDiskMatch -and $AuditDiskMatch.bus_type) { $AuditDiskMatch.bus_type } else { $null }
            $ResolvedPartNum = if ($null -ne $PDisk.partition_number) { [int]$PDisk.partition_number } elseif ($AuditPartMatch -and $null -ne $AuditPartMatch.partition_number) { [int]$AuditPartMatch.partition_number } else { $null }
            $ResolvedPartGuid = if ($PDisk.partition_guid) { $PDisk.partition_guid } elseif ($AuditPartMatch -and $AuditPartMatch.partition_guid) { $AuditPartMatch.partition_guid } else { $null }
            $ResolvedLabel = if ($PDisk.label) { $PDisk.label } elseif ($AuditPartMatch -and $AuditPartMatch.label) { $AuditPartMatch.label } elseif ($AuditDiskMatch) { $AuditDiskMatch.friendly_name } else { "" }

            $IsDiskRequired = if ($null -ne $PDisk.required) {
                [bool]$PDisk.required
            } else {
                [bool]($PLetter -and $ReferencedLetterSet.Contains($PLetter))
            }

            $PreservedDiskSpecs.Add([PSCustomObject]@{
                DiskId          = $PDiskId
                SerialNumber    = $PSerial
                BusType         = $ResolvedBusType
                PartitionNumber = $ResolvedPartNum
                PartitionGuid   = $ResolvedPartGuid
                ExpectedMount   = $PMount
                DriveVariable   = $PDisk.drive_variable
                Label           = $ResolvedLabel
                Required        = $IsDiskRequired
            })
        }
    }

    $DiskConfigObj = [PSCustomObject]@{
        TargetOsDisk = [PSCustomObject]@{
            DiskId        = if ($Blueprint.disks.target_os_disk) { $Blueprint.disks.target_os_disk.disk_id } else { 0 }
            SerialNumber  = if ($Blueprint.disks.target_os_disk) { $Blueprint.disks.target_os_disk.serial_number } else { "" }
            BusType       = if ($Blueprint.disks.target_os_disk) { $Blueprint.disks.target_os_disk.bus_type } else { "NVMe" }
            ExpectedMount = "C:"
        }
        PreservedDisks          = $PreservedDiskSpecs.ToArray()
        StreamMountPoint        = $StreamMountPoint
        ReferencedLetters       = @($ReferencedLetterSet | Sort-Object)
        UnconfiguredDrivePolicy = "clear_internal_reassign_removable"
    }
    $DiskConfigPath = Join-Path $PayloadDir "disk-config.json"
    $DiskConfigObj | ConvertTo-Json -Depth 6 | Set-Content -Path $DiskConfigPath -Encoding UTF8

    # =========================================================================
    # 3. Extract BitLocker Recovery Keys (bitlocker-keys.json)
    # =========================================================================
    $BitLockerEntries = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ($AuditReference -and $AuditReference.bitlocker_recovery_keys) {
        $BKeys = $AuditReference.bitlocker_recovery_keys
        $KeyItems = if ($BKeys -is [System.Collections.IEnumerable] -and -not ($BKeys -is [System.Collections.IDictionary]) -and -not ($BKeys -is [string])) {
            @($BKeys)
        } elseif ($BKeys -is [System.Collections.IDictionary]) {
            @($BKeys.Keys | ForEach-Object {
                $V = $BKeys[$_]
                if (-not $V.MountPoint -and -not $V.mount_point) { Add-Member -InputObject $V -MemberType NoteProperty -Name "MountPoint" -Value $_ -Force }
                $V
            })
        } else {
            @($BKeys.PSObject.Properties | ForEach-Object {
                $V = $_.Value
                if (-not $V.MountPoint -and -not $V.mount_point) { Add-Member -InputObject $V -MemberType NoteProperty -Name "MountPoint" -Value $_.Name -Force }
                $V
            })
        }

        foreach ($VolObj in $KeyItems) {
            $Mount = if ($VolObj.MountPoint) { $VolObj.MountPoint } elseif ($VolObj.mount_point) { $VolObj.mount_point } else { $null }
            $RecPass = if ($VolObj.RecoveryPassword) { $VolObj.RecoveryPassword } else { $VolObj.recovery_password }
            $RecKeyId = if ($VolObj.RecoveryKeyId) { $VolObj.RecoveryKeyId } else { $VolObj.key_protector_id }
            $VolType = if ($VolObj.VolumeType) { $VolObj.VolumeType } elseif ($VolObj.volume_type) { $VolObj.volume_type } else { "Data" }
            $DiskSer = if ($VolObj.DiskSerialNumber) { $VolObj.DiskSerialNumber } elseif ($VolObj.disk_serial_number) { $VolObj.disk_serial_number } else { $null }
            $PartNum = if ($null -ne $VolObj.PartitionNumber) { $VolObj.PartitionNumber } else { $VolObj.partition_number }
            $PartGuid = if ($VolObj.PartitionGuid) { $VolObj.PartitionGuid } else { $VolObj.partition_guid }

            # Skip C: drive since C: is wiped and reinstalled with fresh encryption post-install
            if ($Mount -and $Mount -notlike "C*") {
                $CleanMount = ([System.IO.Path]::GetPathRoot($Mount)).TrimEnd('\')
                if (-not $CleanMount) { $CleanMount = $Mount.TrimEnd('\') }

                # Match against PreservedDiskSpecs to bind hardware identity
                $MatchedSpec = $null
                if ($DiskSer) {
                    $MatchedSpec = $PreservedDiskSpecs | Where-Object { $_.SerialNumber -ieq $DiskSer } | Select-Object -First 1
                }
                if (-not $MatchedSpec -and $CleanMount) {
                    $MatchedSpec = $PreservedDiskSpecs | Where-Object { $_.ExpectedMount -ieq $CleanMount } | Select-Object -First 1
                }
                if ($MatchedSpec) {
                    if (-not $DiskSer) { $DiskSer = $MatchedSpec.SerialNumber }
                    if ($null -eq $PartNum) { $PartNum = $MatchedSpec.PartitionNumber }
                    if (-not $PartGuid) { $PartGuid = $MatchedSpec.PartitionGuid }
                    if ($MatchedSpec.ExpectedMount) { $CleanMount = $MatchedSpec.ExpectedMount }
                }

                $BitLockerEntries.Add([PSCustomObject]@{
                    MountPoint       = $CleanMount
                    DiskSerialNumber = $DiskSer
                    PartitionNumber  = $PartNum
                    PartitionGuid    = $PartGuid
                    VolumeType       = $VolType
                    RecoveryPassword = $RecPass
                    RecoveryKeyId    = $RecKeyId
                })
            }
        }
    }
    $BitLockerPath = Join-Path $PayloadDir "bitlocker-keys.json"
    $BitLockerJson = if ($BitLockerEntries.Count -eq 0) { "[]" } else { ConvertTo-Json -InputObject @($BitLockerEntries.ToArray()) -Depth 4 }
    $BitLockerJson | Set-Content -Path $BitLockerPath -Encoding UTF8

    # =========================================================================
    # 4. Generate Pre-Computed Junctions Manifest (junctions-manifest.json)
    # =========================================================================
    $JunctionsList = [System.Collections.Generic.List[PSCustomObject]]::new()
    $Catalog = Get-ReglazeCatalog -RepoRoot $RepoRoot -UserConfigDir $UserConfigDir

    $TestIsCloudOrPhase5Target = {
        param([string]$RawTarget, [string]$ResolvedTarget, $CatApp)
        if ($RawTarget -like "*%STREAM%*" -or $RawTarget -like "*%SYNC_*") { return $true }
        if ($StreamMountPoint -and $ResolvedTarget.StartsWith($StreamMountPoint, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        foreach ($SPath in $SyncRootPaths) {
            if ($ResolvedTarget.StartsWith($SPath, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        if ($CatApp -and $CatApp.install -and $CatApp.install.method -in @("steam", "manual")) { return $true }
        return $false
    }

    if ($Blueprint.applications) {
        $AppProps = @($Blueprint.applications.PSObject.Properties)
        foreach ($Prop in $AppProps) {
            $AppId = $Prop.Name
            if ($AppId -eq "custom") { continue }
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
                    if (-not $ConfiguredLink) {
                        $ConfiguredLink = $Dir.default_path
                    }

                    if ($ConfiguredTarget) {
                        $ResolvedLink = Resolve-VariableString -InputString $ConfiguredLink -VariableMap $VarMap
                        $ResolvedTarget = Resolve-VariableString -InputString $ConfiguredTarget -VariableMap $VarMap

                        $RequiresElevation = [bool]($ResolvedLink -like "C:\ProgramData*" -or $ResolvedLink -like "C:\Program Files*")
                        $DependsOnPhase5 = & $TestIsCloudOrPhase5Target $ConfiguredTarget $ResolvedTarget $CatalogApp

                        # Defer cloud-backed (%STREAM%, %SYNC_*%) and Steam/Manual app junctions to Phase 5 (hydrate.ps1)
                        $Scope = if ($RequiresElevation -and -not $DependsOnPhase5) { "machine" } else { "user" }
                        $StorageType = if ($Dir.recommended_storage) { $Dir.recommended_storage } else { "streaming" }
                        $ItemType = if ($Dir.item_type) { [string]$Dir.item_type } else { "directory" }

                        $JunctionsList.Add([PSCustomObject]@{
                            AppId             = $AppId
                            DirectoryId       = $Dir.id
                            Description       = $Dir.description
                            Link              = $ResolvedLink
                            Target            = $ResolvedTarget
                            Scope             = $Scope
                            ItemType          = $ItemType
                            RequiresElevation = $RequiresElevation
                            StorageType       = $StorageType
                            SafeForStream     = [bool]$Dir.safe_for_stream
                            CollisionAction   = "backup"
                        })
                    }
                }
            }
        }
    }

    # Inspect custom directory mappings (both applications.custom and top-level custom)
    foreach ($CustomApp in $CombinedCustomApps) {
        if ($CustomApp.directories) {
            foreach ($CustDir in $CustomApp.directories) {
                if ($CustDir.link -and $CustDir.target) {
                    $ResolvedLink = Resolve-VariableString -InputString $CustDir.link -VariableMap $VarMap
                    $ResolvedTarget = Resolve-VariableString -InputString $CustDir.target -VariableMap $VarMap
                    $RequiresElevation = [bool]($ResolvedLink -like "C:\ProgramData*" -or $ResolvedLink -like "C:\Program Files*")
                    $DependsOnPhase5 = & $TestIsCloudOrPhase5Target $CustDir.target $ResolvedTarget $null
                    $Scope = if ($RequiresElevation -and -not $DependsOnPhase5) { "machine" } else { "user" }
                    $StorageType = if ($CustDir.storage_type) { $CustDir.storage_type } else { "streaming" }
                    $CustItemType = if ($CustDir.item_type) { [string]$CustDir.item_type } else { "directory" }

                    $JunctionsList.Add([PSCustomObject]@{
                        AppId             = "custom"
                        DirectoryId       = if ($CustDir.name) { ($CustDir.name -replace '[^a-zA-Z0-9_]', '_').ToLower() } else { "custom_dir" }
                        Description       = if ($CustDir.name) { $CustDir.name } else { "Custom Directory Junction" }
                        Link              = $ResolvedLink
                        Target            = $ResolvedTarget
                        Scope             = $Scope
                        ItemType          = $CustItemType
                        RequiresElevation = $RequiresElevation
                        StorageType       = $StorageType
                        SafeForStream     = $true
                        CollisionAction   = "backup"
                    })
                }
            }
        }
    }

    $JunctionsPath = Join-Path $PayloadDir "junctions-manifest.json"
    $JunctionsJson = if ($JunctionsList.Count -eq 0) { "[]" } else { ConvertTo-Json -InputObject @($JunctionsList.ToArray()) -Depth 4 }
    $JunctionsJson | Set-Content -Path $JunctionsPath -Encoding UTF8

    # =========================================================================
    # 5. Generate Google Drive Setup & Sync Migration Payload (google-drive-setup.json)
    # =========================================================================
    $ProfileName = if ($Blueprint.profile) {
        [string]$Blueprint.profile
    } elseif ($AuditReference -and $AuditReference.audit_metadata -and $AuditReference.audit_metadata.profile) {
        [string]$AuditReference.audit_metadata.profile
    } else {
        "workstation"
    }

    $TargetComputerName = if ($Blueprint.system -and $Blueprint.system.computer_name) { [string]$Blueprint.system.computer_name } else { "WORKSTATION" }
    $PrimaryUserEmail = if ($Blueprint.system -and $Blueprint.system.users -and $Blueprint.system.users.primary_user -and $Blueprint.system.users.primary_user.email) {
        [string]$Blueprint.system.users.primary_user.email
    } elseif ($AuditReference -and $AuditReference.user_identity -and $AuditReference.user_identity.email) {
        [string]$AuditReference.user_identity.email
    } else {
        "user@example.com"
    }

    # Resolve SourceComputerName (Google Drive 'Other computers\<Name>' container name, e.g., 'My Computer')
    $SourceComputerName = $null
    if ($Blueprint.storage -and $Blueprint.storage.sync) {
        if ($Blueprint.storage.sync.google_drive_computer_name) {
            $SourceComputerName = [string]$Blueprint.storage.sync.google_drive_computer_name
        } elseif ($Blueprint.storage.sync.source_computer) {
            $SourceComputerName = [string]$Blueprint.storage.sync.source_computer
        }
    }
    if (-not $SourceComputerName -and $AuditReference -and $AuditReference.storage_providers) {
        if ($AuditReference.storage_providers.google_drive -and $AuditReference.storage_providers.google_drive.computer_folder_name) {
            $SourceComputerName = [string]$AuditReference.storage_providers.google_drive.computer_folder_name
        } elseif ($AuditReference.storage_providers.computer_folder_name) {
            $SourceComputerName = [string]$AuditReference.storage_providers.computer_folder_name
        }
    }
    if (-not $SourceComputerName -and $BlueprintFile) {
        $BpDir = Split-Path -Parent $BlueprintFile
        $ProfRegPath = Join-Path $BpDir "profile-computers.json"
        if (Test-Path $ProfRegPath) {
            try {
                $ProfReg = Get-Content -Raw -Path $ProfRegPath | ConvertFrom-Json
                if ($ProfReg.profiles -and $ProfReg.profiles.$ProfileName) {
                    $PEntry = $ProfReg.profiles.$ProfileName
                    if ($PEntry.google_drive_computer_name) {
                        $SourceComputerName = [string]$PEntry.google_drive_computer_name
                    }
                }
            } catch {}
        }
    }
    if (-not $SourceComputerName) {
        $SourceComputerName = "My Computer"
    }

    $MigrationMode = if ($Blueprint.storage -and $Blueprint.storage.sync -and $Blueprint.storage.sync.migration_mode) {
        [string]$Blueprint.storage.sync.migration_mode
    } else {
        "copy"
    }

    $StreamSentinel = if ($VarMap.ContainsKey("STREAM")) { $VarMap["STREAM"] } else { "$StreamMountPoint\My Drive" }

    $SyncDirPayloads = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ($Blueprint.storage -and $Blueprint.storage.sync -and $Blueprint.storage.sync.directories) {
        $SyncDirsObj = $Blueprint.storage.sync.directories
        $SyncDirProps = if ($SyncDirsObj -is [System.Collections.IDictionary]) { $SyncDirsObj.Keys } else { $SyncDirsObj.PSObject.Properties.Name }
        foreach ($SProp in $SyncDirProps) {
            $SDir = if ($SyncDirsObj -is [System.Collections.IDictionary]) { $SyncDirsObj[$SProp] } else { $SyncDirsObj.$SProp }
            $ResolvedLocal = Resolve-VariableString -InputString $SDir.local_path -VariableMap $VarMap
            $ResolvedVerify = if ($SDir.verify_folder) { Resolve-VariableString -InputString $SDir.verify_folder -VariableMap $VarMap } else { $ResolvedLocal }
            $CloudFolder = if ($SDir.cloud_folder) { [string]$SDir.cloud_folder } else { Split-Path -Leaf $ResolvedLocal }

            $LocalDriveRoot = if ($ResolvedLocal) { ([System.IO.Path]::GetPathRoot($ResolvedLocal)).TrimEnd('\') } else { "" }
            $IsOnPreservedDisk = [bool](
                ($LocalDriveRoot -and $LocalDriveRoot -inotlike "C*") -or
                ($PreservedDiskSpecs | Where-Object { $_.ExpectedMount -and $_.ExpectedMount -ieq $LocalDriveRoot })
            )

            $CloudDocId = $null
            if ($AuditReference -and $AuditReference.storage_providers -and $AuditReference.storage_providers.sync_directories) {
                $AuditSyncMatch = $AuditReference.storage_providers.sync_directories | Where-Object { $_.id -eq $SProp -or $_.cloud_folder -eq $CloudFolder } | Select-Object -First 1
                if ($AuditSyncMatch -and $AuditSyncMatch.cloud_doc_id) {
                    $CloudDocId = [string]$AuditSyncMatch.cloud_doc_id
                }
            }

            $SyncDirPayloads.Add([PSCustomObject]@{
                Id                       = $SProp
                LocalPath                = $ResolvedLocal
                CloudFolder              = $CloudFolder
                VerifyFolder             = $ResolvedVerify
                SyncVariable             = $SDir.sync_variable
                CloudDocId               = $CloudDocId
                IsOnPreservedDisk        = $IsOnPreservedDisk
                SourceComputerStreamPath = "$StreamMountPoint\Other computers\$SourceComputerName\$CloudFolder"
            })
        }
    }

    $SyncSummaryStr = if ($SyncDirPayloads.Count -gt 0) {
        ($SyncDirPayloads | ForEach-Object { "$($_.CloudFolder) ($($_.LocalPath))" }) -join ", "
    } else {
        "None configured"
    }

    $SyncBulletsLines = @()
    if ($SyncDirPayloads.Count -gt 0) {
        foreach ($SD in $SyncDirPayloads) {
            $SyncBulletsLines += "- **$($SD.CloudFolder)** (`$($SD.Id)`):"
            $SyncBulletsLines += "  - Local Path: ``$($SD.LocalPath)``"
            $SyncBulletsLines += "  - Previous Computer Container Path: ``$($SD.SourceComputerStreamPath)``"
        }
    } else {
        $SyncBulletsLines += "- *(No Folders from this computer configured)*"
    }
    $SyncBulletsStr = $SyncBulletsLines -join "`n"

    $SyncSetupInstruction = if ($SyncDirPayloads.Count -gt 0) {
        "DO configure Sync folders: Open Google Drive Preferences -> 'Folders from your computer' -> click 'Add folder', select 'Sync with Google Drive' (do NOT select 'Back up to Google Photos'), and add ONLY these pre-created local sync directories: $SyncSummaryStr."
    } else {
        "DO NOT create or add any Sync folders under Google Drive Preferences -> 'Folders from your computer' (leave 'Folders from your computer' empty; this blueprint uses streaming junctions only)."
    }

    $SyncMigrationInstruction = if ($SyncDirPayloads.Count -gt 0) {
        "In Google Drive under Computers (or via '$StreamMountPoint\Other computers\$SourceComputerName'), $MigrationMode the contents of each synced folder from the previous computer '$SourceComputerName' (profile '$ProfileName') into the newly created computer's folders and wait for initial sync to finish."
    } else {
        "No 'Folders from your computer' sync migration is required for this configuration."
    }

    $TemplateTokens = @{
        "{{PRIMARY_EMAIL}}"              = $PrimaryUserEmail
        "{{STREAM_MOUNT}}"               = $StreamMountPoint
        "{{STREAM_DRIVE_LETTER}}"        = $StreamDriveLetter
        "{{STREAM_VERIFY_FOLDER}}"       = $StreamSentinel
        "{{SYNC_DIRS_SUMMARY}}"          = $SyncSummaryStr
        "{{SYNC_DIRS_BULLETS}}"          = $SyncBulletsStr
        "{{SYNC_DIRECTORIES_LIST}}"      = $SyncBulletsStr
        "{{SYNC_SETUP_INSTRUCTION}}"     = $SyncSetupInstruction
        "{{SYNC_MIGRATION_INSTRUCTION}}" = $SyncMigrationInstruction
        "{{MIGRATION_MODE}}"             = $MigrationMode
        "{{SOURCE_COMPUTER_NAME}}"       = $SourceComputerName
        "{{TARGET_COMPUTER_NAME}}"       = $TargetComputerName
        "{{PROFILE_NAME}}"               = $ProfileName
    }

    $ApplyTemplateTokens = {
        param([string]$Text)
        if ([string]::IsNullOrEmpty($Text)) { return $Text }
        $Out = $Text
        foreach ($Key in $TemplateTokens.Keys) {
            $Out = $Out.Replace($Key, [string]$TemplateTokens[$Key])
        }
        return $Out
    }

    # Render google_drive catalog entry instructions & guide.md
    $RenderedInstructions = @()
    $GDriveApp = $Catalog | Where-Object { $_.app_id -eq "google_drive" } | Select-Object -First 1
    if ($GDriveApp -and $GDriveApp.install -and $GDriveApp.install.instructions) {
        foreach ($InstLine in $GDriveApp.install.instructions) {
            $RenderedInstructions += (& $ApplyTemplateTokens $InstLine)
        }
        $GDriveApp.install.instructions = $RenderedInstructions
    }

    $GDriveGuideTemplatePath = Join-Path $RepoRoot "data\applications\google_drive\guide.md"
    $RenderedGuideContent = ""
    if (Test-Path $GDriveGuideTemplatePath) {
        $RawGuide = Get-Content -Raw -Path $GDriveGuideTemplatePath
        $RenderedGuideContent = & $ApplyTemplateTokens $RawGuide
        $GoogleDriveGuidePath = Join-Path $PayloadDir "google-drive-guide.md"
        $RenderedGuideContent | Set-Content -Path $GoogleDriveGuidePath -Encoding UTF8
    }

    $GoogleDriveSetupObj = [PSCustomObject]@{
        Profile              = $ProfileName
        TargetComputerName   = $TargetComputerName
        SourceComputerName   = $SourceComputerName
        PrimaryUserEmail     = $PrimaryUserEmail
        StreamMountPoint     = $StreamMountPoint
        StreamVerifyFolder   = $StreamSentinel
        MigrationMode        = $MigrationMode
        SyncDirectories      = $SyncDirPayloads.ToArray()
        RenderedInstructions = $RenderedInstructions
        GuideFile            = "google-drive-guide.md"
    }
    $GoogleDriveSetupPath = Join-Path $PayloadDir "google-drive-setup.json"
    $GoogleDriveSetupObj | ConvertTo-Json -Depth 6 | Set-Content -Path $GoogleDriveSetupPath -Encoding UTF8

    # =========================================================================
    # 6. Generate Machine Bootstrap Scripts (bootstrap.ps1 & bootstrap-helpers.ps1)
    # =========================================================================
    $BootstrapGenResult = Build-ReglazeBootstrapScripts `
        -Blueprint $Blueprint `
        -PayloadDir $PayloadDir `
        -StreamMountPoint $StreamMountPoint `
        -StreamDriveLetter $StreamDriveLetter `
        -PrimaryUser $PrimaryUser
    $BootstrapPath = $BootstrapGenResult.BootstrapPath

    # =========================================================================
    # 7. Generate User Hydration Scripts (hydrate.ps1, hydrate-helpers.ps1, setup-wsl.sh)
    # =========================================================================
    $HydrateGenResult = Build-ReglazeHydrateScripts `
        -Blueprint $Blueprint `
        -PayloadDir $PayloadDir `
        -VarMap $VarMap
    $HydratePath = $HydrateGenResult.HydratePath
    $WslPath = $HydrateGenResult.WslScriptPath

    # =========================================================================
    # 8. Export Filtered Applications Catalog for Blueprint (applications.json) & Non-Steam Shortcuts
    # =========================================================================
    $CatalogJsonPath = Join-Path $PayloadDir "applications.json"
    $PayloadCatalog = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ($Blueprint.applications) {
        foreach ($Prop in @($Blueprint.applications.PSObject.Properties)) {
            $AppId = $Prop.Name
            if ($AppId -eq "custom") { continue }
            $AppCfg = $Prop.Value
            if ($null -ne $AppCfg.install -and ($AppCfg.install -eq $false -or $AppCfg.install.enabled -eq $false)) {
                continue
            }
            $CatEntry = $Catalog | Where-Object { $_.app_id -ieq $AppId } | Select-Object -First 1
            if ($CatEntry) {
                $PayloadCatalog.Add($CatEntry)
            } elseif ($AppCfg -and $AppCfg.install) {
                $PayloadCatalog.Add([PSCustomObject]@{
                    app_id  = $AppId
                    name    = if ($AppCfg.name) { $AppCfg.name } else { $AppId }
                    website = $AppCfg.website
                    install = $AppCfg.install
                })
            }
        }
        foreach ($CApp in $CombinedCustomApps) {
            if ($null -ne $CApp.install -and ($CApp.install -eq $false -or $CApp.install.enabled -eq $false)) {
                continue
            }
            if ($CApp.install) {
                $CId = if ($CApp.app_id) { $CApp.app_id } elseif ($CApp.name) { ($CApp.name -replace '[^a-zA-Z0-9_]', '_').ToLower() } else { "custom_app" }
                $PayloadCatalog.Add([PSCustomObject]@{
                    app_id  = $CId
                    name    = if ($CApp.name) { $CApp.name } else { $CId }
                    website = $CApp.website
                    install = $CApp.install
                })
            }
        }
    } else {
        foreach ($CatItem in $Catalog) {
            $PayloadCatalog.Add($CatItem)
        }
    }
    $CatalogJson = if ($PayloadCatalog.Count -eq 0) { "[]" } else { ConvertTo-Json -InputObject @($PayloadCatalog.ToArray()) -Depth 6 }
    $CatalogJson | Set-Content -Path $CatalogJsonPath -Encoding UTF8

    # Export non-Steam shortcuts (steam-shortcuts.json) if present in blueprint or audit-reference.json
    $SteamShortcutsPath = Join-Path $PayloadDir "steam-shortcuts.json"
    $ShortcutsToExport = [System.Collections.Generic.List[object]]::new()
    if ($Blueprint.steam_shortcuts) {
        foreach ($Sc in @($Blueprint.steam_shortcuts)) { $ShortcutsToExport.Add($Sc) }
    } elseif ($AuditReference -and $AuditReference.steam_shortcuts) {
        foreach ($Sc in @($AuditReference.steam_shortcuts)) { $ShortcutsToExport.Add($Sc) }
    }
    foreach ($PApp in $PayloadCatalog) {
        if ($PApp.install -and $PApp.install.steam_shortcut) {
            $ShortcutsToExport.Add($PApp.install.steam_shortcut)
        }
    }
    $ShortcutsJson = if ($ShortcutsToExport.Count -eq 0) { "[]" } else { ConvertTo-Json -InputObject @($ShortcutsToExport.ToArray()) -Depth 5 }
    $ShortcutsJson | Set-Content -Path $SteamShortcutsPath -Encoding UTF8

    return [PSCustomObject]@{
        PayloadDir           = $PayloadDir
        DscPath              = $DscPath
        DiskConfigPath       = $DiskConfigPath
        GoogleDriveSetupPath = $GoogleDriveSetupPath
        BitLockerPath        = $BitLockerPath
        JunctionsPath        = $JunctionsPath
        BootstrapPath        = $BootstrapPath
        BootstrapHelpersPath = $BootstrapGenResult.BootstrapHelpersPath
        HydratePath          = $HydratePath
        HydrateHelpersPath   = $HydrateGenResult.HydrateHelpersPath
        WslScriptPath        = $WslPath
        CatalogPath          = $CatalogJsonPath
        WindowsSettingsPath  = $WinSettingsPath
        JunctionCount        = $JunctionsList.Count
        BitLockerKeyCount    = $BitLockerEntries.Count
    }
}
