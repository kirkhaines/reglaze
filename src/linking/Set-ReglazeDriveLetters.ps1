<#
.SYNOPSIS
    Reconciles physical disk and partition drive letters against declarative Reglaze configuration.
.DESCRIPTION
    Identifies preserved disks by hardware SerialNumber, BusType, PartitionGuid, PartitionNumber,
    and Label. Executes a 3-phase atomic drive letter reconciliation:
      Phase A: Evicts colliding letters on reserved mounts (including the Google Drive streaming mount
               letter) and clears letters on unconfigured internal fixed disks or preserved_disks
               with expected_mount: null.
      Phase B: Assigns expected_mount letters to matched preserved disk partitions.
      Phase C: Reassigns displaced removable/USB volumes (such as the REGLAZE installation media)
               to safe free drive letters outside the reserved set.
    Also detects whether any required preserved disks are physically disconnected and signals
    whether a power-down / drive-reconnection step is needed.
#>

function Format-NormalizedDriveLetter {
    param([string]$MountOrLetter)
    if ([string]::IsNullOrWhiteSpace($MountOrLetter)) { return $null }
    $Clean = $MountOrLetter.Trim().TrimEnd('\').TrimEnd(':')
    if ($Clean.Length -eq 1 -and $Clean -match '^[A-Za-z]$') {
        return $Clean.ToUpperInvariant()
    }
    return $null
}

function Invoke-DriveLetterReconciliation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$DiskConfigPath = $null,

        [Parameter(Mandatory=$false)]
        [object]$DiskConfig = $null,

        [Parameter(Mandatory=$false)]
        [array]$MockSystemDisks = $null,

        [switch]$Simulation = $true,
        [switch]$Live = $false
    )

    if (-not (Get-Command Write-ReglazeInfo -ErrorAction SilentlyContinue)) {
        function Write-ReglazeInfo ($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
        function Write-ReglazeSuccess ($msg) { Write-Host "[OK]   $msg" -ForegroundColor Green }
        function Write-ReglazeWarning ($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
        function Write-ReglazeError ($msg) { Write-Host "[ERR]  $msg" -ForegroundColor Red }
    }

    if (-not $DiskConfig) {
        if ($DiskConfigPath -and (Test-Path $DiskConfigPath)) {
            $DiskConfig = Get-Content -Raw -Path $DiskConfigPath | ConvertFrom-Json
        } else {
            Write-ReglazeWarning "No disk configuration found at '$DiskConfigPath'. Skipping drive letter reconciliation."
            return [PSCustomObject]@{
                Status                    = "Skipped"
                Changes                   = @()
                ConnectedPreservedDisks   = @()
                MissingRequiredDisks      = @()
                MissingOptionalDisks      = @()
                RequiresReconnectShutdown = $false
                ReservedLetters           = @("C")
            }
        }
    }

    # 1. Build Reserved Drive Letter Set
    $ReservedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    [void]$ReservedSet.Add("C")

    $PreservedEntries = @()
    if ($DiskConfig.PreservedDisks) {
        $PreservedEntries = @($DiskConfig.PreservedDisks)
    } elseif ($DiskConfig.preserved_disks) {
        $PreservedEntries = @($DiskConfig.preserved_disks)
    }

    foreach ($Entry in $PreservedEntries) {
        $ExpMount = if ($null -ne $Entry.ExpectedMount) { $Entry.ExpectedMount } else { $Entry.expected_mount }
        $NormLetter = Format-NormalizedDriveLetter $ExpMount
        if ($NormLetter) { [void]$ReservedSet.Add($NormLetter) }
    }

    $StreamMount = if ($DiskConfig.StreamMountPoint) { $DiskConfig.StreamMountPoint } else { $DiskConfig.stream_mount_point }
    $NormStream = Format-NormalizedDriveLetter $StreamMount
    if ($NormStream) { [void]$ReservedSet.Add($NormStream) }

    $RefLetters = if ($DiskConfig.ReferencedLetters) { @($DiskConfig.ReferencedLetters) } elseif ($DiskConfig.referenced_letters) { @($DiskConfig.referenced_letters) } else { @() }
    foreach ($Ref in $RefLetters) {
        $NormRef = Format-NormalizedDriveLetter $Ref
        if ($NormRef) { [void]$ReservedSet.Add($NormRef) }
    }

    $ReservedLetters = @($ReservedSet | Sort-Object)
    Write-ReglazeInfo "Reserved drive letters: $(($ReservedLetters | ForEach-Object { "${_}:" }) -join ', ')"

    # 2. Discover or Synthesize System Disks
    $SystemDisks = @()
    if ($null -ne $MockSystemDisks) {
        # Clone mock disks so in-memory state updates cleanly across Phases A, B, and C
        foreach ($MDisk in $MockSystemDisks) {
            $ClonedParts = @()
            if ($MDisk.Partitions) {
                foreach ($MPart in $MDisk.Partitions) {
                    $ClonedParts += [PSCustomObject]@{
                        DiskNumber      = if ($null -ne $MPart.DiskNumber) { [int]$MPart.DiskNumber } else { [int]$MDisk.DiskNumber }
                        PartitionNumber = [int]$MPart.PartitionNumber
                        PartitionGuid   = [string]$MPart.PartitionGuid
                        DriveLetter     = Format-NormalizedDriveLetter $MPart.DriveLetter
                        Label           = [string]$MPart.Label
                        SizeBytes       = if ($null -ne $MPart.SizeBytes) { [int64]$MPart.SizeBytes } else { 1000000000L }
                        IsSystem        = [bool]$MPart.IsSystem
                        IsHidden        = [bool]$MPart.IsHidden
                    }
                }
            }
            $SystemDisks += [PSCustomObject]@{
                DiskNumber   = [int]$MDisk.DiskNumber
                SerialNumber = [string]$MDisk.SerialNumber
                BusType      = [string]$MDisk.BusType
                FriendlyName = [string]$MDisk.FriendlyName
                IsRemovable  = [bool]($MDisk.IsRemovable -or $MDisk.BusType -in @("USB", "SD", "MMC"))
                Partitions   = $ClonedParts
            }
        }
    } elseif ($Live -and -not $Simulation) {
        # =============================================================================
        # [HITL-ID]: HITL-M5-03
        # [HITL-TARGET]: Get-Disk / Get-Partition / Remove-PartitionAccessPath / Set-Partition
        # [HITL-STATUS]: VERIFIED
        # [HITL-DESCRIPTION]: Enumerate live physical disks and partitions, evict colliding drive letters, and assign expected_mount letters in Phase 4 bootstrap.
        # [HITL-TEST-SNIPPET]:
        #   Get-Disk | Select-Object Number, FriendlyName, SerialNumber, BusType, IsBoot, IsSystem | Format-Table -AutoSize
        #   Get-Partition | Where-Object { $_.DriveLetter } | Select-Object DiskNumber, PartitionNumber, DriveLetter, Guid, Size | Format-Table -AutoSize
        # [HITL-LAST-INPUT]: Read-only inspection of multi-disk layout and mounted partitions on test host (2026-10-28)
        # [HITL-LAST-RESULT]: Get-Disk returned unique SerialNumbers for all drives including USB-attached external SSDs and accurate BusTypes (NVMe, SATA, USB), whereas Get-PhysicalDisk returned "000000000000" and "RAID" on USB UASP bridges. MBR-formatted disks had empty PartitionGuid; GPT-formatted disks had unique PartitionGuids on data partitions.
        # [HITL-PATTERN]: Query Get-Disk for primary SerialNumber and BusType; match partitions by PartitionGuid (when GPT) -> PartitionNumber -> Label -> largest non-system partition; use Remove-PartitionAccessPath and Set-Partition for 3-phase reconciliation.
        # [HITL-AVOID]: Do not rely solely on Get-PhysicalDisk for SerialNumber/BusType on USB-attached SSDs; do not require PartitionGuid to be non-null (MBR partitions have null Guid); never run Set-Partition or Remove-PartitionAccessPath on the host workstation OS.
        # =============================================================================
        $RawDisks = @(Get-Disk -ErrorAction SilentlyContinue | Sort-Object Number)
        $PhysDisks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
        foreach ($RDisk in $RawDisks) {
            $MatchPhys = $PhysDisks | Where-Object { $_.DeviceId -eq $RDisk.Number.ToString() } | Select-Object -First 1
            $Bus = if ($RDisk.BusType -and $RDisk.BusType.ToString() -ne "Unknown") {
                $RDisk.BusType.ToString()
            } elseif ($MatchPhys -and $MatchPhys.BusType) {
                $MatchPhys.BusType.ToString()
            } else {
                "Unknown"
            }
            $Serial = if ($RDisk.SerialNumber -and $RDisk.SerialNumber.Trim() -notmatch '^0+$') {
                $RDisk.SerialNumber.Trim()
            } elseif ($MatchPhys -and $MatchPhys.SerialNumber -and $MatchPhys.SerialNumber.Trim() -notmatch '^0+$') {
                $MatchPhys.SerialNumber.Trim()
            } elseif ($RDisk.SerialNumber) {
                $RDisk.SerialNumber.Trim()
            } elseif ($MatchPhys -and $MatchPhys.SerialNumber) {
                $MatchPhys.SerialNumber.Trim()
            } else {
                ""
            }

            $RawParts = @(Get-Partition -DiskNumber $RDisk.Number -ErrorAction SilentlyContinue | Sort-Object PartitionNumber)
            $PartList = @()
            foreach ($RPart in $RawParts) {
                $Vol = Get-Volume -Partition $RPart -ErrorAction SilentlyContinue
                $Letter = if ($RPart.DriveLetter -and [int][char]$RPart.DriveLetter -ne 0) {
                    $RPart.DriveLetter.ToString().ToUpperInvariant()
                } else { $null }
                $IsSys = [bool]($RPart.IsSystem -or $RPart.IsBoot -or $RPart.GptType -in @(
                    "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}", # EFI System
                    "{e3c9e316-0b5c-4db8-817d-f92df00215ae}", # MSR
                    "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}"  # Recovery
                ))
                $PartList += [PSCustomObject]@{
                    DiskNumber      = [int]$RDisk.Number
                    PartitionNumber = [int]$RPart.PartitionNumber
                    PartitionGuid   = [string]$RPart.Guid
                    DriveLetter     = $Letter
                    Label           = if ($Vol) { [string]$Vol.FileSystemLabel } else { "" }
                    SizeBytes       = [int64]$RPart.Size
                    IsSystem        = $IsSys
                    IsHidden        = [bool]$RPart.IsHidden
                }
            }

            $SystemDisks += [PSCustomObject]@{
                DiskNumber   = [int]$RDisk.Number
                SerialNumber = $Serial
                BusType      = $Bus
                FriendlyName = [string]$RDisk.FriendlyName
                IsRemovable  = [bool]($Bus -in @("USB", "SD", "MMC"))
                Partitions   = $PartList
            }
        }
    } else {
        # Simulation mode without explicit MockSystemDisks: synthesize disks matching config
        $TargetOs = if ($DiskConfig.TargetOsDisk) { $DiskConfig.TargetOsDisk } else { $DiskConfig.target_os_disk }
        $OsDiskNum = if ($TargetOs -and $null -ne $TargetOs.DiskId) { [int]$TargetOs.DiskId } elseif ($TargetOs -and $null -ne $TargetOs.disk_id) { [int]$TargetOs.disk_id } else { 0 }
        $OsSerial = if ($TargetOs -and $TargetOs.SerialNumber) { $TargetOs.SerialNumber } elseif ($TargetOs -and $TargetOs.serial_number) { $TargetOs.serial_number } else { "SIM-OS-SERIAL" }
        $OsBus = if ($TargetOs -and $TargetOs.BusType) { $TargetOs.BusType } elseif ($TargetOs -and $TargetOs.bus_type) { $TargetOs.bus_type } else { "NVMe" }

        $SystemDisks += [PSCustomObject]@{
            DiskNumber   = $OsDiskNum
            SerialNumber = $OsSerial
            BusType      = $OsBus
            FriendlyName = "Simulated OS Disk"
            IsRemovable  = $false
            Partitions   = @(
                [PSCustomObject]@{
                    DiskNumber      = $OsDiskNum
                    PartitionNumber = 1
                    PartitionGuid   = "{sim-os-part}"
                    DriveLetter     = "C"
                    Label           = "OS"
                    SizeBytes       = 500000000000L
                    IsSystem        = $true
                    IsHidden        = $false
                }
            )
        }

        foreach ($Entry in $PreservedEntries) {
            $DId = if ($null -ne $Entry.DiskId) { [int]$Entry.DiskId } else { [int]$Entry.disk_id }
            $DSerial = if ($Entry.SerialNumber) { $Entry.SerialNumber } else { $Entry.serial_number }
            $DBus = if ($Entry.BusType) { $Entry.BusType } elseif ($Entry.bus_type) { $Entry.bus_type } else { "NVMe" }
            $PNum = if ($null -ne $Entry.PartitionNumber) { [int]$Entry.PartitionNumber } elseif ($null -ne $Entry.partition_number) { [int]$Entry.partition_number } else { 1 }
            $PGuid = if ($Entry.PartitionGuid) { $Entry.PartitionGuid } else { $Entry.partition_guid }
            $ExpMount = if ($null -ne $Entry.ExpectedMount) { $Entry.ExpectedMount } else { $Entry.expected_mount }
            $PLabel = if ($Entry.Label) { $Entry.Label } else { $Entry.label }

            $ExistingSimDisk = $SystemDisks | Where-Object { $_.DiskNumber -eq $DId -and $_.SerialNumber -eq $DSerial } | Select-Object -First 1
            $SimPart = [PSCustomObject]@{
                DiskNumber      = $DId
                PartitionNumber = $PNum
                PartitionGuid   = [string]$PGuid
                DriveLetter     = Format-NormalizedDriveLetter $ExpMount
                Label           = [string]$PLabel
                SizeBytes       = 1000000000000L
                IsSystem        = $false
                IsHidden        = $false
            }
            if ($ExistingSimDisk) {
                $ExistingSimDisk.Partitions += $SimPart
            } else {
                $SystemDisks += [PSCustomObject]@{
                    DiskNumber   = $DId
                    SerialNumber = [string]$DSerial
                    BusType      = [string]$DBus
                    FriendlyName = [string]$PLabel
                    IsRemovable  = $false
                    Partitions   = @($SimPart)
                }
            }
        }
    }

    # 3. Identify OS Disk (hosting C:)
    $TargetOsCfg = if ($DiskConfig.TargetOsDisk) { $DiskConfig.TargetOsDisk } else { $DiskConfig.target_os_disk }
    $TargetOsSerial = if ($TargetOsCfg -and $TargetOsCfg.SerialNumber) { $TargetOsCfg.SerialNumber } elseif ($TargetOsCfg -and $TargetOsCfg.serial_number) { $TargetOsCfg.serial_number } else { $null }

    $OsDisk = $SystemDisks | Where-Object {
        $_.Partitions | Where-Object { $_.DriveLetter -eq "C" }
    } | Select-Object -First 1
    if (-not $OsDisk -and $TargetOsSerial) {
        $OsDisk = $SystemDisks | Where-Object { $_.SerialNumber -and $_.SerialNumber.Trim() -ieq $TargetOsSerial.Trim() } | Select-Object -First 1
    }

    # 4. Match Preserved Disks & Partitions
    $ConnectedPreservedDisks = @()
    $MissingRequiredDisks = @()
    $MissingOptionalDisks = @()
    $MatchedDiskNumbers = [System.Collections.Generic.HashSet[int]]::new()
    if ($OsDisk) { [void]$MatchedDiskNumbers.Add($OsDisk.DiskNumber) }

    # Key: "DiskNumber:PartitionNumber" -> ExpectedLetter (or "" for explicitly unmounted)
    $TargetPartitionMap = @{}
    $ExplicitlyUnmountedDiskNumbers = [System.Collections.Generic.HashSet[int]]::new()

    foreach ($Entry in $PreservedEntries) {
        $CfgDiskId = if ($null -ne $Entry.DiskId) { [int]$Entry.DiskId } elseif ($null -ne $Entry.disk_id) { [int]$Entry.disk_id } else { -1 }
        $CfgSerial = if ($Entry.SerialNumber) { $Entry.SerialNumber.Trim() } elseif ($Entry.serial_number) { $Entry.serial_number.Trim() } else { "" }
        $CfgBus = if ($Entry.BusType) { $Entry.BusType.Trim() } elseif ($Entry.bus_type) { $Entry.bus_type.Trim() } else { "" }
        $CfgPartNum = if ($null -ne $Entry.PartitionNumber) { [int]$Entry.PartitionNumber } elseif ($null -ne $Entry.partition_number) { [int]$Entry.partition_number } else { $null }
        $CfgPartGuid = if ($Entry.PartitionGuid) { $Entry.PartitionGuid.Trim() } elseif ($Entry.partition_guid) { $Entry.partition_guid.Trim() } else { "" }
        $CfgMount = if ($null -ne $Entry.ExpectedMount) { $Entry.ExpectedMount } else { $Entry.expected_mount }
        $CfgLabel = if ($Entry.Label) { $Entry.Label } else { $Entry.label }
        $ExpectedLetter = Format-NormalizedDriveLetter $CfgMount

        $IsRequired = if ($null -ne $Entry.Required) {
            [bool]$Entry.Required
        } elseif ($null -ne $Entry.required) {
            [bool]$Entry.required
        } else {
            [bool]($null -ne $ExpectedLetter -and $ExpectedLetter -in $RefLetters)
        }

        # Match Physical Disk: Primary = SerialNumber (non-zero), Fallback 1 = PartitionGuid, Fallback 2 = FriendlyName/Label, Fallback 3 = BusType + DiskId
        $MatchedDisk = $null
        if (-not [string]::IsNullOrWhiteSpace($CfgSerial) -and $CfgSerial -notmatch '^0+$') {
            $MatchedDisk = $SystemDisks | Where-Object {
                ($null -eq $OsDisk -or $_.DiskNumber -ne $OsDisk.DiskNumber) -and
                $_.SerialNumber -and $_.SerialNumber.Trim() -ieq $CfgSerial
            } | Select-Object -First 1
        }
        if (-not $MatchedDisk -and -not [string]::IsNullOrWhiteSpace($CfgPartGuid)) {
            $MatchedDisk = $SystemDisks | Where-Object {
                ($null -eq $OsDisk -or $_.DiskNumber -ne $OsDisk.DiskNumber) -and
                ($_.Partitions | Where-Object { $_.PartitionGuid -and $_.PartitionGuid.Trim() -ieq $CfgPartGuid })
            } | Select-Object -First 1
        }
        if (-not $MatchedDisk -and -not [string]::IsNullOrWhiteSpace($CfgLabel)) {
            $MatchedDisk = $SystemDisks | Where-Object {
                ($null -eq $OsDisk -or $_.DiskNumber -ne $OsDisk.DiskNumber) -and
                (
                    ($_.FriendlyName -and $_.FriendlyName.Trim() -ieq $CfgLabel.Trim()) -or
                    ($_.Partitions | Where-Object { $_.Label -and $_.Label.Trim() -ieq $CfgLabel.Trim() })
                )
            } | Select-Object -First 1
        }
        if (-not $MatchedDisk -and ([string]::IsNullOrWhiteSpace($CfgSerial) -or $CfgSerial -match '^0+$') -and $CfgDiskId -ge 0) {
            $MatchedDisk = $SystemDisks | Where-Object {
                ($null -eq $OsDisk -or $_.DiskNumber -ne $OsDisk.DiskNumber) -and
                $_.DiskNumber -eq $CfgDiskId -and
                ([string]::IsNullOrWhiteSpace($CfgBus) -or $_.BusType -ieq $CfgBus)
            } | Select-Object -First 1
        }

        if (-not $MatchedDisk) {
            $MissingRecord = [PSCustomObject]@{
                DiskId        = $CfgDiskId
                SerialNumber  = $CfgSerial
                ExpectedMount = if ($ExpectedLetter) { "${ExpectedLetter}:" } else { $null }
                Label         = $CfgLabel
                Required      = $IsRequired
            }
            if ($IsRequired) {
                $MissingRequiredDisks += $MissingRecord
                Write-ReglazeWarning "Required preserved disk missing: Label='$CfgLabel', Serial='$CfgSerial', ExpectedMount='${ExpectedLetter}:'"
            } else {
                $MissingOptionalDisks += $MissingRecord
                Write-ReglazeInfo "Optional preserved disk not connected: Label='$CfgLabel', Serial='$CfgSerial'"
            }
            continue
        }

        [void]$MatchedDiskNumbers.Add($MatchedDisk.DiskNumber)

        if (-not $ExpectedLetter) {
            [void]$ExplicitlyUnmountedDiskNumbers.Add($MatchedDisk.DiskNumber)
            $ConnectedPreservedDisks += [PSCustomObject]@{
                DiskNumber      = $MatchedDisk.DiskNumber
                SerialNumber    = $MatchedDisk.SerialNumber
                PartitionNumber = $null
                ExpectedMount   = $null
                Label           = $CfgLabel
            }
            continue
        }

        # Match Partition on MatchedDisk
        $CandidateParts = @($MatchedDisk.Partitions | Where-Object { -not $_.IsSystem -and $_.DriveLetter -ne "C" })
        $MatchedPart = $null
        if (-not [string]::IsNullOrWhiteSpace($CfgPartGuid)) {
            $MatchedPart = $CandidateParts | Where-Object { $_.PartitionGuid -and $_.PartitionGuid.Trim() -ieq $CfgPartGuid } | Select-Object -First 1
        }
        if (-not $MatchedPart -and $null -ne $CfgPartNum -and $CfgPartNum -gt 0) {
            $MatchedPart = $CandidateParts | Where-Object { $_.PartitionNumber -eq $CfgPartNum } | Select-Object -First 1
        }
        if (-not $MatchedPart -and -not [string]::IsNullOrWhiteSpace($CfgLabel)) {
            $MatchedPart = $CandidateParts | Where-Object { $_.Label -and $_.Label.Trim() -ieq $CfgLabel.Trim() } | Select-Object -First 1
        }
        if (-not $MatchedPart -and $CandidateParts.Count -gt 0) {
            $MatchedPart = $CandidateParts | Sort-Object SizeBytes -Descending | Select-Object -First 1
        }

        if ($MatchedPart) {
            $PartKey = "$($MatchedDisk.DiskNumber):$($MatchedPart.PartitionNumber)"
            $TargetPartitionMap[$PartKey] = $ExpectedLetter
            $ConnectedPreservedDisks += [PSCustomObject]@{
                DiskNumber      = $MatchedDisk.DiskNumber
                SerialNumber    = $MatchedDisk.SerialNumber
                PartitionNumber = $MatchedPart.PartitionNumber
                PartitionGuid   = $MatchedPart.PartitionGuid
                CurrentMount    = if ($MatchedPart.DriveLetter) { "$($MatchedPart.DriveLetter):" } else { $null }
                ExpectedMount   = "${ExpectedLetter}:"
                Label           = $CfgLabel
            }
        } else {
            Write-ReglazeWarning "Disk $($MatchedDisk.DiskNumber) ('$CfgSerial') found, but no suitable data partition could be matched for ${ExpectedLetter}:"
        }
    }

    $Changes = @()
    $PendingReassignPartitions = @()

    # Helper to remove a partition's drive letter
    $RemoveLetterAction = {
        param($DiskObj, $PartObj, [string]$Reason)
        $OldLetter = $PartObj.DriveLetter
        if (-not $OldLetter) { return }
        if ($Live -and -not $Simulation) {
            Write-ReglazeInfo "Removing drive letter ${OldLetter}: from Disk $($DiskObj.DiskNumber) Partition $($PartObj.PartitionNumber) ($Reason)"
            Remove-PartitionAccessPath -DiskNumber $DiskObj.DiskNumber -PartitionNumber $PartObj.PartitionNumber -AccessPath "${OldLetter}:\" -ErrorAction Stop
        } else {
            Write-ReglazeInfo "[SIMULATION] Would remove drive letter ${OldLetter}: from Disk $($DiskObj.DiskNumber) Partition $($PartObj.PartitionNumber) ($Reason)"
        }
        $PartObj.DriveLetter = $null
        return [PSCustomObject]@{
            Phase           = "PhaseA_EvictOrClear"
            Action          = $Reason
            DiskNumber      = $DiskObj.DiskNumber
            SerialNumber    = $DiskObj.SerialNumber
            PartitionNumber = $PartObj.PartitionNumber
            OldLetter       = "${OldLetter}:"
            NewLetter       = $null
        }
    }

    # Helper to assign a partition's drive letter
    $AssignLetterAction = {
        param($DiskObj, $PartObj, [string]$NewLetter, [string]$PhaseName, [string]$Reason)
        $OldLetter = $PartObj.DriveLetter
        if ($OldLetter -eq $NewLetter) { return $null }
        if ($Live -and -not $Simulation) {
            Write-ReglazeInfo "Assigning drive letter ${NewLetter}: to Disk $($DiskObj.DiskNumber) Partition $($PartObj.PartitionNumber) ($Reason)"
            Set-Partition -DiskNumber $DiskObj.DiskNumber -PartitionNumber $PartObj.PartitionNumber -NewDriveLetter $NewLetter -ErrorAction Stop
        } else {
            Write-ReglazeInfo "[SIMULATION] Would assign drive letter ${NewLetter}: to Disk $($DiskObj.DiskNumber) Partition $($PartObj.PartitionNumber) ($Reason)"
        }
        $PartObj.DriveLetter = $NewLetter
        return [PSCustomObject]@{
            Phase           = $PhaseName
            Action          = $Reason
            DiskNumber      = $DiskObj.DiskNumber
            SerialNumber    = $DiskObj.SerialNumber
            PartitionNumber = $PartObj.PartitionNumber
            OldLetter       = if ($OldLetter) { "${OldLetter}:" } else { $null }
            NewLetter       = "${NewLetter}:"
        }
    }

    # 5. Phase A: Evict Collisions & Clear Unconfigured Internal Disks
    foreach ($SysDisk in $SystemDisks) {
        if ($OsDisk -and $SysDisk.DiskNumber -eq $OsDisk.DiskNumber) { continue }

        foreach ($Part in $SysDisk.Partitions) {
            if ($Part.IsSystem -or $Part.DriveLetter -eq "C") { continue }
            $PartKey = "$($SysDisk.DiskNumber):$($Part.PartitionNumber)"
            $CurrentLetter = $Part.DriveLetter

            if ($TargetPartitionMap.ContainsKey($PartKey)) {
                $DesiredLetter = $TargetPartitionMap[$PartKey]
                if ($CurrentLetter -and $CurrentLetter -ne $DesiredLetter) {
                    $Change = & $RemoveLetterAction $SysDisk $Part "EvictForPreservedSwap"
                    if ($Change) { $Changes += $Change }
                }
            } elseif ($ExplicitlyUnmountedDiskNumbers.Contains($SysDisk.DiskNumber)) {
                if ($CurrentLetter) {
                    $Change = & $RemoveLetterAction $SysDisk $Part "ClearExplicitlyUnmountedPreservedDisk"
                    if ($Change) { $Changes += $Change }
                }
            } elseif (-not $MatchedDiskNumbers.Contains($SysDisk.DiskNumber)) {
                if ($SysDisk.IsRemovable) {
                    # Removable / USB volume (e.g. REGLAZE boot media): only evict if holding a reserved letter
                    if ($CurrentLetter -and $ReservedSet.Contains($CurrentLetter)) {
                        $Change = & $RemoveLetterAction $SysDisk $Part "EvictCollidingRemovableDrive"
                        if ($Change) { $Changes += $Change }
                        $PendingReassignPartitions += [PSCustomObject]@{
                            Disk = $SysDisk
                            Part = $Part
                        }
                    }
                } else {
                    # Unconfigured internal fixed disk: clear drive letter mount
                    if ($CurrentLetter) {
                        $Change = & $RemoveLetterAction $SysDisk $Part "ClearUnconfiguredInternalDisk"
                        if ($Change) { $Changes += $Change }
                    }
                }
            } else {
                # Additional unconfigured partition on a matched preserved disk
                if ($CurrentLetter -and $ReservedSet.Contains($CurrentLetter)) {
                    $Change = & $RemoveLetterAction $SysDisk $Part "ClearCollidingSecondaryPartition"
                    if ($Change) { $Changes += $Change }
                }
            }
        }
    }

    # 6. Phase B: Assign Expected Mount Letters to Preserved Disk Partitions
    foreach ($SysDisk in $SystemDisks) {
        foreach ($Part in $SysDisk.Partitions) {
            $PartKey = "$($SysDisk.DiskNumber):$($Part.PartitionNumber)"
            if ($TargetPartitionMap.ContainsKey($PartKey)) {
                $DesiredLetter = $TargetPartitionMap[$PartKey]
                if ($Part.DriveLetter -ne $DesiredLetter) {
                    $Change = & $AssignLetterAction $SysDisk $Part $DesiredLetter "PhaseB_AssignPreserved" "AssignExpectedMount"
                    if ($Change) { $Changes += $Change }
                } else {
                    Write-ReglazeSuccess "Disk $($SysDisk.DiskNumber) Partition $($Part.PartitionNumber) already mounted at ${DesiredLetter}:"
                }
            }
        }
    }

    # 7. Phase C: Reassign Displaced Removable Volumes to Safe Free Letters (I:..Z:)
    if ($PendingReassignPartitions.Count -gt 0) {
        $UsedLetters = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($R in $ReservedLetters) { [void]$UsedLetters.Add($R) }
        foreach ($SysDisk in $SystemDisks) {
            foreach ($Part in $SysDisk.Partitions) {
                if ($Part.DriveLetter) { [void]$UsedLetters.Add($Part.DriveLetter) }
            }
        }

        $SafeCandidateLetters = @([char[]]([char]'I'..[char]'Z') + [char[]]([char]'D'..[char]'H')) |
            ForEach-Object { $_.ToString() } |
            Select-Object -Unique

        foreach ($Pending in $PendingReassignPartitions) {
            $FreeLetter = $SafeCandidateLetters | Where-Object { -not $UsedLetters.Contains($_) } | Select-Object -First 1
            if ($FreeLetter) {
                [void]$UsedLetters.Add($FreeLetter)
                $Change = & $AssignLetterAction $Pending.Disk $Pending.Part $FreeLetter "PhaseC_ReassignRemovable" "ReassignDisplacedRemovableDrive"
                if ($Change) { $Changes += $Change }
            } else {
                Write-ReglazeWarning "No free drive letters available to reassign removable Disk $($Pending.Disk.DiskNumber) Partition $($Pending.Part.PartitionNumber)."
            }
        }
    }

    $RequiresShutdown = ($MissingRequiredDisks.Count -gt 0)
    $FinalStatus = if ($RequiresShutdown) {
        "MissingRequiredDisks"
    } elseif ($Changes.Count -gt 0) {
        "Reconciled"
    } else {
        "NoChangesNeeded"
    }

    return [PSCustomObject]@{
        Status                    = $FinalStatus
        Changes                   = $Changes
        ConnectedPreservedDisks   = $ConnectedPreservedDisks
        MissingRequiredDisks      = $MissingRequiredDisks
        MissingOptionalDisks      = $MissingOptionalDisks
        RequiresReconnectShutdown = $RequiresShutdown
        ReservedLetters           = $ReservedLetters
        SimulatedSystemDisks      = $SystemDisks
    }
}

