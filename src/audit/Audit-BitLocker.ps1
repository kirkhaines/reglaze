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
    param(
        [string]$RepoRoot = $null,
        [switch]$SkipElevation = $false,
        [switch]$Elevate = $false
    )

    $BitLockerVolumes = @()

    # Check if running elevated (Administrator privileges are strictly required by BitLocker WMI provider)
    $IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($IsAdmin) {
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
        return $BitLockerVolumes
    }

    # Non-elevated session: determine if we can prompt for UAC elevation
    $CanPrompt = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and -not $SkipElevation
    $ShouldElevate = $Elevate

    if (-not $Elevate -and $CanPrompt) {
        Write-Host ""
        Write-Host "  [?] BitLocker recovery key extraction requires Administrator elevation." -ForegroundColor Yellow
        $Response = Read-Host "      Prompt for UAC elevation to capture BitLocker recovery keys? [Y/n]"
        if (-not $Response -or $Response.Trim().ToLower() -ne 'n') {
            $ShouldElevate = $true
        }
    }

    if ($ShouldElevate) {
        if (-not $RepoRoot) {
            $RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
        }
        $AdminScript = Join-Path $RepoRoot "src\audit\Invoke-AdminAudit.ps1"
        $TempFile = Join-Path $env:TEMP "reglaze_admin_audit_$([Guid]::NewGuid().ToString('N')).json"

        $Candidates = @()
        if ($PSVersionTable.PSEdition -eq 'Core') {
            $Candidates += "pwsh.exe"
            $Candidates += "pwsh"
            $Candidates += "powershell.exe"
        } else {
            $Candidates += "powershell.exe"
            $Candidates += "pwsh.exe"
        }

        $Success = $false
        $LastError = $null

        Write-Host "  [i] Requesting Administrator elevation via UAC..." -ForegroundColor Cyan

        foreach ($Exe in $Candidates) {
            if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) { continue }

            try {
                $Proc = Start-Process -FilePath $Exe `
                    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$AdminScript`" -OutputFile `"$TempFile`"" `
                    -Verb RunAs `
                    -Wait `
                    -PassThru `
                    -WindowStyle Minimized `
                    -ErrorAction Stop

                if (Test-Path $TempFile) {
                    $Success = $true
                    break
                }
            } catch {
                $LastError = $_.Exception.Message
            }
        }

        if ($Success -and (Test-Path $TempFile)) {
            $AdminData = Get-Content -Raw -Path $TempFile -Encoding UTF8 | ConvertFrom-Json
            Remove-Item -Path $TempFile -Force -ErrorAction SilentlyContinue
            if ($AdminData.bitlocker_volumes) {
                $BitLockerVolumes = @($AdminData.bitlocker_volumes)
            }
            return $BitLockerVolumes
        } elseif ($LastError) {
            Write-Warning "Administrative elevation failed or was canceled: $LastError"
        } else {
            Write-Warning "Elevated audit completed without generating output file (UAC may have been declined)."
        }
    } else {
        Write-Warning "Querying BitLocker recovery keys requires Administrator elevation. Please run an elevated PowerShell session to extract BitLocker keys."
    }

    return $BitLockerVolumes
}

