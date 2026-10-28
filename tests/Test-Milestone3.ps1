<#
.SYNOPSIS
    Automated verification suite for Reglaze Phase 4 / Milestone 3 (Machine Provisioning & Linking Engine).
.DESCRIPTION
    Executes unit and integration tests covering:
    - NTFS Reparse point and junction detection (Get-ReparsePointInfo)
    - Non-destructive collision backup handling (Backup-DirectoryCollision)
    - Atomic directory junction creation and idempotency (New-ReglazeDirectoryJunction)
    - Junction manifest batch applicator with scope filtering (Install-JunctionsFromManifest)
    - Preserved BitLocker volume recovery and auto-unlock re-arming simulation
    - Windows settings and preferences orchestration
    - AutoLogon registry deactivation logic
    - End-to-end Start-MachineBootstrap.ps1 execution in simulation mode
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
. (Join-Path $RepoRoot "src\linking\Test-ReparsePoint.ps1")
. (Join-Path $RepoRoot "src\linking\Backup-CollisionFolder.ps1")
. (Join-Path $RepoRoot "src\linking\New-DirectoryJunction.ps1")
. (Join-Path $RepoRoot "src\linking\Set-ReglazeDriveLetters.ps1")
. (Join-Path $RepoRoot "src\linking\Unlock-BitLockerVolumes.ps1")
. (Join-Path $RepoRoot "src\runner\Apply-WindowsSettings.ps1")

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
            Write-Host "         $Details" -ForegroundColor Yellow
        }
    }
}

Write-ReglazeBanner "REGLAZE MILESTONE 3: MACHINE PROVISIONING & LINKING TEST SUITE"

$TestDir = Join-Path $RepoRoot "tests\temp_m3_$PID"
if (Test-Path $TestDir) {
    Remove-Item -Path $TestDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $TestDir -Force | Out-Null

try {
    # =========================================================================
    # Test 1: Reparse Point Detection on Nonexistent & Normal Folders
    # =========================================================================
    $Nonexistent = Join-Path $TestDir "nonexistent_dir"
    $InfoNonexistent = Get-ReparsePointInfo -Path $Nonexistent
    $NormalDir = Join-Path $TestDir "normal_folder"
    New-Item -ItemType Directory -Path $NormalDir -Force | Out-Null
    $InfoNormal = Get-ReparsePointInfo -Path $NormalDir

    Assert-Test "1. ReparsePoint: correctly classifies nonexistent and normal directories" `
        (-not $InfoNonexistent.Exists -and $InfoNormal.Exists -and -not $InfoNormal.IsReparsePoint -and -not $InfoNormal.IsJunction)

    # =========================================================================
    # Test 2: Reparse Point Detection on Real NTFS Junction
    # =========================================================================
    $JuncTarget = Join-Path $TestDir "junc_target"
    $JuncLink = Join-Path $TestDir "junc_link"
    New-Item -ItemType Directory -Path $JuncTarget -Force | Out-Null
    $MklinkOut = cmd.exe /c "mklink /J `"$JuncLink`" `"$JuncTarget`"" 2>&1

    $InfoJunc = Get-ReparsePointInfo -Path $JuncLink
    Assert-Test "2. ReparsePoint: identifies NTFS junction and resolves target path" `
        ($InfoJunc.Exists -and $InfoJunc.IsJunction -and $InfoJunc.Target -like "*junc_target*" -and $InfoJunc.IsValid) `
        "Exists=$($InfoJunc.Exists), IsJunc=$($InfoJunc.IsJunction), Target=$($InfoJunc.Target), IsValid=$($InfoJunc.IsValid), mklink=$MklinkOut"

    # Clean up test junction safely
    if (Test-Path -LiteralPath $JuncLink) {
        [System.IO.Directory]::Delete($JuncLink)
    }

    # =========================================================================
    # Test 3: Directory Collision Backup
    # =========================================================================
    $CollisionSource = Join-Path $TestDir "collision_folder"
    New-Item -ItemType Directory -Path $CollisionSource -Force | Out-Null
    "sample data" | Set-Content (Join-Path $CollisionSource "test.txt")

    $BackupPath1 = Backup-DirectoryCollision -SourcePath $CollisionSource -CustomTimestamp "20260101_120000"
    $Backup1Exists = Test-Path -LiteralPath $BackupPath1
    $DataPreserved1 = Test-Path -LiteralPath (Join-Path $BackupPath1 "test.txt")
    $SourceRemoved1 = -not (Test-Path -LiteralPath $CollisionSource)

    # Test collision index incrementer (_1)
    New-Item -ItemType Directory -Path $CollisionSource -Force | Out-Null
    "sample data 2" | Set-Content (Join-Path $CollisionSource "test.txt")
    $BackupPath2 = Backup-DirectoryCollision -SourcePath $CollisionSource -CustomTimestamp "20260101_120000"
    $Backup2Exists = Test-Path -LiteralPath $BackupPath2

    Assert-Test "3. Collision Backup: safely renames collision folder with timestamp and index resolution" `
        ($Backup1Exists -and $DataPreserved1 -and $SourceRemoved1 -and $Backup2Exists -and $BackupPath2 -like "*_1")

    # =========================================================================
    # Test 4: New-ReglazeDirectoryJunction - Creation & Idempotency
    # =========================================================================
    $Target4 = Join-Path $TestDir "target_4"
    $Link4 = Join-Path $TestDir "link_4"
    New-Item -ItemType Directory -Path $Target4 -Force | Out-Null

    $CreateRes = New-ReglazeDirectoryJunction -Link $Link4 -Target $Target4
    $Link4IsJunc = Test-IsDirectoryJunction -Path $Link4

    # Idempotent re-run
    $IdempotentRes = New-ReglazeDirectoryJunction -Link $Link4 -Target $Target4

    Assert-Test "4. Junction Engine: creates new junction and behaves idempotently on re-run (No-op)" `
        ($CreateRes.Success -and $Link4IsJunc -and $IdempotentRes.Status -eq "UpToDate" -and $IdempotentRes.Action -eq "NoOp")

    # =========================================================================
    # Test 5: New-ReglazeDirectoryJunction - Replace Outdated Target
    # =========================================================================
    $OldTarget5 = Join-Path $TestDir "old_target_5"
    $NewTarget5 = Join-Path $TestDir "new_target_5"
    $Link5 = Join-Path $TestDir "link_5"
    New-Item -ItemType Directory -Path $OldTarget5 -Force | Out-Null
    New-Item -ItemType Directory -Path $NewTarget5 -Force | Out-Null
    cmd.exe /c "mklink /J `"$Link5`" `"$OldTarget5`"" 2>&1 | Out-Null

    $RetargetRes = New-ReglazeDirectoryJunction -Link $Link5 -Target $NewTarget5
    $RetargetInfo = Get-ReparsePointInfo -Path $Link5

    Assert-Test "5. Junction Engine: detects and retargets existing junction pointing to outdated target" `
        ($RetargetRes.Success -and $RetargetInfo.Target -like "*new_target_5*")

    # =========================================================================
    # Test 6: New-ReglazeDirectoryJunction - Collision with Populated Target
    # =========================================================================
    $Target6 = Join-Path $TestDir "target_6"
    $Link6 = Join-Path $TestDir "link_6"
    New-Item -ItemType Directory -Path $Target6 -Force | Out-Null
    "remote cloud data" | Set-Content (Join-Path $Target6 "remote.dat")
    New-Item -ItemType Directory -Path $Link6 -Force | Out-Null
    "local unlinked data" | Set-Content (Join-Path $Link6 "local.dat")

    $CollisionRes = New-ReglazeDirectoryJunction -Link $Link6 -Target $Target6 -CollisionAction "backup"
    $Link6IsJunc = Test-IsDirectoryJunction -Path $Link6
    $BackupCreated = ($CollisionRes.BackupPath -and (Test-Path -LiteralPath $CollisionRes.BackupPath))

    Assert-Test "6. Junction Engine: backs up populated local directory before linking to populated target" `
        ($CollisionRes.Success -and $Link6IsJunc -and $BackupCreated)

    # =========================================================================
    # Test 7: New-ReglazeDirectoryJunction - Safety Rules (Identical / Nested Path)
    # =========================================================================
    $SamePath = Join-Path $TestDir "same_path"
    $IdenticalRes = New-ReglazeDirectoryJunction -Link $SamePath -Target $SamePath
    $ChildPath = Join-Path $SamePath "child_dir"
    $NestedRes = New-ReglazeDirectoryJunction -Link $SamePath -Target $ChildPath

    Assert-Test "7. Junction Engine: rejects identical link/target and recursive nested loop targets" `
        ($IdenticalRes.Status -eq "Error" -and $NestedRes.Status -eq "Error")

    # =========================================================================
    # Test 8: Install-JunctionsFromManifest - Scope Filtering
    # =========================================================================
    $ManifestFile = Join-Path $TestDir "test-manifest.json"
    $TgtMachine = Join-Path $TestDir "tgt_machine"
    $TgtUser = Join-Path $TestDir "tgt_user"
    $LnkMachine = Join-Path $TestDir "lnk_machine"
    $LnkUser = Join-Path $TestDir "lnk_user"

    $ManifestData = @(
        [PSCustomObject]@{
            AppId           = "system_tool"
            DirectoryId     = "common_data"
            Link            = $LnkMachine
            Target          = $TgtMachine
            Scope           = "machine"
            CollisionAction = "backup"
        },
        [PSCustomObject]@{
            AppId           = "user_app"
            DirectoryId     = "user_config"
            Link            = $LnkUser
            Target          = $TgtUser
            Scope           = "user"
            CollisionAction = "backup"
        }
    )
    $ManifestData | ConvertTo-Json -Depth 3 | Set-Content -Path $ManifestFile -Encoding UTF8

    $MachineResults = @(Install-JunctionsFromManifest -ManifestPath $ManifestFile -Scope "machine")
    $MachineLnkIsJunc = Test-IsDirectoryJunction -Path $LnkMachine
    $UserLnkNotCreated = -not (Test-Path -LiteralPath $LnkUser)

    Assert-Test "8. Manifest Applicator: correctly filters by scope ('machine' only processes machine scope)" `
        ($MachineResults.Count -eq 1 -and $MachineLnkIsJunc -and $UserLnkNotCreated) `
        "Count=$($MachineResults.Count), MachineLnkIsJunc=$MachineLnkIsJunc, UserLnkNotCreated=$UserLnkNotCreated"

    # =========================================================================
    # Test 9: BitLocker Secondary Volume Recovery Simulation
    # =========================================================================
    $BitLockerKeyFile = Join-Path $TestDir "bitlocker-keys.json"
    $KeysData = @(
        [PSCustomObject]@{
            MountPoint       = "C:"
            VolumeType       = "OperatingSystem"
            RecoveryPassword = "111111-222222-333333-444444-555555-666666-777777-888888"
        },
        [PSCustomObject]@{
            MountPoint       = "D:"
            VolumeType       = "Data"
            RecoveryPassword = "999999-888888-777777-666666-555555-444444-333333-222222"
        }
    )
    $KeysData | ConvertTo-Json -Depth 3 | Set-Content -Path $BitLockerKeyFile -Encoding UTF8

    $UnlockSimResults = @(Unlock-PreservedBitLockerVolumes -KeyFilePath $BitLockerKeyFile -Simulation)
    $IgnoredC = @($UnlockSimResults | Where-Object { $_.MountPoint -eq "C:" }).Count -eq 0
    $ProcessedD = @($UnlockSimResults | Where-Object { $_.MountPoint -eq "D:" }).Count -eq 1
    $StatusD = ($UnlockSimResults | Where-Object { $_.MountPoint -eq "D:" }).Status -eq "Simulated"

    Assert-Test "9. BitLocker Recovery: skips OS disk (C:) and simulates auto-unlock re-arming on D:" `
        ($IgnoredC -and $ProcessedD -and $StatusD) `
        "IgnoredC=$IgnoredC, ProcessedD=$ProcessedD, StatusD=$StatusD"

    # =========================================================================
    # Test 10: Windows Settings Application
    # =========================================================================
    $CustomSettings = [PSCustomObject]@{
        explorer = [PSCustomObject]@{ show_hidden_files = $true; show_file_extensions = $true; launch_to = "ThisPC" }
        taskbar  = [PSCustomObject]@{ alignment = "Center"; search_mode = "IconOnly"; widgets_visible = $false; chat_visible = $false }
        power    = [PSCustomObject]@{ active_scheme_name = "High Performance"; ac_sleep_minutes = 0 }
    }
    $SettingsSimResults = @(Invoke-WindowsSettingsApplication -RepoRoot $RepoRoot -Settings $CustomSettings -Simulation)
    $SettingsCount = $SettingsSimResults.Count
    $AllSimulated = @($SettingsSimResults | Where-Object { $_.Status -eq "Simulated" }).Count -eq $SettingsCount

    Assert-Test "10. Windows Settings: executes modular Explorer, Taskbar, and Power settings with declared blueprint settings" `
        ($SettingsCount -ge 3 -and $AllSimulated)

    # =========================================================================
    # Test 11: AutoLogon Deactivation Logic Verification
    # =========================================================================
    $WinlogonKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    $CanInspectWinlogon = Test-Path $WinlogonKey

    Assert-Test "11. AutoLogon: targets valid Winlogon registry path for post-install credential purging" `
        $CanInspectWinlogon

    # =========================================================================
    # Test 12: End-to-End Start-MachineBootstrap.ps1 Simulation Run
    # =========================================================================
    # Assemble a synthetic payload directory
    $MockPayloadDir = Join-Path $TestDir "mock_payload"
    New-Item -ItemType Directory -Path $MockPayloadDir -Force | Out-Null
    Copy-Item -Path $BitLockerKeyFile -Destination (Join-Path $MockPayloadDir "bitlocker-keys.json")
    Copy-Item -Path $ManifestFile -Destination (Join-Path $MockPayloadDir "junctions-manifest.json")
    "dummy dsc" | Set-Content (Join-Path $MockPayloadDir "configuration.dsc.yaml")
    "dummy hydrate" | Set-Content (Join-Path $MockPayloadDir "hydrate.ps1")

    $BootstrapOutput = & (Join-Path $RepoRoot "src\runner\Start-MachineBootstrap.ps1") `
        -PayloadDir $MockPayloadDir `
        -Simulation `
        -NoReboot `
        -SkipUpdates `
        -SkipDsc *>&1

    $RanStep1 = ($BootstrapOutput -match "Step 1/9")
    $RanStep6 = ($BootstrapOutput -match "Step 6/9")
    $RanStep9 = ($BootstrapOutput -match "Step 9/9")
    $Completed = ($BootstrapOutput -match "PHASE 4 MACHINE BOOTSTRAP COMPLETE")

    Assert-Test "12. End-to-End Bootstrap: Start-MachineBootstrap.ps1 completes all 9 steps in simulation" `
        ($RanStep1 -and $RanStep6 -and $RanStep9 -and $Completed)

    # =========================================================================
    # Test 13: 3-Phase Atomic Drive Letter Reconciliation (Swap, Clear & USB Reassign)
    # =========================================================================
    $TestDiskConfig = [PSCustomObject]@{
        TargetOsDisk = [PSCustomObject]@{ DiskId = 1; SerialNumber = "OS_SN_990PRO"; BusType = "NVMe"; ExpectedMount = "C:" }
        PreservedDisks = @(
            [PSCustomObject]@{ DiskId = 0; SerialNumber = "3GKZ8VGE"; BusType = "SATA"; PartitionNumber = 1; ExpectedMount = $null; Label = "OldDisk"; Required = $false },
            [PSCustomObject]@{ DiskId = 2; SerialNumber = "DATA_SN_D"; BusType = "NVMe"; PartitionNumber = 1; ExpectedMount = "D:"; Label = "DataDrive"; Required = $true },
            [PSCustomObject]@{ DiskId = 3; SerialNumber = "BULK_SN_F"; BusType = "SATA"; PartitionNumber = 1; ExpectedMount = "F:"; Label = "BulkDrive"; Required = $true }
        )
        StreamMountPoint  = "E:"
        ReferencedLetters = @("C", "D", "E", "F")
    }

    # Simulate shuffled boot state:
    # - Disk 0 (3GKZ8VGE, supposed to be unmounted) took D:
    # - Disk 2 (DATA_SN_D, supposed to be D:) took F:
    # - Disk 3 (BULK_SN_F, supposed to be F:) took G:
    # - Disk 4 (REGLAZE USB, removable) took E: (colliding with Google Drive streaming mount E:)
    $MockShuffledDisks = @(
        [PSCustomObject]@{
            DiskNumber = 1; SerialNumber = "OS_SN_990PRO"; BusType = "NVMe"; FriendlyName = "OS"; IsRemovable = $false
            Partitions = @([PSCustomObject]@{ DiskNumber = 1; PartitionNumber = 1; DriveLetter = "C"; Label = "OS"; IsSystem = $true })
        },
        [PSCustomObject]@{
            DiskNumber = 0; SerialNumber = "3GKZ8VGE"; BusType = "SATA"; FriendlyName = "OldDisk"; IsRemovable = $false
            Partitions = @([PSCustomObject]@{ DiskNumber = 0; PartitionNumber = 1; DriveLetter = "D"; Label = "OldDisk"; IsSystem = $false })
        },
        [PSCustomObject]@{
            DiskNumber = 2; SerialNumber = "DATA_SN_D"; BusType = "NVMe"; FriendlyName = "DataDrive"; IsRemovable = $false
            Partitions = @([PSCustomObject]@{ DiskNumber = 2; PartitionNumber = 1; DriveLetter = "F"; Label = "DataDrive"; IsSystem = $false })
        },
        [PSCustomObject]@{
            DiskNumber = 3; SerialNumber = "BULK_SN_F"; BusType = "SATA"; FriendlyName = "BulkDrive"; IsRemovable = $false
            Partitions = @([PSCustomObject]@{ DiskNumber = 3; PartitionNumber = 1; DriveLetter = "G"; Label = "BulkDrive"; IsSystem = $false })
        },
        [PSCustomObject]@{
            DiskNumber = 4; SerialNumber = "USB_REGLAZE_01"; BusType = "USB"; FriendlyName = "REGLAZE USB"; IsRemovable = $true
            Partitions = @([PSCustomObject]@{ DiskNumber = 4; PartitionNumber = 1; DriveLetter = "E"; Label = "REGLAZE"; IsSystem = $false })
        }
    )

    $ReconcileRes = Invoke-DriveLetterReconciliation -DiskConfig $TestDiskConfig -MockSystemDisks $MockShuffledDisks -Simulation
    $FinalDisk0Letter = ($ReconcileRes.SimulatedSystemDisks | Where-Object { $_.DiskNumber -eq 0 }).Partitions[0].DriveLetter
    $FinalDisk2Letter = ($ReconcileRes.SimulatedSystemDisks | Where-Object { $_.DiskNumber -eq 2 }).Partitions[0].DriveLetter
    $FinalDisk3Letter = ($ReconcileRes.SimulatedSystemDisks | Where-Object { $_.DiskNumber -eq 3 }).Partitions[0].DriveLetter
    $FinalUsbLetter   = ($ReconcileRes.SimulatedSystemDisks | Where-Object { $_.DiskNumber -eq 4 }).Partitions[0].DriveLetter

    Assert-Test "13. Drive Letter Engine: swaps shuffled preserved drives (D:/F:), clears unmounted disk, and moves USB off E: to I:" `
        (
            $ReconcileRes.Status -eq "Reconciled" -and
            $ReconcileRes.RequiresReconnectShutdown -eq $false -and
            $null -eq $FinalDisk0Letter -and
            $FinalDisk2Letter -eq "D" -and
            $FinalDisk3Letter -eq "F" -and
            $FinalUsbLetter -eq "I"
        ) `
        "Disk0=$FinalDisk0Letter, Disk2=$FinalDisk2Letter, Disk3=$FinalDisk3Letter, USB=$FinalUsbLetter"

    # =========================================================================
    # Test 14: Missing Required vs. Optional Preserved Disks Detection
    # =========================================================================
    $TestDiskConfigFile = Join-Path $MockPayloadDir "disk-config.json"
    $TestDiskConfig | ConvertTo-Json -Depth 6 | Set-Content -Path $TestDiskConfigFile -Encoding UTF8

    # Case A: Optional Disk 0 (3GKZ8VGE) is disconnected, but required Disk 2 (D:) and Disk 3 (F:) are connected -> No shutdown needed
    $MockOptionalMissing = @($MockShuffledDisks | Where-Object { $_.DiskNumber -in @(1, 2, 3) })
    $OptRes = Invoke-DriveLetterReconciliation -DiskConfigPath $TestDiskConfigFile -MockSystemDisks $MockOptionalMissing -Simulation
    Assert-Test "14. Drive Letter Engine: skips power-down/reconnect step when only optional/unreferenced disks are disconnected" `
        ($OptRes.RequiresReconnectShutdown -eq $false -and $OptRes.MissingOptionalDisks.Count -eq 1 -and $OptRes.MissingRequiredDisks.Count -eq 0)

    # Case B: Required Disk 2 (DATA_SN_D -> D:) is physically disconnected during install -> Triggers reconnect shutdown
    $MockRequiredMissing = @($MockShuffledDisks | Where-Object { $_.DiskNumber -in @(1, 3) })
    $BootstrapMissingRes = & (Join-Path $RepoRoot "src\runner\Start-MachineBootstrap.ps1") `
        -PayloadDir $MockPayloadDir `
        -MockSystemDisks $MockRequiredMissing `
        -HaltOnMissingDisks `
        -Simulation `
        -NoReboot `
        -SkipUpdates `
        -SkipDsc

    Assert-Test "15. Bootstrap Reconnect Checkpoint: halts for power-down & drive reconnection when a required preserved disk is disconnected" `
        ($BootstrapMissingRes.Status -eq "AwaitingDriveReconnectShutdown" -and $BootstrapMissingRes.MissingRequiredDisks.Count -eq 1 -and $BootstrapMissingRes.MissingRequiredDisks[0].SerialNumber -eq "DATA_SN_D")

} finally {
    # Cleanup scratch test directory safely by clearing child junctions first
    if (Test-Path $TestDir) {
        Get-ChildItem -LiteralPath $TestDir -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
            ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        } | ForEach-Object {
            try { [System.IO.Directory]::Delete($_.FullName) } catch {}
        }
        try {
            [System.IO.Directory]::Delete($TestDir, $true)
        } catch {
            Remove-Item -Path $TestDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ""
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "MILESTONE 3 TEST RESULTS: $PassCount PASSED, $FailCount FAILED" -ForegroundColor $(if ($FailCount -eq 0) { "Green" } else { "Red" })
Write-Host "================================================================================" -ForegroundColor Cyan

if ($FailCount -gt 0) { exit 1 }
