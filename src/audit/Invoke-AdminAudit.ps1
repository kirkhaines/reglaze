<#
.SYNOPSIS
    Targeted administrator audit worker for Reglaze.
.DESCRIPTION
    Runs with elevated Administrator privileges to extract BitLocker recovery keys
    and OEM firmware product keys. Outputs results to a specified JSON file.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$OutputFile
)

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Error "Invoke-AdminAudit.ps1 must be executed with elevated Administrator privileges."
    exit 1
}

$BitLockerVolumes = @()
if (Get-Command "Get-BitLockerVolume" -ErrorAction SilentlyContinue) {
    try {
        $AllParts = @(Get-Partition -ErrorAction SilentlyContinue)
        $AllDisks = @(Get-Disk -ErrorAction SilentlyContinue)
        $AllPhys = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
        $Volumes = Get-BitLockerVolume -ErrorAction Stop
        if ($Volumes) {
            foreach ($Vol in $Volumes) {
                $RecoveryKey = $Vol.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1
                $ProtectorTypes = @($Vol.KeyProtector | ForEach-Object { "$($_.KeyProtectorType)" })

                $DiskSerial = $null
                $DiskNum = $null
                $PartNum = $null
                $PartGuid = $null
                $CleanMount = ($Vol.MountPoint -replace '\\+$', '')
                $MatchedPart = $AllParts | Where-Object {
                    ($_.DriveLetter -and "$($_.DriveLetter):" -ieq $CleanMount) -or
                    ($_.AccessPaths -and ($_.AccessPaths | Where-Object { ($_ -replace '\\+$', '') -ieq $CleanMount }))
                } | Select-Object -First 1

                if ($MatchedPart) {
                    $DiskNum = [int]$MatchedPart.DiskNumber
                    $PartNum = [int]$MatchedPart.PartitionNumber
                    $PartGuid = if ($MatchedPart.Guid) { "$($MatchedPart.Guid)" } else { $null }
                    $MatchedDisk = $AllDisks | Where-Object { [int]$_.Number -eq $DiskNum } | Select-Object -First 1
                    $MatchedPhys = $AllPhys | Where-Object { [int]$_.DeviceId -eq $DiskNum } | Select-Object -First 1
                    if ($MatchedDisk -and $MatchedDisk.SerialNumber -and $MatchedDisk.SerialNumber.Trim() -notmatch '^0+$') {
                        $DiskSerial = $MatchedDisk.SerialNumber.Trim()
                    } elseif ($MatchedPhys -and $MatchedPhys.SerialNumber) {
                        $DiskSerial = $MatchedPhys.SerialNumber.Trim()
                    }
                }

                $BitLockerVolumes += [PSCustomObject]@{
                    mount_point        = $Vol.MountPoint
                    disk_number        = $DiskNum
                    disk_serial_number = $DiskSerial
                    partition_number   = $PartNum
                    partition_guid     = $PartGuid
                    volume_type        = "$($Vol.VolumeType)"
                    protection_status  = "$($Vol.ProtectionStatus)"
                    encryption_method  = "$($Vol.EncryptionMethod)"
                    recovery_key_id    = if ($RecoveryKey) { $RecoveryKey.KeyProtectorId } else { $null }
                    recovery_password  = if ($RecoveryKey) { $RecoveryKey.RecoveryPassword } else { $null }
                    key_protectors     = $ProtectorTypes
                }
            }
        }
    } catch {
        Write-Warning "Failed to query BitLocker volumes: $($_.Exception.Message)"
    }
}

$FirmwareKey = $null
try {
    $FirmwareKey = (Get-CimInstance -Namespace root/cimv2 -ClassName SoftwareLicensingService -ErrorAction SilentlyContinue).OA3xOriginalProductKey
} catch {}

$Result = [PSCustomObject]@{
    bitlocker_volumes    = $BitLockerVolumes
    firmware_product_key = $FirmwareKey
}

$Result | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputFile -Encoding UTF8
