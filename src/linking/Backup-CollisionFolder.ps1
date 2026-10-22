<#
.SYNOPSIS
    Atomic directory collision backup utility for Reglaze.
.DESCRIPTION
    Safely renames colliding real directories to a timestamped backup folder
    prior to creating an NTFS directory junction, preventing data loss.
#>
[CmdletBinding()]
param()

function Backup-DirectoryCollision {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)]
        [string]$SourcePath,

        [string]$CustomTimestamp = $null
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        return $null
    }

    $Timestamp = if ($CustomTimestamp) { $CustomTimestamp } else { (Get-Date).ToString("yyyyMMdd_HHmmss") }
    $BackupPath = "$SourcePath.bak_$Timestamp"

    if (Test-Path -LiteralPath $BackupPath) {
        $Idx = 1
        while (Test-Path -LiteralPath "$BackupPath`_$Idx") {
            $Idx++
        }
        $BackupPath = "$BackupPath`_$Idx"
    }

    if ($PSCmdlet.ShouldProcess($SourcePath, "Rename collision directory to $BackupPath")) {
        try {
            [System.IO.Directory]::Move($SourcePath, $BackupPath)
        } catch {
            Move-Item -LiteralPath $SourcePath -Destination $BackupPath -Force
        }
        return $BackupPath
    }

    return $BackupPath
}
