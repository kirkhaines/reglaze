<#
.SYNOPSIS
    Automated verification suite for Reglaze Milestone 2 (Compiler & Artifact Generator).
.DESCRIPTION
    Executes 16 comprehensive unit and integration tests covering:
    - Pure PowerShell YAML parsing
    - Variable token resolution and recursion
    - Safety and catalog validation (safe_for_stream enforcement)
    - WinGet DSC manifest generation & Store ID detection
    - Dynamic WinPE disk matching logic and preserved disk safety
    - autounattend.xml well-formedness and account structure
    - Payload assembly (BitLocker, junctions, bootstrap, hydrate, WSL2)
    - Full end-to-end compiler orchestration
#>
[CmdletBinding()]
param(
    [switch]$All = $false
)

$ErrorActionPreference = "Continue"
$RepoRoot = Split-Path -Parent $PSScriptRoot

# Import modules under test
. (Join-Path $RepoRoot "src\common\Logging.ps1")
. (Join-Path $RepoRoot "src\common\ConfigResolver.ps1")
. (Join-Path $RepoRoot "src\common\Catalog.ps1")
. (Join-Path $RepoRoot "src\common\YamlParser.ps1")
. (Join-Path $RepoRoot "src\compiler\Resolve-Variables.ps1")
. (Join-Path $RepoRoot "src\compiler\Test-ReglazeValidation.ps1")
. (Join-Path $RepoRoot "src\compiler\Build-WinGetDSC.ps1")
. (Join-Path $RepoRoot "src\compiler\Build-Autounattend.ps1")
. (Join-Path $RepoRoot "src\compiler\DiskMatch.ps1")
. (Join-Path $RepoRoot "src\compiler\Build-Payload.ps1")
. (Join-Path $RepoRoot "src\compiler\Compile-Reglaze.ps1")
. (Join-Path $RepoRoot "src\media\Get-WindowsIso.ps1")
. (Join-Path $RepoRoot "src\media\Build-Media.ps1")
. (Join-Path $RepoRoot "src\linking\Invoke-PreInstallMigration.ps1")

$PassCount = 0
$FailCount = 0

function Assert-Test {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$Details = ""
    )
    if ($Condition) {
        $script:PassCount++
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } else {
        $script:FailCount++
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        if ($Details) {
            Write-Host "         Details: $Details" -ForegroundColor Yellow
        }
    }
}

Write-ReglazeBanner "REGLAZE MILESTONE 2: COMPILER TEST SUITE"

$TestDir = Join-Path $RepoRoot "tests\temp_m2"
if (Test-Path $TestDir) { Remove-Item -Path $TestDir -Recurse -Force | Out-Null }
New-Item -ItemType Directory -Path $TestDir -Force | Out-Null
$env:LOCAL_ADMIN_PASSWORD = "TestAdminPassword123!"

try {
    # -------------------------------------------------------------------------
    # TEST 1: Pure PowerShell YAML Parser
    # -------------------------------------------------------------------------
    $SampleYaml = @"
version: "1.0.0"
profile: "developer"
enabled: true
count: 42
tags:
  - alpha
  - beta
nested:
  user: "developer"
  is_admin: false
"@
    $ParsedObj = ConvertFrom-ReglazeYaml -YamlText $SampleYaml
    Assert-Test -Name "1. YAML Parser: parses scalars, booleans, arrays, and nested maps" `
        -Condition ($ParsedObj.version -eq "1.0.0" -and $ParsedObj.enabled -eq $true -and $ParsedObj.tags.Count -eq 2 -and $ParsedObj.nested.user -eq "developer" -and $ParsedObj.nested.is_admin -eq $false)

    # -------------------------------------------------------------------------
    # TEST 2: Variable Token Resolution
    # -------------------------------------------------------------------------
    $MockBp = [PSCustomObject]@{
        disks = [PSCustomObject]@{
            target_os_disk = [PSCustomObject]@{ drive_variable = "OS_DRIVE" }
            preserved_disks = @(
                [PSCustomObject]@{ drive_variable = "DATA_DRIVE"; expected_mount = "D:" }
            )
        }
        storage = [PSCustomObject]@{
            streaming = [PSCustomObject]@{ verify_folder = "E:\My Drive"; stream_variable = "STREAM" }
            sync = [PSCustomObject]@{
                directories = [PSCustomObject]@{
                    projects = [PSCustomObject]@{ sync_variable = "SYNC_PROJECTS"; local_path = "%DATA_DRIVE%\Dev\Projects" }
                }
            }
        }
        variables = [PSCustomObject]@{
            GAMES_DIR = "%DATA_DRIVE%\SteamLibrary"
        }
    }
    $VarMap = Get-BlueprintVariables -Blueprint $MockBp
    Assert-Test -Name "2. Variable Engine: resolves standard drive tokens (%OS_DRIVE%, %DATA_DRIVE%, %STREAM%)" `
        -Condition ($VarMap["OS_DRIVE"] -eq "C:" -and $VarMap["DATA_DRIVE"] -eq "D:" -and $VarMap["STREAM"] -eq "E:\My Drive")

    Assert-Test -Name "3. Variable Engine: resolves recursive nested variables (%SYNC_PROJECTS%, %GAMES_DIR%)" `
        -Condition ($VarMap["SYNC_PROJECTS"] -eq "D:\Dev\Projects" -and $VarMap["GAMES_DIR"] -eq "D:\SteamLibrary")

    $ResolvedString = Resolve-VariableString -InputString "%STREAM%\\Backups\\Save" -VariableMap $VarMap
    Assert-Test -Name "4. Variable Engine: normalizes consecutive backslashes cleanly" `
        -Condition ($ResolvedString -eq "E:\My Drive\Backups\Save")

    $Unresolved = Test-UnresolvedTokens -InputString "%INVALID_TOKEN%\file.txt"
    Assert-Test -Name "5. Variable Engine: detects unresolvable tokens" `
        -Condition ($Unresolved.Count -eq 1 -and $Unresolved[0] -eq "INVALID_TOKEN")

    # -------------------------------------------------------------------------
    # TEST 3: Semantic Blueprint Validation & Safety Rules
    # -------------------------------------------------------------------------
    # Test valid blueprint
    $ValidYamlFile = Join-Path $TestDir "valid.yaml"
    @"
version: "1.0.0"
system:
  computer_name: "TESTPC"
  users:
    local_admin:
      username: "LocalAdmin"
    primary_user:
      username: "developer"
      is_admin: false
disks:
  target_os_disk:
    disk_id: 0
    bus_type: "NVMe"
    serial_number: "NVME_OS_01"
  preserved_disks:
    - disk_id: 1
      bus_type: "SATA"
      serial_number: "SATA_DATA_01"
      expected_mount: "D:"
storage:
  streaming:
    mount_point: "E:"
    verify_folder: "E:\My Drive"
applications:
  spotify: {}
"@ | Set-Content -Path $ValidYamlFile -Encoding UTF8

    $ValResult = Test-ReglazeBlueprint -Path $ValidYamlFile -RepoRoot $RepoRoot
    Assert-Test -Name "6. Validator: accepts compliant blueprint with 0 errors" `
        -Condition ($ValResult.IsValid -eq $true -and $ValResult.Errors.Count -eq 0) `
        -Details ($ValResult.Errors -join '; ')

    # Test safety rule: safe_for_stream: false violation (e.g. Lightroom catalog target pointing to %STREAM%)
    $UnsafeYamlFile = Join-Path $TestDir "unsafe.yaml"
    @"
version: "1.0.0"
system:
  users:
    local_admin:
      username: "LocalAdmin"
    primary_user:
      username: "developer"
disks:
  target_os_disk:
    disk_id: 0
    serial_number: "NVME_OS_01"
storage:
  streaming:
    verify_folder: "E:\My Drive"
applications:
  adobe_lightroom:
    directories:
      catalog:
        target: "%STREAM%\Backups\Lightroom"
"@ | Set-Content -Path $UnsafeYamlFile -Encoding UTF8

    $UnsafeResult = Test-ReglazeBlueprint -Path $UnsafeYamlFile -RepoRoot $RepoRoot
    Assert-Test -Name "7. Validator: catches safe_for_stream: false safety violation" `
        -Condition ($UnsafeResult.IsValid -eq $false -and ($UnsafeResult.Errors -match "safe_for_stream")) `
        -Details ($UnsafeResult.Errors -join '; ')

    # Test disk conflict: Preserved disk ID matching target OS disk
    $ConflictYamlFile = Join-Path $TestDir "conflict.yaml"
    @"
version: "1.0.0"
system:
  users:
    local_admin:
      username: "LocalAdmin"
    primary_user:
      username: "developer"
disks:
  target_os_disk:
    disk_id: 1
    serial_number: "NVME_OS_01"
  preserved_disks:
    - disk_id: 1
      serial_number: "PRESERVED_01"
storage:
  streaming:
    verify_folder: "E:\My Drive"
"@ | Set-Content -Path $ConflictYamlFile -Encoding UTF8

    $ConflictResult = Test-ReglazeBlueprint -Path $ConflictYamlFile -RepoRoot $RepoRoot
    Assert-Test -Name "8. Validator: catches target OS disk and preserved disk index conflict" `
        -Condition ($ConflictResult.IsValid -eq $false -and ($ConflictResult.Errors -match "conflict")) `
        -Details ($ConflictResult.Errors -join '; ')

    # Test junction rule: Nested junction collision detection (parent-child conflict)
    $NestedYamlFile = Join-Path $TestDir "nested_junction.yaml"
    @"
version: "1.0.0"
system:
  users:
    local_admin:
      username: "LocalAdmin"
    primary_user:
      username: "developer"
disks:
  target_os_disk:
    disk_id: 0
    serial_number: "NVME_OS_01"
storage:
  streaming:
    mount_point: "E:"
    verify_folder: "E:\My Drive"
custom:
  - name: "CollisionTestApp"
    directories:
      - name: "parent_dir"
        link: "%LOCALAPPDATA%\TestApp\Saves"
        target: "%STREAM%\Backups\parent"
      - name: "child_dir"
        link: "%LOCALAPPDATA%\TestApp\Saves\SubFolder"
        target: "%STREAM%\Backups\child"
"@ | Set-Content -Path $NestedYamlFile -Encoding UTF8

    $NestedResult = Test-ReglazeBlueprint -Path $NestedYamlFile -RepoRoot $RepoRoot
    Assert-Test -Name "9. Validator: catches nested directory junction collision (child inside parent link)" `
        -Condition ($NestedResult.IsValid -eq $false -and ($NestedResult.Errors -match "Nested junction collision")) `
        -Details ($NestedResult.Errors -join '; ')

    # Test junction rule: Network UNC target rejection
    $UncYamlFile = Join-Path $TestDir "unc_junction.yaml"
    @"
version: "1.0.0"
system:
  users:
    local_admin:
      username: "LocalAdmin"
    primary_user:
      username: "developer"
disks:
  target_os_disk:
    disk_id: 0
    serial_number: "NVME_OS_01"
storage:
  streaming:
    mount_point: "E:"
    verify_folder: "E:\My Drive"
custom:
  - name: "Network Backup Test"
    directories:
      - name: "UNC Link"
        link: "%OS_DRIVE%\Data\Test"
        target: "\\\\nas\backups\test"
"@ | Set-Content -Path $UncYamlFile -Encoding UTF8

    $UncResult = Test-ReglazeBlueprint -Path $UncYamlFile -RepoRoot $RepoRoot
    Assert-Test -Name "10. Validator: rejects network UNC paths as junction targets (NTFS requirement)" `
        -Condition ($UncResult.IsValid -eq $false -and ($UncResult.Errors -match "UNC")) `
        -Details ($UncResult.Errors -join '; ')

    # Test junction rule: Target drive not defined in storage topology
    $BadDriveYamlFile = Join-Path $TestDir "baddrive_junction.yaml"
    @"
version: "1.0.0"
system:
  users:
    local_admin:
      username: "LocalAdmin"
    primary_user:
      username: "developer"
disks:
  target_os_disk:
    disk_id: 0
    serial_number: "NVME_OS_01"
storage:
  streaming:
    mount_point: "E:"
    verify_folder: "E:\My Drive"
custom:
  - name: "Unmapped Drive Test"
    directories:
      - name: "Z Drive Target"
        link: "%OS_DRIVE%\Data\Test"
        target: "Z:\UnmappedDrive\Folder"
"@ | Set-Content -Path $BadDriveYamlFile -Encoding UTF8

    $BadDriveResult = Test-ReglazeBlueprint -Path $BadDriveYamlFile -RepoRoot $RepoRoot
    Assert-Test -Name "11. Validator: flags target drive letters not declared in storage topology" `
        -Condition ($BadDriveResult.IsValid -eq $false -and ($BadDriveResult.Errors -match "not declared in blueprint storage topology")) `
        -Details ($BadDriveResult.Errors -join '; ')

    # Test sync directory rule: Synced directory cannot reside on virtual streaming mount (%STREAM%) or undeclared drive
    $BadSyncYamlFile = Join-Path $TestDir "badsync_drive.yaml"
    @"
version: "1.0.0"
profile: "workstation"
system:
  users:
    local_admin:
      username: "LocalAdmin"
    primary_user:
      username: "developer"
disks:
  target_os_disk:
    disk_id: 0
    serial_number: "NVME_OS_01"
  preserved_disks:
    - disk_id: 1
      serial_number: "SATA_01"
      expected_mount: "E:"
storage:
  streaming:
    mount_point: "E:"
    verify_folder: "E:\My Drive"
  sync:
    directories:
      bad_sync:
        local_path: "Z:\MissingDrive\Folder"
        cloud_folder: "Folder"
        sync_variable: "SYNC_BAD"
"@ | Set-Content -Path $BadSyncYamlFile -Encoding UTF8

    $BadSyncResult = Test-ReglazeBlueprint -Path $BadSyncYamlFile -RepoRoot $RepoRoot
    Assert-Test -Name "11b. Validator: catches streaming mount collision with preserved_disks and sync root on undeclared drive" `
        -Condition ($BadSyncResult.IsValid -eq $false -and ($BadSyncResult.Errors -match "Drive letter collision") -and ($BadSyncResult.Errors -match "undeclared physical drive")) `
        -Details ($BadSyncResult.Errors -join '; ')

    # Test junction inside synced directory warning (switches from sync to stream behavior)
    $SyncNestedJuncFile = Join-Path $TestDir "sync_nested_junc.yaml"
    @"
version: "1.0.0"
profile: "workstation"
system:
  users:
    local_admin:
      username: "LocalAdmin"
    primary_user:
      username: "developer"
disks:
  target_os_disk:
    disk_id: 0
    serial_number: "NVME_OS_01"
storage:
  streaming:
    mount_point: "E:"
    verify_folder: "E:\My Drive"
  sync:
    directories:
      documents:
        local_path: "C:\Users\developer\Documents"
        cloud_folder: "Documents"
        sync_variable: "SYNC_DOCUMENTS"
applications:
  lotro:
    directories:
      user_configs:
        target: "%STREAM%\Gaming\LOTRO"
"@ | Set-Content -Path $SyncNestedJuncFile -Encoding UTF8

    $SyncNestedResult = Test-ReglazeBlueprint -Path $SyncNestedJuncFile -RepoRoot $RepoRoot
    Assert-Test -Name "11c. Validator: emits warning (not error) when junction link is nested inside a synced directory" `
        -Condition ($SyncNestedResult.IsValid -eq $true -and [bool]($SyncNestedResult.Warnings -match "switches .* from sync behavior to stream")) `
        -Details ($SyncNestedResult.Warnings -join '; ')

    # Test user applications.json in blueprint config directory (validation + WinGet DSC + payload junctions)
    $UserCatDir = Join-Path $TestDir "user_cat_test"
    New-Item -ItemType Directory -Path $UserCatDir -Force | Out-Null
    $UserAppsFile = Join-Path $UserCatDir "applications.json"
    @(
        [PSCustomObject]@{
            app_id  = "my_user_app"
            name    = "My User App"
            website = "https://example.com"
            install = [PSCustomObject]@{
                method    = "winget"
                winget_id = "Example.MyUserApp"
            }
            directories = @(
                [PSCustomObject]@{
                    id                  = "settings"
                    description         = "User app settings"
                    default_path        = "%APPDATA%\MyUserApp"
                    category            = "configs"
                    needs_mapping       = $true
                    safe_for_stream     = $true
                    recommended_storage = "streaming"
                    notes               = "Flat config files."
                }
            )
        }
    ) | ConvertTo-Json -Depth 6 | Set-Content -Path $UserAppsFile -Encoding UTF8

    $UserCatYaml = Join-Path $UserCatDir "reglaze.yaml"
    @"
version: "1.0.0"
profile: "workstation"
system:
  computer_name: "TESTPC"
  users:
    local_admin:
      username: "LocalAdmin"
    primary_user:
      username: "developer"
disks:
  target_os_disk:
    disk_id: 0
    serial_number: "NVME_OS_01"
storage:
  streaming:
    mount_point: "E:"
    verify_folder: "E:\My Drive"
applications:
  my_user_app:
    directories:
      settings:
        target: "%STREAM%\Backups\my_user_app\settings"
  custom:
    - name: "Unrecognized Winget Tool"
      install:
        method: "winget"
        winget_id: "Vendor.UnrecognizedTool"
      directories: []
"@ | Set-Content -Path $UserCatYaml -Encoding UTF8

    $UserCatVal = Test-ReglazeBlueprint -Path $UserCatYaml -RepoRoot $RepoRoot
    $UserCatPayloadDir = Join-Path $UserCatDir "payload"
    $UserCatPayloadRes = Build-ReglazePayload -Blueprint $UserCatVal.Blueprint -RepoRoot $RepoRoot -PayloadDir $UserCatPayloadDir -BlueprintFile $UserCatYaml
    $UserCatDscContent = Get-Content -Raw $UserCatPayloadRes.DscPath
    $UserCatJuncs = Get-Content -Raw $UserCatPayloadRes.JunctionsPath | ConvertFrom-Json

    Assert-Test -Name "11d. User Catalog & Custom Apps: loads <config-dir>/applications.json and compiles DSC + junctions without unknown-app warnings" `
        -Condition (
            $UserCatVal.IsValid -eq $true -and
            $UserCatVal.Warnings.Count -eq 0 -and
            $UserCatDscContent -match "Example\.MyUserApp" -and
            $UserCatDscContent -match "Vendor\.UnrecognizedTool" -and
            $UserCatJuncs.Count -eq 1 -and
            $UserCatJuncs[0].AppId -eq "my_user_app"
        ) `
        -Details "Valid: $($UserCatVal.IsValid), Warnings: $($UserCatVal.Warnings -join '; '), JuncCount: $($UserCatJuncs.Count)"

    # -------------------------------------------------------------------------
    # TEST 4: WinGet DSC Manifest Generator
    # -------------------------------------------------------------------------
    $DscBlueprint = [PSCustomObject]@{
        applications = [PSCustomObject]@{
            spotify = [PSCustomObject]@{}
            python3 = [PSCustomObject]@{}
            nvidia_app = [PSCustomObject]@{}
            outfox = [PSCustomObject]@{} # method manual - should be excluded
            disabled_app = [PSCustomObject]@{ install = $false }
        }
        custom = @(
            [PSCustomObject]@{
                name = "Custom Tool"
                install = [PSCustomObject]@{ method = "winget"; package_id = "Custom.Package" }
            }
        )
    }
    $DscOut = Join-Path $TestDir "configuration.dsc.yaml"
    $DscResult = Build-WinGetDSCManifest -Blueprint $DscBlueprint -RepoRoot $RepoRoot -OutputPath $DscOut
    $DscContent = Get-Content -Raw $DscOut

    Assert-Test -Name "12. WinGet DSC: compiles valid DSC YAML schema with expected package entries" `
        -Condition ($DscContent -match "Spotify\.Spotify" -and $DscContent -match "Python\.Python\.3\.12" -and $DscContent -match "Custom\.Package")

    Assert-Test -Name "13. WinGet DSC: assigns msstore source to Microsoft Store IDs (NVIDIA App)" `
        -Condition ($DscContent -match 'id: "XP8CLZL93F5Z4P"[\s\S]*?source: msstore')

    Assert-Test -Name "14. WinGet DSC: excludes manual install apps and disabled apps" `
        -Condition ($DscContent -notmatch "outfox" -and $DscContent -notmatch "disabled_app")

    # -------------------------------------------------------------------------
    # TEST 5: autounattend.xml Generator
    # -------------------------------------------------------------------------
    $XmlOut = Join-Path $TestDir "autounattend.xml"
    $AuditMock = [PSCustomObject]@{
        system_and_licensing = [PSCustomObject]@{
            installed_product_key = "VK7JG-NPHTM-C97JM-9MPGT-3V66T"
        }
    }
    Build-AutounattendXml -Blueprint $ValResult.Blueprint -AuditReference $AuditMock -OutputPath $XmlOut | Out-Null
    
    $XmlParsed = $null
    $XmlValid = $false
    try {
        [xml]$XmlParsed = Get-Content -Raw $XmlOut
        $XmlValid = ($null -ne $XmlParsed.unattend)
    } catch {
        $XmlValid = $false
    }
    Assert-Test -Name "15. autounattend.xml: parses as valid well-formed XML" `
        -Condition $XmlValid

    $AutoLogonUser = $XmlParsed.unattend.settings | Where-Object { $_.pass -eq "oobeSystem" } | 
        ForEach-Object { $_.component } | Where-Object { $_.name -eq "Microsoft-Windows-Shell-Setup" } |
        ForEach-Object { $_.AutoLogon.Username }

    $WinPeSetup = $XmlParsed.unattend.settings | Where-Object { $_.pass -eq "windowsPE" } |
        ForEach-Object { $_.component } | Where-Object { $_.name -eq "Microsoft-Windows-Setup" }
    $RunSyncPath = $WinPeSetup.RunSynchronous.RunSynchronousCommand.Path
    $ImageUi = $WinPeSetup.ImageInstall.OSImage.WillShowUI

    Assert-Test -Name "16. autounattend.xml: configures AutoLogon for LocalAdmin and WinPE target preparation command" `
        -Condition ($AutoLogonUser -eq "LocalAdmin" -and $ImageUi -eq "Always" -and $RunSyncPath -match "prepare-target-disk\.cmd")

    # -------------------------------------------------------------------------
    # TEST 6: WinPE Disk Matching & Preserved Safety
    # -------------------------------------------------------------------------
    $FirstDisk = try { Get-PhysicalDisk -ErrorAction Stop | Select-Object -First 1 } catch { $null }
    $MockDiskList = $null
    if (-not $FirstDisk) {
        $FirstDisk = [PSCustomObject]@{ DeviceId = 0; FriendlyName = "Simulated NVMe SSD"; SerialNumber = "SIM_NVME_001"; BusType = "NVMe"; Size = 1000GB }
        $MockDiskList = @($FirstDisk)
    }
    $TargetId = [int]$FirstDisk.DeviceId
    $TargetSer = [string]$FirstDisk.SerialNumber

    $DiskpartOut = Join-Path $TestDir "diskpart.txt"
    $DiskMatchResult = Invoke-DiskMatching -TargetSerialNumber $TargetSer -TargetDiskId $TargetId -PreservedSerialNumbers @("PRESERVED_SAMPLE_999") -DiskpartOutputPath $DiskpartOut -MockDisks $MockDiskList
    Assert-Test -Name "17. DiskMatch: dynamically matches target disk and generates GPT/EFI/MSR/OS/Recovery diskpart layout" `
        -Condition ((Test-Path $DiskpartOut) -and ((Get-Content -Raw $DiskpartOut) -match "create partition efi") -and ($DiskMatchResult.TargetDiskIndex -eq $TargetId))

    $SafetyHaltCaught = $false
    try {
        Invoke-DiskMatching -TargetSerialNumber $TargetSer -TargetDiskId $TargetId -PreservedSerialNumbers @($TargetSer) -DiskpartOutputPath $DiskpartOut -MockDisks $MockDiskList | Out-Null
    } catch {
        $SafetyHaltCaught = ($_.Exception.Message -match "PRESERVED DISKS")
    }
    Assert-Test -Name "18. DiskMatch: halts setup immediately if target disk is in preserved serial numbers" `
        -Condition $SafetyHaltCaught

    # -------------------------------------------------------------------------
    # TEST 7: Deployment Payload Generator
    # -------------------------------------------------------------------------
    $PayloadOut = Join-Path $TestDir "payload"
    $PayloadRes = Build-ReglazePayload -Blueprint $ValResult.Blueprint -AuditReference $AuditMock -RepoRoot $RepoRoot -PayloadDir $PayloadOut
    Assert-Test -Name "19. Payload: generates all required provisioning artifacts (bootstrap, hydrate, disk-config, google-drive-setup, WSL, DSC, manifest)" `
        -Condition (
            (Test-Path (Join-Path $PayloadOut "bootstrap.ps1")) -and
            (Test-Path (Join-Path $PayloadOut "hydrate.ps1")) -and
            (Test-Path (Join-Path $PayloadOut "disk-config.json")) -and
            (Test-Path (Join-Path $PayloadOut "google-drive-setup.json")) -and
            (Test-Path (Join-Path $PayloadOut "google-drive-guide.md")) -and
            (Test-Path (Join-Path $PayloadOut "Set-ReglazeDriveLetters.ps1")) -and
            (Test-Path (Join-Path $PayloadOut "setup-wsl.sh")) -and
            (Test-Path (Join-Path $PayloadOut "configuration.dsc.yaml")) -and
            (Test-Path (Join-Path $PayloadOut "junctions-manifest.json")) -and
            (Test-Path (Join-Path $PayloadOut "bitlocker-keys.json")) -and
            (Test-Path (Join-Path $PayloadOut "applications.json"))
        )

    $GDrivePayload = Get-Content -Raw (Join-Path $PayloadOut "google-drive-setup.json") | ConvertFrom-Json
    Assert-Test -Name "19b. Payload: renders Google Drive setup template payload with target mount and source computer" `
        -Condition ($GDrivePayload.StreamMountPoint -eq "E:" -and $GDrivePayload.SourceComputerName -eq "TESTPC" -and $GDrivePayload.MigrationMode -eq "copy" -and ($GDrivePayload.RenderedInstructions -join ' ') -notmatch '\{\{')

    $WslScriptContent = Get-Content -Raw (Join-Path $PayloadOut "setup-wsl.sh")
    Assert-Test -Name "20. WSL Provisioner: defaults to primary Windows username ('developer')" `
        -Condition ($WslScriptContent -match 'WSL_USER="developer"' -and $WslScriptContent -match 'default = developer')

    # -------------------------------------------------------------------------
    # TEST 8: Full End-to-End Compile Command
    # -------------------------------------------------------------------------
    $E2EMedia = Join-Path $TestDir "media_e2e"
    $CompileRes = Invoke-ReglazeCompilation -ConfigFile $ValidYamlFile -DistDir $E2EMedia -AuditReferencePath $null -BypassValidation $false
    Assert-Test -Name "21. End-to-End Compile: generates media tree with autounattend.xml and staged DiskMatch tools" `
        -Condition (
            $CompileRes.Status -eq "Success" -and
            (Test-Path (Join-Path $E2EMedia "autounattend.xml")) -and
            (Test-Path (Join-Path $E2EMedia "Reglaze\DiskMatch.vbs")) -and
            (Test-Path (Join-Path $E2EMedia "Reglaze\protect-disks.cmd")) -and
            (Test-Path (Join-Path $E2EMedia "Reglaze\DiskMatch.ps1")) -and
            (Test-Path (Join-Path $E2EMedia "Reglaze\prepare-target-disk.cmd")) -and
            (Test-Path (Join-Path $E2EMedia "Reglaze\prepare-target-disk.vbs")) -and
            (Test-Path (Join-Path $E2EMedia "Reglaze\payload\bootstrap.ps1"))
        )

    # -------------------------------------------------------------------------
    # TEST 9: Windows 11 ISO Discovery & Download Simulation
    # -------------------------------------------------------------------------
    $IsoSimRes = Get-Windows11Iso -DestinationDir (Join-Path $TestDir "downloads") -Simulation:$true
    Assert-Test -Name "22. ISO Acquisition: simulates official Windows 11 ISO discovery and destination resolution" `
        -Condition ($IsoSimRes.Status -in @("Simulated", "Found") -and ($IsoSimRes.IsoPath -like "*Win11*.iso" -or $IsoSimRes.IsoPath -like "*Windows11*.iso")) `
        -Details "Status: $($IsoSimRes.Status), Path: $($IsoSimRes.IsoPath)"

    # -------------------------------------------------------------------------
    # TEST 10: UEFI Bootable Media Builder Simulation
    # -------------------------------------------------------------------------
    $MediaSimRes = New-ReglazeBootableUsb -UsbDrive "E:" -IsoPath $IsoSimRes.IsoPath -MediaArtifactsDir $E2EMedia -Simulation:$true
    Assert-Test -Name "23. Media Builder: creates vanilla UEFI bootable USB payload with FAT32 & DISM split simulation" `
        -Condition ($MediaSimRes.Status -eq "Success" -and $MediaSimRes.Format -eq "FAT32" -and $MediaSimRes.IsSimulated -eq $true) `
        -Details "Status: $($MediaSimRes.Status), Format: $($MediaSimRes.Format)"

    # -------------------------------------------------------------------------
    # TEST 11: Safety Constraint - Target USB Rejects System Drive
    # -------------------------------------------------------------------------
    $RejectedC = $false
    try {
        Test-ValidUsbDrive -DriveLetter "C:"
    } catch {
        $RejectedC = ($_.Exception.Message -match "CRITICAL SAFETY VIOLATION")
    }
    Assert-Test -Name "24. Media Safety: Test-ValidUsbDrive strictly rejects C: system drive with critical safety violation" `
        -Condition $RejectedC `
        -Details "Rejected C: $RejectedC"

    # -------------------------------------------------------------------------
    # TEST 12: Dynamic Most Recent ISO Selection
    # -------------------------------------------------------------------------
    $MultiIsoDir = Join-Path $TestDir "multi_iso"
    New-Item -ItemType Directory -Path $MultiIsoDir -Force | Out-Null
    $OlderIsoPath = Join-Path $MultiIsoDir "Win11_23H2_English_x64.iso"
    $NewerIsoPath = Join-Path $MultiIsoDir "Win11_24H2_English_x64.iso"

    $Stream1 = [System.IO.File]::Create($OlderIsoPath); $Stream1.SetLength(4GB); $Stream1.Close()
    $Stream2 = [System.IO.File]::Create($NewerIsoPath); $Stream2.SetLength(4GB); $Stream2.Close()
    (Get-Item $OlderIsoPath).LastWriteTime = (Get-Date).AddDays(-30)
    (Get-Item $NewerIsoPath).LastWriteTime = (Get-Date)

    $SelectedIso = Find-LocalWindowsIso -SearchDir $MultiIsoDir
    Assert-Test -Name "25. ISO Selection: Find-LocalWindowsIso scans candidates and selects the most recent release" `
        -Condition ($SelectedIso -eq $NewerIsoPath) `
        -Details "Selected: $SelectedIso, Expected: $NewerIsoPath"

    # -------------------------------------------------------------------------
    # TEST 13: Pre-Install Migration Planner & Multi-Threaded Robocopy Staging
    # -------------------------------------------------------------------------
    $MigRoot = Join-Path $TestDir "migration_test"
    $MigSourceUser = Join-Path $MigRoot "source_user"
    $MigStreamRoot = Join-Path $MigRoot "stream_drive"
    $MigSyncRoot   = Join-Path $MigRoot "sync_drive"
    $MigDataRoot   = Join-Path $MigRoot "data_drive"
    $MigCfgDir     = Join-Path $MigRoot "config"

    New-Item -ItemType Directory -Path $MigCfgDir -Force | Out-Null

    # Create mock source directories and files
    $MockVscodeDir = Join-Path $MigSourceUser "AppData\Roaming\Code\User"
    $MockEmulatorDir  = Join-Path $MigSourceUser "AppData\Roaming\CustomEmulator"
    $MockMediaDir  = Join-Path $MigSourceUser "AppData\Local\MediaTool\Cache"
    $MockGitConfig = Join-Path $MigSourceUser ".gitconfig"

    New-Item -ItemType Directory -Path $MockVscodeDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $MockEmulatorDir "game1") -Force | Out-Null
    New-Item -ItemType Directory -Path $MockMediaDir -Force | Out-Null

    Set-Content -Path (Join-Path $MockVscodeDir "settings.json") -Value '{"editor.fontSize": 14}' -Encoding UTF8
    Set-Content -Path (Join-Path $MockEmulatorDir "game1\save1.dat") -Value 'EMULATOR_SAVE_DATA_12345' -Encoding UTF8
    Set-Content -Path (Join-Path $MockMediaDir "cache.bin") -Value 'SKIP_THIS_LARGE_CONTENT' -Encoding UTF8
    Set-Content -Path $MockGitConfig -Value "[user]`n`tname = Developer" -Encoding UTF8

    $EscSourceUser = $MigSourceUser -replace '\\', '\\'
    $EscStreamRoot = $MigStreamRoot -replace '\\', '\\'
    $EscSyncRoot   = $MigSyncRoot -replace '\\', '\\'
    $EscDataRoot   = $MigDataRoot -replace '\\', '\\'

    $MigBlueprintYaml = @"
profile: "workstation"
variables:
  USER_DIR: "$EscSourceUser"
  STREAM: "$EscStreamRoot"
  SYNC_JUNCTIONS: "$EscSyncRoot"
  DATA_DRIVE: "$EscDataRoot"
system:
  computer_name: "WORKSTATION-01"
  username: "developer"
storage:
  sync:
    provider: "google_drive"
    source_computer: "WORKSTATION-01"
    directories:
      projects:
        local_path: "%SYNC_JUNCTIONS%"
        cloud_folder: "SyncJunctions"
        sync_variable: "SYNC_JUNCTIONS"
applications:
  vscode:
    directories:
      user_settings:
        target: "%STREAM%\\vscode\\user_settings"
  git:
    directories:
      gitconfig:
        target: "%STREAM%\\git\\gitconfig"
  custom:
    - name: "CustomEmulator"
      directories:
        - name: "Emulator Saves"
          storage_type: "streaming"
          link: "%USER_DIR%\\AppData\\Roaming\\CustomEmulator"
          target: "%STREAM%\\CustomEmulator\\saves"
    - name: "MediaTool"
      directories:
        - name: "Media Cache"
          storage_type: "local_preserved"
          link: "%USER_DIR%\\AppData\\Local\\MediaTool\\Cache"
          target: "%DATA_DRIVE%\\MediaCache"
"@
    $MigBpPath = Join-Path $MigCfgDir "reglaze.yaml"
    Set-Content -Path $MigBpPath -Value $MigBlueprintYaml -Encoding UTF8

    $PlanResult = New-ReglazeMigrationPlan -ConfigFile $MigBpPath -RepoRoot $RepoRoot -Force
    Assert-Test -Name "26. Migration Planner: New-ReglazeMigrationPlan generates migration-manifest.yaml with measured file counts & sizes" `
        -Condition ((Test-Path $PlanResult.ManifestPath) -and $PlanResult.ItemCount -eq 4 -and $PlanResult.TotalCloudBytes -gt 0 -and $PlanResult.LocalBytes -gt 0) `
        -Details "Items: $($PlanResult.ItemCount), CloudBytes: $($PlanResult.TotalCloudBytes), LocalBytes: $($PlanResult.LocalBytes)"

    # Simulate user editing migration-manifest.yaml to disable MediaTool content transfer
    $ManifestRaw = Get-Content -Raw -Path $PlanResult.ManifestPath -Encoding UTF8
    $EditedManifest = $ManifestRaw -replace '(?ms)(id: "custom\.mediatool\.media_cache".*?enabled:\s*)true', '${1}false'
    Set-Content -Path $PlanResult.ManifestPath -Value $EditedManifest -Encoding UTF8

    $StageResult = Invoke-ReglazePreInstallMigration -ManifestPath $PlanResult.ManifestPath -Threads 8
    $ExpectedVscodeTarget = Join-Path $MigStreamRoot "vscode\user_settings\settings.json"
    $ExpectedEmulatorTarget  = Join-Path $MigStreamRoot "CustomEmulator\saves\game1\save1.dat"
    $ExpectedGitTarget    = Join-Path $MigStreamRoot "git\gitconfig\.gitconfig"
    $DisabledMediaTarget  = Join-Path $MigDataRoot "MediaCache\cache.bin"

    Assert-Test -Name "27. Migration Staging: Invoke-ReglazePreInstallMigration copies enabled items via Robocopy and skips user-disabled items" `
        -Condition (
            $StageResult.Status -eq "Success" -and
            $StageResult.CopiedCount -eq 3 -and
            $StageResult.SkippedDisabled -eq 1 -and
            (Test-Path $MigSyncRoot) -and
            (Test-Path $ExpectedVscodeTarget) -and
            (Test-Path $ExpectedEmulatorTarget) -and
            (Test-Path $ExpectedGitTarget) -and
            -not (Test-Path $DisabledMediaTarget)
        ) `
        -Details "Status: $($StageResult.Status), Copied: $($StageResult.CopiedCount), SkippedDisabled: $($StageResult.SkippedDisabled)"

    # -------------------------------------------------------------------------
    # TEST 11: WinPE Disk Isolation (DiskMatch.vbs & protect-disks.cmd)
    # -------------------------------------------------------------------------
    $VbsScript = Join-Path $RepoRoot "src\compiler\DiskMatch.vbs"
    $CmdScript = Join-Path $RepoRoot "src\compiler\protect-disks.cmd"
    $VbsContent = if (Test-Path $VbsScript) { Get-Content -Raw $VbsScript } else { "" }
    $CmdContent = if (Test-Path $CmdScript) { Get-Content -Raw $CmdScript } else { "" }

    $VbsValid = ($VbsContent -match "Win32_DiskDrive" -and $VbsContent -match "offline disk" -and $VbsContent -match "attribute disk set readonly" -and $VbsContent -match "GetDiskIndexForDriveLetter")
    $CmdValid = ($CmdContent -match "cscript\.exe" -and $CmdContent -match "DiskMatch\.vbs" -and $CmdContent -match "diskpart\.exe /s")

    Assert-Test -Name "28. WinPE Disk Isolation: DiskMatch.vbs & protect-disks.cmd implement non-PowerShell disk protection" `
        -Condition ($VbsValid -and $CmdValid) `
        -Details "VbsValid: $VbsValid, CmdValid: $CmdValid"

    # -------------------------------------------------------------------------
    # TEST 11b: WinPE Target Disk Preparation (prepare-target-disk.cmd & vbs)
    # -------------------------------------------------------------------------
    $PrepCmd = Join-Path $RepoRoot "src\compiler\prepare-target-disk.cmd"
    $PrepVbs = Join-Path $RepoRoot "src\compiler\prepare-target-disk.vbs"
    $PrepCmdContent = if (Test-Path $PrepCmd) { Get-Content -Raw $PrepCmd } else { "" }
    $PrepVbsContent = if (Test-Path $PrepVbs) { Get-Content -Raw $PrepVbs } else { "" }

    $PrepValid = ($PrepCmdContent -match "prepare-target-disk\.vbs" -and
                  $PrepCmdContent -match "diskpart\.exe /s" -and
                  $PrepCmdContent -match "Are you sure you want to clean and partition" -and
                  $PrepVbsContent -match "Win32_DiskDrive" -and
                  $PrepVbsContent -match "create partition efi size=100" -and
                  $PrepVbsContent -match "de94bba4-06d1-4d40-a16a-bfd50179d6ac")

    Assert-Test -Name "28b. WinPE Target Preparation: prepare-target-disk.cmd & prepare-target-disk.vbs implement interactive UEFI/GPT partition layout" `
        -Condition $PrepValid `
        -Details "PrepValid: $PrepValid"

    # -------------------------------------------------------------------------
    # TEST 12: Phase 4 Bootstrap Onlining of Offline Preserved Disks
    # -------------------------------------------------------------------------
    . (Join-Path $RepoRoot "src\linking\Set-ReglazeDriveLetters.ps1")
    $MockPreservedCfg = [PSCustomObject]@{
        PreservedDisks = @(
            [PSCustomObject]@{
                DiskId        = 1
                SerialNumber  = "OFFLINE_DATA_DISK_001"
                ExpectedMount = "D:"
                Label         = "DataDrive"
            },
            [PSCustomObject]@{
                DiskId        = 2
                SerialNumber  = "OFFLINE_UNMOUNTED_002"
                ExpectedMount = $null
                Label         = "UnmountedBackup"
            }
        )
        StreamMountPoint  = "G:"
        ReferencedLetters = @("C", "D", "G")
    }
    $MockDisksForOnline = @(
        [PSCustomObject]@{
            DiskNumber   = 0
            SerialNumber = "OS_DISK_000"
            BusType      = "NVMe"
            IsOffline    = $false
            IsReadOnly   = $false
            Partitions   = @(
                [PSCustomObject]@{ DiskNumber = 0; PartitionNumber = 3; DriveLetter = "C"; Label = "Windows"; SizeBytes = 500GB }
            )
        },
        [PSCustomObject]@{
            DiskNumber   = 1
            SerialNumber = "OFFLINE_DATA_DISK_001"
            BusType      = "SATA"
            IsOffline    = $true
            IsReadOnly   = $true
            Partitions   = @(
                [PSCustomObject]@{ DiskNumber = 1; PartitionNumber = 1; DriveLetter = "D"; Label = "DataDrive"; SizeBytes = 1000GB }
            )
        },
        [PSCustomObject]@{
            DiskNumber   = 2
            SerialNumber = "OFFLINE_UNMOUNTED_002"
            BusType      = "SATA"
            IsOffline    = $true
            IsReadOnly   = $true
            Partitions   = @(
                [PSCustomObject]@{ DiskNumber = 2; PartitionNumber = 1; DriveLetter = $null; Label = "UnmountedBackup"; SizeBytes = 2000GB }
            )
        }
    )
    $OnlineTestRes = Invoke-DriveLetterReconciliation -DiskConfig $MockPreservedCfg -MockSystemDisks $MockDisksForOnline -Simulation:$true
    $Disk1BroughtOnline = ($OnlineTestRes.OnlinedDisks -contains 1)
    $Disk2RemainsOffline = ($OnlineTestRes.OnlinedDisks -notcontains 2)
    $SimDisk1 = $OnlineTestRes.SimulatedSystemDisks | Where-Object { $_.DiskNumber -eq 1 } | Select-Object -First 1
    $SimDisk2 = $OnlineTestRes.SimulatedSystemDisks | Where-Object { $_.DiskNumber -eq 2 } | Select-Object -First 1

    Assert-Test -Name "29. Phase 4 Reconciliation: Onlines configured preserved disks with ExpectedMount and leaves expected_mount:null offline" `
        -Condition (
            $Disk1BroughtOnline -and
            $Disk2RemainsOffline -and
            ($SimDisk1.IsOffline -eq $false) -and
            ($SimDisk1.IsReadOnly -eq $false) -and
            ($SimDisk2.IsOffline -eq $true)
        ) `
        -Details "OnlinedDisks: $($OnlineTestRes.OnlinedDisks -join ','), Disk1Offline: $($SimDisk1.IsOffline), Disk2Offline: $($SimDisk2.IsOffline)"

} finally {
    Remove-Item env:LOCAL_ADMIN_PASSWORD -ErrorAction SilentlyContinue
    # Cleanup temporary test files
    if (Test-Path $TestDir) {
        Remove-Item -Path $TestDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

Write-Host ""
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "MILESTONE 2 TEST RESULTS: $PassCount PASSED, $FailCount FAILED" -ForegroundColor $(if ($FailCount -eq 0) { "Green" } else { "Red" })
Write-Host "================================================================================" -ForegroundColor Cyan

if ($FailCount -gt 0) {
    exit 1
}
exit 0
