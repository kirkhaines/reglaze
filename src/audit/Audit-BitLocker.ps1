<#
.SYNOPSIS
    BitLocker recovery key extraction and encryption status audit module for Reglaze.
.DESCRIPTION
    Queries protected volumes using Get-BitLockerVolume, capturing volume types,
    encryption algorithms, protector types, and 48-digit numerical recovery passwords.
#>
[CmdletBinding()]
param()

function Get-BitLockerAudit {
    [CmdletBinding()]
    param()

    $BitLockerVolumes = @()

    # Check if BitLocker cmdlets are available
    if (-not (Get-Command "Get-BitLockerVolume" -ErrorAction SilentlyContinue)) {
        Write-Warning "Get-BitLockerVolume cmdlet is not available on this system."
        return $BitLockerVolumes
    }

    try {
        $Volumes = Get-BitLockerVolume -ErrorAction SilentlyContinue
        if ($Volumes) {
            foreach ($Vol in $Volumes) {
                $RecoveryKey = $Vol.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1
                $ProtectorTypes = @($Vol.KeyProtector | ForEach-Object { "$($_.KeyProtectorType)" })

                $BitLockerVolumes += [PSCustomObject]@{
                    mount_point       = $Vol.MountPoint
                    volume_type       = "$($Vol.VolumeType)"
                    protection_status = "$($Vol.ProtectionStatus)"
                    encryption_method = "$($Vol.EncryptionMethod)"
                    recovery_key_id   = if ($RecoveryKey) { $RecoveryKey.KeyProtectorId } else { $null }
                    recovery_password = if ($RecoveryKey) { $RecoveryKey.RecoveryPassword } else { $null }
                    key_protectors    = $ProtectorTypes
                }
            }
        }
    } catch {
        Write-Warning "Failed to query BitLocker volumes (requires Administrator privileges): $($_.Exception.Message)"
    }

    return $BitLockerVolumes
}

