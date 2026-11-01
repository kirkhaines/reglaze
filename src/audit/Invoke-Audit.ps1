<#
.SYNOPSIS
    Master pre-flight audit orchestrator for Reglaze.
.DESCRIPTION
    Runs non-destructive hardware, licensing, BitLocker, installed applications (WinGet + ARP + Steam),
    Windows desktop/shell/input/audio/display settings, networking/firewall configuration, and
    directory junction audits. Emits 'audit-reference.json' and scaffolds a personalized
    'reglaze.yaml' in the resolved output directory (or $env:REGLAZE_DIR).
#>
[CmdletBinding()]
param(
    [Alias("Config", "c")]
    [string]$ConfigDir = $null,
    [Alias("p")]
    [string]$Profile = $null,
    [switch]$Force = $false,
    [switch]$SkipElevation = $false,
    [switch]$Elevate = $false
)

$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
if (-not (Test-Path (Join-Path $RepoRoot "data\applications"))) {
    $RepoRoot = (Get-Location).Path
}

# Import helpers
. (Join-Path $RepoRoot "src\common\Logging.ps1")
. (Join-Path $RepoRoot "src\common\ConfigResolver.ps1")
. (Join-Path $RepoRoot "src\common\Catalog.ps1")
. (Join-Path $RepoRoot "src\audit\Audit-Hardware.ps1")
. (Join-Path $RepoRoot "src\audit\Audit-Licensing.ps1")
. (Join-Path $RepoRoot "src\audit\Audit-BitLocker.ps1")
. (Join-Path $RepoRoot "src\audit\Audit-Apps.ps1")
. (Join-Path $RepoRoot "src\audit\Audit-Junctions.ps1")
. (Join-Path $RepoRoot "src\audit\Audit-StorageProviders.ps1")
. (Join-Path $RepoRoot "src\audit\Audit-Wsl.ps1")
. (Join-Path $RepoRoot "src\audit\Audit-Network.ps1")

Write-ReglazeBanner "PRE-FLIGHT SYSTEM AUDIT"

# 1. Resolve Target Output Directory & Profile Association
$TargetDir = Resolve-ReglazeTargetDirectory -ExplicitDirectory $ConfigDir
if (-not (Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
}
Write-ReglazeInfo "Audit artifacts will be saved to: $TargetDir"

$BlueprintPath = Join-Path $TargetDir "reglaze.yaml"
$ExistingBlueprintContent = $null
$ExistingProfile = $null
if (Test-Path $BlueprintPath) {
    $ExistingBlueprintContent = Get-Content -Raw -Path $BlueprintPath -ErrorAction SilentlyContinue
    if ($ExistingBlueprintContent -and $ExistingBlueprintContent -match '(?m)^\s*profile:\s*["'']?([^"''\r\n#]+)["'']?') {
        $ExistingProfile = $Matches[1].Trim()
    }
}

$ResolvedProfile = $null
if (-not [string]::IsNullOrWhiteSpace($Profile)) {
    $ResolvedProfile = $Profile.Trim()
} elseif (-not [string]::IsNullOrWhiteSpace($ExistingProfile)) {
    $ResolvedProfile = $ExistingProfile
    Write-ReglazeInfo "Inherited profile '$ResolvedProfile' from existing reglaze.yaml."
} elseif (-not [string]::IsNullOrWhiteSpace($env:REGLAZE_PROFILE)) {
    $ResolvedProfile = $env:REGLAZE_PROFILE.Trim()
    Write-ReglazeInfo "Using profile '$ResolvedProfile' from `$env:REGLAZE_PROFILE."
} else {
    Write-ReglazeError "Missing required -Profile parameter. When no existing reglaze.yaml is present in '$TargetDir', you must specify -Profile <name> (e.g. -Profile 'workstation')."
    throw "Missing required -Profile parameter for initial audit in '$TargetDir'."
}
Write-ReglazeInfo "Active Reglaze Profile: $ResolvedProfile"

# 2. Execute Hardware & Storage Audit
Write-ReglazeStep "Auditing Hardware & Storage Topology..."
$HardwareData = Get-HardwareAudit
Write-ReglazeSuccess "Discovered $($HardwareData.storage_topology.disks.Count) physical disk(s)."

# 3. Execute Licensing & OS Audit
Write-ReglazeStep "Auditing Windows Operating System & Licensing..."
$LicensingData = Get-LicensingAudit
Write-ReglazeSuccess "$($LicensingData.os_edition) (Build $($LicensingData.os_build)) - $($LicensingData.license_channel) Channel"

# 4. Execute BitLocker Audit (Elevates via UAC if needed and confirmed)
Write-ReglazeStep "Auditing BitLocker Volumes & Recovery Protectors..."
$BitLockerData = Get-BitLockerAudit -RepoRoot $RepoRoot -SkipElevation:$SkipElevation -Elevate:$Elevate
if ($BitLockerData.Count -gt 0) {
    Write-ReglazeSuccess "Captured $($BitLockerData.Count) BitLocker volume status(es)."
} else {
    $IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $IsAdmin) {
        Write-ReglazeWarning "BitLocker keys require Administrator elevation to extract. If any drive uses BitLocker, rerun audit in an elevated PowerShell session to back up recovery keys."
    } else {
        Write-ReglazeInfo "No BitLocker encrypted volumes detected."
    }
}

# 5. Execute Comprehensive Application Discovery (WinGet + Add/Remove Programs + Steam)
Write-ReglazeStep "Auditing Applications (WinGet Packages, Steam Libraries & Add/Remove Programs)..."
$UserCatalogFile = Join-Path $TargetDir "applications.json"
if (Test-Path -LiteralPath $UserCatalogFile) {
    Write-ReglazeInfo "Loaded custom user application catalog: $UserCatalogFile"
}
$AppsData = Get-InstalledApplicationsAudit -RepoRoot $RepoRoot -UserConfigDir $TargetDir
Write-ReglazeSuccess "Found $($AppsData.installed_winget_packages.Count) WinGet packages and $($AppsData.detected_non_winget_applications.Count) non-WinGet applications."

# 6. Execute Directory Junctions Discovery
Write-ReglazeStep "Auditing Existing NTFS Directory Junctions & Reparse Points..."
$JunctionsData = Get-JunctionsAudit -RepoRoot $RepoRoot -UserConfigDir $TargetDir
Write-ReglazeSuccess "Detected $($JunctionsData.Count) directory junction(s)."

# 7. Execute Windows Settings Discovery
Write-ReglazeStep "Auditing Windows Preferences, Shell Pins, Theme, Input, Audio & Display Settings..."
$WindowsSettings = $null
$WinSettingsScript = Join-Path $RepoRoot "data\windows\audit-windows-settings.ps1"
if (Test-Path $WinSettingsScript) {
    try {
        $WindowsSettings = & $WinSettingsScript
        Write-ReglazeSuccess "Captured Explorer, Taskbar, Theme, Clock, Input, Power, Audio/Camera, and Display preferences."
        if ($WindowsSettings.system_ergonomics -and $WindowsSettings.system_ergonomics.ssh_keys_unmapped_warning) {
            Write-ReglazeWarning "Detected '%USERPROFILE%\.ssh' on C: without a directory junction. Consider mapping or backing up your SSH keys before re-imaging!"
        }
    } catch {
        Write-ReglazeWarning "Could not execute Windows settings audit: $($_.Exception.Message)"
    }
}

# 8. Execute Storage Providers & User Identity Discovery
Write-ReglazeStep "Auditing Cloud Storage Providers & User Identity..."
$PhysicalDiskMountLetters = @(
    $HardwareData.storage_topology.disks |
        ForEach-Object { $_.partitions } |
        Where-Object { $_ -and $_.mount_point } |
        ForEach-Object { $_.mount_point }
)
$StorageProvidersData = Get-StorageProvidersAudit -AdditionalOccupiedLetters $PhysicalDiskMountLetters
$UserIdentityData = Get-UserIdentityAudit
Write-ReglazeSuccess "User Identity: $($UserIdentityData.email) ($($UserIdentityData.account_type))"
Write-ReglazeSuccess "Cloud Streaming: $($StorageProvidersData.streaming.mount_point) ($($StorageProvidersData.streaming.cloud_provider), detected=$($StorageProvidersData.streaming.detected)), Synced roots: $($StorageProvidersData.sync_directories.Count)."

# 9. Execute Network & Firewall Discovery
Write-ReglazeStep "Auditing Network Adapters, Sharing Preferences & Custom Firewall Rules..."
$NetworkData = Get-NetworkAudit
Write-ReglazeSuccess "Discovered $($NetworkData.adapters.Count) network adapter(s) and $($NetworkData.firewall_rules.Count) custom firewall rule(s)."

# 10. Execute WSL Environment Discovery
Write-ReglazeStep "Auditing WSL Distributions & Packages..."
$WslData = Get-WslAudit
Write-ReglazeSuccess "WSL Enabled: $($WslData.enabled), Default Distro: $($WslData.default_distro), Packages: $($WslData.detected_packages.Count)."

# 11. Assemble Profile-to-Computer Association and Emit audit-reference.json
Write-ReglazeStep "Compiling Audit Reference Document & Profile Registry..."
$ComputerName = $env:COMPUTERNAME
$AuditTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# Update persistent profile-computers.json registry in TargetDir
$ProfileRegistryPath = Join-Path $TargetDir "profile-computers.json"
$ProfileRegistry = @{
    profiles = @{}
}
if (Test-Path $ProfileRegistryPath) {
    try {
        $LoadedReg = Get-Content -Raw -Path $ProfileRegistryPath -ErrorAction Stop | ConvertFrom-Json
        if ($LoadedReg -and $LoadedReg.profiles) {
            foreach ($Prop in $LoadedReg.profiles.PSObject.Properties) {
                $ExistingComputers = @()
                if ($Prop.Value.computers) {
                    $ExistingComputers = @($Prop.Value.computers)
                }
                $ProfileRegistry.profiles[$Prop.Name] = @{
                    latest_computer_name   = $Prop.Value.latest_computer_name
                    previous_computer_name = $Prop.Value.previous_computer_name
                    latest_audit_timestamp = $Prop.Value.latest_audit_timestamp
                    computers              = $ExistingComputers
                }
            }
        }
    } catch {
        Write-ReglazeWarning "Could not parse existing profile-computers.json; reinitializing registry."
    }
}

$SyncDirEntries = @()
foreach ($SyncDir in $StorageProvidersData.sync_directories) {
    $SyncDirEntries += [PSCustomObject]@{
        id           = $SyncDir.id
        cloud_folder = $SyncDir.cloud_folder
        local_path   = $SyncDir.local_path
        cloud_doc_id = $SyncDir.cloud_doc_id
    }
}

$ExistingProfileEntry = $ProfileRegistry.profiles[$ResolvedProfile]
$PreviousComputerName = $null
$ComputerHistory = @()
if ($ExistingProfileEntry) {
    if ($ExistingProfileEntry.latest_computer_name -and $ExistingProfileEntry.latest_computer_name -ne $ComputerName) {
        $PreviousComputerName = $ExistingProfileEntry.latest_computer_name
    } elseif ($ExistingProfileEntry.previous_computer_name) {
        $PreviousComputerName = $ExistingProfileEntry.previous_computer_name
    }
    foreach ($CompEntry in $ExistingProfileEntry.computers) {
        if ($CompEntry.computer_name -ne $ComputerName) {
            $ComputerHistory += $CompEntry
        }
    }
}

$CurrentComputerRecord = [PSCustomObject]@{
    computer_name    = $ComputerName
    audited_at       = $AuditTimestamp
    sync_directories = $SyncDirEntries
}
$ComputerHistory = @($CurrentComputerRecord) + $ComputerHistory

$ProfileAssociation = [PSCustomObject]@{
    profile                = $ResolvedProfile
    latest_computer_name   = $ComputerName
    previous_computer_name = $PreviousComputerName
    latest_audit_timestamp = $AuditTimestamp
    computers              = $ComputerHistory
}

$ProfileRegistry.profiles[$ResolvedProfile] = $ProfileAssociation
$ProfileRegistry | ConvertTo-Json -Depth 8 | Set-Content -Path $ProfileRegistryPath -Encoding UTF8
Write-ReglazeSuccess "Updated profile-to-computer association registry: $ProfileRegistryPath"

$AuditMetadata = [PSCustomObject]@{
    timestamp       = $AuditTimestamp
    reglaze_version = "1.0.0"
    profile         = $ResolvedProfile
    host_name       = $ComputerName
    os_version      = $LicensingData.os_version
}

$AuditReference = [PSCustomObject]@{
    audit_metadata                   = $AuditMetadata
    profile_association              = $ProfileAssociation
    system_and_licensing             = $LicensingData
    user_identity                    = $UserIdentityData
    storage_providers                = $StorageProvidersData
    detected_wsl                     = $WslData
    detected_network                 = $NetworkData
    bitlocker_recovery_keys          = $BitLockerData
    storage_topology                 = $HardwareData.storage_topology
    detected_junctions               = $JunctionsData
    installed_winget_packages        = $AppsData.installed_winget_packages
    detected_non_winget_applications = $AppsData.detected_non_winget_applications
    detected_windows_settings        = $WindowsSettings
    detected_game_libraries          = $AppsData.detected_game_libraries
}

$AuditJsonPath = Join-Path $TargetDir "audit-reference.json"
$AuditReference | ConvertTo-Json -Depth 6 | Set-Content -Path $AuditJsonPath -Encoding UTF8
Write-ReglazeSuccess "Wrote audit profile: $AuditJsonPath"

# 12. Archive Existing reglaze.yaml (if present) and Scaffold Fresh Blueprint
if (Test-Path $BlueprintPath) {
    $ExistingContent = if ($ExistingBlueprintContent) { $ExistingBlueprintContent } else { Get-Content -Raw -Path $BlueprintPath -ErrorAction SilentlyContinue }
    $GenDateStr = $null
    if ($ExistingContent -and $ExistingContent -match '(?m)^\s*(?:generation_date|generated_at):\s*["'']?([^"''\r\n]+)["'']?') {
        $RawVal = $Matches[1].Trim()
        $ParsedDate = [DateTime]::MinValue
        if ([DateTime]::TryParse($RawVal, [ref]$ParsedDate)) {
            if ($RawVal -match '\d{1,2}:\d{2}' -or $ParsedDate.TimeOfDay.TotalSeconds -gt 0) {
                $GenDateStr = $ParsedDate.ToString("yyyy-MM-ddTHH-mm-ss")
            } else {
                $GenTime = (Get-Item $BlueprintPath).LastWriteTime.ToString("HH-mm-ss")
                $GenDateStr = "$($ParsedDate.ToString('yyyy-MM-dd'))T$GenTime"
            }
        } else {
            $GenDateStr = ($RawVal -replace '[:\\/*?"<>| ]', '-')
        }
    }
    if (-not $GenDateStr) {
        $GenDateStr = (Get-Item $BlueprintPath).LastWriteTime.ToString("yyyy-MM-ddTHH-mm-ss")
    }

    $ArchiveName = "reglaze.$GenDateStr.yaml"
    $ArchivePath = Join-Path $TargetDir $ArchiveName
    if (Test-Path $ArchivePath) {
        $Idx = 1
        while (Test-Path (Join-Path $TargetDir "reglaze.$GenDateStr.$Idx.yaml")) {
            $Idx++
        }
        $ArchiveName = "reglaze.$GenDateStr.$Idx.yaml"
        $ArchivePath = Join-Path $TargetDir $ArchiveName
    }

    Rename-Item -Path $BlueprintPath -NewName $ArchiveName -Force
    Write-ReglazeInfo "Archived existing blueprint to $ArchiveName"
}

Write-ReglazeStep "Scaffolding Personalized reglaze.yaml Blueprint..."

# Identify Target OS Disk (disk hosting C:)
$AllDisks = $HardwareData.storage_topology.disks
$OsDisk = $AllDisks | Where-Object { 
    $_.partitions | Where-Object { $_.mount_point -eq "C:" }
} | Select-Object -First 1

if (-not $OsDisk -and $AllDisks.Count -gt 0) {
    $OsDisk = $AllDisks[0]
}

$PreservedDisks = @($AllDisks | Where-Object { $_.disk_number -ne $OsDisk.disk_number })

# Resolve conflict-free streaming drive letter against C: and all preserved disks
$OccupiedDiskMounts = @("C:") + @(
    $PreservedDisks |
        ForEach-Object { $_.partitions } |
        Where-Object { $_ -and $_.mount_point } |
        ForEach-Object { $_.mount_point }
)
$PreferredStreamLetter = if ($StorageProvidersData.streaming.detected -and $StorageProvidersData.streaming.mount_point) {
    $StorageProvidersData.streaming.mount_point
} else {
    "G:"
}
$StreamMount = Resolve-ConflictFreeStreamingMountLetter -OccupiedLetters $OccupiedDiskMounts -PreferredLetter $PreferredStreamLetter
$StreamVerify = "$StreamMount\My Drive"
$StreamVerifyYaml = $StreamVerify -replace '\\', '\\'

$EscapeYamlStr = {
    param([string]$Val)
    if ([string]::IsNullOrEmpty($Val)) { return "" }
    $Clean = ($Val -replace "[\r\n\0]", "").Trim()
    return ($Clean -replace '\\', '\\' -replace '"', '\"')
}

$TokenizePath = {
    param([string]$RawPath)
    if ([string]::IsNullOrWhiteSpace($RawPath)) { return "" }
    $P = $RawPath.Trim()
    if ($env:USERPROFILE -and $P.StartsWith($env:USERPROFILE, [System.StringComparison]::OrdinalIgnoreCase)) {
        $P = "%USER_DIR%" + $P.Substring($env:USERPROFILE.Length)
    } elseif ($StreamMount -and $P.StartsWith("$StreamMount\", [System.StringComparison]::OrdinalIgnoreCase)) {
        $P = "%STREAM%" + $P.Substring($StreamMount.Length)
    } elseif ($P -match '^[dD]:\\') {
        $P = "%DATA_DRIVE%" + $P.Substring(2)
    } elseif ($P -match '^[cC]:\\') {
        $P = "%OS_DRIVE%" + $P.Substring(2)
    }
    return (& $EscapeYamlStr $P)
}

# Build Scaffolded Blueprint Content
$CurrentDateStr = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
$YamlLines = [System.Collections.Generic.List[string]]::new()
@(
    'version: "1.0"',
    "profile: `"$ResolvedProfile`"",
    "generation_date: `"$CurrentDateStr`"",
    '',
    'system:',
    "  computer_name: `"$ComputerName`"",
    "  os_edition: `"$($LicensingData.os_edition)`"",
    "  timezone: `"$([System.TimeZoneInfo]::Local.Id)`"",
    '  licensing:',
    "    channel: `"$($LicensingData.license_channel)`"",
    '    backup_key_reference: "audit-reference.json"',
    '  users:',
    '    local_admin:',
    '      username: "LocalAdmin"',
    '      password_env: "LOCAL_ADMIN_PASSWORD"',
    '      auto_logon: true',
    '    primary_user:',
    "      account_type: `"$($UserIdentityData.account_type)`"",
    "      email: `"$($UserIdentityData.email)`"",
    "      username: `"$($UserIdentityData.username)`"",
    '      is_admin: false',
    '      auto_logon: false',
    '  features:',
    '    developer_mode: true',
    '    virtual_machine_platform: true',
    '    subsystem_for_linux: true',
    '  updates:',
    '    drivers: true',
    '    windows_updates: true',
    '',
    'windows_settings:',
    '  explorer:',
    "    show_hidden_files: $(if ($WindowsSettings.explorer.show_hidden_files) { 'true' } else { 'false' })",
    "    show_file_extensions: $(if ($WindowsSettings.explorer.show_file_extensions) { 'true' } else { 'false' })",
    "    launch_to: `"$($WindowsSettings.explorer.launch_to)`"",
    "    hide_recent_in_quick_access: $(if ($WindowsSettings.explorer.hide_recent_in_quick_access) { 'true' } else { 'false' })",
    "    classic_context_menu: $(if ($WindowsSettings.explorer.classic_context_menu) { 'true' } else { 'false' })"
) | ForEach-Object { $YamlLines.Add($_) }

if ($WindowsSettings.explorer.quick_access_pins -and $WindowsSettings.explorer.quick_access_pins.Count -gt 0) {
    $YamlLines.Add('    quick_access_pins:')
    foreach ($QaPin in $WindowsSettings.explorer.quick_access_pins) {
        $YamlLines.Add("      - `"$(& $TokenizePath $QaPin)`"")
    }
} else {
    $YamlLines.Add('    quick_access_pins: []')
}

@(
    '  taskbar:',
    "    alignment: `"$($WindowsSettings.taskbar.alignment)`"",
    "    search_mode: `"$($WindowsSettings.taskbar.search_mode)`"",
    "    widgets_visible: $(if ($WindowsSettings.taskbar.widgets_visible) { 'true' } else { 'false' })",
    "    chat_visible: $(if ($WindowsSettings.taskbar.chat_visible) { 'true' } else { 'false' })",
    "    show_seconds_in_clock: $(if ($WindowsSettings.taskbar.show_seconds_in_clock) { 'true' } else { 'false' })",
    "    end_task_enabled: $(if ($WindowsSettings.taskbar.end_task_enabled) { 'true' } else { 'false' })"
) | ForEach-Object { $YamlLines.Add($_) }

if ($WindowsSettings.taskbar.pinned_apps -and $WindowsSettings.taskbar.pinned_apps.Count -gt 0) {
    $YamlLines.Add('    pinned_apps:')
    foreach ($TbPin in $WindowsSettings.taskbar.pinned_apps) {
        $YamlLines.Add("      - `"$(& $TokenizePath $TbPin)`"")
    }
} else {
    $YamlLines.Add('    pinned_apps: []')
}

if ($WindowsSettings.taskbar.promoted_tray_icons -and $WindowsSettings.taskbar.promoted_tray_icons.Count -gt 0) {
    $YamlLines.Add('    promoted_tray_icons:')
    foreach ($TrayIcon in $WindowsSettings.taskbar.promoted_tray_icons) {
        $YamlLines.Add("      - `"$(& $EscapeYamlStr $TrayIcon)`"")
    }
} else {
    $YamlLines.Add('    promoted_tray_icons: []')
}

$YamlLines.Add('  start_menu:')
if ($WindowsSettings.start_menu -and $WindowsSettings.start_menu.pinned_apps -and $WindowsSettings.start_menu.pinned_apps.Count -gt 0) {
    $YamlLines.Add('    pinned_apps:')
    foreach ($SmPin in $WindowsSettings.start_menu.pinned_apps) {
        $YamlLines.Add("      - `"$(& $TokenizePath $SmPin)`"")
    }
} else {
    $YamlLines.Add('    pinned_apps: []')
}

$WallpaperTokenized = if ($WindowsSettings.theme -and $WindowsSettings.theme.wallpaper_path) {
    "`"$(& $TokenizePath $WindowsSettings.theme.wallpaper_path)`""
} else {
    "null"
}
$AccentStr = if ($WindowsSettings.theme -and $WindowsSettings.theme.accent_color) {
    "`"$($WindowsSettings.theme.accent_color)`""
} else {
    "null"
}

@(
    '  theme:',
    "    apps_mode: `"$(if ($WindowsSettings.theme) { $WindowsSettings.theme.apps_mode } else { 'Dark' })`"",
    "    system_mode: `"$(if ($WindowsSettings.theme) { $WindowsSettings.theme.system_mode } else { 'Dark' })`"",
    "    transparency: $(if ($WindowsSettings.theme -and $WindowsSettings.theme.transparency) { 'true' } else { 'false' })",
    "    accent_color: $AccentStr",
    "    accent_on_taskbar: $(if ($WindowsSettings.theme -and $WindowsSettings.theme.accent_on_taskbar) { 'true' } else { 'false' })",
    "    accent_on_titlebars: $(if ($WindowsSettings.theme -and $WindowsSettings.theme.accent_on_titlebars) { 'true' } else { 'false' })",
    "    wallpaper_path: $WallpaperTokenized",
    "    wallpaper_style: $(if ($WindowsSettings.theme -and $null -ne $WindowsSettings.theme.wallpaper_style) { $WindowsSettings.theme.wallpaper_style } else { 10 })",
    '  clock_and_region:',
    "    short_time_format: `"$(if ($WindowsSettings.clock_and_region) { & $EscapeYamlStr $WindowsSettings.clock_and_region.short_time_format } else { 'h:mm tt' })`"",
    "    long_time_format: `"$(if ($WindowsSettings.clock_and_region) { & $EscapeYamlStr $WindowsSettings.clock_and_region.long_time_format } else { 'h:mm:ss tt' })`"",
    "    short_date_format: `"$(if ($WindowsSettings.clock_and_region) { & $EscapeYamlStr $WindowsSettings.clock_and_region.short_date_format } else { 'M/d/yyyy' })`"",
    "    use_24_hour_clock: $(if ($WindowsSettings.clock_and_region -and $WindowsSettings.clock_and_region.use_24_hour_clock) { 'true' } else { 'false' })",
    '  input:',
    '    mouse:',
    "      speed: $(if ($WindowsSettings.input -and $WindowsSettings.input.mouse) { $WindowsSettings.input.mouse.speed } else { 10 })",
    "      enhance_pointer_precision: $(if ($WindowsSettings.input -and $WindowsSettings.input.mouse -and $WindowsSettings.input.mouse.enhance_pointer_precision) { 'true' } else { 'false' })",
    "      swap_buttons: $(if ($WindowsSettings.input -and $WindowsSettings.input.mouse -and $WindowsSettings.input.mouse.swap_buttons) { 'true' } else { 'false' })",
    "      wheel_scroll_lines: $(if ($WindowsSettings.input -and $WindowsSettings.input.mouse) { $WindowsSettings.input.mouse.wheel_scroll_lines } else { 3 })",
    '    keyboard:',
    "      repeat_delay: $(if ($WindowsSettings.input -and $WindowsSettings.input.keyboard) { $WindowsSettings.input.keyboard.repeat_delay } else { 1 })",
    "      repeat_speed: $(if ($WindowsSettings.input -and $WindowsSettings.input.keyboard) { $WindowsSettings.input.keyboard.repeat_speed } else { 31 })",
    "      numlock_on_startup: $(if ($WindowsSettings.input -and $WindowsSettings.input.keyboard -and $WindowsSettings.input.keyboard.numlock_on_startup) { 'true' } else { 'false' })"
) | ForEach-Object { $YamlLines.Add($_) }

$LangList = if ($WindowsSettings.input -and $WindowsSettings.input.keyboard -and $WindowsSettings.input.keyboard.input_languages) {
    @($WindowsSettings.input.keyboard.input_languages)
} else {
    @("en-US")
}
$YamlLines.Add('      input_languages:')
foreach ($Lang in $LangList) {
    $YamlLines.Add("        - `"$(& $EscapeYamlStr $Lang)`"")
}

$SpkYaml = if ($WindowsSettings.audio_and_devices -and $WindowsSettings.audio_and_devices.default_speakers) {
    "`"$(& $EscapeYamlStr $WindowsSettings.audio_and_devices.default_speakers)`""
} else { "null" }
$MicYaml = if ($WindowsSettings.audio_and_devices -and $WindowsSettings.audio_and_devices.default_microphone) {
    "`"$(& $EscapeYamlStr $WindowsSettings.audio_and_devices.default_microphone)`""
} else { "null" }
$CamYaml = if ($WindowsSettings.audio_and_devices -and $WindowsSettings.audio_and_devices.default_camera) {
    "`"$(& $EscapeYamlStr $WindowsSettings.audio_and_devices.default_camera)`""
} else { "null" }

@(
    '  power:',
    "    active_scheme_name: `"$($WindowsSettings.power.active_scheme_name)`"",
    "    ac_sleep_minutes: $($WindowsSettings.power.ac_sleep_minutes)",
    "    ac_display_minutes: $(if ($null -ne $WindowsSettings.power.ac_display_minutes) { $WindowsSettings.power.ac_display_minutes } else { 15 })",
    '  audio_and_devices:',
    "    default_speakers: $SpkYaml",
    "    default_microphone: $MicYaml",
    "    default_camera: $CamYaml",
    "    master_volume_percent: $(if ($WindowsSettings.audio_and_devices) { $WindowsSettings.audio_and_devices.master_volume_percent } else { 50 })",
    "    master_muted: $(if ($WindowsSettings.audio_and_devices -and $WindowsSettings.audio_and_devices.master_muted) { 'true' } else { 'false' })"
) | ForEach-Object { $YamlLines.Add($_) }

if ($WindowsSettings.audio_and_devices -and $WindowsSettings.audio_and_devices.disabled_cameras -and $WindowsSettings.audio_and_devices.disabled_cameras.Count -gt 0) {
    $YamlLines.Add('    disabled_cameras:')
    foreach ($DisCam in $WindowsSettings.audio_and_devices.disabled_cameras) {
        $YamlLines.Add("      - `"$(& $EscapeYamlStr $DisCam)`"")
    }
} else {
    $YamlLines.Add('    disabled_cameras: []')
}

@(
    '  display:',
    "    game_mode_enabled: $(if ($WindowsSettings.display -and $WindowsSettings.display.game_mode_enabled) { 'true' } else { 'false' })",
    "    hardware_gpu_scheduling: $(if ($WindowsSettings.display -and $WindowsSettings.display.hardware_gpu_scheduling) { 'true' } else { 'false' })"
) | ForEach-Object { $YamlLines.Add($_) }

if ($WindowsSettings.display -and $WindowsSettings.display.monitors -and $WindowsSettings.display.monitors.Count -gt 0) {
    $YamlLines.Add('    monitors:')
    foreach ($Mon in $WindowsSettings.display.monitors) {
        $YamlLines.Add("      - hardware_id: `"$(& $EscapeYamlStr $Mon.hardware_id)`"")
        $YamlLines.Add("        device_name: `"$(& $EscapeYamlStr $Mon.device_name)`"")
        $YamlLines.Add("        width: $($Mon.width)")
        $YamlLines.Add("        height: $($Mon.height)")
        $YamlLines.Add("        refresh_rate_hz: $($Mon.refresh_rate_hz)")
        $YamlLines.Add("        position_x: $($Mon.position_x)")
        $YamlLines.Add("        position_y: $($Mon.position_y)")
        $YamlLines.Add("        is_primary: $(if ($Mon.is_primary) { 'true' } else { 'false' })")
    }
} else {
    $YamlLines.Add('    monitors: []')
}

$DefBrowserStr = if ($WindowsSettings.system_ergonomics -and $WindowsSettings.system_ergonomics.default_browser_prog_id) {
    "`"$(& $EscapeYamlStr $WindowsSettings.system_ergonomics.default_browser_prog_id)`""
} else { "null" }

@(
    '  system_ergonomics:',
    "    clipboard_history_enabled: $(if ($WindowsSettings.system_ergonomics -and $WindowsSettings.system_ergonomics.clipboard_history_enabled) { 'true' } else { 'false' })",
    "    long_paths_enabled: $(if ($WindowsSettings.system_ergonomics -and $WindowsSettings.system_ergonomics.long_paths_enabled) { 'true' } else { 'false' })",
    "    ssh_agent_startup: `"$(if ($WindowsSettings.system_ergonomics -and $WindowsSettings.system_ergonomics.ssh_agent_startup) { $WindowsSettings.system_ergonomics.ssh_agent_startup } else { 'Disabled' })`"",
    "    default_browser_prog_id: $DefBrowserStr",
    "    default_terminal: `"$(if ($WindowsSettings.system_ergonomics -and $WindowsSettings.system_ergonomics.default_terminal) { $WindowsSettings.system_ergonomics.default_terminal } else { 'Conhost' })`"",
    '',
    'network:',
    "  sharing_wizard_enabled: $(if ($NetworkData.sharing_wizard_enabled) { 'true' } else { 'false' })",
    "  network_category: `"$($NetworkData.network_category)`"",
    "  network_discovery_enabled: $(if ($NetworkData.network_discovery_enabled) { 'true' } else { 'false' })",
    "  file_and_printer_sharing_enabled: $(if ($NetworkData.file_and_printer_sharing_enabled) { 'true' } else { 'false' })",
    "  password_protected_sharing: $(if ($NetworkData.password_protected_sharing) { 'true' } else { 'false' })"
) | ForEach-Object { $YamlLines.Add($_) }

if ($NetworkData.adapters -and $NetworkData.adapters.Count -gt 0) {
    $YamlLines.Add('  adapters:')
    foreach ($Nic in $NetworkData.adapters) {
        $YamlLines.Add("    - name: `"$(& $EscapeYamlStr $Nic.name)`"")
        $YamlLines.Add("      description: `"$(& $EscapeYamlStr $Nic.description)`"")
        $YamlLines.Add("      mac_address: `"$(& $EscapeYamlStr $Nic.mac_address)`"")
        $YamlLines.Add("      enabled: $(if ($Nic.enabled) { 'true' } else { 'false' })")
        if ($Nic.dns_servers -and $Nic.dns_servers.Count -gt 0) {
            $YamlLines.Add('      dns_servers:')
            foreach ($Dns in $Nic.dns_servers) {
                $YamlLines.Add("        - `"$(& $EscapeYamlStr $Dns)`"")
            }
        } else {
            $YamlLines.Add('      dns_servers: []')
        }
    }
} else {
    $YamlLines.Add('  adapters: []')
}

if ($NetworkData.hosts_entries -and $NetworkData.hosts_entries.Count -gt 0) {
    $YamlLines.Add('  hosts_entries:')
    foreach ($HEntry in $NetworkData.hosts_entries) {
        $YamlLines.Add("    - `"$(& $EscapeYamlStr $HEntry)`"")
    }
} else {
    $YamlLines.Add('  hosts_entries: []')
}

if ($NetworkData.firewall_rules -and $NetworkData.firewall_rules.Count -gt 0) {
    $YamlLines.Add('  firewall_rules:')
    foreach ($FwRule in $NetworkData.firewall_rules) {
        $YamlLines.Add("    - display_name: `"$(& $EscapeYamlStr $FwRule.display_name)`"")
        $YamlLines.Add("      direction: `"$($FwRule.direction)`"")
        $YamlLines.Add("      action: `"$($FwRule.action)`"")
        $YamlLines.Add("      protocol: `"$($FwRule.protocol)`"")
        $YamlLines.Add("      local_port: `"$(& $EscapeYamlStr $FwRule.local_port)`"")
        $YamlLines.Add("      remote_port: `"$(& $EscapeYamlStr $FwRule.remote_port)`"")
        $YamlLines.Add("      program: `"$(if ($FwRule.program -and $FwRule.program -ne 'Any') { & $TokenizePath $FwRule.program } else { 'Any' })`"")
        $YamlLines.Add("      profile: `"$($FwRule.profile)`"")
        $YamlLines.Add("      enabled: $(if ($FwRule.enabled) { 'true' } else { 'false' })")
    }
} else {
    $YamlLines.Add('  firewall_rules: []')
}

@(
    '',
    'disks:',
    '  target_os_disk:',
    "    disk_id: $($OsDisk.disk_number)",
    "    serial_number: `"$($OsDisk.serial_number)`"",
    "    bus_type: `"$($OsDisk.bus_type)`"",
    '    wipe_and_partition: true',
    '    drive_variable: "OS_DRIVE"',
    '  preserved_disks:'
) | ForEach-Object { $YamlLines.Add($_) }

if ($PreservedDisks.Count -gt 0) {
    $HasAssignedDataDrive = $false
    foreach ($PDisk in $PreservedDisks) {
        $FirstPart = $PDisk.partitions | Where-Object { $_.mount_point } | Select-Object -First 1
        $Mount = if ($FirstPart) { $FirstPart.mount_point } else { $null }
        $Label = if ($FirstPart -and $FirstPart.label) { $FirstPart.label } else { $PDisk.friendly_name }

        $DriveVar = $null
        if ($Mount -eq "D:" -and -not $HasAssignedDataDrive) {
            $DriveVar = "DATA_DRIVE"
            $HasAssignedDataDrive = $true
        }

        $YamlLines.Add("    - disk_id: $($PDisk.disk_number)")
        $YamlLines.Add("      serial_number: `"$($PDisk.serial_number)`"")
        if ($PDisk.bus_type) {
            $YamlLines.Add("      bus_type: `"$($PDisk.bus_type)`"")
        }
        if ($FirstPart -and $FirstPart.partition_number) {
            $YamlLines.Add("      partition_number: $($FirstPart.partition_number)")
        }
        if ($FirstPart -and $FirstPart.partition_guid) {
            $YamlLines.Add("      partition_guid: `"$($FirstPart.partition_guid)`"")
        }
        if ($Mount) {
            $YamlLines.Add("      expected_mount: `"$Mount`"")
        } else {
            $YamlLines.Add("      expected_mount: null")
        }
        if ($DriveVar) {
            $YamlLines.Add("      drive_variable: `"$DriveVar`"")
        }
        $YamlLines.Add("      label: `"$Label`"")
    }
} else {
    $YamlLines.Add('    []')
}

@(
    '',
    'storage:',
    '  streaming:',
    "    cloud_provider: `"$($StorageProvidersData.streaming.cloud_provider)`"",
    "    mount_point: `"$StreamMount`"",
    "    verify_folder: `"$StreamVerifyYaml`"",
    '    stream_variable: "STREAM"',
    '  sync:',
    '    provider: "google-drive-sync"',
    "    source_computer: `"$ComputerName`"",
    '    migration_mode: "copy"',
    '    directories:'
) | ForEach-Object { $YamlLines.Add($_) }

if ($StorageProvidersData.sync_directories.Count -gt 0) {
    foreach ($SyncDir in $StorageProvidersData.sync_directories) {
        $LocalPathYaml = & $TokenizePath $SyncDir.local_path
        $YamlLines.Add("      $($SyncDir.id):")
        $YamlLines.Add("        local_path: `"$LocalPathYaml`"")
        $YamlLines.Add("        cloud_folder: `"$($SyncDir.cloud_folder)`"")
        $YamlLines.Add("        verify_folder: `"$LocalPathYaml`"")
        $YamlLines.Add("        sync_variable: `"$($SyncDir.sync_variable)`"")
    }
} else {
    @(
        '      catalogs:',
        '        local_path: "%OS_DRIVE%\\Sync\\Catalogs"',
        '        cloud_folder: "Catalogs"',
        '        verify_folder: "%OS_DRIVE%\\Sync\\Catalogs"',
        '        sync_variable: "SYNC_CATALOGS"',
        '      projects:',
        '        local_path: "%DATA_DRIVE%\\Projects"',
        '        cloud_folder: "Projects"',
        '        sync_variable: "SYNC_PROJECTS"'
    ) | ForEach-Object { $YamlLines.Add($_) }
}

# Emit relocated Known User Shell Folders (Desktop, Documents, Downloads, Pictures, Music, Videos)
$YamlLines.Add('  user_shell_folders:')
$ShellFolderProps = @("desktop", "documents", "downloads", "pictures", "music", "videos")
$HasAnyShellFolder = $false
if ($StorageProvidersData.user_shell_folders) {
    foreach ($SfProp in $ShellFolderProps) {
        $SfVal = $StorageProvidersData.user_shell_folders.$SfProp
        if (-not [string]::IsNullOrWhiteSpace($SfVal)) {
            $HasAnyShellFolder = $true
            $YamlLines.Add("    ${SfProp}: `"$(& $TokenizePath $SfVal)`"")
        }
    }
}
if (-not $HasAnyShellFolder) {
    $YamlLines.Add('    {}')
}

# Emit preserved Steam library folders
$PreservedSteamLibs = @(
    $AppsData.detected_game_libraries |
        Where-Object { $_.manager -eq "steam" -and $_.path -and $_.path -notmatch '^[cC]:\\' } |
        Select-Object -ExpandProperty path -Unique
)
if ($PreservedSteamLibs.Count -gt 0) {
    $YamlLines.Add('  steam_libraries:')
    foreach ($SLib in $PreservedSteamLibs) {
        $YamlLines.Add("    - `"$(& $TokenizePath $SLib)`"")
    }
} else {
    $YamlLines.Add('  steam_libraries: []')
}

$CleanUserStr = if ($UserIdentityData.username) { & $EscapeYamlStr ($UserIdentityData.username -replace '[\r\n\0]', '').Trim() } else { "user" }
@(
    '  api_credentials:',
    '    client_id_env: "GDRIVE_CLIENT_ID"',
    '    client_secret_env: "GDRIVE_CLIENT_SECRET"',
    '',
    'variables:',
    "  USER_DIR: `"%OS_DRIVE%\\Users\\$CleanUserStr`"",
    '  GAMES_DIR: "%DATA_DRIVE%\\Games"',
    '  STEAM_DIR: "%DATA_DRIVE%\\SteamLibrary"',
    '',
    'applications:'
) | ForEach-Object { $YamlLines.Add($_) }

# Correlate detected apps from catalog (built-in + user applications.json)
$DiscoveredAppIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($Pkg in $AppsData.installed_winget_packages) {
    if ($Pkg.matched_app_id) { $DiscoveredAppIds.Add($Pkg.matched_app_id) | Out-Null }
}
foreach ($App in $AppsData.detected_non_winget_applications) {
    if ($App.matched_app_id) { $DiscoveredAppIds.Add($App.matched_app_id) | Out-Null }
}
if ($AppsData.detected_game_libraries) {
    foreach ($Lib in $AppsData.detected_game_libraries) {
        if ($Lib.games) {
            foreach ($Game in $Lib.games) {
                if ($Game.matched_app_id) { $DiscoveredAppIds.Add($Game.matched_app_id) | Out-Null }
            }
        }
    }
}
if ($JunctionsData) {
    foreach ($Junc in $JunctionsData) {
        if ($Junc.matched_app_id) { $DiscoveredAppIds.Add($Junc.matched_app_id) | Out-Null }
    }
}

$AvailableSyncVars = @($StorageProvidersData.sync_directories | Select-Object -ExpandProperty sync_variable)

if ($DiscoveredAppIds.Count -gt 0) {
    foreach ($AppId in ($DiscoveredAppIds | Sort-Object)) {
        $CatalogApp = Get-ReglazeApplicationById -AppId $AppId -RepoRoot $RepoRoot -UserConfigDir $TargetDir
        $YamlLines.Add("  ${AppId}:")
        $HasDirs = ($CatalogApp.directories -and $CatalogApp.directories.Count -gt 0)
        $HasPathEntries = ($CatalogApp.PSObject.Properties["path_entries"] -and $CatalogApp.path_entries -and $CatalogApp.path_entries.Count -gt 0)
        if ($HasDirs -or $HasPathEntries) {
            if ($HasDirs) {
                $YamlLines.Add('    directories:')
                foreach ($Dir in $CatalogApp.directories) {
                    $SuggestedTarget = if ($Dir.recommended_storage -eq "local_preserved") {
                        "%DATA_DRIVE%\\Backups\\$AppId\\$($Dir.id)"
                    } elseif ($Dir.safe_for_stream -and $Dir.recommended_storage -ne "sync") { 
                        "%STREAM%\\Backups\\$AppId\\$($Dir.id)" 
                    } elseif ($AvailableSyncVars -contains "SYNC_DIRECTORYJUNCTIONS") {
                        "%SYNC_DIRECTORYJUNCTIONS%\\$AppId"
                    } elseif ($AvailableSyncVars -contains "SYNC_CATALOGS") {
                        "%SYNC_CATALOGS%\\$AppId"
                    } elseif ($AvailableSyncVars.Count -gt 0) {
                        "%$($AvailableSyncVars[0])%\\$AppId"
                    } else {
                        "%DATA_DRIVE%\\Backups\\$AppId"
                    }
                    $YamlLines.Add("      $($Dir.id):")
                    $YamlLines.Add("        target: `"$SuggestedTarget`"")
                }
            }
            if ($HasPathEntries) {
                $YamlLines.Add('    path_entries:')
                foreach ($PEntry in $CatalogApp.path_entries) {
                    $YamlLines.Add("      - `"$(& $EscapeYamlStr $PEntry)`"")
                }
            }
        } else {
            $YamlLines.Add('    {}')
        }
    }
} else {
    $YamlLines.Add('  git: {}')
    $YamlLines.Add('  vscode: {}')
}

# Populate unrecognized applications from WinGet, Steam, Registry (ARP), and Junctions into applications.custom
$CustomYamlLines = [System.Collections.Generic.List[string]]::new()
$SeenCustomKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

# 1. Unmatched WinGet packages
foreach ($Pkg in @($AppsData.installed_winget_packages | Where-Object { -not $_.matched_app_id })) {
    $PkgName = if ($Pkg.name) { $Pkg.name } else { $Pkg.id }
    $DedupKey = "winget:$($Pkg.id)"
    if (-not $SeenCustomKeys.Add($DedupKey)) { continue }
    [void]$SeenCustomKeys.Add("name:$PkgName")

    $EscName = & $EscapeYamlStr $PkgName
    $EscId = & $EscapeYamlStr $Pkg.id
    $CustomYamlLines.Add("    - name: `"$EscName`"")
    $CustomYamlLines.Add("      install:")
    $CustomYamlLines.Add("        method: `"winget`"")
    $CustomYamlLines.Add("        winget_id: `"$EscId`"")
    $CustomYamlLines.Add("      directories: []")
}

# 2. Unmatched Steam games (from Steam libraries and Steam ARP entries)
$UnmatchedSteamGames = [System.Collections.Generic.List[PSCustomObject]]::new()
if ($AppsData.detected_game_libraries) {
    foreach ($Lib in $AppsData.detected_game_libraries) {
        if ($Lib.games) {
            foreach ($Game in $Lib.games) {
                if (-not $Game.matched_app_id -and $null -ne $Game.steam_id) {
                    $UnmatchedSteamGames.Add([PSCustomObject]@{
                        steam_id = [int]$Game.steam_id
                        name     = if ($Game.name) { $Game.name } else { "Steam App $($Game.steam_id)" }
                    })
                }
            }
        }
    }
}
foreach ($App in @($AppsData.detected_non_winget_applications | Where-Object { -not $_.matched_app_id -and $null -ne $_.steam_id })) {
    $UnmatchedSteamGames.Add([PSCustomObject]@{
        steam_id = [int]$App.steam_id
        name     = $App.display_name
    })
}
foreach ($SGame in $UnmatchedSteamGames) {
    $DedupKey = "steam:$($SGame.steam_id)"
    if (-not $SeenCustomKeys.Add($DedupKey)) { continue }
    [void]$SeenCustomKeys.Add("name:$($SGame.name)")

    $EscGameName = & $EscapeYamlStr $SGame.name
    $CustomYamlLines.Add("    - name: `"$EscGameName`"")
    $CustomYamlLines.Add("      install:")
    $CustomYamlLines.Add("        method: `"steam`"")
    $CustomYamlLines.Add("        steam_id: $($SGame.steam_id)")
    $CustomYamlLines.Add("      directories: []")
}

# 3. Unmatched non-WinGet Registry (ARP) applications
foreach ($App in @($AppsData.detected_non_winget_applications | Where-Object { -not $_.matched_app_id -and $null -eq $_.steam_id })) {
    if (-not $App.display_name) { continue }
    if (-not $SeenCustomKeys.Add("name:$($App.display_name)")) { continue }

    $EscDispName = & $EscapeYamlStr $App.display_name
    $CustomYamlLines.Add("    - name: `"$EscDispName`"")
    $CustomYamlLines.Add("      install:")
    $CustomYamlLines.Add("        method: `"manual`"")
    if (-not [string]::IsNullOrWhiteSpace($App.install_location)) {
        $EscLoc = & $EscapeYamlStr $App.install_location
        $CustomYamlLines.Add("        target_directory: `"$EscLoc`"")
    }
    $CustomYamlLines.Add("      directories: []")
}

# 4. Unmatched NTFS Directory Junctions
foreach ($Junc in @($JunctionsData | Where-Object { -not $_.matched_app_id })) {
    if (-not $Junc.source_path -or -not $Junc.target_path) { continue }
    $LeafName = Split-Path -Leaf $Junc.source_path
    $EscLeaf = & $EscapeYamlStr $LeafName
    $EscLink = & $EscapeYamlStr $Junc.source_path
    $EscTarget = & $EscapeYamlStr $Junc.target_path
    $CustomYamlLines.Add("    - name: `"Custom Junction ($EscLeaf)`"")
    $CustomYamlLines.Add("      install: false")
    $CustomYamlLines.Add("      directories:")
    $CustomYamlLines.Add("        - name: `"$EscLeaf`"")
    $CustomYamlLines.Add("          link: `"$EscLink`"")
    $CustomYamlLines.Add("          target: `"$EscTarget`"")
}

if ($CustomYamlLines.Count -gt 0) {
    $YamlLines.Add('  custom:')
    foreach ($CLine in $CustomYamlLines) { $YamlLines.Add($CLine) }
} else {
    $YamlLines.Add('  custom: []')
}

$WslDistroName = if ($WslData.default_distro) { $WslData.default_distro } else { "Ubuntu" }
$WslUsername = if ($UserIdentityData.username) { $UserIdentityData.username.ToLower() } else { "user" }
$YamlLines.Add('')
$YamlLines.Add('wsl2:')
$YamlLines.Add("  enabled: $($WslData.enabled.ToString().ToLower())")
$YamlLines.Add("  distro: `"$WslDistroName`"")
$YamlLines.Add("  default_user: `"$WslUsername`"")
if ($WslData.detected_packages -and $WslData.detected_packages.Count -gt 0) {
    $YamlLines.Add('  packages:')
    foreach ($WslPkg in $WslData.detected_packages) {
        $CleanPkg = ($WslPkg -replace "`0", "").Trim()
        if ($CleanPkg) {
            $YamlLines.Add("    - `"$(& $EscapeYamlStr $CleanPkg)`"")
        }
    }
} else {
    $YamlLines.Add('  packages: []')
}

$DefaultDevReposRoot = if ($AvailableSyncVars -contains "SYNC_PROJECTS") {
    "%SYNC_PROJECTS%"
} elseif ($AvailableSyncVars.Count -gt 0) {
    "%$($AvailableSyncVars[0])%"
} else {
    "%DATA_DRIVE%\\Projects"
}
@(
    '',
    'dev_repos:',
    "  root: `"$DefaultDevReposRoot`"",
    '  remotes: []'
) | ForEach-Object { $YamlLines.Add($_) }

[System.IO.File]::WriteAllLines($BlueprintPath, $YamlLines.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
Write-ReglazeSuccess "Scaffolded starter blueprint: $BlueprintPath"

Write-Host ""
Write-ReglazeSuccess "Pre-flight audit complete! You can now review and customize your blueprint."
Write-Host ""
