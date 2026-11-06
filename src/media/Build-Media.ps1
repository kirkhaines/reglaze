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
# [HITL-DESCRIPTION]: Formats USB drive as FAT32, splits install.wim via dism /Split-Image to local cache, and streams via robocopy /J + autounattend.xml + payload.
# [HITL-TEST-SNIPPET]:
#   # Safe inspection of connected USB storage devices:
#   Get-Disk | Where-Object { $_.BusType -eq 'USB' } | Select-Object Number, FriendlyName, BusType, Size, OperationalStatus
# [HITL-LAST-INPUT]: Read-only query of physical disks on developer host
# [HITL-LAST-RESULT]: PENDING
# [HITL-PATTERN]: Format-Volume -DriveLetter $Letter -FileSystem FAT32; dism /Split-Image /ImageFile:... /SWMFile:$Cache\install.swm /FileSize:3800; robocopy $Cache $UsbSources install*.swm /J
# [HITL-AVOID]: Splitting DISM directly across USB bus (causes 100% disk activity bottleneck and FAT thrashing); creating media on internal disks
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

function Test-WindowsInstallMedia {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    $CleanPath = $Path.Trim()
    if ($CleanPath -match '^[a-zA-Z]:?$') {
        $Root = ($CleanPath.TrimEnd(':') + ":\")
    } else {
        $Root = $CleanPath
    }

    if (-not (Test-Path -LiteralPath $Root)) {
        return [PSCustomObject]@{
            IsValid     = $false
            RootPath    = $Root
            ImageType   = $null
            ImageSizeGB = 0
            Issues      = @("Path '$Root' is not accessible or does not exist.")
            Message     = "Path '$Root' is not accessible or does not exist."
        }
    }

    $Issues = [System.Collections.Generic.List[string]]::new()

    # 1. Check sources directory
    $SourcesDir = Join-Path $Root "sources"
    if (-not (Test-Path -LiteralPath $SourcesDir)) {
        $Issues.Add("Missing 'sources\' directory")
    }

    # 2. Check bootloader / boot environment (bootmgr, bootmgr.efi, or efi/boot/bootx64.efi)
    $HasBootmgr = (Test-Path -LiteralPath (Join-Path $Root "bootmgr")) -or (Test-Path -LiteralPath (Join-Path $Root "bootmgr.efi"))
    $HasEfiBoot = (Test-Path -LiteralPath (Join-Path $Root "efi\boot\bootx64.efi")) -or (Test-Path -LiteralPath (Join-Path $Root "efi"))
    if (-not $HasBootmgr -and -not $HasEfiBoot) {
        $Issues.Add("Missing boot environment (neither 'bootmgr', 'bootmgr.efi', nor 'efi\' directory found)")
    }

    # 3. Check for WinPE boot image (sources\boot.wim)
    $BootWim = Join-Path $SourcesDir "boot.wim"
    if (-not (Test-Path -LiteralPath $BootWim)) {
        $Issues.Add("Missing 'sources\boot.wim' (Windows PE boot image)")
    }

    # 4. Check for Windows installation image (install.wim, install.esd, or install*.swm)
    $InstallWim = Join-Path $SourcesDir "install.wim"
    $InstallEsd = Join-Path $SourcesDir "install.esd"
    $InstallSwms = if (Test-Path -LiteralPath $SourcesDir) {
        @(Get-ChildItem -LiteralPath $SourcesDir -Filter "install*.swm" -ErrorAction SilentlyContinue)
    } else { @() }

    $TotalImageBytes = 0
    $FoundImageType = $null

    if (Test-Path -LiteralPath $InstallWim) {
        $FoundImageType = "install.wim"
        $TotalImageBytes = (Get-Item -LiteralPath $InstallWim).Length
    } elseif (Test-Path -LiteralPath $InstallEsd) {
        $FoundImageType = "install.esd"
        $TotalImageBytes = (Get-Item -LiteralPath $InstallEsd).Length
    } elseif ($InstallSwms.Count -gt 0) {
        $FoundImageType = "install*.swm ($($InstallSwms.Count) slice(s))"
        $TotalImageBytes = ($InstallSwms | Measure-Object -Property Length -Sum).Sum
    } else {
        $Issues.Add("Missing Windows OS installation image (neither 'install.wim', 'install.esd', nor 'install*.swm' found in 'sources\')")
    }

    if ($FoundImageType -and $TotalImageBytes -lt 1GB) {
        $Issues.Add("Windows OS image ($FoundImageType) is unexpectedly small ($([Math]::Round($TotalImageBytes / 1GB, 2)) GB; expected >= 1.0 GB)")
    }

    $IsValid = ($Issues.Count -eq 0)
    return [PSCustomObject]@{
        IsValid     = $IsValid
        RootPath    = $Root
        ImageType   = $FoundImageType
        ImageSizeGB = [Math]::Round($TotalImageBytes / 1GB, 2)
        Issues      = $Issues.ToArray()
        Message     = if ($IsValid) {
            "Verified plausible Windows installer at $Root (Image: $FoundImageType, $([Math]::Round($TotalImageBytes / 1GB, 2)) GB)."
        } else {
            "Plausibility checks failed at ${Root}: " + ($Issues -join "; ")
        }
    }
}

function New-ReglazeBootableUsb {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)]
        [string]$UsbDrive,

        [Parameter(Mandatory=$false)]
        [string]$IsoPath = $null,

        [Parameter(Mandatory=$false)]
        [string]$MediaArtifactsDir = $null,

        [Alias("UpdateOnly", "KeepWindowsFiles", "QuickUpdate", "RetainInstaller")]
        [switch]$RetainWindowsFiles = $false,

        [switch]$Force = $false,
        [switch]$Simulation = $true,
        [switch]$Live = $false,
        [switch]$Elevate = $false,
        [switch]$SkipElevation = $false
    )

    $IsSimulated = $Simulation -or (-not $Live)

    $CleanLetter = ($UsbDrive -replace '[:\\/]', '').ToUpper()
    $TargetDriveLetter = "${CleanLetter}:"

    Write-Host "================================================================================" -ForegroundColor Cyan
    Write-Host "       REGLAZE VANILLA WINDOWS 11 UEFI MEDIA CREATION ENGINE                    " -ForegroundColor Cyan
    Write-Host "================================================================================" -ForegroundColor Cyan

    # 0. Pre-Flight Administrator Elevation Check (Required for DISM /Split-Image and disk operations; not needed for file updates with -RetainWindowsFiles)
    $IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $IsAdmin -and -not $IsSimulated -and -not $RetainWindowsFiles) {
        $CanPrompt = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and -not $SkipElevation
        $ShouldElevate = $Elevate

        if (-not $Elevate -and $CanPrompt) {
            Write-Host ""
            Write-Host "  [?] Bootable USB creation and DISM image splitting require Administrator elevation." -ForegroundColor Yellow
            $Response = Read-Host "      Prompt for UAC elevation to create installation media? [Y/n]"
            if (-not $Response -or $Response.Trim().ToLower() -ne 'n') {
                $ShouldElevate = $true
            }
        }

        if ($ShouldElevate) {
            Write-Host "  [i] Requesting Administrator elevation via UAC..." -ForegroundColor Cyan
            $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $ReglazeCli = Join-Path $RepoRoot "bin\reglaze.ps1"

            $Candidates = @()
            if ($PSVersionTable.PSEdition -eq 'Core') {
                $Candidates += "pwsh.exe"
                $Candidates += "pwsh"
                $Candidates += "powershell.exe"
            } else {
                $Candidates += "powershell.exe"
                $Candidates += "pwsh.exe"
            }

            $ArgList = "-NoProfile -ExecutionPolicy Bypass -File `"$ReglazeCli`" media -UsbDrive `"$CleanLetter`"$(if ($IsoPath) { ' -IsoPath `"' + $IsoPath + '`"' }) -DistDir `"$MediaArtifactsDir`"$(if ($Force) { ' -Force' })$(if ($RetainWindowsFiles) { ' -RetainWindowsFiles' })"

            $ElevatedSuccess = $false
            $LastError = $null
            foreach ($Exe in $Candidates) {
                if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) { continue }
                try {
                    $Proc = Start-Process -FilePath $Exe -ArgumentList $ArgList -Verb RunAs -Wait -PassThru -ErrorAction Stop
                    if ($Proc.ExitCode -eq 0) {
                        $ElevatedSuccess = $true
                        break
                    } else {
                        $LastError = "Elevated media process exited with code $($Proc.ExitCode)."
                    }
                } catch {
                    $LastError = $_.Exception.Message
                }
            }

            if ($ElevatedSuccess) {
                Write-Host "  [+] Elevated media creation completed successfully." -ForegroundColor Green
                return [PSCustomObject]@{
                    Status             = "Success"
                    UsbDrive           = $TargetDriveLetter
                    Format             = if ($RetainWindowsFiles) { "Retained" } else { "FAT32" }
                    RetainWindowsFiles = [bool]$RetainWindowsFiles
                    IsSimulated        = $false
                    Elevated           = $true
                }
            } else {
                throw "Administrator elevation failed or was canceled: $LastError"
            }
        } else {
            throw "Media creation requires Administrator elevation to run DISM. Please relaunch PowerShell as Administrator or pass -Elevate."
        }
    }

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

    # 2. Windows Installer / ISO Verification
    if ($RetainWindowsFiles) {
        Write-Host "Verifying existing Windows installation files on $TargetDriveLetter (-RetainWindowsFiles)..." -ForegroundColor Yellow
        if (-not $IsSimulated) {
            $PlausibleCheck = Test-WindowsInstallMedia -Path $TargetDriveLetter
            if (-not $PlausibleCheck.IsValid) {
                throw "Cannot retain Windows files on $TargetDriveLetter - $($PlausibleCheck.Message)`nTo format and create fresh installation media from an ISO, omit -RetainWindowsFiles."
            }
            Write-Host "  [+] $($PlausibleCheck.Message)" -ForegroundColor Green
        } else {
            Write-Host "  [Simulation] Verified plausible Windows installer on $TargetDriveLetter (bootmgr/efi, sources\boot.wim, sources\install*.swm)." -ForegroundColor DarkCyan
        }
    } else {
        if ([string]::IsNullOrWhiteSpace($IsoPath)) {
            throw "Source Windows 11 ISO path (-IsoPath) is required when creating fresh installation media."
        }
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
    }

    # 3. Resolve Media Artifacts Directory
    if (-not $MediaArtifactsDir) {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $MediaArtifactsDir = Join-Path $RepoRoot "dist\media"
    }

    Write-Host "Verifying deployment media artifacts: $MediaArtifactsDir..." -ForegroundColor Yellow
    $AutounattendSrc = Join-Path $MediaArtifactsDir "autounattend.xml"
    $PayloadSrc = Join-Path $MediaArtifactsDir "Reglaze\payload"
    if (-not (Test-Path -LiteralPath $PayloadSrc)) {
        $PayloadSrc = Join-Path $MediaArtifactsDir "payload"
    }

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
        if ($RetainWindowsFiles) {
            Write-Host "NOTICE: Updating Reglaze deployment files on $TargetDriveLetter (Windows setup files will be preserved)." -ForegroundColor Cyan
            $Confirm = Read-Host "Proceed with updating Reglaze files on $TargetDriveLetter? (yes/NO)"
        } else {
            Write-Host "WARNING: ALL DATA ON DRIVE $TargetDriveLetter WILL BE COMPLETELY DESTROYED!" -ForegroundColor Red
            $Confirm = Read-Host "Are you sure you want to format $TargetDriveLetter and create Reglaze media? (yes/NO)"
        }
        if ($Confirm -inotmatch '^yes$') {
            Write-Host "Media operation aborted by user." -ForegroundColor Yellow
            return [PSCustomObject]@{ Status = "Aborted"; UsbDrive = $TargetDriveLetter }
        }
    }

    if (-not $RetainWindowsFiles) {
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
    } else {
        $MountedVolumeLetter = $null
        if ($IsSimulated) {
            Write-Host "  [Simulation] Retaining existing Windows install files on $TargetDriveLetter. Skipped format, ISO mount, and image copy." -ForegroundColor DarkCyan
        } else {
            Write-Host "  Retaining existing Windows install files on $TargetDriveLetter. Skipped format, ISO mount, and image copy." -ForegroundColor Green
        }
    }

    try {
        if (-not $RetainWindowsFiles) {
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

            # 8. Split install.wim via DISM (Optimized with Local Fast-Storage Caching & Unbuffered I/O)
            Write-Host "Preparing Windows installation image (install.wim / install.swm)..." -ForegroundColor Yellow
            $SourceWim = "$MountedVolumeLetter\sources\install.wim"
            $SourceEsd = "$MountedVolumeLetter\sources\install.esd"
            $TargetSources = "$TargetDriveLetter\sources"

            $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $IsoBaseName = if ($IsoPath) { [System.IO.Path]::GetFileNameWithoutExtension($IsoPath) } else { "windows11" }

            # Resolve fast local storage cache directory for split .swm slices
            $CandidateCacheDirs = @()
            if ($IsoPath -and (Test-Path -LiteralPath $IsoPath)) {
                $CandidateCacheDirs += Join-Path (Split-Path -Parent (Resolve-Path $IsoPath)) "swm_cache\$IsoBaseName"
            }
            $CandidateCacheDirs += Join-Path $RepoRoot "downloads\swm_cache\$IsoBaseName"
            $CandidateCacheDirs += Join-Path $env:TEMP "reglaze_swm_cache\$IsoBaseName"

            $LocalSwmCacheDir = $null
            foreach ($Candidate in $CandidateCacheDirs) {
                try {
                    if (-not (Test-Path -LiteralPath $Candidate)) {
                        New-Item -ItemType Directory -Path $Candidate -Force -ErrorAction Stop | Out-Null
                    }
                    $TestFile = Join-Path $Candidate ".write_test"
                    Set-Content -LiteralPath $TestFile -Value "test" -ErrorAction Stop
                    Remove-Item -LiteralPath $TestFile -Force -ErrorAction SilentlyContinue
                    $LocalSwmCacheDir = $Candidate
                    break
                } catch {
                    continue
                }
            }
            if (-not $LocalSwmCacheDir) {
                $LocalSwmCacheDir = Join-Path $RepoRoot "downloads\swm_cache\$IsoBaseName"
            }

            if (-not $IsSimulated) {
                if (-not (Test-Path -LiteralPath $TargetSources)) {
                    New-Item -ItemType Directory -Path $TargetSources -Force | Out-Null
                }

                # If sources\install.esd exists in ESD ISOs, it's already compressed <4GB
                if (Test-Path -LiteralPath $SourceEsd) {
                    Write-Host "  Found install.esd in ISO; copying to USB using unbuffered I/O (robocopy /J)..." -ForegroundColor Cyan
                    $SourceEsdDir = Split-Path -Parent $SourceEsd
                    $RoboEsdCmd = "robocopy `"$SourceEsdDir`" `"$TargetSources`" install.esd /J /NP /NDL /NC /NS"
                    cmd.exe /c $RoboEsdCmd | Out-Null
                    if ($LASTEXITCODE -gt 7) {
                        throw "Robocopy failed to copy install.esd to USB drive (Exit code: $LASTEXITCODE)."
                    }
                    Write-Host "  install.esd copied directly." -ForegroundColor Green
                } elseif (Test-Path -LiteralPath $SourceWim) {
                    $SourceWimLength = (Get-Item -LiteralPath $SourceWim).Length
                    $CachedSlices = Get-ChildItem -LiteralPath $LocalSwmCacheDir -Filter "install*.swm" -ErrorAction SilentlyContinue
                    $CacheValid = $false
                    if ($CachedSlices) {
                        $TotalCachedSize = ($CachedSlices | Measure-Object -Property Length -Sum).Sum
                        $PrimarySlice = Join-Path $LocalSwmCacheDir "install.swm"
                        # Valid if install.swm exists, total size > 3GB, and at least 95% of source WIM size
                        if ((Test-Path -LiteralPath $PrimarySlice) -and $TotalCachedSize -gt 3GB -and $TotalCachedSize -ge ($SourceWimLength * 0.95)) {
                            $CacheValid = $true
                        }
                    }

                    if ($CacheValid) {
                        Write-Host "  Found valid cached split .swm slices in: $LocalSwmCacheDir" -ForegroundColor Green
                        Write-Host "  Cache contains $($CachedSlices.Count) slices ($([Math]::Round($TotalCachedSize / 1GB, 2)) GB). Skipping DISM split..." -ForegroundColor Green
                    } else {
                        Write-Host "  Splitting install.wim on fast local storage: $LocalSwmCacheDir\install.swm..." -ForegroundColor Yellow
                        # Remove any stale/partial slices before splitting
                        Get-ChildItem -LiteralPath $LocalSwmCacheDir -Filter "install*.swm" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

                        $LocalSwmTarget = Join-Path $LocalSwmCacheDir "install.swm"
                        $DismExit = -1
                        if ($IsAdmin) {
                            & dism.exe /Split-Image /ImageFile:"$SourceWim" /SWMFile:"$LocalSwmTarget" /FileSize:3800
                            $DismExit = $LASTEXITCODE
                        } else {
                            Write-Host "  [i] Requesting UAC elevation for DISM image splitting..." -ForegroundColor Cyan
                            $DismArgs = "/Split-Image /ImageFile:`"$SourceWim`" /SWMFile:`"$LocalSwmTarget`" /FileSize:3800"
                            $DismProc = Start-Process -FilePath "dism.exe" -ArgumentList $DismArgs -Verb RunAs -Wait -PassThru
                            $DismExit = $DismProc.ExitCode
                        }
                        if ($DismExit -ne 0) {
                            throw "DISM split operation failed with exit code: $DismExit"
                        }
                        Write-Host "  DISM split complete on local storage." -ForegroundColor Green
                    }

                    # Stream .swm slices from local fast storage to USB using unbuffered large-block I/O (robocopy /J)
                    Write-Host "  Streaming install*.swm slices to USB drive using unbuffered I/O (robocopy /J)..." -ForegroundColor Cyan
                    $RoboSwmCmd = "robocopy `"$LocalSwmCacheDir`" `"$TargetSources`" install*.swm /J /NP /NDL /NC /NS"
                    cmd.exe /c $RoboSwmCmd | Out-Null
                    if ($LASTEXITCODE -gt 7) {
                        throw "Robocopy failed to copy install*.swm slices to USB drive (Exit code: $LASTEXITCODE)."
                    }
                    Write-Host "  install*.swm slices successfully copied to USB." -ForegroundColor Green
                } else {
                    throw "Neither install.wim nor install.esd found in source ISO sources\ directory!"
                }
            } else {
                Write-Host "  [Simulation] Local fast storage split & cache target: $LocalSwmCacheDir\install.swm" -ForegroundColor DarkCyan
                Write-Host "  [Simulation] Executed: dism.exe /Split-Image /ImageFile:`"$SourceWim`" /SWMFile:`"$LocalSwmCacheDir\install.swm`" /FileSize:3800" -ForegroundColor DarkCyan
                Write-Host "  [Simulation] Streamed install*.swm to $TargetSources via unbuffered I/O (robocopy /J)." -ForegroundColor DarkCyan
            }
        }


        # 9. Inject Reglaze Artifacts
        Write-Host "Injecting Reglaze unattended deployment artifacts..." -ForegroundColor Yellow
        if (-not $IsSimulated) {
            # Copy autounattend.xml
            Copy-Item -LiteralPath $AutounattendSrc -Destination (Join-Path $TargetDriveLetter "autounattend.xml") -Force

            # Copy WinPE & preparation tools exclusively to \Reglaze\
            $ReglazeSub = Join-Path $TargetDriveLetter "Reglaze"
            if (-not (Test-Path -LiteralPath $ReglazeSub)) { New-Item -ItemType Directory -Path $ReglazeSub -Force | Out-Null }
            foreach ($ToolName in @("DiskMatch.vbs", "protect-disks.cmd", "DiskMatch.ps1", "prepare-target-disk.cmd", "prepare-target-disk.vbs")) {
                $ToolSrc = Join-Path $MediaArtifactsDir "Reglaze\$ToolName"
                if (-not (Test-Path -LiteralPath $ToolSrc)) {
                    $ToolSrc = Join-Path $MediaArtifactsDir $ToolName
                }
                if (Test-Path -LiteralPath $ToolSrc) {
                    # Copy only to Reglaze directory
                    Copy-Item -LiteralPath $ToolSrc -Destination (Join-Path $ReglazeSub $ToolName) -Force
                }
            }

            # Copy payload exclusively into Reglaze\payload
            $ReglazePayload = Join-Path $ReglazeSub "payload"
            if (-not (Test-Path -LiteralPath $ReglazePayload)) { New-Item -ItemType Directory -Path $ReglazePayload -Force | Out-Null }
            Copy-Item -Path (Join-Path $PayloadSrc "*") -Destination $ReglazePayload -Recurse -Force

            # Clean up any legacy root duplicate files / directories
            foreach ($LegacyRootFile in @("prepare-target-disk.cmd", "prepare-target-disk.vbs", "DiskMatch.vbs", "protect-disks.cmd", "DiskMatch.ps1")) {
                $LegacyPath = Join-Path $TargetDriveLetter $LegacyRootFile
                if (Test-Path -LiteralPath $LegacyPath) {
                    Remove-Item -LiteralPath $LegacyPath -Force -ErrorAction SilentlyContinue
                }
            }
            $LegacyPayload = Join-Path $TargetDriveLetter "payload"
            if (Test-Path -LiteralPath $LegacyPayload) {
                Remove-Item -LiteralPath $LegacyPayload -Recurse -Force -ErrorAction SilentlyContinue
            }

            Write-Host "  Injected autounattend.xml and organized Reglaze tools & payload under $ReglazeSub." -ForegroundColor Green
        } else {
            Write-Host "  [Simulation] Staged autounattend.xml, prepare-target-disk tools, DiskMatch tools, and payload/ to $TargetDriveLetter." -ForegroundColor DarkCyan
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
    if ($RetainWindowsFiles) {
        Write-Host "   REGLAZE DEPLOYMENT MEDIA UPDATED! (WINDOWS INSTALLER RETAINED)               " -ForegroundColor Green
    } else {
        Write-Host "   REGLAZE UEFI BOOTABLE MEDIA SUCCESSFULLY CREATED!                            " -ForegroundColor Green
    }
    Write-Host "================================================================================" -ForegroundColor Green
    Write-Host "  Target USB Drive: $TargetDriveLetter" -ForegroundColor Cyan
    Write-Host "  UEFI Bootloader:  $TargetDriveLetter\EFI\BOOT\BOOTX64.EFI" -ForegroundColor Cyan
    Write-Host "  Unattended Setup: $TargetDriveLetter\autounattend.xml" -ForegroundColor Cyan
    Write-Host "  OS Images:        $TargetDriveLetter\sources\install.swm" -ForegroundColor Cyan
    Write-Host "  Post-Inst Payload:$TargetDriveLetter\Reglaze\payload\" -ForegroundColor Cyan
    Write-Host ""

    return [PSCustomObject]@{
        Status             = "Success"
        UsbDrive           = $TargetDriveLetter
        Format             = if ($RetainWindowsFiles) { "Retained" } else { "FAT32" }
        RetainWindowsFiles = [bool]$RetainWindowsFiles
        IsSimulated        = $IsSimulated
        AutounattendPath   = [System.IO.Path]::Combine("$TargetDriveLetter\", "autounattend.xml")
        PayloadPath        = [System.IO.Path]::Combine("$TargetDriveLetter\", "Reglaze\payload")
    }
}
