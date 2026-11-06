<#
.SYNOPSIS
    Payload artifact generator and assembler for Reglaze.
.DESCRIPTION
    Compiles and generates the complete media payload directory:
    - bitlocker-keys.json: Extracted BitLocker recovery keys for secondary/preserved volumes
    - junctions-manifest.json: Pre-computed junction mapping table with collision backup rules
    - bootstrap.ps1: Phase 4 machine script running under LocalAdmin (BitLocker, WHQL drivers, Windows Updates, WinGet DSC, WSL2, RunOnce staging)
    - hydrate.ps1: Phase 5 interactive user hydration script with state checkpoints and HITL steps
    - setup-wsl.sh: Non-interactive WSL2 provisioning script
    - configuration.dsc.yaml: WinGet DSC manifest
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
        [string]$BlueprintFile = $null
    )

    if (-not $RepoRoot) {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }

    if (-not (Test-Path $PayloadDir)) {
        New-Item -ItemType Directory -Path $PayloadDir -Force | Out-Null
    }

    # Stage linking & drive letter reconciliation modules into payload
    $LinkingDir = Join-Path $RepoRoot "src\linking"
    if (Test-Path $LinkingDir) {
        foreach ($LinkScript in @("Set-ReglazeDriveLetters.ps1", "Unlock-BitLockerVolumes.ps1", "New-DirectoryJunction.ps1", "Test-ReparsePoint.ps1", "Backup-CollisionFolder.ps1")) {
            $SrcScript = Join-Path $LinkingDir $LinkScript
            if (Test-Path $SrcScript) {
                Copy-Item -Path $SrcScript -Destination (Join-Path $PayloadDir $LinkScript) -Force
            }
        }
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
    # 1. Generate WinGet DSC Manifest (configuration.dsc.yaml)
    # =========================================================================
    $DscPath = Join-Path $PayloadDir "configuration.dsc.yaml"
    Build-WinGetDSCManifest -Blueprint $Blueprint -RepoRoot $RepoRoot -UserConfigDir $UserConfigDir -OutputPath $DscPath | Out-Null

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

                    if ($AppConfig.directories -and $AppConfig.directories.$($Dir.id)) {
                        $DirConf = $AppConfig.directories.$($Dir.id)
                        $ConfiguredTarget = $DirConf.target
                        if ($DirConf.link) { $ConfiguredLink = $DirConf.link }
                    }

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

    # Resolve SourceComputerName from: (1) storage.sync.source_computer, (2) profile-computers.json, (3) audit-reference.json, (4) system.computer_name
    $SourceComputerName = $null
    if ($Blueprint.storage -and $Blueprint.storage.sync -and $Blueprint.storage.sync.source_computer) {
        $SourceComputerName = [string]$Blueprint.storage.sync.source_computer
    }
    if (-not $SourceComputerName -and $BlueprintFile) {
        $BpDir = Split-Path -Parent $BlueprintFile
        $ProfRegPath = Join-Path $BpDir "profile-computers.json"
        if (Test-Path $ProfRegPath) {
            try {
                $ProfReg = Get-Content -Raw -Path $ProfRegPath | ConvertFrom-Json
                if ($ProfReg.profiles -and $ProfReg.profiles.$ProfileName) {
                    $PEntry = $ProfReg.profiles.$ProfileName
                    if ($PEntry.latest_computer_name) {
                        $SourceComputerName = [string]$PEntry.latest_computer_name
                    }
                }
            } catch {}
        }
    }
    if (-not $SourceComputerName -and $AuditReference) {
        if ($AuditReference.profile_association -and $AuditReference.profile_association.latest_computer_name) {
            $SourceComputerName = [string]$AuditReference.profile_association.latest_computer_name
        } elseif ($AuditReference.audit_metadata -and $AuditReference.audit_metadata.host_name) {
            $SourceComputerName = [string]$AuditReference.audit_metadata.host_name
        }
    }
    if (-not $SourceComputerName) {
        $SourceComputerName = $TargetComputerName
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
    # 6. Generate Machine Bootstrap Runner (bootstrap.ps1)
    # =========================================================================
    $UpdatesDrivers = if ($Blueprint.system.updates -and $null -ne $Blueprint.system.updates.drivers) { [bool]$Blueprint.system.updates.drivers } else { $true }
    $UpdatesWindows = if ($Blueprint.system.updates -and $null -ne $Blueprint.system.updates.windows_updates) { [bool]$Blueprint.system.updates.windows_updates } else { $true }
    $LocalAdminUser = if ($Blueprint.system.users.local_admin.username) { $Blueprint.system.users.local_admin.username } else { "LocalAdmin" }
    $PrimaryIsAdmin = if ($Blueprint.system -and $Blueprint.system.users -and $Blueprint.system.users.primary_user -and $null -ne $Blueprint.system.users.primary_user.is_admin) { [bool]$Blueprint.system.users.primary_user.is_admin } else { $false }
    $PrimaryGroup = if ($PrimaryIsAdmin) { "Administrators" } else { "Users" }

    $BootstrapScript = @"
<#
.SYNOPSIS
    Reglaze Phase 4 Machine Bootstrap Runner.
.DESCRIPTION
    Executes automatically under LocalAdmin account upon initial post-install boot.
    Reconciles preserved disk drive letters, unlocks connected BitLocker volumes,
    provisions a standalone UEFI bootloader on the target disk's EFI partition,
    executes automated WHQL driver updates, checks for disconnected required drives
    (offering a safe power-down and reconnect checkpoint with LocalAdmin AutoLogon + RunOnce),
    applies general Windows updates, configures Google Drive streaming mount policy,
    executes WinGet DSC machine-scope application provisioning, stages WSL2, creates machine-scope
    directory junctions, applies machine-level system settings, destroys auto-logon credentials,
    and stages user hydration.
#>
[CmdletBinding()]
param()

`$ErrorActionPreference = "Continue"
`$ReglazeRoot = "C:\Reglaze"
if (-not (Test-Path `$ReglazeRoot)) {
    New-Item -ItemType Directory -Path `$ReglazeRoot -Force | Out-Null
}
# Grant Modify permissions on C:\Reglaze to BUILTIN\Users (S-1-5-32-545) so standard user hydration can write logs and checkpoints
try {
    & icacls.exe `$ReglazeRoot /grant "*S-1-5-32-545:(OI)(CI)M" /T /C /Q 2>&1 | Out-Null
} catch {}

# Enable Developer Mode for unprivileged symbolic links
try {
    `$DevRegPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
    if (-not (Test-Path `$DevRegPath)) { New-Item -Path `$DevRegPath -Force | Out-Null }
    Set-ItemProperty -Path `$DevRegPath -Name "AllowDevelopmentWithoutDevLicense" -Value 1 -Type DWord -Force
} catch {}
`$TranscriptFile = "C:\Reglaze\bootstrap.log"
try {
    Start-Transcript -Path `$TranscriptFile -Append -Force | Out-Null
} catch {}

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "               REGLAZE PHASE 4: MACHINE BOOTSTRAP RUNNER                       " -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "Transcript log: `$TranscriptFile" -ForegroundColor DarkGray

`$PayloadDir = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$StateFile = "C:\Reglaze\bootstrap-state.json"
`$DiskConfigFile = Join-Path `$PayloadDir "disk-config.json"
`$BitLockerKeyFile = Join-Path `$PayloadDir "bitlocker-keys.json"
`$DriveLetterScript = Join-Path `$PayloadDir "Set-ReglazeDriveLetters.ps1"
`$BitLockerScript = Join-Path `$PayloadDir "Unlock-BitLockerVolumes.ps1"

if (Test-Path `$DriveLetterScript) { . `$DriveLetterScript }
if (Test-Path `$BitLockerScript) { . `$BitLockerScript }

`$BootstrapState = [PSCustomObject]@{
    CompletedSteps = @()
    StartedAt      = (Get-Date).ToString("o")
}
if (Test-Path `$StateFile) {
    try {
        `$BootstrapState = Get-Content -Raw `$StateFile | ConvertFrom-Json
        if (-not `$BootstrapState.CompletedSteps) { `$BootstrapState.CompletedSteps = @() }
        Write-Host "Resumed Phase 4 bootstrap state. Completed steps: `$(`$BootstrapState.CompletedSteps -join ', ')" -ForegroundColor DarkCyan
    } catch {}
}

function Save-BootstrapStep ([string]`$StepName) {
    if (`$BootstrapState.CompletedSteps -notcontains `$StepName) {
        `$BootstrapState.CompletedSteps += `$StepName
    }
    `$StateDir = Split-Path -Parent `$StateFile
    if (-not (Test-Path `$StateDir)) { New-Item -ItemType Directory -Path `$StateDir -Force | Out-Null }
    `$BootstrapState | ConvertTo-Json -Depth 4 | Set-Content -Path `$StateFile -Encoding UTF8
}

function Initialize-PSWindowsUpdate {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force -ErrorAction SilentlyContinue
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ForceBootstrap -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null
    Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    if (-not (Get-Module -Name PSWindowsUpdate -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-Module -Name PSWindowsUpdate -Force -SkipPublisherCheck -AcceptLicense -Confirm:`$false -Scope CurrentUser -ErrorAction Stop
    }
    # Trust the PSWindowsUpdate Authenticode publisher certificate and unblock module files so Import-Module never prompts for untrusted publisher
    `$ModCandidates = @(Get-Module -Name PSWindowsUpdate -ListAvailable -ErrorAction SilentlyContinue)
    foreach (`$Mod in `$ModCandidates) {
        if (`$Mod.ModuleBase -and (Test-Path -LiteralPath `$Mod.ModuleBase)) {
            `$ModFiles = @(Get-ChildItem -Path `$Mod.ModuleBase -Recurse -File -ErrorAction SilentlyContinue)
            foreach (`$Mf in `$ModFiles) {
                try { Unblock-File -LiteralPath `$Mf.FullName -ErrorAction SilentlyContinue } catch {}
                if (`$Mf.Extension -in @('.psm1', '.ps1xml', '.dll', '.ps1')) {
                    try {
                        `$Sig = Get-AuthenticodeSignature -FilePath `$Mf.FullName -ErrorAction SilentlyContinue
                        if (`$Sig -and `$Sig.SignerCertificate) {
                            foreach (`$StoreScope in @('CurrentUser', 'LocalMachine')) {
                                try {
                                    `$Store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPublisher", `$StoreScope)
                                    `$Store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
                                    `$Store.Add(`$Sig.SignerCertificate)
                                    `$Store.Close()
                                } catch {}
                            }
                        }
                    } catch {}
                }
            }
        }
    }
    Import-Module -Name PSWindowsUpdate -Force -DisableNameChecking -Global -ErrorAction Stop
}

# 1. Pass 1 Drive Letter Reconciliation and Connected BitLocker Unlock
Write-Host "[1/9] Reconciling drive letters (Pass 1) and unlocking connected BitLocker volumes..." -ForegroundColor Yellow
`$Pass1Disks = `$null
if (Get-Command Invoke-DriveLetterReconciliation -ErrorAction SilentlyContinue) {
    `$Pass1Disks = Invoke-DriveLetterReconciliation -DiskConfigPath `$DiskConfigFile -Simulation:`$false -Live:`$true
}
if ((Test-Path `$BitLockerKeyFile) -and (Get-Command Unlock-PreservedBitLockerVolumes -ErrorAction SilentlyContinue)) {
    `$ConnectedSerials = if (`$Pass1Disks -and `$Pass1Disks.ConnectedPreservedDisks) {
        @(`$Pass1Disks.ConnectedPreservedDisks | ForEach-Object { `$_.SerialNumber })
    } else { `$null }
    Unlock-PreservedBitLockerVolumes -KeyFilePath `$BitLockerKeyFile -ConnectedSerialNumbers `$ConnectedSerials -Simulation:`$false -Live:`$true | Out-Null
}
Save-BootstrapStep "pass1_disks_and_bitlocker"

# 1b. Standalone UEFI Bootloader Provisioning on Target OS Disk EFI System Partition
if (`$BootstrapState.CompletedSteps -notcontains "efi_bootloader") {
    Write-Host "[1b/9] Ensuring standalone UEFI bootloader on target OS disk EFI partition..." -ForegroundColor Yellow
    try {
        `$OsPart = Get-Partition -DriveLetter C -ErrorAction SilentlyContinue
        if (`$OsPart) {
            `$EfiPart = Get-Partition -DiskNumber `$OsPart.DiskNumber -ErrorAction SilentlyContinue |
                Where-Object { `$_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -or `$_.IsSystem } |
                Select-Object -First 1
            if (`$EfiPart) {
                `$TempEfiLetter = `$null
                `$TargetEfiDrive = `$null
                if (`$EfiPart.DriveLetter) {
                    `$TargetEfiDrive = "`$(`$EfiPart.DriveLetter):"
                } else {
                    foreach (`$CandLetter in @('S', 'T', 'U', 'V', 'W', 'R', 'Q', 'P')) {
                        if (-not (Get-PSDrive -Name `$CandLetter -ErrorAction SilentlyContinue)) {
                            `$TempEfiLetter = `$CandLetter
                            break
                        }
                    }
                    if (`$TempEfiLetter) {
                        Set-Partition -DiskNumber `$EfiPart.DiskNumber -PartitionNumber `$EfiPart.PartitionNumber -NewDriveLetter `$TempEfiLetter -ErrorAction Stop
                        `$TargetEfiDrive = "`${TempEfiLetter}:"
                    }
                }
                if (`$TargetEfiDrive) {
                    Write-Host " - Running bcdboot C:\Windows /s `$TargetEfiDrive /f UEFI (Disk `$(`$OsPart.DiskNumber), Partition `$(`$EfiPart.PartitionNumber))..."
                    & bcdboot.exe C:\Windows /s `$TargetEfiDrive /f UEFI
                    if (`$TempEfiLetter) {
                        Remove-PartitionAccessPath -DiskNumber `$EfiPart.DiskNumber -PartitionNumber `$EfiPart.PartitionNumber -AccessPath "`${TempEfiLetter}:\" -ErrorAction SilentlyContinue
                    }
                    Write-Host "   Standalone UEFI bootloader provisioned on target disk." -ForegroundColor Green
                }
            } else {
                Write-Warning "   No EFI System Partition detected on OS Disk `$(`$OsPart.DiskNumber); skipping bcdboot."
            }
        }
    } catch {
        Write-Warning "   Could not provision standalone UEFI bootloader: `$(`$_.Exception.Message)"
    }
    Save-BootstrapStep "efi_bootloader"
}

# 2. Automated WHQL Driver Updates (Chipset, Storage Controllers, Audio, Network, GPU)
if (`$BootstrapState.CompletedSteps -notcontains "whql_drivers") {
    if (`$$($UpdatesDrivers.ToString().ToLower())) {
        Write-Host "[2/9] Running automated WHQL driver servicing pass..." -ForegroundColor Yellow
        try {
            Initialize-PSWindowsUpdate
            Write-Host " - Scanning and installing WHQL device drivers..."
            Get-WindowsUpdate -Category "Drivers" -Install -AcceptAll -IgnoreReboot -ErrorAction SilentlyContinue
            Write-Host "   WHQL driver pass completed." -ForegroundColor Green
        } catch {
            Write-Warning "   Driver update pass encountered an issue: `$(`$_.Exception.Message). Continuing installation."
        }
    } else {
        Write-Host "[2/9] Automated driver servicing pass skipped by configuration." -ForegroundColor DarkGray
    }
    Save-BootstrapStep "whql_drivers"
}

# 2b. Pass 2 Drive Letter Reconciliation and Missing Required Disk Reconnection Check
Write-Host "[2b/9] Verifying required preserved disks and reconciling drive letters (Pass 2)..." -ForegroundColor Yellow
if (Get-Command Invoke-DriveLetterReconciliation -ErrorAction SilentlyContinue) {
    `$Pass2Disks = Invoke-DriveLetterReconciliation -DiskConfigPath `$DiskConfigFile -Simulation:`$false -Live:`$true
    while (`$Pass2Disks.RequiresReconnectShutdown) {
        Write-Host ""
        Write-Host "================================================================================" -ForegroundColor Yellow
        Write-Host "  ACTION REQUIRED: PRESERVED DRIVE(S) DISCONNECTED" -ForegroundColor Yellow
        Write-Host "================================================================================" -ForegroundColor Yellow
        Write-Host "The following preserved disk(s) are required by your configuration:" -ForegroundColor White
        foreach (`$Missing in `$Pass2Disks.MissingRequiredDisks) {
            Write-Host "  - Expected Mount: `$(`$Missing.ExpectedMount) | Label: `$(`$Missing.Label) | Serial: `$(`$Missing.SerialNumber)" -ForegroundColor Cyan
        }
        Write-Host ""
        Write-Host "Options:"
        Write-Host "  [P] Power down (shut down) now so you can safely reconnect SATA/NVMe drives (Recommended)"
        Write-Host "      (Reglaze will automatically log back in and resume Phase 4 when powered on)"
        Write-Host "  [R] Re-scan storage bus now (if you just connected an external/hot-plug drive)"
        Write-Host "  [C] Continue without missing drives (not recommended)"
        `$Choice = Read-Host "Select an option [P/R/C] (default: P)"
        if ([string]::IsNullOrWhiteSpace(`$Choice) -or `$Choice -match '^[Pp]') {
            `$BootstrapCmd = "powershell.exe -ExecutionPolicy Bypass -File ``"C:\Reglaze\payload\bootstrap.ps1``""
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "ReglazeBootstrapResume" -Value `$BootstrapCmd -ErrorAction SilentlyContinue
            `$WinlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
            Set-ItemProperty -Path `$WinlogonPath -Name "AutoAdminLogon" -Value "1" -ErrorAction SilentlyContinue
            Set-ItemProperty -Path `$WinlogonPath -Name "DefaultUserName" -Value "$LocalAdminUser" -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path `$WinlogonPath -Name "AutoLogonCount" -ErrorAction SilentlyContinue
            Save-BootstrapStep "awaiting_drive_reconnect"
            Write-Host "Shutting down workstation for drive reconnection..." -ForegroundColor Yellow
            try { Stop-Transcript | Out-Null } catch {}
            Start-Sleep -Seconds 3
            Stop-Computer -Force
            exit 0
        } elseif (`$Choice -match '^[Rr]') {
            Update-HostStorageCache -ErrorAction SilentlyContinue
            `$Pass2Disks = Invoke-DriveLetterReconciliation -DiskConfigPath `$DiskConfigFile -Simulation:`$false -Live:`$true
        } else {
            Write-Warning "Proceeding without missing required disks by user override."
            break
        }
    }

    if ((Test-Path `$BitLockerKeyFile) -and (Get-Command Unlock-PreservedBitLockerVolumes -ErrorAction SilentlyContinue)) {
        Unlock-PreservedBitLockerVolumes -KeyFilePath `$BitLockerKeyFile -Simulation:`$false -Live:`$true | Out-Null
    }
}
Save-BootstrapStep "pass2_disks_verified"

# 3. General Windows Quality and Security Updates
if (`$BootstrapState.CompletedSteps -notcontains "windows_updates") {
    if (`$$($UpdatesWindows.ToString().ToLower())) {
        Write-Host "[3/9] Running general Windows update pass..." -ForegroundColor Yellow
        try {
            Initialize-PSWindowsUpdate
            Write-Host " - Installing quality and security patches..."
            Get-WindowsUpdate -NotCategory "Drivers" -Install -AcceptAll -IgnoreReboot -ErrorAction SilentlyContinue
            Write-Host "   General Windows update pass completed." -ForegroundColor Green
        } catch {
            Write-Warning "   Windows update pass encountered an issue: `$(`$_.Exception.Message). Continuing installation."
        }
    } else {
        Write-Host "[3/9] General Windows updates skipped by configuration." -ForegroundColor DarkGray
    }
    Save-BootstrapStep "windows_updates"
}

# 4. Pre-configure Google Drive DefaultMountPoint Policy and Execute WinGet DSC
Write-Host "[4/9] Configuring Google Drive streaming mount policy ($StreamMountPoint) and running WinGet DSC..." -ForegroundColor Yellow
try {
    `$DriveFsPolicyPath = "HKLM:\SOFTWARE\Policies\Google\DriveFS"
    if (-not (Test-Path `$DriveFsPolicyPath)) {
        New-Item -Path `$DriveFsPolicyPath -Force | Out-Null
    }
    Set-ItemProperty -Path `$DriveFsPolicyPath -Name "DefaultMountPoint" -Value "$StreamDriveLetter" -Type String -Force
    Write-Host " - Configured DriveFS DefaultMountPoint policy to '${StreamDriveLetter}:'" -ForegroundColor Green
} catch {
    Write-Warning "   Could not set DriveFS DefaultMountPoint policy: `$(`$_.Exception.Message)"
}

# Ensure WinGet (Microsoft.DesktopAppInstaller) is registered, installed, and in PATH on clean Windows 11 installs
function Resolve-WinGetBinary {
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction SilentlyContinue
    } catch {}
    `$wingetExe = (Get-ChildItem -Path "`$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending |
                  Select-Object -First 1).FullName
    if (`$wingetExe) {
        `$wgDir = Split-Path `$wingetExe -Parent
        if (`$env:Path -notlike "*`$wgDir*") {
            `$env:Path += ";`$wgDir;`$env:LOCALAPPDATA\Microsoft\WindowsApps"
        }
    } elseif (`$env:Path -notlike "*`$env:LOCALAPPDATA\Microsoft\WindowsApps*") {
        `$env:Path += ";`$env:LOCALAPPDATA\Microsoft\WindowsApps"
    }
    return (Get-Command winget -ErrorAction SilentlyContinue)
}

`$WingetCmd = Resolve-WinGetBinary
if (-not `$WingetCmd) {
    Write-Host " - WinGet CLI not yet available on fresh OS; installing/repairing Microsoft.DesktopAppInstaller..." -ForegroundColor Yellow
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    # Strategy 1: Repair-WinGetPackageManager via Microsoft.WinGet.Client
    try {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ForceBootstrap -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null
        Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Install-Module -Name Microsoft.WinGet.Client -Force -SkipPublisherCheck -AcceptLicense -Confirm:`$false -Scope CurrentUser -ErrorAction Stop
        Import-Module -Name Microsoft.WinGet.Client -Force -ErrorAction SilentlyContinue
        Repair-WinGetPackageManager -AllUsers -Force -Latest -ErrorAction Stop
    } catch {
        Write-Host "   Repair-WinGetPackageManager fallback: downloading official WinGet MSIX bundle (https://aka.ms/getwinget)..." -ForegroundColor DarkCyan
        try {
            `$WgTempDir = "C:\Reglaze\temp"
            if (-not (Test-Path `$WgTempDir)) { New-Item -ItemType Directory -Path `$WgTempDir -Force | Out-Null }
            `$VcLibsPath = Join-Path `$WgTempDir "Microsoft.VCLibs.x64.14.00.Desktop.appx"
            `$UiXamlPath = Join-Path `$WgTempDir "Microsoft.UI.Xaml.2.8.x64.appx"
            `$BundlePath = Join-Path `$WgTempDir "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
            Invoke-WebRequest -Uri "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx" -OutFile `$VcLibsPath -UseBasicParsing -ErrorAction SilentlyContinue
            Invoke-WebRequest -Uri "https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx" -OutFile `$UiXamlPath -UseBasicParsing -ErrorAction SilentlyContinue
            Invoke-WebRequest -Uri "https://aka.ms/getwinget" -OutFile `$BundlePath -UseBasicParsing -ErrorAction Stop
            if (Test-Path `$VcLibsPath) { Add-AppxPackage -Path `$VcLibsPath -ErrorAction SilentlyContinue }
            if (Test-Path `$UiXamlPath) { Add-AppxPackage -Path `$UiXamlPath -ErrorAction SilentlyContinue }
            if (Test-Path `$BundlePath) {
                Add-AppxPackage -Path `$BundlePath -ErrorAction SilentlyContinue
                `$Deps = @(`$VcLibsPath, `$UiXamlPath) | Where-Object { Test-Path `$_ }
                Add-AppxProvisionedPackage -Online -PackagePath `$BundlePath -DependencyPackagePath `$Deps -SkipLicense -ErrorAction SilentlyContinue | Out-Null
            }
        } catch {
            Write-Warning "   Could not download/install WinGet MSIX bundle: `$(`$_.Exception.Message)"
        }
    }
    `$WingetCmd = Resolve-WinGetBinary
}
if (`$WingetCmd) {
    Write-Host " - WinGet CLI ready at: `$(`$WingetCmd.Source)" -ForegroundColor Green
} else {
    Write-Warning " - WinGet CLI could not be resolved; package installations may be skipped."
}

# Enforce machine-wide installer preference in WinGet settings
foreach (`$WsDir in @("`$env:LOCALAPPDATA\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState", "`$env:LOCALAPPDATA\Microsoft\WinGet\Settings")) {
    try {
        if (-not (Test-Path `$WsDir)) { New-Item -ItemType Directory -Path `$WsDir -Force | Out-Null }
        '{"installBehavior":{"preferences":{"scope":"machine"}}}' | Set-Content -Path (Join-Path `$WsDir "settings.json") -Encoding UTF8 -Force
    } catch {}
}

`$DscManifest = Join-Path `$PayloadDir "configuration.dsc.yaml"
if (Test-Path `$DscManifest) {
    Write-Host " - Enabling WinGet DSC configuration feature..."
    & winget configure enable 2>&1 | Out-Null
    & winget configure --enable --accept-configuration-agreements 2>&1 | Out-Null

    # Install WinGet packages with explicit --scope machine and retry logic (up to 2 attempts per package)
    `$DscText = Get-Content -Raw -LiteralPath `$DscManifest -ErrorAction SilentlyContinue
    if (`$DscText) {
        `$PkgMatches = [regex]::Matches(`$DscText, 'id:\s*"([^"]+)"\s*\r?\n\s*source:\s*(\S+)')
        foreach (`$Match in `$PkgMatches) {
            `$PkgId = `$Match.Groups[1].Value
            `$PkgSource = `$Match.Groups[2].Value
            if (`$PkgSource -eq "winget") {
                `$PkgInstalled = `$false
                for (`$Attempt = 1; `$Attempt -le 2; `$Attempt++) {
                    if (`$Attempt -gt 1) {
                        Write-Host "   Retrying package installation for `$PkgId (Attempt `$Attempt of 2)..." -ForegroundColor Yellow
                        Start-Sleep -Seconds 5
                    }
                    Write-Host " - Installing machine-wide package: `$PkgId (--scope machine, attempt `$Attempt/2)..."
                    & winget install --id `$PkgId --source `$PkgSource --scope machine --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
                    # 0 = Installed, -1978335189 (0x8A15002B) = Already installed / no applicable update
                    if (`$LASTEXITCODE -eq 0 -or `$LASTEXITCODE -eq -1978335189) {
                        `$PkgInstalled = `$true
                        break
                    }
                    Write-Host "   Package `$PkgId has no dedicated machine-scope installer or returned exit `$LASTEXITCODE; trying default scope..." -ForegroundColor DarkGray
                    & winget install --id `$PkgId --source `$PkgSource --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
                    if (`$LASTEXITCODE -eq 0 -or `$LASTEXITCODE -eq -1978335189) {
                        `$PkgInstalled = `$true
                        break
                    }
                }
                if (-not `$PkgInstalled) {
                    Write-Warning "   Package `$PkgId failed after 2 attempts (last exit code: `$LASTEXITCODE)."
                }
            }
        }
    }

    for (`$DscAttempt = 1; `$DscAttempt -le 2; `$DscAttempt++) {
        if (`$DscAttempt -gt 1) {
            Write-Host "   Retrying WinGet DSC configuration pass (Attempt `$DscAttempt of 2)..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
        Write-Host " - Running: winget configure --file ``"`$DscManifest``" --accept-configuration-agreements --disable-interactivity (Attempt `$DscAttempt/2)"
        & winget configure --file `$DscManifest --accept-configuration-agreements --disable-interactivity
        if (`$LASTEXITCODE -eq 0) {
            break
        }
    }
    Write-Host "   WinGet DSC deployment pass completed." -ForegroundColor Green
} else {
    Write-Warning "   WinGet DSC configuration manifest not found at `$DscManifest."
}
Save-BootstrapStep "winget_dsc"

# 5. Stage WSL2 Base Kernel and Ubuntu Distro
Write-Host "[5/9] Staging WSL2 subsystem and Ubuntu distribution..." -ForegroundColor Yellow
try {
    & wsl.exe --install -d Ubuntu --no-launch
    Write-Host "   WSL2 staged successfully." -ForegroundColor Green
} catch {
    Write-Warning "   WSL2 staging returned: `$(`$_.Exception.Message)"
}
Save-BootstrapStep "wsl_staged"

# 6. Create Machine-Level Junctions (Local/Preserved Disk Targets Only)
Write-Host "[6/9] Creating machine-level directory junctions..." -ForegroundColor Yellow
`$JunctionsManifest = Join-Path `$PayloadDir "junctions-manifest.json"
if (Test-Path `$JunctionsManifest) {
    `$Junctions = Get-Content -Raw `$JunctionsManifest | ConvertFrom-Json
    foreach (`$Junc in `$Junctions) {
        if (`$Junc.Scope -eq "machine") {
            `$Link = `$Junc.Link
            `$Target = `$Junc.Target
            `$IsFile = (`$Junc.ItemType -eq "file")
            Write-Host " - Link: `$Link -> `$Target"
            if (`$IsFile) {
                `$TargetFile = if (Test-Path -LiteralPath `$Target -PathType Container) {
                    Join-Path `$Target (Split-Path `$Link -Leaf)
                } elseif (`$Target.EndsWith((Split-Path `$Link -Leaf), [System.StringComparison]::OrdinalIgnoreCase)) {
                    `$Target
                } else {
                    Join-Path `$Target (Split-Path `$Link -Leaf)
                }
                `$TargetParent = Split-Path -Parent `$TargetFile
                if (`$TargetParent -and -not (Test-Path -LiteralPath `$TargetParent)) {
                    New-Item -ItemType Directory -Path `$TargetParent -Force | Out-Null
                }
            } else {
                if (-not (Test-Path -LiteralPath `$Target)) {
                    New-Item -ItemType Directory -Path `$Target -Force | Out-Null
                }
            }
            if (Test-Path `$Link) {
                `$Item = Get-Item `$Link -Force
                if (-not (`$Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    `$BackupPath = "`$Link.bak_`$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                    Move-Item -Path `$Link -Destination `$BackupPath -Force
                    Write-Host "   Collision detected: Backed up existing to `$BackupPath." -ForegroundColor Yellow
                } else {
                    Remove-Item -Path `$Link -Force
                }
            }
            `$ParentDir = Split-Path -Parent `$Link
            if (-not (Test-Path `$ParentDir)) { New-Item -ItemType Directory -Path `$ParentDir -Force | Out-Null }
            if (`$IsFile) {
                cmd.exe /c mklink "`$Link" "`$TargetFile" | Out-Null
            } else {
                cmd.exe /c mklink /J "`$Link" "`$Target" | Out-Null
            }
        }
    }
}
Save-BootstrapStep "machine_junctions"

# 7. Apply Machine-Scope System Preferences (Power, Audio/Display Hardware, Network & Firewall)
# NOTE: User-specific HKCU personalization and User Shell Folders are deferred to hydrate.ps1
# so we never pre-create C:\Users\$PrimaryUser before the user's first interactive login.
Write-Host "[7/9] Applying machine-level power, audio/display hardware, and network preferences..." -ForegroundColor Yellow
`$WinSettingsFile = Join-Path `$PayloadDir "windows-settings.json"
`$WinScriptsDir = Join-Path `$PayloadDir "windows"
if (Test-Path `$WinSettingsFile) {
    try {
        `$WinCfg = Get-Content -Raw `$WinSettingsFile | ConvertFrom-Json
        `$PwrScript = Join-Path `$WinScriptsDir "performance-power.ps1"
        if (Test-Path `$PwrScript) {
            `$Plan = (`$WinCfg.power.active_scheme_name -replace '\s+', '')
            `$AcDisp = if (`$null -ne `$WinCfg.power.ac_display_minutes) { [int]`$WinCfg.power.ac_display_minutes } else { 30 }
            `$LongPaths = if (`$WinCfg.system_ergonomics -and `$null -ne `$WinCfg.system_ergonomics.long_paths_enabled) { [bool]`$WinCfg.system_ergonomics.long_paths_enabled } else { `$null }
            `$SshStartup = if (`$WinCfg.system_ergonomics -and `$WinCfg.system_ergonomics.ssh_agent_startup) { [string]`$WinCfg.system_ergonomics.ssh_agent_startup } else { `$null }
            & `$PwrScript -PowerPlan `$Plan -AcSleepTimeoutMinutes ([int]`$WinCfg.power.ac_sleep_minutes) -AcDisplayTimeoutMinutes `$AcDisp -LongPathsEnabled `$LongPaths -SshAgentStartup `$SshStartup
        }
        `$AudioScript = Join-Path `$WinScriptsDir "audio-display.ps1"
        if ((Test-Path `$AudioScript) -and `$WinCfg.audio_and_devices) {
            `$GameMode = if (`$WinCfg.display -and `$null -ne `$WinCfg.display.game_mode_enabled) { [bool]`$WinCfg.display.game_mode_enabled } else { `$true }
            `$HwGpu = if (`$WinCfg.display -and `$null -ne `$WinCfg.display.hardware_gpu_scheduling) { [bool]`$WinCfg.display.hardware_gpu_scheduling } else { `$true }
            & `$AudioScript -DefaultSpeakers `$WinCfg.audio_and_devices.default_speakers -DefaultMicrophone `$WinCfg.audio_and_devices.default_microphone -DefaultCamera `$WinCfg.audio_and_devices.default_camera -DisabledCameras @(`$WinCfg.audio_and_devices.disabled_cameras) -MasterVolumePercent ([int]`$WinCfg.audio_and_devices.master_volume_percent) -MasterMuted:([bool]`$WinCfg.audio_and_devices.master_muted) -GameModeEnabled:`$GameMode -HardwareGpuScheduling:`$HwGpu
        }
        `$NetScript = Join-Path `$WinScriptsDir "network-firewall.ps1"
        if ((Test-Path `$NetScript) -and `$WinCfg.network) {
            & `$NetScript -SharingWizardEnabled:([bool]`$WinCfg.network.sharing_wizard_enabled) -NetworkCategory `$WinCfg.network.network_category -NetworkDiscoveryEnabled:([bool]`$WinCfg.network.network_discovery_enabled) -FileAndPrinterSharingEnabled:([bool]`$WinCfg.network.file_and_printer_sharing_enabled) -PasswordProtectedSharing:([bool]`$WinCfg.network.password_protected_sharing) -Adapters @(`$WinCfg.network.adapters) -HostsEntries @(`$WinCfg.network.hosts_entries) -FirewallRules @(`$WinCfg.network.firewall_rules)
        }
        Write-Host "   Machine-level Windows preferences applied successfully." -ForegroundColor Green
    } catch {
        Write-Warning "   Could not apply machine-level Windows preferences: `$(`$_.Exception.Message)"
    }
}
Save-BootstrapStep "machine_settings"

# Ensure Primary Daily Driver Account Exists
Write-Host "Ensuring primary user account '$PrimaryUser' exists..." -ForegroundColor Yellow
if (-not (Get-LocalUser -Name "$PrimaryUser" -ErrorAction SilentlyContinue)) {
    try {
        New-LocalUser -Name "$PrimaryUser" -NoPassword -Description "Reglaze Standard Daily Driver" -FullName "$PrimaryUser" | Out-Null
        Add-LocalGroupMember -Group "$PrimaryGroup" -Member "$PrimaryUser" -ErrorAction SilentlyContinue
        Write-Host "   Created primary user '$PrimaryUser' (Group: $PrimaryGroup)." -ForegroundColor Green
    } catch {
        Write-Warning "   Could not create primary user '$PrimaryUser': `$(`$_.Exception.Message)"
    }
}

# 8. Destroy AutoLogon Credentials
Write-Host "[8/9] Destroying temporary LocalAdmin AutoLogon credentials..." -ForegroundColor Yellow
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "DefaultPassword" -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "AutoAdminLogon" -Value "0" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "ReglazeBootstrapResume" -ErrorAction SilentlyContinue
Write-Host "   AutoLogon deactivated." -ForegroundColor Green

# 9. Schedule Phase 5 Hydration on User Logon and Stage Desktop Shortcut
Write-Host "[9/9] Scheduling Phase 5 User Hydration..." -ForegroundColor Yellow
`$HydrateCmd = "powershell.exe -ExecutionPolicy Bypass -NoExit -File ``"C:\Reglaze\payload\hydrate.ps1``""
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "ReglazeHydrate" -Value `$HydrateCmd -ErrorAction SilentlyContinue

try {
    `$WshShell = New-Object -ComObject WScript.Shell
    `$ShortcutPath = "C:\Users\Public\Desktop\Reglaze Hydration.lnk"
    `$Shortcut = `$WshShell.CreateShortcut(`$ShortcutPath)
    `$Shortcut.TargetPath = "powershell.exe"
    `$Shortcut.Arguments = "-ExecutionPolicy Bypass -NoExit -File ``"C:\Reglaze\payload\hydrate.ps1``""
    `$Shortcut.IconLocation = "shell32.dll,238"
    `$Shortcut.Description = "Resume Reglaze User Hydration Wizard"
    `$Shortcut.Save()
    Write-Host "   Created desktop shortcut: `$ShortcutPath" -ForegroundColor Green
} catch {
    Write-Warning "   Could not create public desktop shortcut: `$(`$_.Exception.Message)"
}

Save-BootstrapStep "completed"
Write-Host ""
Write-Host "================================================================================" -ForegroundColor Green
Write-Host "   PHASE 4 MACHINE BOOTSTRAP COMPLETE! REBOOTING INTO USER SESSION...           " -ForegroundColor Green
Write-Host "================================================================================" -ForegroundColor Green
try { Stop-Transcript | Out-Null } catch {}
Start-Sleep -Seconds 3
Restart-Computer -Force
"@

    $BootstrapPath = Join-Path $PayloadDir "bootstrap.ps1"
    $BootstrapScript | Set-Content -Path $BootstrapPath -Encoding UTF8

    # =========================================================================
    # 7. Generate User Hydration Runner (hydrate.ps1) with State Checkpoints
    # =========================================================================
    $StreamSentinel = if ($VarMap.ContainsKey("STREAM")) { $VarMap["STREAM"] } else { "E:\My Drive" }
    $DataDrive = if ($VarMap.ContainsKey("DATA_DRIVE")) { $VarMap["DATA_DRIVE"] } else { "D:" }

    $HydrateScript = @"
<#
.SYNOPSIS
    Reglaze Phase 5 User Hydration and Interactive Wizard.
.DESCRIPTION
    Runs in the primary user session. Manages state persistence via C:\Reglaze\hydrate-state.json
    so users can safely exit and resume at any point. Verifies preserved drive mounts, walks through
    Microsoft Account sign-in, Google Drive virtual mount and Computer sync folder setup/migration,
    Steam library auto-discovery, manual app installations, user-scope directory junctions,
    user-specific Windows Explorer/Taskbar/Theme/Input/UserShellFolders personalization,
    WSL2 user hydration, and dev repositories.
#>
[CmdletBinding()]
param(
    [switch]`$ResetState = `$false
)

`$ErrorActionPreference = "Continue"
`$TranscriptFile = "C:\Reglaze\hydrate.log"
try {
    `$TranscriptDir = Split-Path -Parent `$TranscriptFile
    if (-not (Test-Path `$TranscriptDir)) { New-Item -ItemType Directory -Path `$TranscriptDir -Force | Out-Null }
    Start-Transcript -Path `$TranscriptFile -Append -Force | Out-Null
} catch {
    try {
        `$FallbackLog = Join-Path `$env:LOCALAPPDATA "Reglaze\hydrate.log"
        `$FallbackDir = Split-Path -Parent `$FallbackLog
        if (-not (Test-Path `$FallbackDir)) { New-Item -ItemType Directory -Path `$FallbackDir -Force | Out-Null }
        Start-Transcript -Path `$FallbackLog -Append -Force | Out-Null
    } catch {}
}

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "            REGLAZE PHASE 5: USER HYDRATION AND STATE LINKING WIZARD            " -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "Transcript log: `$TranscriptFile" -ForegroundColor DarkGray

# Ensure WinGet AppX execution alias is registered for the standard user account
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction SilentlyContinue
    `$env:Path += ";`$env:LOCALAPPDATA\Microsoft\WindowsApps"
}

`$PayloadDir = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$StateFile = "C:\Reglaze\hydrate-state.json"
`$State = [PSCustomObject]@{
    CompletedSteps = @()
    StartedAt = (Get-Date).ToString("o")
}

if ((Test-Path `$StateFile) -and -not `$ResetState) {
    try {
        `$State = Get-Content -Raw `$StateFile | ConvertFrom-Json
        if (-not `$State.CompletedSteps) { `$State.CompletedSteps = @() }
        Write-Host "Loaded existing hydration state. Completed steps: `$(`$State.CompletedSteps -join ', ')" -ForegroundColor DarkCyan
    } catch {
        Write-Warning "Could not parse state file; starting fresh."
    }
}

function Save-HydrateState {
    param([string]`$StepName)
    if (`$State.CompletedSteps -notcontains `$StepName) {
        `$State.CompletedSteps += `$StepName
    }
    `$StateDir = Split-Path -Parent `$StateFile
    if (-not (Test-Path `$StateDir)) { New-Item -ItemType Directory -Path `$StateDir -Force | Out-Null }
    `$State | ConvertTo-Json -Depth 3 | Set-Content -Path `$StateFile -Encoding UTF8
    Write-Host "[Checkpoint: Saved step '`$StepName']" -ForegroundColor DarkGray
}

# --- STEP 0: Verify Preserved Disk Mounts ---
`$DiskConfigFile = Join-Path `$PayloadDir "disk-config.json"
if (Test-Path `$DiskConfigFile) {
    `$DiskCfg = Get-Content -Raw `$DiskConfigFile | ConvertFrom-Json
    foreach (`$PD in `$DiskCfg.PreservedDisks) {
        if (`$PD.Required -and `$PD.ExpectedMount -and -not (Test-Path "`$(`$PD.ExpectedMount)\")) {
            Write-Warning "Required preserved disk '`$(`$PD.Label)' (`$(`$PD.ExpectedMount)) is not currently mounted!"
        }
    }
}

# --- STEP 1: Microsoft Account Connection ---
if (`$State.CompletedSteps -notcontains "microsoft_account") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 1: Microsoft Account Sign-In (Optional)" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "If you wish to link this standard account to your Microsoft Account for store and"
    Write-Host "digital license sync, open Windows Settings -> Accounts -> Your Info."
    `$PromptMSA = Read-Host "Would you like to open Windows Accounts settings now? (y/N)"
    if (`$PromptMSA -match '^[Yy]') {
        Start-Process "ms-settings:yourinfo"
        Write-Host "Settings opened. Complete your sign-in, then return here."
        Read-Host "Press [Enter] when ready to proceed to Step 2..."
    }
    Save-HydrateState "microsoft_account"
} else {
    Write-Host "[V] Step 1: Microsoft Account (Already completed)" -ForegroundColor DarkGray
}

# --- STEP 2: Cloud Virtual Mount and Synced Folders Setup (Google Drive) ---
if (`$State.CompletedSteps -notcontains "cloud_mount") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 2: Google Drive Streaming Mount and Synced Folder Migration" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    `$SentinelPath = "$StreamSentinel"
    `$GDriveSetupFile = Join-Path `$PayloadDir "google-drive-setup.json"
    `$GDriveSetup = if (Test-Path `$GDriveSetupFile) { Get-Content -Raw `$GDriveSetupFile | ConvertFrom-Json } else { `$null }

    if (`$GDriveSetup) {
        # Pre-create local synced directories on physical disks
        foreach (`$SDir in `$GDriveSetup.SyncDirectories) {
            if (`$SDir.LocalPath -and -not (Test-Path `$SDir.LocalPath)) {
                New-Item -ItemType Directory -Path `$SDir.LocalPath -Force | Out-Null
            }
        }
        Write-Host "Google Drive Setup Checklist (Profile: `$(`$GDriveSetup.Profile)):" -ForegroundColor Cyan
        Write-Host "  [WHAT TO DO / WHAT NOT TO DO DURING GOOGLE DRIVE SETUP]" -ForegroundColor Yellow
        foreach (`$InstLine in `$GDriveSetup.RenderedInstructions) {
            Write-Host "  * `$InstLine"
        }
        if (`$GDriveSetup.SyncDirectories -and `$GDriveSetup.SyncDirectories.Count -gt 0) {
            Write-Host ""
            Write-Host "  Pre-created Sync Folders to add in Google Drive Preferences -> 'Folders from your computer':" -ForegroundColor Green
            foreach (`$SDir in `$GDriveSetup.SyncDirectories) {
                Write-Host "    + `$(`$SDir.LocalPath) (Cloud folder: `$(`$SDir.CloudFolder))" -ForegroundColor Green
            }
        } else {
            Write-Host ""
            Write-Host "  IMPORTANT: No local Sync folders are configured in this blueprint." -ForegroundColor Yellow
            Write-Host "  DO NOT create or add any folders under 'Folders from your computer' in Google Drive Preferences." -ForegroundColor Yellow
        }
        Write-Host ""
    } else {
        Write-Host "Directory junctions require your cloud storage virtual stream to be mounted at:"
        Write-Host "  `$SentinelPath" -ForegroundColor Cyan
        Write-Host "  * DO NOT select Desktop, Documents, or Pictures for backup during Google Drive onboarding." -ForegroundColor Yellow
        Write-Host "  * DO configure Google Drive ('My Drive') to 'Stream files' (NOT 'Mirror files')." -ForegroundColor Yellow
        Write-Host ""
    }

    # Launch Google Drive client if not running
    if (-not (Get-Process "GoogleDriveFS" -ErrorAction SilentlyContinue)) {
        `$GDFPath = "C:\Program Files\Google\Drive File Stream\launch.bat"
        if (Test-Path `$GDFPath) {
            Start-Process `$GDFPath
        } else {
            Start-Process "powershell.exe" "-Command Start-Process 'shell:AppsFolder\Google.GoogleDrive'" -ErrorAction SilentlyContinue
        }
    }

    Write-Host "Waiting for sentinel directory: `$SentinelPath..." -ForegroundColor Yellow
    `$WaitCount = 0
    while (-not (Test-Path `$SentinelPath)) {
        Start-Sleep -Seconds 3
        `$WaitCount++
        if (`$WaitCount -ge 5 -and (`$WaitCount % 5 -eq 0)) {
            `$ManualChoice = Read-Host "Sentinel not yet found. Press [Enter] to keep waiting, or type 'skip' to bypass:"
            if (`$ManualChoice -eq 'skip') {
                Write-Warning "Skipping cloud sentinel verification by user request."
                break
            }
        }
    }

    if (Test-Path `$SentinelPath) {
        Write-Host "[SUCCESS] Cloud streaming mount verified at `$SentinelPath!" -ForegroundColor Green
    }

    # Migrate (copy/move) files from previous computer's synced folders if configured
    if (`$GDriveSetup -and `$GDriveSetup.SyncDirectories -and `$GDriveSetup.SyncDirectories.Count -gt 0 -and `$GDriveSetup.MigrationMode -ne "skip") {
        Write-Host ""
        Write-Host "Checking previous computer ('`$(`$GDriveSetup.SourceComputerName)') synced folders for migration (`$(`$GDriveSetup.MigrationMode))..." -ForegroundColor Cyan
        Read-Host "Ensure you have added your synced folder(s) under Google Drive Preferences -> 'Folders from your computer', then press [Enter] to migrate files..."
        foreach (`$SDir in `$GDriveSetup.SyncDirectories) {
            `$SrcStreamPath = `$SDir.SourceComputerStreamPath
            `$DstLocalPath = `$SDir.LocalPath
            if (`$SrcStreamPath -and (Test-Path `$SrcStreamPath)) {
                Write-Host " - Migrating (`$(`$GDriveSetup.MigrationMode)) '`$(`$SDir.CloudFolder)' from `$SrcStreamPath -> `$DstLocalPath..." -ForegroundColor Yellow
                if (-not (Test-Path `$DstLocalPath)) {
                    New-Item -ItemType Directory -Path `$DstLocalPath -Force | Out-Null
                }
                if (`$GDriveSetup.MigrationMode -eq "move") {
                    Get-ChildItem -LiteralPath `$SrcStreamPath -Force | ForEach-Object {
                        Move-Item -LiteralPath `$_.FullName -Destination `$DstLocalPath -Force -ErrorAction Continue
                    }
                } else {
                    Copy-Item -Path (Join-Path `$SrcStreamPath "*") -Destination `$DstLocalPath -Recurse -Force -ErrorAction Continue
                }
                Write-Host "   Completed migration for '`$(`$SDir.CloudFolder)'." -ForegroundColor Green
            } else {
                Write-Host " - Previous computer folder not found at '`$SrcStreamPath' (skipping automatic copy for '`$(`$SDir.CloudFolder)')." -ForegroundColor DarkGray
            }
        }
    }

    Save-HydrateState "cloud_mount"
} else {
    Write-Host "[V] Step 2: Cloud Storage Mount and Sync Migration (Already completed)" -ForegroundColor DarkGray
}

# --- STEP 3: Game Managers and Multi-Library Discovery / Fresh Installs ---
if (`$State.CompletedSteps -notcontains "steam_signin") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 3: Steam Multi-Library Rediscovery and Fresh Game Installs" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    `$SteamExe = "`${env:ProgramFiles(x86)}\Steam\steam.exe"

    # Discover all Steam libraries across all drives
    `$DiscoveredLibs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    `$Drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
    foreach (`$Drv in `$Drives) {
        if (`$Drv.Root) {
            foreach (`$Sub in @("SteamLibrary", "Steam", "Games\SteamLibrary", "Games\Steam")) {
                `$Cand = Join-Path `$Drv.Root `$Sub
                if ((Test-Path `$Cand) -and (Test-Path (Join-Path `$Cand "steamapps"))) {
                    `$DiscoveredLibs.Add(`$Cand) | Out-Null
                }
            }
        }
    }
    if (`$DiscoveredLibs.Count -gt 0) {
        Write-Host "Discovered `$(`$DiscoveredLibs.Count) Steam library folder(s) across drives:" -ForegroundColor Green
        foreach (`$Lib in `$DiscoveredLibs) {
            Write-Host " - `$Lib" -ForegroundColor Cyan
        }
    }

    if (Test-Path `$SteamExe) {
        Write-Host "Launching Steam for user sign-in and Steam Guard verification..."
        Start-Process `$SteamExe
        Read-Host "Press [Enter] when signed in to Steam to proceed..."
    } else {
        Write-Host "Steam client not found at `$SteamExe; skipping launch." -ForegroundColor DarkGray
    }

    # Inspect games declared in applications catalog or blueprint
    `$CatalogFile = Join-Path `$PayloadDir "applications.json"
    if (Test-Path `$CatalogFile) {
        `$CatApps = @(Get-Content -Raw `$CatalogFile | ConvertFrom-Json)
        `$SteamGames = @(`$CatApps | Where-Object { `$_.install -and (`$_.install.method -eq "steam" -or `$_.install.steam_id) })
        `$UninstalledGames = @()
        foreach (`$Game in `$SteamGames) {
            `$SId = `$Game.install.steam_id
            `$GName = if (`$Game.name) { `$Game.name } else { `$Game.app_id }
            if (`$SId) {
                # Check if game is in ANY discovered library
                `$FoundLib = `$null
                foreach (`$Lib in `$DiscoveredLibs) {
                    `$Mf = Join-Path `$Lib "steamapps\appmanifest_`$SId.acf"
                    if (Test-Path `$Mf) {
                        `$FoundLib = `$Lib
                        break
                    }
                }
                if (`$FoundLib) {
                    Write-Host " [V] Game '`$GName' (`$SId) present in reattached library: `$FoundLib" -ForegroundColor Green
                } else {
                    `$UninstalledGames += [PSCustomObject]@{
                        SId   = `$SId
                        GName = `$GName
                    }
                }
            }
        }

        if (`$UninstalledGames.Count -gt 0) {
            Write-Host ""
            Write-Host "Found `$(`$UninstalledGames.Count) Steam game(s) requiring fresh installation:" -ForegroundColor Cyan
            for (`$i = 0; `$i -lt `$UninstalledGames.Count; `$i++) {
                `$UGame = `$UninstalledGames[`$i]
                Write-Host " [`$(`$i + 1)/`$(`$UninstalledGames.Count)] Triggering Steam install for '`$(`$UGame.GName)' (`$(`$UGame.SId))..." -ForegroundColor Cyan
                try {
                    Start-Process "steam://install/`$(`$UGame.SId)"
                    if (`$i -lt (`$UninstalledGames.Count - 1)) {
                        Read-Host "Press [Enter] after confirming the install prompt in Steam to queue the next game"
                    } else {
                        Read-Host "Press [Enter] after confirming the final install prompt in Steam to continue"
                    }
                } catch {
                    Write-Warning "Could not trigger steam://install/`$(`$UGame.SId)"
                }
            }
        }
    }
    Save-HydrateState "steam_signin"
} else {
    Write-Host "[V] Step 3: Steam Multi-Library and Game Provisioning (Already completed)" -ForegroundColor DarkGray
}

# --- STEP 4: Manual Application Installs Walkthrough ---
if (`$State.CompletedSteps -notcontains "manual_installs") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 4: Manual Application Installation Guidance" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    `$CatalogFile = Join-Path `$PayloadDir "applications.json"
    if (Test-Path `$CatalogFile) {
        `$CatApps = @(Get-Content -Raw `$CatalogFile | ConvertFrom-Json)
        `$ManualApps = @(`$CatApps | Where-Object { `$_.install -and `$_.install.method -eq "manual" })
        if (`$ManualApps.Count -gt 0) {
            foreach (`$MApp in `$ManualApps) {
                Write-Host ""
                Write-Host "  [Application: `$(`$MApp.name)]" -ForegroundColor Green
                if (`$MApp.website) { Write-Host "   Official URL: `$(`$MApp.website)" }
                if (`$MApp.install.download_url) { Write-Host "   Download:     `$(`$MApp.install.download_url)" }
                if (`$MApp.install.default_target_directory) { Write-Host "   Target Dir:   `$(`$MApp.install.default_target_directory)" }
                if (`$MApp.install.instructions) {
                    Write-Host "   Instructions:"
                    foreach (`$Inst in `$MApp.install.instructions) {
                        Write-Host "    - `$Inst"
                    }
                }
                Read-Host "Press [Enter] when you have completed or skipped `$(`$MApp.name)..."
            }
        } else {
            Write-Host "No manual installation applications detected." -ForegroundColor DarkGray
        }
    }
    Save-HydrateState "manual_installs"
} else {
    Write-Host "[V] Step 4: Manual Applications (Already completed)" -ForegroundColor DarkGray
}

# --- STEP 5: User-Level Directory Junctions and Personalization ---
if (`$State.CompletedSteps -notcontains "user_junctions") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 5: Creating User-Level Directory Junctions and Personalization" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    `$JunctionsManifest = Join-Path `$PayloadDir "junctions-manifest.json"
    if (Test-Path `$JunctionsManifest) {
        `$Junctions = Get-Content -Raw `$JunctionsManifest | ConvertFrom-Json
        `$UserJuncs = @(`$Junctions | Where-Object { `$_.Scope -eq "user" })
        Write-Host "Linking `$(`$UserJuncs.Count) user-scope directory junction(s)..."

        foreach (`$Junc in `$UserJuncs) {
            `$Link = `$Junc.Link
            `$Target = `$Junc.Target
            `$IsFile = (`$Junc.ItemType -eq "file")
            Write-Host " - [`$(`$Junc.AppId)] `$Link -> `$Target (type: `$(if (`$IsFile) { 'file' } else { 'directory' }))"

            if (`$IsFile) {
                # Resolve target file path (if Target is a folder, append link's leaf filename)
                `$TargetFile = if (Test-Path -LiteralPath `$Target -PathType Container) {
                    Join-Path `$Target (Split-Path `$Link -Leaf)
                } elseif (`$Target.EndsWith((Split-Path `$Link -Leaf), [System.StringComparison]::OrdinalIgnoreCase)) {
                    `$Target
                } elseif (Test-Path -LiteralPath (Join-Path `$Target (Split-Path `$Link -Leaf))) {
                    Join-Path `$Target (Split-Path `$Link -Leaf)
                } else {
                    Join-Path `$Target (Split-Path `$Link -Leaf)
                }
                `$TargetParent = Split-Path -Parent `$TargetFile
                if (`$TargetParent -and -not (Test-Path -LiteralPath `$TargetParent)) {
                    try {
                        New-Item -ItemType Directory -Path `$TargetParent -Force | Out-Null
                    } catch {}
                }
            } else {
                # Ensure cloud target directory exists
                if (-not (Test-Path `$Target)) {
                    try {
                        New-Item -ItemType Directory -Path `$Target -Force | Out-Null
                        Write-Host "   Created target folder: `$Target" -ForegroundColor DarkGray
                    } catch {
                        Write-Warning "   Could not create target `${Target}: `$(`$_.Exception.Message)"
                    }
                }
            }

            # Handle existing collision
            if (Test-Path `$Link) {
                `$Item = Get-Item `$Link -Force
                if (-not (`$Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    `$BackupPath = "`$Link.bak_`$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                    try {
                        if (`$Item -is [System.IO.DirectoryInfo]) {
                            [System.IO.Directory]::Move(`$Link, `$BackupPath)
                        } else {
                            [System.IO.File]::Move(`$Link, `$BackupPath)
                        }
                        Write-Host "   Collision: Backed up existing file/directory to `$BackupPath." -ForegroundColor Yellow
                    } catch {
                        Write-Warning "   Could not backup existing `${Link}: `$(`$_.Exception.Message)"
                    }
                } else {
                    if ((Get-Item `$Link -Force) -is [System.IO.DirectoryInfo]) {
                        [System.IO.Directory]::Delete(`$Link)
                    } else {
                        [System.IO.File]::Delete(`$Link)
                    }
                }
            }

            # Create Link
            `$ParentDir = Split-Path -Parent `$Link
            if (-not (Test-Path `$ParentDir)) { New-Item -ItemType Directory -Path `$ParentDir -Force | Out-Null }

            if (`$IsFile) {
                # Create file symbolic link
                `$MkOut = & cmd.exe /c "mklink `"`$Link`" `"`$TargetFile`" 2>&1"
                if (`$LASTEXITCODE -ne 0 -or -not (Test-Path `$Link)) {
                    Write-Warning "   Failed to create file symbolic link: `$MkOut"
                } else {
                    Write-Host "   [+] Created file symbolic link: `$Link -> `$TargetFile" -ForegroundColor Green
                }
            } else {
                cmd.exe /c mklink /J "`$Link" "`$Target" | Out-Null
            }
        }
        Write-Host "[SUCCESS] All user directory junctions created successfully!" -ForegroundColor Green
    }

    # Apply user-level Windows Explorer, User Shell Folders, Taskbar, Theme, Input, and Shell Pins
    `$WinSettingsFile = Join-Path `$PayloadDir "windows-settings.json"
    `$WinScriptsDir = Join-Path `$PayloadDir "windows"
    if (Test-Path `$WinSettingsFile) {
        try {
            `$WinCfg = Get-Content -Raw `$WinSettingsFile | ConvertFrom-Json
            `$ExpScript = Join-Path `$WinScriptsDir "explorer-folder-options.ps1"
            if (Test-Path `$ExpScript) {
                & `$ExpScript -ShowHiddenFiles:([bool]`$WinCfg.explorer.show_hidden_files) -ShowFileExtensions:([bool]`$WinCfg.explorer.show_file_extensions) -LaunchTo `$WinCfg.explorer.launch_to -HideRecentFromQuickAccess:([bool]`$WinCfg.explorer.hide_recent_in_quick_access) -ClassicContextMenu:([bool]`$WinCfg.explorer.classic_context_menu) -UserShellFolders `$WinCfg.user_shell_folders
            }
            `$TbScript = Join-Path `$WinScriptsDir "taskbar-system-tray.ps1"
            if (Test-Path `$TbScript) {
                & `$TbScript -TaskbarAlignment `$WinCfg.taskbar.alignment -SearchMode `$WinCfg.taskbar.search_mode -HideWidgets:(-not [bool]`$WinCfg.taskbar.widgets_visible) -HideChat:(-not [bool]`$WinCfg.taskbar.chat_visible) -ShowSecondsInClock:([bool]`$WinCfg.taskbar.show_seconds_in_clock) -EndTaskEnabled:([bool]`$WinCfg.taskbar.end_task_enabled) -PromotedTrayIcons @(`$WinCfg.taskbar.promoted_tray_icons)
            }
            `$ThemeScript = Join-Path `$WinScriptsDir "theme-personalization.ps1"
            if ((Test-Path `$ThemeScript) -and `$WinCfg.theme) {
                & `$ThemeScript -AppsMode `$WinCfg.theme.apps_mode -SystemMode `$WinCfg.theme.system_mode -Transparency:([bool]`$WinCfg.theme.transparency) -AccentColor `$WinCfg.theme.accent_color -AccentOnTaskbar:([bool]`$WinCfg.theme.accent_on_taskbar) -AccentOnTitlebars:([bool]`$WinCfg.theme.accent_on_titlebars) -WallpaperPath `$WinCfg.theme.wallpaper_path -WallpaperStyle ([int]`$WinCfg.theme.wallpaper_style)
            }
            `$InputScript = Join-Path `$WinScriptsDir "input-mouse-keyboard.ps1"
            if ((Test-Path `$InputScript) -and `$WinCfg.input) {
                & `$InputScript -MouseSpeed ([int]`$WinCfg.input.mouse.speed) -EnhancePointerPrecision:([bool]`$WinCfg.input.mouse.enhance_pointer_precision) -SwapMouseButtons:([bool]`$WinCfg.input.mouse.swap_buttons) -WheelScrollLines ([int]`$WinCfg.input.mouse.wheel_scroll_lines) -KeyboardRepeatDelay ([int]`$WinCfg.input.keyboard.repeat_delay) -KeyboardRepeatSpeed ([int]`$WinCfg.input.keyboard.repeat_speed) -NumLockOnStartup:([bool]`$WinCfg.input.keyboard.numlock_on_startup) -InputLanguages @(`$WinCfg.input.keyboard.input_languages)
            }
            `$PwrScript = Join-Path `$WinScriptsDir "performance-power.ps1"
            if ((Test-Path `$PwrScript) -and `$WinCfg.system_ergonomics) {
                `$Plan = (`$WinCfg.power.active_scheme_name -replace '\s+', '')
                `$AcDisp = if (`$null -ne `$WinCfg.power.ac_display_minutes) { [int]`$WinCfg.power.ac_display_minutes } else { 30 }
                & `$PwrScript -PowerPlan `$Plan -AcSleepTimeoutMinutes ([int]`$WinCfg.power.ac_sleep_minutes) -AcDisplayTimeoutMinutes `$AcDisp -ClipboardHistoryEnabled:([bool]`$WinCfg.system_ergonomics.clipboard_history_enabled) -DefaultTerminal `$WinCfg.system_ergonomics.default_terminal
            }
            `$ShellPinsScript = Join-Path `$WinScriptsDir "shell-pins.ps1"
            if (Test-Path `$ShellPinsScript) {
                & `$ShellPinsScript -QuickAccessPins @(`$WinCfg.explorer.quick_access_pins) -TaskbarPinnedApps @(`$WinCfg.taskbar.pinned_apps) -StartMenuPinnedApps @(`$WinCfg.start_menu.pinned_apps) -AppPathEntries @(`$WinCfg.app_path_entries) -SteamLibraries @(`$WinCfg.steam_libraries)
            }
        } catch {
            Write-Warning "Could not apply user personalization and shell pins: `$(`$_.Exception.Message)"
        }
    }

    Save-HydrateState "user_junctions"
} else {
    Write-Host "[V] Step 5: User Junctions and Personalization (Already completed)" -ForegroundColor DarkGray
}

# --- STEP 6: Non-Interactive WSL2 Setup ---
if (`$State.CompletedSteps -notcontains "wsl_setup") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 6: Non-Interactive WSL2 Subsystem Configuration" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    `$WslScript = Join-Path `$PayloadDir "setup-wsl.sh"
    if (Test-Path `$WslScript) {
        Write-Host "Executing non-interactive setup-wsl.sh inside Ubuntu distro..."
        try {
            & wsl.exe -d Ubuntu -u root -- /bin/bash /mnt/c/Reglaze/payload/setup-wsl.sh
            Write-Host "[SUCCESS] WSL2 environment provisioned!" -ForegroundColor Green
        } catch {
            Write-Warning "WSL setup encountered an error: `$(`$_.Exception.Message)"
        }
    } else {
        Write-Host "No setup-wsl.sh script found; skipping WSL2 customization." -ForegroundColor DarkGray
    }
    Save-HydrateState "wsl_setup"
} else {
    Write-Host "[V] Step 6: WSL2 Environment (Already completed)" -ForegroundColor DarkGray
}

# --- STEP 7: Developer Repositories and Dotfiles ---
if (`$State.CompletedSteps -notcontains "dev_repos") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 7: Developer Repositories and Dotfiles Configuration" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "Verifying chezmoi and git developer repositories..."
    if (Get-Command "chezmoi" -ErrorAction SilentlyContinue) {
        Write-Host "Chezmoi detected. Ready for dotfiles init/apply."
    } else {
        Write-Host "Chezmoi not found in PATH; developer can run 'chezmoi init' when ready." -ForegroundColor DarkGray
    }
    Save-HydrateState "dev_repos"
} else {
    Write-Host "[V] Step 7: Dev Repositories (Already completed)" -ForegroundColor DarkGray
}

# --- STEP 8: Cleanup and Unregister ---
Write-Host ""
Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Green
Write-Host "  FINALIZING HYDRATION" -ForegroundColor Green
Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Green

# Unregister from RunOnce so it does not launch on next reboot
Remove-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "ReglazeHydrate" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "ReglazeHydrate" -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "================================================================================" -ForegroundColor Green
Write-Host "    REGLAZE HYDRATION COMPLETE! YOUR WORKSTATION IS FULLY PROVISIONED.          " -ForegroundColor Green
Write-Host "================================================================================" -ForegroundColor Green
Write-Host "Note: You can re-run this wizard anytime via the 'Reglaze Hydration' desktop shortcut."
Write-Host ""
try { Stop-Transcript | Out-Null } catch {}
"@

    $HydratePath = Join-Path $PayloadDir "hydrate.ps1"
    $HydrateScript | Set-Content -Path $HydratePath -Encoding UTF8

    $PrimaryUser = if ($Blueprint.system -and $Blueprint.system.users -and $Blueprint.system.users.primary_user -and $Blueprint.system.users.primary_user.username) {
        $Blueprint.system.users.primary_user.username
    } else {
        "User"
    }
    $WslDefaultUser = if ($Blueprint.wsl2 -and $Blueprint.wsl2.default_user -and $Blueprint.wsl2.default_user -ne "developer") {
        $Blueprint.wsl2.default_user
    } else {
        $PrimaryUser.ToLower()
    }
    $WslPackages = @()
    if ($Blueprint.wsl2 -and $Blueprint.wsl2.packages) {
        $WslPackages = @($Blueprint.wsl2.packages)
    }
    if ($WslPackages.Count -eq 0) {
        $WslPackages = @("build-essential", "git", "curl", "zsh", "rclone", "unzip")
    }
    $WslPackagesStr = $WslPackages -join " "

    $WslScript = @"
#!/usr/bin/env bash
# Non-interactive WSL2 root setup script for Reglaze
set -e

WSL_USER="$WslDefaultUser"
PACKAGES="$WslPackagesStr"

echo "=== Reglaze WSL2 Non-Interactive Provisioner ==="
echo "Configuring primary user: `$WSL_USER"

# 1. Create default user if not already present
if ! id -u "`$WSL_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "`$WSL_USER"
    echo "`$WSL_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/99-`$WSL_USER"
    chmod 0440 "/etc/sudoers.d/99-`$WSL_USER"
    echo "Created user `$WSL_USER with passwordless sudo."
fi

# 2. Configure /etc/wsl.conf to boot into default user
cat << 'EOF' > /etc/wsl.conf
[user]
default = $WslDefaultUser

[boot]
systemd = true

[interop]
enabled = true
appendWindowsPath = true
EOF

# 3. Update repositories and install declared packages
echo "Installing WSL2 packages: `$PACKAGES"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends `$PACKAGES || true

echo "=== WSL2 Provisioning Completed Successfully ==="
"@

    $WslPath = Join-Path $PayloadDir "setup-wsl.sh"
    # Ensure UNIX-style LF line endings
    $WslScript = $WslScript.Replace("`r`n", "`n")
    [System.IO.File]::WriteAllText($WslPath, $WslScript, [System.Text.UTF8Encoding]::new($false))

    # =========================================================================
    # 7. Export Filtered Applications Catalog for Blueprint (applications.json)
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
    } else {
        foreach ($CatItem in $Catalog) {
            $PayloadCatalog.Add($CatItem)
        }
    }
    $CatalogJson = if ($PayloadCatalog.Count -eq 0) { "[]" } else { ConvertTo-Json -InputObject @($PayloadCatalog.ToArray()) -Depth 6 }
    $CatalogJson | Set-Content -Path $CatalogJsonPath -Encoding UTF8

    return [PSCustomObject]@{
        PayloadDir           = $PayloadDir
        DscPath              = $DscPath
        DiskConfigPath       = $DiskConfigPath
        GoogleDriveSetupPath = $GoogleDriveSetupPath
        BitLockerPath        = $BitLockerPath
        JunctionsPath        = $JunctionsPath
        BootstrapPath        = $BootstrapPath
        HydratePath          = $HydratePath
        WslScriptPath        = $WslPath
        CatalogPath          = $CatalogJsonPath
        WindowsSettingsPath  = $WinSettingsPath
        JunctionCount        = $JunctionsList.Count
        BitLockerKeyCount    = $BitLockerEntries.Count
    }
}
