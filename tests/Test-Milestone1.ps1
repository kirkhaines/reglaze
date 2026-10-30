<#
.SYNOPSIS
    Automated verification test suite for Reglaze Milestone 1.
.DESCRIPTION
    Validates CLI foundation, config resolution, catalog loading,
    pre-flight audit modules, and end-to-end audit artifact generation.
#>
[CmdletBinding()]
param(
    [switch]$All = $false
)

$Script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$RepoRoot = $Script:RepoRoot

# Import modules
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

Write-ReglazeBanner "REGLAZE MILESTONE 1 VERIFICATION SUITE"

$Passed = 0
$Failed = 0

function Assert-Test {
    param(
        [string]$Description,
        [scriptblock]$TestBlock
    )

    try {
        $Result = & $TestBlock
        if ($Result -ne $false) {
            Write-Host "  [PASS] $Description" -ForegroundColor Green
            $script:Passed++
        } else {
            Write-Host "  [FAIL] $Description (Returned false)" -ForegroundColor Red
            $script:Failed++
        }
    } catch {
        Write-Host "  [FAIL] ${Description}: $($_.Exception.Message)" -ForegroundColor Red
        $script:Failed++
    }
}

# Test 1: Config Resolver and Environment Variables
Write-ReglazeStep "Testing Path Resolution & Environment Variables..."
Assert-Test "Resolve-ReglazeTargetDirectory defaults to current path or REGLAZE_DIR" {
    $Dir = Resolve-ReglazeTargetDirectory
    return ($Dir -ne $null -and (Test-Path $Dir))
}

Assert-Test "Resolve-ReglazeTargetDirectory respects explicit directory parameter" {
    $TestPath = Join-Path $RepoRoot "tests\temp_dir"
    $Resolved = Resolve-ReglazeTargetDirectory -ExplicitDirectory $TestPath
    return ($Resolved -eq [System.IO.Path]::GetFullPath($TestPath))
}

# Test 2: Modular Application Catalog
Write-ReglazeStep "Testing Modular Application Catalog..."
Assert-Test "Get-ReglazeCatalog loads applications from data/applications/" {
    $Catalog = Get-ReglazeCatalog -RepoRoot $RepoRoot
    Write-ReglazeInfo "Loaded $($Catalog.Count) application manifests."
    return ($Catalog.Count -ge 10)
}

Assert-Test "Get-ReglazeApplicationById finds known application (outfox)" {
    $App = Get-ReglazeApplicationById -AppId "outfox" -RepoRoot $RepoRoot
    return ($App -ne $null -and $App.name -eq "Project OutFox")
}

Assert-Test "Catalog application (adobe_lightroom) has recommended_storage sync for catalog" {
    $App = Get-ReglazeApplicationById -AppId "adobe_lightroom" -RepoRoot $RepoRoot
    $CatDir = $App.directories | Where-Object { $_.id -eq "catalog" }
    return ($CatDir.safe_for_stream -eq $false -and $CatDir.recommended_storage -eq "sync")
}

# Test 3: Hardware Audit Module
Write-ReglazeStep "Testing Hardware & Storage Discovery..."
Assert-Test "Get-HardwareAudit returns physical disks with serial numbers and bus types" {
    $Hw = Get-HardwareAudit
    $Disks = $Hw.storage_topology.disks
    Write-ReglazeInfo "Discovered $($Disks.Count) disk(s)."
    if ($Disks.Count -eq 0) { return $false }
    $FirstDisk = $Disks[0]
    return ($FirstDisk.serial_number -ne $null -and $FirstDisk.bus_type -ne $null -and $FirstDisk.size_bytes -gt 0)
}

# Test 4: Licensing Audit Module
Write-ReglazeStep "Testing Windows OS & Licensing Audit..."
Assert-Test "Get-LicensingAudit extracts OS edition and license channel" {
    $Lic = Get-LicensingAudit
    Write-ReglazeInfo "Detected: $($Lic.os_edition) ($($Lic.license_channel))"
    return ($Lic.os_edition -ne $null -and $Lic.license_channel -ne $null)
}

Assert-Test "Get-UserIdentityAudit discovers primary user email and account type" {
    $User = Get-UserIdentityAudit
    Write-ReglazeInfo "Discovered email: $($User.email) ($($User.account_type))"
    return ($User.username -ne $null -and $User.email -ne $null -and $User.email.Contains("@"))
}

Assert-Test "Get-StorageProvidersAudit discovers cloud streaming mount and sync roots" {
    $Storage = Get-StorageProvidersAudit
    Write-ReglazeInfo "Streaming Mount: $($Storage.streaming.mount_point), Synced Roots: $($Storage.sync_directories.Count)"
    return ($Storage.streaming.cloud_provider -ne $null -and $Storage.streaming.mount_point -ne $null)
}

# Test 5: BitLocker Audit Module
Write-ReglazeStep "Testing BitLocker Discovery..."
Assert-Test "Get-BitLockerAudit executes gracefully without unhandled exceptions" {
    $Bit = Get-BitLockerAudit
    $Count = if ($Bit) { $Bit.Count } else { 0 }
    Write-ReglazeInfo "Captured $Count BitLocker volume status(es)."
    return $true
}

# Test 6: Application Discovery (WinGet + Add/Remove Programs)
Write-ReglazeStep "Testing Dual Application Discovery..."
Assert-Test "Get-InstalledApplicationsAudit discovers WinGet and ARP applications" {
    $Apps = Get-InstalledApplicationsAudit -RepoRoot $RepoRoot
    Write-ReglazeInfo "Discovered $($Apps.installed_winget_packages.Count) WinGet packages and $($Apps.detected_non_winget_applications.Count) ARP apps."
    return ($Apps.installed_winget_packages.Count -gt 0 -or $Apps.detected_non_winget_applications.Count -gt 0)
}

# Test 7: Directory Junctions Audit
Write-ReglazeStep "Testing Directory Junction Discovery..."
Assert-Test "Get-JunctionsAudit executes without error" {
    $Junc = Get-JunctionsAudit -RepoRoot $RepoRoot
    $Count = if ($Junc) { $Junc.Count } else { 0 }
    Write-ReglazeInfo "Discovered $Count junction(s)."
    return $true
}

# Test 8: WSL Audit Module
Write-ReglazeStep "Testing WSL Distribution & Package Discovery..."
Assert-Test "Get-WslAudit detects WSL state and package inventory" {
    $Wsl = Get-WslAudit
    Write-ReglazeInfo "WSL Enabled: $($Wsl.enabled), Default Distro: $($Wsl.default_distro), Packages: $($Wsl.detected_packages -join ', ')"
    return ($Wsl -ne $null -and $Wsl.detected_packages.Count -gt 0)
}

# Test 8: End-to-End Invoke-Audit Execution
Write-ReglazeStep "Testing End-to-End Audit Run & File Emission..."
$TestOutputDir = Join-Path $RepoRoot "tests\scratch_audit_output"
if (Test-Path $TestOutputDir) {
    Remove-Item -Path $TestOutputDir -Recurse -Force
}

Assert-Test "Invoke-Audit.ps1 requires -Profile when no existing reglaze.yaml is present" {
    $AuditScript = Join-Path $RepoRoot "src\audit\Invoke-Audit.ps1"
    $ThrewMissingProfile = $false
    try {
        & $AuditScript -OutputDir $TestOutputDir -SkipElevation 2>$null
    } catch {
        if ($_.Exception.Message -match "Profile") {
            $ThrewMissingProfile = $true
        }
    }
    return $ThrewMissingProfile
}

Assert-Test "Invoke-Audit.ps1 emits audit-reference.json, profile-computers.json, and scaffolds reglaze.yaml" {
    $AuditScript = Join-Path $RepoRoot "src\audit\Invoke-Audit.ps1"
    & $AuditScript -OutputDir $TestOutputDir -Profile "workstation" -Force -SkipElevation

    $AuditJson = Join-Path $TestOutputDir "audit-reference.json"
    $ProfileRegJson = Join-Path $TestOutputDir "profile-computers.json"
    $Blueprint = Join-Path $TestOutputDir "reglaze.yaml"

    if (-not (Test-Path $AuditJson)) { return $false }
    if (-not (Test-Path $ProfileRegJson)) { return $false }
    if (-not (Test-Path $Blueprint)) { return $false }

    # Validate audit-reference.json content
    $AuditData = Get-Content -Raw $AuditJson | ConvertFrom-Json
    $HasMetadata = ($AuditData.audit_metadata -ne $null -and $AuditData.audit_metadata.profile -eq "workstation")
    $HasProfileAssoc = ($AuditData.profile_association -ne $null -and $AuditData.profile_association.latest_computer_name -eq $env:COMPUTERNAME)
    $HasDisks = ($AuditData.storage_topology.disks.Count -gt 0)
    $HasLicensing = ($AuditData.system_and_licensing.os_edition -ne $null)

    # Validate scaffolded reglaze.yaml content
    $YamlContent = Get-Content -Raw $Blueprint
    $HasOsDisk = ($YamlContent -match "target_os_disk:")
    $HasUsers = ($YamlContent -match "local_admin:")
    $HasSourceComp = ($YamlContent -match 'source_computer:')
    # Ensure at most one DATA_DRIVE is assigned in preserved_disks
    $DataDriveMatches = [regex]::Matches($YamlContent, 'drive_variable:\s*"DATA_DRIVE"')
    $SingleDataDrive = ($DataDriveMatches.Count -le 1)

    $HasGenDate = ($YamlContent -match 'generation_date:\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}"')

    return ($HasMetadata -and $HasProfileAssoc -and $HasDisks -and $HasLicensing -and $HasOsDisk -and $HasUsers -and $HasSourceComp -and $SingleDataDrive -and $HasGenDate)
}

Assert-Test "Invoke-Audit.ps1 inherits profile from existing reglaze.yaml and archives with second-level precision generation_date" {
    $AuditScript = Join-Path $RepoRoot "src\audit\Invoke-Audit.ps1"
    $Blueprint = Join-Path $TestOutputDir "reglaze.yaml"
    if (-not (Test-Path $Blueprint)) { return $false }

    # Put a specific generation_date with second-level precision and profile: "test" into existing file
    $CustomContent = "version: `"1.0`"`r`nprofile: `"test`"`r`ngeneration_date: `"2025-01-15T14:30:22`"`r`nsystem:`r`n  computer_name: `"TEST`"`r`n"
    Set-Content -Path $Blueprint -Value $CustomContent -Encoding UTF8

    # Second audit run without -Profile should inherit 'test' and archive existing to reglaze.2025-01-15T14-30-22.yaml
    & $AuditScript -OutputDir $TestOutputDir -SkipElevation

    $ExpectedArchive = Join-Path $TestOutputDir "reglaze.2025-01-15T14-30-22.yaml"
    $ArchiveExists = Test-Path $ExpectedArchive
    $FreshBlueprintExists = Test-Path $Blueprint

    $ArchivedContent = if ($ArchiveExists) { Get-Content -Raw $ExpectedArchive } else { "" }
    $FreshContent = if ($FreshBlueprintExists) { Get-Content -Raw $Blueprint } else { "" }

    $ArchivePreserved = ($ArchivedContent -match 'generation_date:\s*"2025-01-15T14:30:22"')
    $FreshHasDate = ($FreshContent -match 'generation_date:\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}"')
    $InheritedProfile = ($FreshContent -match 'profile:\s*"test"')

    return ($ArchiveExists -and $FreshBlueprintExists -and $ArchivePreserved -and $FreshHasDate -and $InheritedProfile)
}

Assert-Test "Invoke-Audit.ps1 populates unrecognized apps into applications.custom and promotes them when user applications.json is added" {
    $AuditScript = Join-Path $RepoRoot "src\audit\Invoke-Audit.ps1"
    $AuditJson = Join-Path $TestOutputDir "audit-reference.json"
    $Blueprint = Join-Path $TestOutputDir "reglaze.yaml"

    $AuditData = Get-Content -Raw $AuditJson | ConvertFrom-Json
    $YamlBefore = Get-Content -Raw $Blueprint

    # Verify custom: section exists in scaffolded reglaze.yaml
    if ($YamlBefore -notmatch '(?m)^\s*custom:') { return $false }

    # Find an unmatched non-winget or winget app from audit-reference.json (or synthesize a user catalog entry matching a detected ARP app)
    $UnmatchedArp = @($AuditData.applications.detected_non_winget_applications | Where-Object { -not $_.matched_app_id }) | Select-Object -First 1
    if ($UnmatchedArp) {
        $TargetDispName = $UnmatchedArp.display_name
        # Verify it was placed in custom: before user applications.json existed
        $EscapedCheck = [regex]::Escape(($TargetDispName -replace '\\', '\\' -replace '"', '\"'))
        if ($YamlBefore -notmatch $EscapedCheck) { return $false }

        # Create user applications.json in $TestOutputDir defining this app
        $UserAppsJson = @(
            [PSCustomObject]@{
                app_id      = "user_custom_promoted_app"
                name        = $TargetDispName
                website     = "https://example.com"
                install     = [PSCustomObject]@{
                    method                   = "manual"
                    winget_id                = $null
                    steam_id                 = $null
                    download_url             = "https://example.com/download"
                    default_target_directory = "%PROGRAMFILES%\PromotedApp"
                    guide_file               = $null
                    post_install_script      = $null
                    instructions             = @("Install PromotedApp to target directory.")
                }
                directories = @(
                    [PSCustomObject]@{
                        id                  = "user_config"
                        description         = "Promoted app configuration"
                        default_path        = "%APPDATA%\PromotedApp"
                        category            = "configs"
                        needs_mapping       = $true
                        safe_for_stream     = $true
                        recommended_storage = "streaming"
                        notes               = "Flat config files."
                    }
                )
            }
        )
        $UserAppsPath = Join-Path $TestOutputDir "applications.json"
        $UserAppsJson | ConvertTo-Json -Depth 6 | Set-Content -Path $UserAppsPath -Encoding UTF8

        # Re-run audit and verify user_custom_promoted_app is now in main applications: list with user_config directory, and no longer in custom:
        & $AuditScript -OutputDir $TestOutputDir -SkipElevation
        $YamlAfter = Get-Content -Raw $Blueprint
        $PromotedToMain = ($YamlAfter -match '(?m)^\s{2}user_custom_promoted_app:' -and $YamlAfter -match '%STREAM%\\\\Backups\\\\user_custom_promoted_app\\\\user_config')
        return $PromotedToMain
    } else {
        # Fallback if test host had 0 unmatched ARP apps: test Get-ReglazeCatalog user merge directly
        $UserAppsPath = Join-Path $TestOutputDir "applications.json"
        @(
            [PSCustomObject]@{
                app_id      = "user_custom_promoted_app"
                name        = "Synthetic User App"
                directories = @()
            }
        ) | ConvertTo-Json -Depth 5 | Set-Content -Path $UserAppsPath -Encoding UTF8
        $Lookup = Get-ReglazeApplicationById -AppId "user_custom_promoted_app" -RepoRoot $RepoRoot -UserConfigDir $TestOutputDir
        return ($null -ne $Lookup -and $Lookup._CatalogSource -eq "user")
    }
}

# Clean up scratch test output
if (Test-Path $TestOutputDir) {
    Remove-Item -Path $TestOutputDir -Recurse -Force
}

# Summary
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  TEST RESULTS: Passed: $Passed, Failed: $Failed" -ForegroundColor $(if ($Failed -eq 0) { "Green" } else { "Red" })
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

if ($Failed -gt 0) {
    exit 1
}
