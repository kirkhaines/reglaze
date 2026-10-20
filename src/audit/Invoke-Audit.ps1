<#
.SYNOPSIS
    Master pre-flight audit orchestrator for Reglaze.
.DESCRIPTION
    Runs non-destructive hardware, licensing, BitLocker, installed applications (WinGet + ARP),
    Windows settings, and directory junction audits. Emits 'audit-reference.json' and scaffolds
    a personalized 'reglaze.yaml' in the resolved output directory (or $env:REGLAZE_DIR).
#>
[CmdletBinding()]
param(
    [string]$OutputDir = $null,
    [switch]$Force = $false
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

Write-ReglazeBanner "PRE-FLIGHT SYSTEM AUDIT"

# 1. Resolve Target Output Directory
$TargetDir = Resolve-ReglazeTargetDirectory -ExplicitDirectory $OutputDir
if (-not (Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
}
Write-ReglazeInfo "Audit artifacts will be saved to: $TargetDir"

# 2. Execute Hardware & Storage Audit
Write-ReglazeStep "Auditing Hardware & Storage Topology..."
$HardwareData = Get-HardwareAudit
Write-ReglazeSuccess "Discovered $($HardwareData.storage_topology.disks.Count) physical disk(s)."

# 3. Execute Licensing & OS Audit
Write-ReglazeStep "Auditing Windows Operating System & Licensing..."
$LicensingData = Get-LicensingAudit
Write-ReglazeSuccess "$($LicensingData.os_edition) (Build $($LicensingData.os_build)) - $($LicensingData.license_channel) Channel"

# 4. Execute BitLocker Audit
Write-ReglazeStep "Auditing BitLocker Volumes & Recovery Protectors..."
$BitLockerData = Get-BitLockerAudit
Write-ReglazeSuccess "Captured $($BitLockerData.Count) BitLocker volume status(es)."

# 5. Execute Comprehensive Application Discovery (WinGet + Add/Remove Programs)
Write-ReglazeStep "Auditing Applications (WinGet Packages & Add/Remove Programs)..."
$AppsData = Get-InstalledApplicationsAudit -RepoRoot $RepoRoot
Write-ReglazeSuccess "Found $($AppsData.installed_winget_packages.Count) WinGet packages and $($AppsData.detected_non_winget_applications.Count) non-WinGet applications."

# 6. Execute Directory Junctions Discovery
Write-ReglazeStep "Auditing Existing NTFS Directory Junctions & Reparse Points..."
$JunctionsData = Get-JunctionsAudit -RepoRoot $RepoRoot
Write-ReglazeSuccess "Detected $($JunctionsData.Count) directory junction(s)."

# 7. Execute Windows Settings Discovery
Write-ReglazeStep "Auditing Windows Preferences & Settings..."
$WindowsSettings = $null
$WinSettingsScript = Join-Path $RepoRoot "data\windows\audit-windows-settings.ps1"
if (Test-Path $WinSettingsScript) {
    try {
        $WindowsSettings = & $WinSettingsScript
        Write-ReglazeSuccess "Captured Explorer, Taskbar, and Power profile preferences."
    } catch {
        Write-ReglazeWarning "Could not execute Windows settings audit: $($_.Exception.Message)"
    }
}

# 8. Execute Storage Providers & User Identity Discovery
Write-ReglazeStep "Auditing Cloud Storage Providers & User Identity..."
$StorageProvidersData = Get-StorageProvidersAudit
$UserIdentityData = Get-UserIdentityAudit
Write-ReglazeSuccess "User Identity: $($UserIdentityData.email) ($($UserIdentityData.account_type))"
Write-ReglazeSuccess "Cloud Streaming: $($StorageProvidersData.streaming.mount_point) ($($StorageProvidersData.streaming.cloud_provider)), Synced roots: $($StorageProvidersData.sync_directories.Count)."

# 9. Execute WSL Environment Discovery
Write-ReglazeStep "Auditing WSL Distributions & Packages..."
$WslData = Get-WslAudit
Write-ReglazeSuccess "WSL Enabled: $($WslData.enabled), Default Distro: $($WslData.default_distro), Packages: $($WslData.detected_packages.Count)."

# 10. Assemble and Emit audit-reference.json
Write-ReglazeStep "Compiling Audit Reference Document..."
$ComputerName = $env:COMPUTERNAME
$AuditMetadata = [PSCustomObject]@{
    timestamp       = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    reglaze_version = "1.0.0"
    host_name       = $ComputerName
    os_version      = $LicensingData.os_version
}

$AuditReference = [PSCustomObject]@{
    audit_metadata                   = $AuditMetadata
    system_and_licensing             = $LicensingData
    user_identity                    = $UserIdentityData
    storage_providers                = $StorageProvidersData
    detected_wsl                     = $WslData
    bitlocker_recovery_keys          = $BitLockerData
    storage_topology                 = $HardwareData.storage_topology
    detected_junctions               = $JunctionsData
    installed_winget_packages        = $AppsData.installed_winget_packages
    detected_non_winget_applications = $AppsData.detected_non_winget_applications
    detected_windows_settings        = $WindowsSettings
}

$AuditJsonPath = Join-Path $TargetDir "audit-reference.json"
$AuditReference | ConvertTo-Json -Depth 6 | Set-Content -Path $AuditJsonPath -Encoding UTF8
Write-ReglazeSuccess "Wrote audit profile: $AuditJsonPath"

# 9. Archive Existing reglaze.yaml (if present) and Scaffold Fresh Blueprint
$BlueprintPath = Join-Path $TargetDir "reglaze.yaml"
if (Test-Path $BlueprintPath) {
    $ExistingContent = Get-Content -Raw -Path $BlueprintPath -ErrorAction SilentlyContinue
    $GenDateStr = $null
    if ($ExistingContent -and $ExistingContent -match '(?m)^\s*(?:generation_date|generated_at):\s*["'']?([^"''\r\n]+)["'']?') {
        $RawVal = $Matches[1].Trim()
        $ParsedDate = [DateTime]::MinValue
        if ([DateTime]::TryParse($RawVal, [ref]$ParsedDate)) {
            $GenDateStr = $ParsedDate.ToString("yyyy-MM-dd")
        } else {
            $GenDateStr = ($RawVal -replace '[:\\/*?"<>|]', '-')
        }
    }
    if (-not $GenDateStr) {
        $GenDateStr = (Get-Item $BlueprintPath).LastWriteTime.ToString("yyyy-MM-dd")
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

# Build Scaffolded Blueprint Content
$CurrentDateStr = (Get-Date).ToString("yyyy-MM-dd")
$YamlLines = @(
    'version: "1.0"',
    'profile: "workstation"',
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
        'disks:',
        '  target_os_disk:',
        "    disk_id: $($OsDisk.disk_number)",
        "    serial_number: `"$($OsDisk.serial_number)`"",
        "    bus_type: `"$($OsDisk.bus_type)`"",
        '    wipe_and_partition: true',
        '    drive_variable: "OS_DRIVE"',
        '  preserved_disks:'
    )

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

            $YamlLines += "    - disk_id: $($PDisk.disk_number)"
            $YamlLines += "      serial_number: `"$($PDisk.serial_number)`""
            if ($Mount) {
                $YamlLines += "      expected_mount: `"$Mount`""
            }
            if ($DriveVar) {
                $YamlLines += "      drive_variable: `"$DriveVar`""
            }
            $YamlLines += "      label: `"$Label`""
        }
    } else {
        $YamlLines += '    []'
    }

    $StreamMount = if ($StorageProvidersData.streaming.detected) { $StorageProvidersData.streaming.mount_point } else { "G:" }
    $StreamVerify = if ($StorageProvidersData.streaming.detected) { $StorageProvidersData.streaming.verify_folder } else { "G:\My Drive" }
    $StreamVerifyYaml = $StreamVerify -replace '\\', '\\'

    $YamlLines += @(
        '',
        'storage:',
        '  streaming:',
        "    cloud_provider: `"$($StorageProvidersData.streaming.cloud_provider)`"",
        "    mount_point: `"$StreamMount`"",
        "    verify_folder: `"$StreamVerifyYaml`"",
        '    stream_variable: "STREAM"',
        '  sync:',
        '    provider: "google-drive-sync"',
        '    directories:'
    )

    if ($StorageProvidersData.sync_directories.Count -gt 0) {
        foreach ($SyncDir in $StorageProvidersData.sync_directories) {
            $LocalPathVar = $SyncDir.local_path
            if ($LocalPathVar -like "D:\*") {
                $LocalPathVar = "%DATA_DRIVE%" + $LocalPathVar.Substring(2)
            } elseif ($LocalPathVar -like "C:\*") {
                $LocalPathVar = "%OS_DRIVE%" + $LocalPathVar.Substring(2)
            }
            $LocalPathYaml = $LocalPathVar -replace '\\', '\\'
            $YamlLines += "      $($SyncDir.id):"
            $YamlLines += "        local_path: `"$LocalPathYaml`""
            $YamlLines += "        cloud_folder: `"$($SyncDir.cloud_folder)`""
            $YamlLines += "        verify_folder: `"$LocalPathYaml`""
            $YamlLines += "        sync_variable: `"$($SyncDir.sync_variable)`""
        }
    } else {
        $YamlLines += @(
            '      catalogs:',
            '        local_path: "%OS_DRIVE%\\Sync\\Catalogs"',
            '        cloud_folder: "Catalogs"',
            '        verify_folder: "%OS_DRIVE%\\Sync\\Catalogs"',
            '        sync_variable: "SYNC_CATALOGS"',
            '      projects:',
            '        local_path: "%DATA_DRIVE%\\Projects"',
            '        cloud_folder: "Projects"',
            '        sync_variable: "SYNC_PROJECTS"'
        )
    }

    $YamlLines += @(
        '  api_credentials:',
        '    client_id_env: "GDRIVE_CLIENT_ID"',
        '    client_secret_env: "GDRIVE_CLIENT_SECRET"',
        '',
        'variables:',
        '  GAMES_DIR: "%DATA_DRIVE%\\Games"',
        '  STEAM_DIR: "%DATA_DRIVE%\\SteamLibrary"',
        '',
        'applications:'
    )

    # Correlate detected apps from catalog
    $DiscoveredAppIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Pkg in $AppsData.installed_winget_packages) {
        if ($Pkg.matched_app_id) { $DiscoveredAppIds.Add($Pkg.matched_app_id) | Out-Null }
    }
    foreach ($App in $AppsData.detected_non_winget_applications) {
        if ($App.matched_app_id) { $DiscoveredAppIds.Add($App.matched_app_id) | Out-Null }
    }

    $AvailableSyncVars = @($StorageProvidersData.sync_directories | Select-Object -ExpandProperty sync_variable)

    if ($DiscoveredAppIds.Count -gt 0) {
        foreach ($AppId in ($DiscoveredAppIds | Sort-Object)) {
            $CatalogApp = Get-ReglazeApplicationById -AppId $AppId -RepoRoot $RepoRoot
            $YamlLines += "  ${AppId}:"
            if ($CatalogApp.directories -and $CatalogApp.directories.Count -gt 0) {
                $YamlLines += '    directories:'
                foreach ($Dir in $CatalogApp.directories) {
                    $SuggestedTarget = if ($Dir.safe_for_stream) { 
                        "%STREAM%\\Backups\\$AppId\\$($Dir.id)" 
                    } elseif ($AvailableSyncVars -contains "SYNC_DIRECTORYJUNCTIONS") {
                        "%SYNC_DIRECTORYJUNCTIONS%\\$AppId"
                    } elseif ($AvailableSyncVars -contains "SYNC_CATALOGS") {
                        "%SYNC_CATALOGS%\\$AppId"
                    } else {
                        "%DATA_DRIVE%\\Backups\\$AppId"
                    }
                    $YamlLines += "      $($Dir.id):"
                    $YamlLines += "        target: `"$SuggestedTarget`""
                }
            } else {
                $YamlLines += '    {}'
            }
        }
    } else {
        $YamlLines += '  git: {}'
        $YamlLines += '  vscode: {}'
    }

    $WslDistroName = if ($WslData.default_distro) { $WslData.default_distro } else { "Ubuntu" }
    $WslUsername = if ($UserIdentityData.username) { $UserIdentityData.username.ToLower() } else { "user" }
    $YamlLines += @(
        '',
        'wsl2:',
        "  enabled: $($WslData.enabled.ToString().ToLower())",
        "  distro: `"$WslDistroName`"",
        "  default_user: `"$WslUsername`"",
        '  packages:'
    )
    foreach ($WslPkg in $WslData.detected_packages) {
        $YamlLines += "    - `"$WslPkg`""
    }

    $YamlLines += @(
        '',
        'dev_repos:',
        '  root: "%SYNC_PROJECTS%"',
        '  remotes: []'
    )

    $YamlLines | Set-Content -Path $BlueprintPath -Encoding UTF8
    Write-ReglazeSuccess "Scaffolded starter blueprint: $BlueprintPath"

Write-Host ""
Write-ReglazeSuccess "Pre-flight audit complete! You can now review and customize your blueprint."
Write-Host ""
