<#
.SYNOPSIS
    WinPE Pre-Install Dynamic Disk Matching Engine for Reglaze.
.DESCRIPTION
    Executes in Windows PE prior to diskpart. Uses multi-factor hardware matching
    (Serial Number + Bus Type) to locate the exact Target OS Disk without relying on
    ephemeral disk index numbers, strictly protecting preserved storage disks.
#>
[CmdletBinding()]
param(
    [string]$TargetSerialNumber,
    [string]$TargetBusType,
    [int]$TargetDiskId = -1,
    [string[]]$PreservedSerialNumbers = @(),
    [string]$DiskpartOutputPath = "X:\diskpart.txt"
)

function Invoke-DiskMatching {
    [CmdletBinding()]
    param(
        [string]$TargetSerialNumber,
        [string]$TargetBusType,
        [int]$TargetDiskId = -1,
        [string[]]$PreservedSerialNumbers = @(),
        [string]$DiskpartOutputPath = "X:\diskpart.txt"
    )

    Write-Host "================================================================"
    Write-Host "  REGLAZE WINPE DISK MATCHING ENGINE"
    Write-Host "================================================================"

    # 1. Query Physical Disks in WinPE
    $Disks = @()
    try {
        $Disks = Get-PhysicalDisk -ErrorAction Stop
    } catch {
        try {
            $CimDisks = Get-CimInstance Win32_DiskDrive
            foreach ($cd in $CimDisks) {
                $Disks += [PSCustomObject]@{
                    DeviceId     = $cd.Index
                    FriendlyName = $cd.Model
                    SerialNumber = $cd.SerialNumber
                    BusType      = $cd.InterfaceType
                    Size         = $cd.Size
                }
            }
        } catch {
            Write-Error "CRITICAL: Unable to query physical disk topology in WinPE environment."
            exit 1
        }
    }

    Write-Host "Discovered $($Disks.Count) physical disk(s) in WinPE."
    foreach ($d in $Disks) {
        Write-Host " - Disk $($d.DeviceId): $($d.FriendlyName) (Bus: $($d.BusType), Serial: $($d.SerialNumber))"
    }

    # 2. Match Target OS Disk
    $MatchedDisk = $null

    if ($TargetSerialNumber) {
        $MatchedDisk = $Disks | Where-Object { 
            $_.SerialNumber -and ($_.SerialNumber.Trim() -eq $TargetSerialNumber.Trim() -or $_.SerialNumber.Trim() -like "*$($TargetSerialNumber.Trim())*")
        } | Select-Object -First 1
    }

    # Secondary fallback by BusType + Disk ID if serial number unavailable
    if (-not $MatchedDisk -and $TargetDiskId -ge 0) {
        $MatchedDisk = $Disks | Where-Object { 
            $_.DeviceId -eq $TargetDiskId -and ($null -eq $TargetBusType -or $_.BusType -eq $TargetBusType)
        } | Select-Object -First 1
    }

    # 3. Safety Verification
    if (-not $MatchedDisk) {
        throw "CRITICAL HALT: Target OS Disk matching criteria not found (Serial: '$TargetSerialNumber', Bus: '$TargetBusType'). Aborting Windows Setup before diskpart executes to prevent data loss."
    }

    # Verify matched disk is NOT in the preserved serial numbers list
    foreach ($PreservedSerial in $PreservedSerialNumbers) {
        if ($PreservedSerial -and $MatchedDisk.SerialNumber -and $MatchedDisk.SerialNumber.Trim() -eq $PreservedSerial.Trim()) {
            throw "CRITICAL SAFETY VIOLATION: Matched disk ($($MatchedDisk.DeviceId) - $($MatchedDisk.SerialNumber)) is listed in PRESERVED DISKS! Aborting immediately to prevent wiping preserved data disk."
        }
    }

    $TargetIndex = $MatchedDisk.DeviceId
    Write-Host "[SUCCESS] Uniquely verified Target OS Disk at Index $TargetIndex ($($MatchedDisk.FriendlyName))."

    # 4. Generate Dynamic Diskpart Script
    $DiskpartScript = @"
select disk $TargetIndex
clean
convert gpt
create partition efi size=100
format quick fs=fat32 label="System"
create partition msr size=16
create partition primary
shrink minimum=1000
format quick fs=ntfs label="Windows"
assign letter="C"
create partition primary
format quick fs=ntfs label="Recovery"
set id="de94bba4-06d1-4d40-a16a-bfd50179d6ac"
gpt attributes=0x8000000000000001
"@

    $OutDir = Split-Path -Parent $DiskpartOutputPath
    if ($OutDir -and -not (Test-Path $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }

    $DiskpartScript | Set-Content -Path $DiskpartOutputPath -Encoding ASCII
    Write-Host "[SUCCESS] Wrote dynamic diskpart layout targeting disk ${TargetIndex}: $DiskpartOutputPath"

    return [PSCustomObject]@{
        TargetDiskIndex    = $TargetIndex
        TargetDiskModel    = $MatchedDisk.FriendlyName
        TargetSerialNumber = $MatchedDisk.SerialNumber
        DiskpartScriptPath = $DiskpartOutputPath
    }
}

if ($TargetSerialNumber -or $TargetDiskId -ge 0) {
    try {
        Invoke-DiskMatching -TargetSerialNumber $TargetSerialNumber -TargetBusType $TargetBusType -TargetDiskId $TargetDiskId -PreservedSerialNumbers $PreservedSerialNumbers -DiskpartOutputPath $DiskpartOutputPath
    } catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}
