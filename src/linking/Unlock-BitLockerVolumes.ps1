<#
.SYNOPSIS
    BitLocker secondary volume unlock and auto-unlock re-arming utility for Reglaze.
.DESCRIPTION
    Ingests preserved secondary disk recovery keys from payload/bitlocker-keys.json,
    unlocks encrypted secondary volumes, and re-arms TPM auto-unlocking.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param()

# =============================================================================
# [HITL-ID]: HITL-M3-01
# [HITL-TARGET]: BitLocker / Unlock-BitLocker & Enable-BitLockerAutoUnlock
# [HITL-STATUS]: VERIFIED
# [HITL-DESCRIPTION]: Secondary volume BitLocker unlock using 48-digit recovery password and TPM auto-unlock re-arming (Enable-BitLockerAutoUnlock).
# [HITL-TEST-SNIPPET]:
#   # Safe inspection snippet to run manually in user session or VM:
#   Get-BitLockerVolume | Select-Object MountPoint, VolumeType, VolumeStatus, ProtectionStatus, KeyProtector
# [HITL-LAST-INPUT]: Get-BitLockerVolume on physical host (2026-10-21)
# [HITL-LAST-RESULT]: D: verified encrypted with {Password, RecoveryPassword}; C: protected with {Tpm, RecoveryPassword}. Volume GUID mountpoints observed.
# [HITL-PATTERN]: Unlock-BitLocker -MountPoint $Mount -RecoveryPassword $Password; Enable-BitLockerAutoUnlock -MountPoint $Mount
# [HITL-AVOID]: Attempting auto-unlock on OS drive (C:) or modifying key protectors on host workstation
# =============================================================================

function Unlock-PreservedBitLockerVolumes {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)]
        [string]$KeyFilePath,

        [Parameter(Mandatory=$false)]
        [string[]]$ConnectedSerialNumbers = $null,

        [switch]$Simulation = $true,
        [switch]$Live = $false
    )

    # Fail-safe: Always simulated unless explicitly flagged -Live
    $IsSimulated = $Simulation -or (-not $Live)

    $Results = [System.Collections.Generic.List[PSCustomObject]]::new()

    if (-not (Test-Path -LiteralPath $KeyFilePath)) {
        return $Results
    }

    $KeysPayload = Get-Content -Raw -LiteralPath $KeyFilePath -Encoding UTF8 | ConvertFrom-Json
    if (-not $KeysPayload) {
        return $Results
    }

    foreach ($Vol in $KeysPayload) {
        $Mount = $Vol.MountPoint
        $Password = $Vol.RecoveryPassword
        $DiskSerial = if ($Vol.DiskSerialNumber) { $Vol.DiskSerialNumber.Trim() } else { $null }
        $PartNum = if ($null -ne $Vol.PartitionNumber) { [int]$Vol.PartitionNumber } else { $null }
        $PartGuid = if ($Vol.PartitionGuid) { $Vol.PartitionGuid.Trim() } else { $null }

        # Never touch C: in secondary volume recovery
        if (-not $Mount -or $Mount -like "C*") {
            continue
        }

        $EntryResult = [PSCustomObject]@{
            MountPoint       = $Mount
            DiskSerialNumber = $DiskSerial
            PartitionNumber  = $PartNum
            PartitionGuid    = $PartGuid
            Unlocked         = $false
            AutoUnlock       = $false
            Status           = "Pending"
            Message          = ""
        }

        if ($null -ne $ConnectedSerialNumbers -and $DiskSerial) {
            $IsConnected = $ConnectedSerialNumbers | Where-Object { $_.Trim() -ieq $DiskSerial } | Select-Object -First 1
            if (-not $IsConnected) {
                $EntryResult.Status = "DeferredDisconnected"
                $EntryResult.Message = "Disk '$DiskSerial' for volume $($Mount) is not currently connected; deferring BitLocker unlock."
                $Results.Add($EntryResult)
                continue
            }
        }

        if (-not $Password) {
            $EntryResult.Status = "Skipped"
            $EntryResult.Message = "No recovery password recorded for volume $($Mount)."
            $Results.Add($EntryResult)
            continue
        }

        if ($IsSimulated) {
            $EntryResult.Unlocked = $true
            $EntryResult.AutoUnlock = $true
            $EntryResult.Status = "Simulated"
            $EntryResult.Message = "Simulated unlock and auto-unlock re-arm for $($Mount) (Serial: $DiskSerial)."
            $Results.Add($EntryResult)
            continue
        }

        try {
            # Verify hardware identity before unlocking in live mode
            $ResolvedMount = $Mount
            if ($DiskSerial -and (Get-Command "Get-Disk" -ErrorAction SilentlyContinue)) {
                $MatchedDisk = Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.SerialNumber -and $_.SerialNumber.Trim() -ieq $DiskSerial } | Select-Object -First 1
                if (-not $MatchedDisk) {
                    $EntryResult.Status = "DeferredDisconnected"
                    $EntryResult.Message = "Physical disk with serial '$DiskSerial' is not connected; deferring unlock for $($Mount)."
                    $Results.Add($EntryResult)
                    continue
                }
                $DiskParts = @(Get-Partition -DiskNumber $MatchedDisk.Number -ErrorAction SilentlyContinue)
                $TargetPart = $null
                if ($PartGuid) {
                    $TargetPart = $DiskParts | Where-Object { $_.Guid -and $_.Guid.Trim() -ieq $PartGuid } | Select-Object -First 1
                }
                if (-not $TargetPart -and $null -ne $PartNum) {
                    $TargetPart = $DiskParts | Where-Object { $_.PartitionNumber -eq $PartNum } | Select-Object -First 1
                }
                if ($TargetPart -and $TargetPart.DriveLetter -and [int][char]$TargetPart.DriveLetter -ne 0) {
                    $ResolvedMount = "$($TargetPart.DriveLetter):"
                    $EntryResult.MountPoint = $ResolvedMount
                }
            }

            if ($PSCmdlet.ShouldProcess($ResolvedMount, "Unlock BitLocker volume")) {
                if (Get-Command "Unlock-BitLocker" -ErrorAction SilentlyContinue) {
                    Unlock-BitLocker -MountPoint $ResolvedMount -RecoveryPassword $Password -ErrorAction Stop | Out-Null
                    $EntryResult.Unlocked = $true

                    try {
                        Enable-BitLockerAutoUnlock -MountPoint $ResolvedMount -ErrorAction Stop | Out-Null
                        $EntryResult.AutoUnlock = $true
                        $EntryResult.Status = "Success"
                        $EntryResult.Message = "Unlocked volume $ResolvedMount and successfully enabled TPM auto-unlock."
                    } catch {
                        $EntryResult.Status = "PartiallyUnlocked"
                        $EntryResult.Message = "Volume $ResolvedMount unlocked, but Enable-BitLockerAutoUnlock failed: $($_.Exception.Message)"
                    }
                } else {
                    $EntryResult.Status = "Warning"
                    $EntryResult.Message = "Unlock-BitLocker cmdlet not available on this platform."
                }
            }
        } catch {
            $EntryResult.Status = "Failed"
            $EntryResult.Message = "Failed to unlock $($Mount): $($_.Exception.Message)"
        }

        $Results.Add($EntryResult)
    }

    return $Results
}
