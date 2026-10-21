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
        $Volumes = Get-BitLockerVolume -ErrorAction Stop
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
