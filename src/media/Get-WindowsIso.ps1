<#
.SYNOPSIS
    Windows 11 Official ISO Discovery and Download Manager for Reglaze.
.DESCRIPTION
    Discovers, verifies, and downloads official vanilla Windows 11 installation ISOs:
    1. Scans designated directories and standard user Downloads across drives for existing ISOs.
    2. Identifies all candidate ISOs and automatically selects the most recent release and timestamp.
    3. Automates download from official Microsoft endpoints via BITS (Background
       Intelligent Transfer Service) or direct URL with dynamic target naming.
    4. Provides interactive guidance and monitoring across Downloads folders when browser download is used.
#>
[CmdletBinding()]
param()

function Get-IsoVersionRank {
    param([string]$FileName)

    # Heuristic scoring for Windows 11 release versions
    if ($FileName -match '(?i)25H2') { return 250 }
    if ($FileName -match '(?i)24H2') { return 240 }
    if ($FileName -match '(?i)23H2') { return 230 }
    if ($FileName -match '(?i)22H2') { return 220 }
    if ($FileName -match '(?i)21H2') { return 210 }
    if ($FileName -match '(?i)(Win11|Windows11|Windows_11|Win_11)') { return 200 }
    return 100
}

function Find-LocalWindowsIso {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$ExplicitPath = $null,

        [Parameter(Mandatory=$false)]
        [string]$SearchDir = $null
    )

    # 1. Check explicit path
    if ($ExplicitPath) {
        if (Test-Path -LiteralPath $ExplicitPath) {
            $Item = Get-Item -LiteralPath $ExplicitPath
            if ($Item.Extension -ieq ".iso" -and $Item.Length -gt 3GB) {
                return $Item.FullName
            }
        }
    }

    # 2. Check candidate directories
    $CandidateDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if ($SearchDir -and (Test-Path -LiteralPath $SearchDir)) {
        try { $CandidateDirs.Add((Get-Item -LiteralPath $SearchDir).FullName) | Out-Null } catch {}
    }

    # Current working dir / repo downloads
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $RepoDownloads = Join-Path $RepoRoot "downloads"
    if (Test-Path -LiteralPath $RepoDownloads) { 
        try { $CandidateDirs.Add((Get-Item -LiteralPath $RepoDownloads).FullName) | Out-Null } catch {}
    }

    $CurrentDownloads = Join-Path (Get-Location) "downloads"
    if (Test-Path -LiteralPath $CurrentDownloads) {
        try { $CandidateDirs.Add((Get-Item -LiteralPath $CurrentDownloads).FullName) | Out-Null } catch {}
    }

    # Candidate user profile download directories
    $UserProfiles = @(
        [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile),
        $env:USERPROFILE,
        "C:\Users\$($env:USERNAME)",
        "D:\Users\$($env:USERNAME)"
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    foreach ($Prof in $UserProfiles) {
        $DlPath = Join-Path $Prof "Downloads"
        if (Test-Path -LiteralPath $DlPath) {
            try { $CandidateDirs.Add((Get-Item -LiteralPath $DlPath).FullName) | Out-Null } catch {}
        }
    }

    # Official Shell Downloads Folder from Registry
    try {
        $ShellDl = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction SilentlyContinue).'{374DE290-123F-4565-9164-39C4925E467B}'
        if ($ShellDl) {
            $Expanded = [System.Environment]::ExpandEnvironmentVariables($ShellDl)
            if (Test-Path -LiteralPath $Expanded) {
                $CandidateDirs.Add((Get-Item -LiteralPath $Expanded).FullName) | Out-Null
            }
        }
    } catch {}

    # 3. Discover all matching ISOs across all candidate directories
    $DiscoveredIsos = [System.Collections.Generic.List[PSCustomObject]]::new()
    $SeenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Dir in $CandidateDirs) {
        $IsoFiles = Get-ChildItem -LiteralPath $Dir -Filter "*.iso" -File -ErrorAction SilentlyContinue
        foreach ($File in $IsoFiles) {
            if ($SeenPaths.Contains($File.FullName)) { continue }

            $IsWin11 = ($File.Length -gt 3GB) -and (
                ($File.Name -match '(?i)(Win11|Windows11|Windows_11|Win_11|Windows.*11)') -or
                ($File.Name -match '(?i)2[2-5]H2') -or
                ($File.Name -match '(?i)^Windows\.iso$') -or
                ($File.Name -match '(?i)en[_-]us.*11.*\.iso$')
            )

            if ($IsWin11) {
                $SeenPaths.Add($File.FullName) | Out-Null
                $DiscoveredIsos.Add([PSCustomObject]@{
                    FullName      = $File.FullName
                    Name          = $File.Name
                    Length        = $File.Length
                    SizeGB        = [Math]::Round($File.Length / 1GB, 2)
                    LastWriteTime = $File.LastWriteTime
                    VersionRank   = (Get-IsoVersionRank -FileName $File.Name)
                    Directory     = $File.DirectoryName
                })
            }
        }
    }

    if ($DiscoveredIsos.Count -eq 0) {
        return $null
    }

    # 4. Sort discovered ISOs by VersionRank descending, then LastWriteTime descending
    $Sorted = $DiscoveredIsos | Sort-Object -Property @{ Expression = { $_.VersionRank }; Descending = $true }, @{ Expression = { $_.LastWriteTime }; Descending = $true }

    if ($Sorted.Count -gt 1) {
        Write-Host "Discovered $($Sorted.Count) candidate Windows 11 ISOs:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $Sorted.Count; $i++) {
            $Item = $Sorted[$i]
            $Tag = if ($i -eq 0) { " [SELECTED: Most Recent]" } else { "" }
            Write-Host "  [$($i+1)] $($Item.Name) ($($Item.SizeGB) GB, Modified: $($Item.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))$Tag" -ForegroundColor $(if ($i -eq 0) { "Green" } else { "DarkGray" })
            Write-Host "      Location: $($Item.FullName)" -ForegroundColor DarkGray
        }
    }

    return $Sorted[0].FullName
}

function Get-Windows11Iso {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$IsoPath = $null,

        [Parameter(Mandatory=$false)]
        [string]$DestinationDir = $null,

        [Parameter(Mandatory=$false)]
        [string]$DownloadUrl = $null,

        [switch]$OpenBrowser = $false,
        [switch]$Simulation = $true,
        [switch]$Live = $false
    )

    $IsSimulated = $Simulation -or (-not $Live)

    if (-not $DestinationDir) {
        $DestinationDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "downloads"
    }

    # 1. Search for existing local ISO (selects most recent)
    $ExistingIso = Find-LocalWindowsIso -ExplicitPath $IsoPath -SearchDir $DestinationDir
    if ($ExistingIso) {
        $FileInfo = Get-Item -LiteralPath $ExistingIso
        $SizeGB = [Math]::Round($FileInfo.Length / 1GB, 2)
        Write-Host "Found existing Windows 11 installation ISO:" -ForegroundColor Green
        Write-Host "  Path: $ExistingIso ($SizeGB GB, Modified: $($FileInfo.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))" -ForegroundColor Cyan
        return [PSCustomObject]@{
            Status   = "Found"
            IsoPath  = $ExistingIso
            SizeGB   = $SizeGB
            Message  = "Existing Windows 11 ISO verified."
        }
    }

    # 2. Simulation mode handling
    if ($IsSimulated) {
        $MockPath = if ($IsoPath) { $IsoPath } else { Join-Path $DestinationDir "Win11_24H2_English_x64.iso" }
        Write-Host "Simulation: Simulated discovery/download of Windows 11 ISO to $MockPath" -ForegroundColor DarkCyan
        return [PSCustomObject]@{
            Status   = "Simulated"
            IsoPath  = $MockPath
            SizeGB   = 5.4
            Message  = "Simulated Windows 11 ISO acquisition."
        }
    }

    # 3. Ensure target destination directory exists
    if (-not (Test-Path -LiteralPath $DestinationDir)) {
        New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
    }

    # 4. Direct download if URL is provided
    if ($DownloadUrl) {
        # Derive target ISO name dynamically from URL
        $TargetIsoName = "Win11_Latest_English_x64.iso"
        try {
            $Uri = [System.Uri]$DownloadUrl
            $UrlFileName = [System.IO.Path]::GetFileName($Uri.LocalPath)
            if ($UrlFileName -and $UrlFileName.EndsWith(".iso", [System.StringComparison]::OrdinalIgnoreCase)) {
                $TargetIsoName = $UrlFileName
            }
        } catch {}

        $TargetIsoPath = Join-Path $DestinationDir $TargetIsoName
        Write-Host "Downloading official Windows 11 ISO via BITS from:" -ForegroundColor Cyan
        Write-Host "  $DownloadUrl" -ForegroundColor DarkCyan
        Write-Host "Target: $TargetIsoPath" -ForegroundColor Cyan

        try {
            if (Get-Command "Start-BitsTransfer" -ErrorAction SilentlyContinue) {
                Start-BitsTransfer -Source $DownloadUrl -Destination $TargetIsoPath -DisplayName "Reglaze Windows 11 ISO Download" -Description "Downloading vanilla Windows 11 ISO from Microsoft CDN" -Priority High
            } else {
                Invoke-WebRequest -Uri $DownloadUrl -OutFile $TargetIsoPath -UseBasicParsing
            }

            if ((Test-Path -LiteralPath $TargetIsoPath) -and (Get-Item -LiteralPath $TargetIsoPath).Length -gt 3GB) {
                $SizeGB = [Math]::Round((Get-Item -LiteralPath $TargetIsoPath).Length / 1GB, 2)
                Write-Host "Download completed successfully: $TargetIsoPath ($SizeGB GB)" -ForegroundColor Green
                return [PSCustomObject]@{
                    Status   = "Downloaded"
                    IsoPath  = $TargetIsoPath
                    SizeGB   = $SizeGB
                    Message  = "Windows 11 ISO downloaded successfully."
                }
            }
        } catch {
            Write-Warning "Direct download failed: $($_.Exception.Message)"
        }
    }

    # 5. Interactive Microsoft Download Helper
    Write-Host ""
    Write-Host "================================================================================" -ForegroundColor Yellow
    Write-Host "           OFFICIAL MICROSOFT WINDOWS 11 ISO ACQUISITION HELPER                 " -ForegroundColor Yellow
    Write-Host "================================================================================" -ForegroundColor Yellow
    Write-Host "Microsoft provides official Windows 11 ISO downloads directly from:"
    Write-Host "  https://www.microsoft.com/software-download/windows11" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Instructions:"
    Write-Host "  1. Select 'Download Windows 11 Disk Image (ISO) for x64 devices'."
    Write-Host "  2. Choose product language: 'English (United States)'."
    Write-Host "  3. Click '64-bit Download'."
    Write-Host "  4. Save or move the downloaded .iso to:"
    Write-Host "     $DestinationDir" -ForegroundColor Green
    Write-Host "     (Or keep it in your Downloads folder; Reglaze monitors both)" -ForegroundColor DarkGray
    Write-Host ""

    if ($OpenBrowser) {
        Write-Host "Opening Microsoft Software Download page in default browser..." -ForegroundColor DarkCyan
        Start-Process "https://www.microsoft.com/software-download/windows11"
    }

    Write-Host "Monitoring Downloads and $DestinationDir for newly downloaded ISO file..." -ForegroundColor Yellow
    Write-Host "Press Ctrl+C at any time to abort." -ForegroundColor DarkGray
    $StartTime = (Get-Date).AddMinutes(-5)
    $PollSeconds = 0
    while ($PollSeconds -lt 1800) { # Wait up to 30 minutes
        Start-Sleep -Seconds 5
        $PollSeconds += 5

        $Discovered = Find-LocalWindowsIso -SearchDir $DestinationDir
        if ($Discovered) {
            $FileInfo = Get-Item -LiteralPath $Discovered
            if ($FileInfo.LastWriteTime -ge $StartTime -or $FileInfo.Length -gt 3GB) {
                # Test whether file is locked by the browser (download in progress)
                $IsLocked = $false
                try {
                    $Stream = [System.IO.File]::Open($Discovered, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
                    if ($Stream) { $Stream.Close() }
                } catch {
                    $IsLocked = $true
                }

                # Also verify no active browser part files exist
                $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($Discovered)
                $ParentDir = $FileInfo.DirectoryName
                $TempParts = Get-ChildItem -LiteralPath $ParentDir -Filter "*$BaseName*.crdownload" -File -ErrorAction SilentlyContinue
                if (-not $TempParts) {
                    $TempParts = Get-ChildItem -LiteralPath $ParentDir -Filter "*$BaseName*.part" -File -ErrorAction SilentlyContinue
                }

                if (-not $IsLocked -and (-not $TempParts -or $TempParts.Count -eq 0)) {
                    $SizeGB = [Math]::Round($FileInfo.Length / 1GB, 2)
                    Write-Host ""
                    Write-Host "Discovered complete Windows 11 ISO: $Discovered ($SizeGB GB)" -ForegroundColor Green
                    return [PSCustomObject]@{
                        Status   = "Acquired"
                        IsoPath  = $Discovered
                        SizeGB   = $SizeGB
                        Message  = "Windows 11 ISO acquired and verified."
                    }
                }
            }
        }
    }

    return [PSCustomObject]@{
        Status   = "NotFound"
        IsoPath  = $null
        SizeGB   = 0
        Message  = "No Windows 11 ISO detected within timeout."
    }
}
