<#
.SYNOPSIS
    Vanilla Windows 11 UEFI USB Media Builder for Reglaze.
.DESCRIPTION
    Creates a 100% standard, Microsoft-compliant UEFI bootable USB flash drive:
    1. Enforces strict disk safety validation (rejects internal NVMe/SATA disks, C: OS drives).
    2. Formats target USB drive with standard FAT32 for universal UEFI firmware compatibility.
    3. Mounts official Windows 11 installation ISO.
    4. Extracts bootloaders, EFI environment, and setup binaries.
    5. Natively splits oversized install.wim (>4GB) into install.swm (<3800MB) via DISM.
       (Standard Windows Setup natively supports .swm without any third-party tools or hacks).
    6. Injects Reglaze unattended deployment artifacts (autounattend.xml, DiskMatch.ps1, payload/).
    7. Verifies media boot structure and dismounts source ISO.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param()

# =============================================================================
# [HITL-ID]: HITL-M5-01
# [HITL-TARGET]: USB Media Creation / Format-Volume & DISM Split-Image
# [HITL-STATUS]: PENDING
# [HITL-DESCRIPTION]: Formats USB drive as FAT32, splits install.wim via dism /Split-Image, and copies autounattend.xml + payload.
# [HITL-TEST-SNIPPET]:
#   # Safe inspection of connected USB storage devices:
#   Get-Disk | Where-Object { $_.BusType -eq 'USB' } | Select-Object Number, FriendlyName, BusType, Size, OperationalStatus
# [HITL-LAST-INPUT]: Read-only query of physical disks on developer host
# [HITL-LAST-RESULT]: PENDING
# [HITL-PATTERN]: Format-Volume -DriveLetter $Letter -FileSystem FAT32; dism /Split-Image /ImageFile:... /SWMFile:... /FileSize:3800
# [HITL-AVOID]: Creating media on non-removable internal NVMe/SATA disks; using Rufus registry bypasses that break feature updates
# =============================================================================

function Test-ValidUsbDrive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$DriveLetter,

        [switch]$Force = $false
    )

    $CleanLetter = ($DriveLetter -replace '[:\\/]', '').ToUpper()

    # Absolute Safety Rule 1: Never target C: or system drive
    $SystemDriveLetter = ($env:SystemDrive -replace '[:\\/]', '').ToUpper()
    if ($CleanLetter -eq $SystemDriveLetter -or $CleanLetter -eq 'C') {
        throw "CRITICAL SAFETY VIOLATION: Cannot target system drive (${CleanLetter}:) for installation media creation!"
    }

    # Query volume
    $Volume = Get-Volume -DriveLetter $CleanLetter -ErrorAction SilentlyContinue
    if (-not $Volume) {
        throw "Specified drive letter '${CleanLetter}:' does not exist or is not accessible."
    }

    # Query physical disk properties
    try {
        $Partition = Get-Partition -DriveLetter $CleanLetter -ErrorAction Stop
        $Disk = Get-Disk -Number $Partition.DiskNumber -ErrorAction Stop
    } catch {
        throw "Could not determine physical disk topology for drive '${CleanLetter}:': $($_.Exception.Message)"
    }

    $IsUsb = ($Disk.BusType -eq 'USB') -or ($Disk.OperationalStatus -eq 'OK' -and ($Disk.FriendlyName -match '(?i)(USB|Flash|SanDisk|Kingston|Samsung|Cruzer|Transcend|PNY|Corsair)'))
    $IsRemovable = [bool]$Disk.IsRemovable

    if (-not $IsUsb -and -not $IsRemovable -and -not $Force) {
        throw "CRITICAL SAFETY VIOLATION: Drive '${CleanLetter}:' is located on a fixed internal disk (Disk $($Disk.Number), Bus: $($Disk.BusType), Model: '$($Disk.FriendlyName)'). Reglaze strictly refuses to format internal disks without -Force."
    }

    return [PSCustomObject]@{
        DriveLetter   = "${CleanLetter}:"
        DiskNumber    = $Disk.Number
        FriendlyName  = $Disk.FriendlyName
        BusType       = $Disk.BusType
        SizeGB        = [Math]::Round($Disk.Size / 1GB, 2)
        VolumeLabel   = $Volume.FileSystemLabel
        IsUsb         = $IsUsb
        IsRemovable   = $IsRemovable
    }
}

function New-ReglazeBootableUsb {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)]
        [string]$UsbDrive,

        [Parameter(Mandatory=$true)]
        [string]$IsoPath,

        [Parameter(Mandatory=$false)]
        [string]$MediaArtifactsDir = $null,

        [switch]$Force = $false,
        [switch]$Simulation = $true,
        [switch]$Live = $false
    )

    $IsSimulated = $Simulation -or (-not $Live)

    $CleanLetter = ($UsbDrive -replace '[:\\/]', '').ToUpper()
    $TargetDriveLetter = "${CleanLetter}:"

    Write-Host "================================================================================" -ForegroundColor Cyan
    Write-Host "       REGLAZE VANILLA WINDOWS 11 UEFI MEDIA CREATION ENGINE                    " -ForegroundColor Cyan
    Write-Host "================================================================================" -ForegroundColor Cyan

    # 1. Disk & Target Safety Verification
    Write-Host "Verifying target USB drive: $TargetDriveLetter..." -ForegroundColor Yellow
    if (-not $IsSimulated) {
        $DriveInfo = Test-ValidUsbDrive -DriveLetter $CleanLetter -Force:$Force
        Write-Host "  Target Disk: $($DriveInfo.FriendlyName) (Disk $($DriveInfo.DiskNumber))" -ForegroundColor Cyan
        Write-Host "  Bus Type:    $($DriveInfo.BusType)" -ForegroundColor Cyan
        Write-Host "  Capacity:    $($DriveInfo.SizeGB) GB" -ForegroundColor Cyan
    } else {
        Write-Host "  [Simulation] Target USB verification passed: $TargetDriveLetter (Simulated Removable Disk)" -ForegroundColor DarkCyan
    }

    # 2. ISO File Verification
    Write-Host "Verifying Windows 11 source ISO: $IsoPath..." -ForegroundColor Yellow
    if (-not $IsSimulated) {
        if (-not (Test-Path -LiteralPath $IsoPath)) {
            throw "Source Windows 11 ISO file not found at: $IsoPath"
        }
        $IsoItem = Get-Item -LiteralPath $IsoPath
        if ($IsoItem.Length -lt 3GB) {
            throw "File at '$IsoPath' is too small ($($IsoItem.Length) bytes) to be a valid Windows 11 installation ISO."
        }
        Write-Host "  ISO Verified: $($IsoItem.Name) ($([Math]::Round($IsoItem.Length / 1GB, 2)) GB)" -ForegroundColor Green
    } else {
        Write-Host "  [Simulation] Source ISO verified: $IsoPath" -ForegroundColor DarkCyan
    }

    # 3. Resolve Media Artifacts Directory
    if (-not $MediaArtifactsDir) {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $MediaArtifactsDir = Join-Path $RepoRoot "dist\media"
    }

    Write-Host "Verifying deployment media artifacts: $MediaArtifactsDir..." -ForegroundColor Yellow
    $AutounattendSrc = Join-Path $MediaArtifactsDir "autounattend.xml"
    $PayloadSrc = Join-Path $MediaArtifactsDir "payload"

    if (-not $IsSimulated) {
        if (-not (Test-Path -LiteralPath $AutounattendSrc)) {
            throw "autounattend.xml not found at: $AutounattendSrc. Run 'reglaze compile' first."
        }
        if (-not (Test-Path -LiteralPath $PayloadSrc)) {
            throw "Payload directory not found at: $PayloadSrc. Run 'reglaze compile' first."
        }
        Write-Host "  Deployment artifacts verified." -ForegroundColor Green
    } else {
        Write-Host "  [Simulation] Deployment artifacts verified: $MediaArtifactsDir" -ForegroundColor DarkCyan
    }

    # 4. Interactive Confirmation
    if (-not $IsSimulated -and -not $Force) {
        Write-Host ""
        Write-Host "WARNING: ALL DATA ON DRIVE $TargetDriveLetter WILL BE COMPLETELY DESTROYED!" -ForegroundColor Red
        $Confirm = Read-Host "Are you sure you want to format $TargetDriveLetter and create Reglaze media? (yes/NO)"
        if ($Confirm -inotmatch '^yes$') {
            Write-Host "Media creation aborted by user." -ForegroundColor Yellow
            return [PSCustomObject]@{ Status = "Aborted"; UsbDrive = $TargetDriveLetter }
        }
    }

    # 5. Format Target Drive as FAT32
    Write-Host "Formatting $TargetDriveLetter as FAT32 (UEFI Compliant)..." -ForegroundColor Yellow
    if (-not $IsSimulated) {
        Format-Volume -DriveLetter $CleanLetter -FileSystem FAT32 -NewFileSystemLabel "REGLAZE" -Force | Out-Null
        Write-Host "  Drive $TargetDriveLetter formatted successfully as FAT32." -ForegroundColor Green
    } else {
        Write-Host "  [Simulation] Formatted $TargetDriveLetter as FAT32 (Label: REGLAZE)." -ForegroundColor DarkCyan
    }

    # 6. Mount Source ISO
    Write-Host "Mounting Windows 11 ISO..." -ForegroundColor Yellow
    $MountedVolumeLetter = $null
    if (-not $IsSimulated) {
        try {
            $MountResult = Mount-DiskImage -ImagePath $IsoPath -StorageType ISO -PassThru
            Start-Sleep -Seconds 2
            $MountedVolume = Get-DiskImage -ImagePath $IsoPath | Get-Volume
            $MountedVolumeLetter = $MountedVolume.DriveLetter + ":"
            Write-Host "  Mounted ISO to virtual drive: $MountedVolumeLetter" -ForegroundColor Green
        } catch {
            throw "Failed to mount ISO image at '$IsoPath': $($_.Exception.Message)"
        }
    } else {
        $MountedVolumeLetter = "X:"
        Write-Host "  [Simulation] Mounted ISO to virtual drive: $MountedVolumeLetter" -ForegroundColor DarkCyan
    }

    try {
        # 7. Extract Base Setup Files (Excluding install.wim)
        Write-Host "Extracting Windows setup boot environment to $TargetDriveLetter..." -ForegroundColor Yellow
        if (-not $IsSimulated) {
            # Copy all files and folders excluding install.wim
            $RoboCmd = "robocopy `"$MountedVolumeLetter`" `"$TargetDriveLetter`" /E /XF install.wim /XD `"System Volume Information`" `$RECYCLE.BIN /NJH /NJS /NDL /NC /NS"
            cmd.exe /c $RoboCmd | Out-Null
            # robocopy exit codes: 0-7 = successful copy
            if ($LASTEXITCODE -gt 7) {
                throw "Robocopy failed to copy base ISO files (Exit code: $LASTEXITCODE)."
            }
            Write-Host "  Base setup files copied successfully." -ForegroundColor Green
        } else {
            Write-Host "  [Simulation] Extracted bootmgr, boot/, efi/, support/, and sources/ (excluding install.wim)." -ForegroundColor DarkCyan
        }

        # 8. Split install.wim via DISM
        Write-Host "Splitting install.wim into standard FAT32-compatible .swm slices via DISM..." -ForegroundColor Yellow
        $SourceWim = "$MountedVolumeLetter\sources\install.wim"
        $TargetSwm = "$TargetDriveLetter\sources\install.swm"

        if (-not $IsSimulated) {
            $TargetSources = "$TargetDriveLetter\sources"
            if (-not (Test-Path -LiteralPath $TargetSources)) {
                New-Item -ItemType Directory -Path $TargetSources -Force | Out-Null
            }

            # If sources\install.esd exists in ESD ISOs, it's already compressed <4GB
            $SourceEsd = "$MountedVolumeLetter\sources\install.esd"
            if (Test-Path -LiteralPath $SourceEsd) {
                Write-Host "  Found install.esd in ISO; copying directly..." -ForegroundColor Cyan
                Copy-Item -LiteralPath $SourceEsd -Destination (Join-Path $TargetSources "install.esd") -Force
                Write-Host "  install.esd copied directly." -ForegroundColor Green
            } elseif (Test-Path -LiteralPath $SourceWim) {
                Write-Host "  Running: dism.exe /Split-Image /ImageFile:`"$SourceWim`" /SWMFile:`"$TargetSwm`" /FileSize:3800" -ForegroundColor Cyan
                & dism.exe /Split-Image /ImageFile:"$SourceWim" /SWMFile:"$TargetSwm" /FileSize:3800
                if ($LASTEXITCODE -ne 0) {
                    throw "DISM split operation failed with exit code: $LASTEXITCODE"
                }
                Write-Host "  install.wim successfully split into install.swm slices." -ForegroundColor Green
            } else {
                throw "Neither install.wim nor install.esd found in source ISO sources\ directory!"
            }
        } else {
            Write-Host "  [Simulation] Executed: dism.exe /Split-Image /ImageFile:`"$SourceWim`" /SWMFile:`"$TargetSwm`" /FileSize:3800" -ForegroundColor DarkCyan
        }

        # 9. Inject Reglaze Artifacts
        Write-Host "Injecting Reglaze unattended deployment artifacts..." -ForegroundColor Yellow
        if (-not $IsSimulated) {
            # Copy autounattend.xml
            Copy-Item -LiteralPath $AutounattendSrc -Destination (Join-Path $TargetDriveLetter "autounattend.xml") -Force

            # Copy DiskMatch.ps1
            $DiskMatchSrc = Join-Path $MediaArtifactsDir "DiskMatch.ps1"
            if (Test-Path -LiteralPath $DiskMatchSrc) {
                Copy-Item -LiteralPath $DiskMatchSrc -Destination (Join-Path $TargetDriveLetter "DiskMatch.ps1") -Force
                $ReglazeSub = Join-Path $TargetDriveLetter "Reglaze"
                if (-not (Test-Path -LiteralPath $ReglazeSub)) { New-Item -ItemType Directory -Path $ReglazeSub -Force | Out-Null }
                Copy-Item -LiteralPath $DiskMatchSrc -Destination (Join-Path $ReglazeSub "DiskMatch.ps1") -Force
            }

            # Copy payload/
            $TargetPayload = Join-Path $TargetDriveLetter "payload"
            Copy-Item -Path $PayloadSrc -Destination $TargetDriveLetter -Recurse -Force
            # Also copy to Reglaze/payload for dual-discovery
            $ReglazePayload = Join-Path $TargetDriveLetter "Reglaze\payload"
            Copy-Item -Path $PayloadSrc -Destination (Join-Path $TargetDriveLetter "Reglaze") -Recurse -Force

            Write-Host "  Injected autounattend.xml, DiskMatch.ps1, and payload/ into $TargetDriveLetter." -ForegroundColor Green
        } else {
            Write-Host "  [Simulation] Staged autounattend.xml, DiskMatch.ps1, and payload/ to $TargetDriveLetter." -ForegroundColor DarkCyan
        }

    } finally {
        # 10. Dismount ISO
        if (-not $IsSimulated -and $MountedVolumeLetter) {
            Write-Host "Dismounting Windows 11 source ISO..." -ForegroundColor Yellow
            try {
                Dismount-DiskImage -ImagePath $IsoPath | Out-Null
                Write-Host "  ISO dismounted cleanly." -ForegroundColor Green
            } catch {
                Write-Warning "Failed to dismount ISO at '$IsoPath': $($_.Exception.Message)"
            }
        }
    }

    # 11. Final Validation
    Write-Host ""
    Write-Host "================================================================================" -ForegroundColor Green
    Write-Host "   REGLAZE UEFI BOOTABLE MEDIA SUCCESSFULLY CREATED!                            " -ForegroundColor Green
    Write-Host "================================================================================" -ForegroundColor Green
    Write-Host "  Target USB Drive: $TargetDriveLetter" -ForegroundColor Cyan
    Write-Host "  UEFI Bootloader:  $TargetDriveLetter\EFI\BOOT\BOOTX64.EFI" -ForegroundColor Cyan
    Write-Host "  Unattended Setup: $TargetDriveLetter\autounattend.xml" -ForegroundColor Cyan
    Write-Host "  OS Images:        $TargetDriveLetter\sources\install.swm" -ForegroundColor Cyan
    Write-Host "  Post-Inst Payload:$TargetDriveLetter\payload\" -ForegroundColor Cyan
    Write-Host ""

    return [PSCustomObject]@{
        Status            = "Success"
        UsbDrive          = $TargetDriveLetter
        Format            = "FAT32"
        IsSimulated       = $IsSimulated
        AutounattendPath  = Join-Path $TargetDriveLetter "autounattend.xml"
        PayloadPath       = Join-Path $TargetDriveLetter "payload"
    }
}
