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

        # Never touch C: in secondary volume recovery
        if (-not $Mount -or $Mount -like "C*") {
            continue
        }

        $EntryResult = [PSCustomObject]@{
            MountPoint = $Mount
            Unlocked   = $false
            AutoUnlock = $false
            Status     = "Pending"
            Message    = ""
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
            $EntryResult.Message = "Simulated unlock and auto-unlock re-arm for $($Mount)."
            $Results.Add($EntryResult)
            continue
        }

        try {
            if ($PSCmdlet.ShouldProcess($Mount, "Unlock BitLocker volume")) {
                if (Get-Command "Unlock-BitLocker" -ErrorAction SilentlyContinue) {
                    Unlock-BitLocker -MountPoint $Mount -RecoveryPassword $Password -ErrorAction Stop | Out-Null
                    $EntryResult.Unlocked = $true

                    try {
                        Enable-BitLockerAutoUnlock -MountPoint $Mount -ErrorAction Stop | Out-Null
                        $EntryResult.AutoUnlock = $true
                        $EntryResult.Status = "Success"
                        $EntryResult.Message = "Unlocked volume and successfully enabled TPM auto-unlock."
                    } catch {
                        $EntryResult.Status = "PartiallyUnlocked"
                        $EntryResult.Message = "Volume unlocked, but Enable-BitLockerAutoUnlock failed: $($_.Exception.Message)"
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
