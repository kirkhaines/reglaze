<#
.SYNOPSIS
    Game Manager & Multi-Library Discovery and Installation Engine for Reglaze.
.DESCRIPTION
    Provides multi-library detection across all mounted drives for gaming managers
    (Steam, Epic Games). Detects existing game installations regardless of which
    drive/library they reside in, and orchestrates fresh installations into default
    libraries for declared games not found on any reattached library.
#>
[CmdletBinding()]
param()

function Get-SteamLibraries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string[]]$AdditionalPaths = @()
    )

    $Libraries = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # 1. Query Steam Install Directory from Registry
    $SteamRegistryPaths = @(
        "HKCU:\Software\Valve\Steam",
        "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam",
        "HKLM:\SOFTWARE\Valve\Steam"
    )

    foreach ($RegPath in $SteamRegistryPaths) {
        if (Test-Path -LiteralPath $RegPath) {
            $SteamPath = (Get-ItemProperty -LiteralPath $RegPath -Name "SteamPath" -ErrorAction SilentlyContinue).SteamPath
            if (-not $SteamPath) {
                $SteamPath = (Get-ItemProperty -LiteralPath $RegPath -Name "InstallPath" -ErrorAction SilentlyContinue).InstallPath
            }
            if ($SteamPath) {
                $Normalized = $SteamPath -replace '/', '\'
                if (Test-Path -LiteralPath $Normalized) {
                    $Libraries.Add($Normalized) | Out-Null
                }
            }
        }
    }

    # Default fallback path
    $DefaultProgFiles = ${env:ProgramFiles(x86)}
    if ($DefaultProgFiles) {
        $DefaultSteam = Join-Path $DefaultProgFiles "Steam"
        if (Test-Path -LiteralPath $DefaultSteam) {
            $Libraries.Add($DefaultSteam) | Out-Null
        }
    }

    # 2. Parse libraryfolders.vdf from all discovered Steam locations
    $InitialLibs = @($Libraries)
    foreach ($Lib in $InitialLibs) {
        $VdfPath = Join-Path $Lib "steamapps\libraryfolders.vdf"
        if (Test-Path -LiteralPath $VdfPath) {
            try {
                $Content = Get-Content -Raw -LiteralPath $VdfPath -Encoding UTF8 -ErrorAction SilentlyContinue
                if ($Content) {
                    $Matches = [regex]::Matches($Content, '"path"\s+"([^"]+)"')
                    foreach ($Match in $Matches) {
                        $ParsedPath = $Match.Groups[1].Value -replace '\\\\', '\' -replace '/', '\'
                        if (Test-Path -LiteralPath $ParsedPath) {
                            $Libraries.Add($ParsedPath) | Out-Null
                        }
                    }
                }
            } catch {}
        }
    }

    # 3. Discover unmounted/reattached libraries across all mounted drives
    try {
        $Drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
        foreach ($Drv in $Drives) {
            if ($Drv.Root) {
                $Candidates = @(
                    (Join-Path $Drv.Root "SteamLibrary"),
                    (Join-Path $Drv.Root "Steam"),
                    (Join-Path $Drv.Root "Games\SteamLibrary"),
                    (Join-Path $Drv.Root "Games\Steam")
                )
                foreach ($Cand in $Candidates) {
                    if (Test-Path -LiteralPath $Cand) {
                        $AppsSub = Join-Path $Cand "steamapps"
                        if (Test-Path -LiteralPath $AppsSub) {
                            $Libraries.Add($Cand) | Out-Null
                        }
                    }
                }
            }
        }
    } catch {}

    # 4. Include explicit additional search paths (for testing / custom configurations)
    if ($AdditionalPaths) {
        foreach ($AddPath in $AdditionalPaths) {
            if ($AddPath -and (Test-Path -LiteralPath $AddPath)) {
                $Libraries.Add($AddPath) | Out-Null
            }
        }
    }

    return @($Libraries)
}

function Get-SteamInstalledGames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string[]]$Libraries = @()
    )

    if (-not $Libraries -or $Libraries.Count -eq 0) {
        $Libraries = Get-SteamLibraries
    }

    $Games = [System.Collections.Generic.List[PSCustomObject]]::new()
    $SeenIds = [System.Collections.Generic.HashSet[int]]::new()

    foreach ($Lib in $Libraries) {
        $SteamApps = Join-Path $Lib "steamapps"
        if (-not (Test-Path -LiteralPath $SteamApps)) { continue }

        $Manifests = Get-ChildItem -LiteralPath $SteamApps -Filter "appmanifest_*.acf" -File -ErrorAction SilentlyContinue
        foreach ($Mf in $Manifests) {
            if ($Mf.Name -match '^appmanifest_(\d+)\.acf$') {
                $AppId = [int]$Matches[1]
                $GameName = "Unknown"
                $InstallDir = ""

                try {
                    $Content = Get-Content -Raw -LiteralPath $Mf.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
                    if ($Content -match '"name"\s+"([^"]+)"') {
                        $GameName = $Matches[1]
                    }
                    if ($Content -match '"installdir"\s+"([^"]+)"') {
                        $InstallDir = $Matches[1]
                    }
                } catch {}

                if (-not $SeenIds.Contains($AppId)) {
                    $SeenIds.Add($AppId) | Out-Null
                    $Games.Add([PSCustomObject]@{
                        SteamId      = $AppId
                        GameName     = $GameName
                        InstallDir   = $InstallDir
                        LibraryPath  = $Lib
                        ManifestPath = $Mf.FullName
                    })
                }
            }
        }
    }

    return @($Games)
}

function Test-SteamGameInLibraries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [int]$SteamId,

        [Parameter(Mandatory=$false)]
        [string]$GameName = "",

        [Parameter(Mandatory=$false)]
        [string[]]$Libraries = @()
    )

    if (-not $Libraries -or $Libraries.Count -eq 0) {
        $Libraries = Get-SteamLibraries
    }

    foreach ($Lib in $Libraries) {
        $SteamApps = Join-Path $Lib "steamapps"
        if (-not (Test-Path -LiteralPath $SteamApps)) { continue }

        # Check for appmanifest file
        $ManifestPath = Join-Path $SteamApps "appmanifest_$SteamId.acf"
        if (Test-Path -LiteralPath $ManifestPath) {
            return [PSCustomObject]@{
                IsInstalled  = $true
                SteamId      = $SteamId
                GameName     = $GameName
                LibraryPath  = $Lib
                ManifestPath = $ManifestPath
            }
        }

        # Check common folder if game name is known
        if ($GameName) {
            $CommonDir = Join-Path $SteamApps "common\$GameName"
            if (Test-Path -LiteralPath $CommonDir) {
                return [PSCustomObject]@{
                    IsInstalled  = $true
                    SteamId      = $SteamId
                    GameName     = $GameName
                    LibraryPath  = $Lib
                    ManifestPath = $CommonDir
                }
            }
        }
    }

    return [PSCustomObject]@{
        IsInstalled  = $false
        SteamId      = $SteamId
        GameName     = $GameName
        LibraryPath  = $null
        ManifestPath = $null
    }
}

function Install-SteamGame {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [int]$SteamId,

        [Parameter(Mandatory=$false)]
        [string]$GameName = "Steam Application",

        [Parameter(Mandatory=$false)]
        [string[]]$Libraries = @(),

        [switch]$Simulation = $true,
        [switch]$Live = $false
    )

    $IsSimulated = $Simulation -or (-not $Live)

    # First check if the game already exists in ANY library
    $Check = Test-SteamGameInLibraries -SteamId $SteamId -GameName $GameName -Libraries $Libraries
    if ($Check.IsInstalled) {
        return [PSCustomObject]@{
            SteamId     = $SteamId
            GameName    = $GameName
            Status      = "AlreadyInstalled"
            LibraryPath = $Check.LibraryPath
            Message     = "Game '$GameName' ($SteamId) is already installed in library: $($Check.LibraryPath)"
        }
    }

    if ($IsSimulated) {
        return [PSCustomObject]@{
            SteamId     = $SteamId
            GameName    = $GameName
            Status      = "Simulated"
            LibraryPath = "Default"
            Message     = "Simulated fresh installation of '$GameName' ($SteamId) into default Steam library via steam://install/$SteamId"
        }
    } else {
        try {
            $Uri = "steam://install/$SteamId"
            Start-Process $Uri
            return [PSCustomObject]@{
                SteamId     = $SteamId
                GameName    = $GameName
                Status      = "Triggered"
                LibraryPath = "Default"
                Message     = "Triggered Steam install dialog for '$GameName' ($SteamId) into default library."
            }
        } catch {
            return [PSCustomObject]@{
                SteamId     = $SteamId
                GameName    = $GameName
                Status      = "Failed"
                LibraryPath = "Default"
                Message     = "Failed to trigger Steam install for ${SteamId}: $($_.Exception.Message)"
            }
        }
    }
}
