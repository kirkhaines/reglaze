<#
.SYNOPSIS
    Atomic NTFS Directory Junction manager and manifest applicator for Reglaze.
.DESCRIPTION
    Creates and verifies NTFS directory junctions with intelligent collision detection,
    automatic file migration, and timestamped backups according to the Reglaze architecture.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param()

$LinkingRoot = $PSScriptRoot
. (Join-Path $LinkingRoot "Test-ReparsePoint.ps1")
. (Join-Path $LinkingRoot "Backup-CollisionFolder.ps1")

# =============================================================================
# [HITL-ID]: HITL-M3-02
# [HITL-TARGET]: NTFS Junctions / cmd.exe /c mklink /J (Machine-Scope Directories)
# [HITL-STATUS]: VERIFIED
# [HITL-DESCRIPTION]: Atomic NTFS directory junction creation on machine paths (e.g. C:\ProgramData) and collision backup handling.
# [HITL-TEST-SNIPPET]:
#   # Non-destructive test of reparse point inspection on existing system paths:
#   Get-Item "C:\Users\Default User" -Force -ErrorAction SilentlyContinue | Select-Object FullName, LinkType, Target
# [HITL-LAST-INPUT]: Get-Item on "C:\Users\Default User" in Windows PowerShell 5.1 (2026-10-21)
# [HITL-LAST-RESULT]: PowerShell 5.1 Get-Item returns blank LinkType/Target for directory junctions.
# [HITL-PATTERN]: Multi-tier resolution (parent dir /AL + fsutil stripping Global\ prefixes) and [System.IO.Directory]::Delete
# [HITL-AVOID]: Creating junctions pointing to live host user profiles or program files outside isolated scratch dirs
# =============================================================================

function Normalize-PathComparison {
    param([string]$Path)
    if (-not $Path) { return "" }
    return $Path.TrimEnd('\', '/').ToLowerInvariant()
}

function New-ReglazeDirectoryJunction {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Link,

        [Parameter(Mandatory=$true)]
        [string]$Target,

        [ValidateSet("backup", "replace", "fail")]
        [string]$CollisionAction = "backup",

        [string]$Description = ""
    )

    $Result = [PSCustomObject]@{
        Link        = $Link
        Target      = $Target
        Status      = "Pending"
        Action      = "None"
        BackupPath  = $null
        Success     = $false
        Message     = ""
    }

    $NormLink = Normalize-PathComparison $Link
    $NormTarget = Normalize-PathComparison $Target

    # Safety validation: Link and Target must not be identical or nested inside each other
    if ($NormLink -eq $NormTarget) {
        $Result.Status = "Error"
        $Result.Message = "Link path and target path are identical: $Link"
        return $Result
    }
    if ($NormTarget.StartsWith($NormLink + "\")) {
        $Result.Status = "Error"
        $Result.Message = "Target path cannot reside inside link path (recursive collision): $Target inside $Link"
        return $Result
    }

    # 1. Inspect existing state at Link path
    $LinkInfo = Get-ReparsePointInfo -Path $Link

    if ($LinkInfo.Exists) {
        if ($LinkInfo.IsJunction) {
            $ExistingNormTarget = Normalize-PathComparison $LinkInfo.Target
            if ($ExistingNormTarget -eq $NormTarget) {
                # Already pointing to correct target
                $Result.Status = "UpToDate"
                $Result.Action = "NoOp"
                $Result.Success = $true
                $Result.Message = "Junction already correctly points to $Target"
                return $Result
            } else {
                # Reparse point pointing to a different target - remove old link
                if ($PSCmdlet.ShouldProcess($Link, "Remove outdated junction pointing to $($LinkInfo.Target)")) {
                    [System.IO.Directory]::Delete($Link)
                    $Result.Action = "ReplacedOldLink"
                }
            }
        } else {
            # Real non-junction folder or file exists at $Link
            if ($CollisionAction -eq "fail") {
                $Result.Status = "Failed"
                $Result.Message = "Collision detected at $Link and CollisionAction is 'fail'."
                return $Result
            }

            $TargetExists = Test-Path -LiteralPath $Target
            $TargetHasFiles = $false
            if ($TargetExists) {
                $TargetChildren = @(Get-ChildItem -LiteralPath $Target -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
                $TargetHasFiles = ($TargetChildren.Count -gt 0)
            }

            if ($TargetHasFiles) {
                # Remote target already has data; back up local directory to avoid overwriting or mixing
                if ($PSCmdlet.ShouldProcess($Link, "Backup collision directory")) {
                    $Backup = Backup-DirectoryCollision -SourcePath $Link
                    $Result.BackupPath = $Backup
                    $Result.Action = "BackedUpSource"
                }
            } else {
                # Remote target is empty or does not exist: migrate local files into target
                if ($PSCmdlet.ShouldProcess($Link, "Migrate local files to target $Target")) {
                    $TargetParent = Split-Path -Parent $Target
                    if (-not (Test-Path -LiteralPath $TargetParent)) {
                        New-Item -ItemType Directory -Path $TargetParent -Force | Out-Null
                    }
                    if (-not $TargetExists) {
                        Move-Item -LiteralPath $Link -Destination $Target -Force
                        $Result.Action = "MigratedSourceToTarget"
                    } else {
                        # Target folder exists but is empty
                        $Backup = Backup-DirectoryCollision -SourcePath $Link
                        $Result.BackupPath = $Backup
                        $Result.Action = "BackedUpSource"
                    }
                }
            }
        }
    }

    # 2. Ensure Target directory exists
    if (-not (Test-Path -LiteralPath $Target)) {
        if ($PSCmdlet.ShouldProcess($Target, "Create target directory")) {
            New-Item -ItemType Directory -Path $Target -Force | Out-Null
        }
    }

    # 3. Ensure parent directory of Link exists
    $LinkParent = Split-Path -Parent $Link
    if ($LinkParent -and -not (Test-Path -LiteralPath $LinkParent)) {
        if ($PSCmdlet.ShouldProcess($LinkParent, "Create parent link directory")) {
            New-Item -ItemType Directory -Path $LinkParent -Force | Out-Null
        }
    }

    # 4. Create the NTFS Directory Junction
    if ($PSCmdlet.ShouldProcess($Link, "Create NTFS Junction to $Target")) {
        try {
            $MklinkOutput = & cmd.exe /c "mklink /J `"$Link`" `"$Target`" 2>&1"
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $Link)) {
                $VerifyInfo = Get-ReparsePointInfo -Path $Link
                if ($VerifyInfo.IsJunction) {
                    $Result.Status = if ($Result.Action -eq "None") { "Created" } else { "CreatedWithMigration" }
                    $Result.Success = $true
                    $Result.Message = "Junction created successfully."
                } else {
                    $Result.Status = "Failed"
                    $Result.Message = "mklink command executed but path is not recognized as a junction: $MklinkOutput"
                }
            } else {
                $Result.Status = "Failed"
                $Result.Message = "mklink failed ($LASTEXITCODE): $MklinkOutput"
            }
        } catch {
            $Result.Status = "Failed"
            $Result.Message = "Exception creating junction: $($_.Exception.Message)"
        }
    }

    return $Result
}

function Install-JunctionsFromManifest {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ManifestPath,

        [ValidateSet("all", "machine", "user")]
        [string]$Scope = "all"
    )

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        Write-Error "Junctions manifest file not found: $ManifestPath"
        return @()
    }

    $ManifestContent = Get-Content -Raw -LiteralPath $ManifestPath -Encoding UTF8 | ConvertFrom-Json
    if (-not $ManifestContent) {
        return @()
    }

    $Results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($Junc in $ManifestContent) {
        $ItemScope = if ($Junc.Scope) { $Junc.Scope.ToLowerInvariant() } else { "user" }
        if ($Scope -ne "all" -and $ItemScope -ne $Scope.ToLowerInvariant()) {
            continue
        }

        $Link = $Junc.Link
        $Target = $Junc.Target
        $Collision = if ($Junc.CollisionAction) { $Junc.CollisionAction } else { "backup" }
        $Desc = if ($Junc.Description) { $Junc.Description } else { "$($Junc.AppId) / $($Junc.DirectoryId)" }

        $ActionResult = New-ReglazeDirectoryJunction -Link $Link -Target $Target -CollisionAction $Collision -Description $Desc
        $Results.Add([PSCustomObject]@{
            AppId       = $Junc.AppId
            DirectoryId = $Junc.DirectoryId
            Link        = $Link
            Target      = $Target
            Scope       = $ItemScope
            Status      = $ActionResult.Status
            Success     = $ActionResult.Success
            BackupPath  = $ActionResult.BackupPath
            Message     = $ActionResult.Message
        })
    }

    return $Results
}
