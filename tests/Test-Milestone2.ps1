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
  user: "kirkh"
  is_admin: false
"@
    $ParsedObj = ConvertFrom-ReglazeYaml -YamlText $SampleYaml
    Assert-Test -Name "1. YAML Parser: parses scalars, booleans, arrays, and nested maps" `
        -Condition ($ParsedObj.version -eq "1.0.0" -and $ParsedObj.enabled -eq $true -and $ParsedObj.tags.Count -eq 2 -and $ParsedObj.nested.user -eq "kirkh" -and $ParsedObj.nested.is_admin -eq $false)

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
      username: "kirkh"
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
      username: "kirkh"
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
      username: "kirkh"
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

    Assert-Test -Name "9. WinGet DSC: compiles valid DSC YAML schema with expected package entries" `
        -Condition ($DscContent -match "Spotify\.Spotify" -and $DscContent -match "Python\.Python\.3\.12" -and $DscContent -match "Custom\.Package")

    Assert-Test -Name "10. WinGet DSC: assigns msstore source to Microsoft Store IDs (NVIDIA App)" `
        -Condition ($DscContent -match 'id: "XP8CLZL93F5Z4P"[\s\S]*?source: msstore')

    Assert-Test -Name "11. WinGet DSC: excludes manual install apps and disabled apps" `
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

    Assert-Test -Name "12. autounattend.xml: parses as valid well-formed XML" `
        -Condition $XmlValid

    $AutoLogonUser = $XmlParsed.unattend.settings | Where-Object { $_.pass -eq "oobeSystem" } | 
        ForEach-Object { $_.component } | Where-Object { $_.name -eq "Microsoft-Windows-Shell-Setup" } |
        ForEach-Object { $_.AutoLogon.Username }

    Assert-Test -Name "13. autounattend.xml: configures AutoLogon for LocalAdmin" `
        -Condition ($AutoLogonUser -eq "LocalAdmin")

    # -------------------------------------------------------------------------
    # TEST 6: WinPE Disk Matching & Preserved Safety
    # -------------------------------------------------------------------------
    $FirstDisk = (Get-PhysicalDisk | Select-Object -First 1)
    $TargetId = [int]$FirstDisk.DeviceId
    $TargetSer = [string]$FirstDisk.SerialNumber

    $DiskpartOut = Join-Path $TestDir "diskpart.txt"
    $DiskMatchResult = Invoke-DiskMatching -TargetSerialNumber $TargetSer -TargetDiskId $TargetId -PreservedSerialNumbers @("PRESERVED_SAMPLE_999") -DiskpartOutputPath $DiskpartOut
    Assert-Test -Name "14. DiskMatch: dynamically matches target disk and generates GPT/EFI/MSR/OS/Recovery diskpart layout" `
        -Condition ((Test-Path $DiskpartOut) -and ((Get-Content -Raw $DiskpartOut) -match "create partition efi") -and ($DiskMatchResult.TargetDiskIndex -eq $TargetId))

    $SafetyHaltCaught = $false
    try {
        Invoke-DiskMatching -TargetSerialNumber $TargetSer -TargetDiskId $TargetId -PreservedSerialNumbers @($TargetSer) -DiskpartOutputPath $DiskpartOut | Out-Null
    } catch {
        $SafetyHaltCaught = ($_.Exception.Message -match "PRESERVED DISKS")
    }
    Assert-Test -Name "15. DiskMatch: halts setup immediately if target disk is in preserved serial numbers" `
        -Condition $SafetyHaltCaught

    # -------------------------------------------------------------------------
    # TEST 7: Deployment Payload Generator
    # -------------------------------------------------------------------------
    $PayloadOut = Join-Path $TestDir "payload"
    $PayloadRes = Build-ReglazePayload -Blueprint $ValResult.Blueprint -AuditReference $AuditMock -RepoRoot $RepoRoot -PayloadDir $PayloadOut
    Assert-Test -Name "16. Payload: generates all required provisioning artifacts (bootstrap, hydrate, WSL, DSC, manifest)" `
        -Condition (
            (Test-Path (Join-Path $PayloadOut "bootstrap.ps1")) -and
            (Test-Path (Join-Path $PayloadOut "hydrate.ps1")) -and
            (Test-Path (Join-Path $PayloadOut "setup-wsl.sh")) -and
            (Test-Path (Join-Path $PayloadOut "configuration.dsc.yaml")) -and
            (Test-Path (Join-Path $PayloadOut "junctions-manifest.json")) -and
            (Test-Path (Join-Path $PayloadOut "bitlocker-keys.json")) -and
            (Test-Path (Join-Path $PayloadOut "applications.json"))
        )

    # -------------------------------------------------------------------------
    # TEST 8: Full End-to-End Compile Command
    # -------------------------------------------------------------------------
    $E2EMedia = Join-Path $TestDir "media_e2e"
    $CompileRes = Invoke-ReglazeCompilation -ConfigFile $ValidYamlFile -TargetOutputDir $E2EMedia -AuditReferencePath $null -BypassValidation $false
    Assert-Test -Name "17. End-to-End Compile: generates media tree with autounattend.xml and staged DiskMatch.ps1" `
        -Condition (
            $CompileRes.Status -eq "Success" -and
            (Test-Path (Join-Path $E2EMedia "autounattend.xml")) -and
            (Test-Path (Join-Path $E2EMedia "Reglaze\DiskMatch.ps1")) -and
            (Test-Path (Join-Path $E2EMedia "payload\bootstrap.ps1"))
        )

} finally {
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
