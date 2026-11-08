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
                        if (Test-Path -LiteralPath $ParsedPath -ErrorAction SilentlyContinue) {
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
                    if (Test-Path -LiteralPath $Cand -ErrorAction SilentlyContinue) {
                        $AppsSub = Join-Path $Cand "steamapps"
                        if (Test-Path -LiteralPath $AppsSub -ErrorAction SilentlyContinue) {
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
            if ($AddPath -and (Test-Path -LiteralPath $AddPath -ErrorAction SilentlyContinue)) {
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

function Read-BinaryVdfNullString {
    param(
        [byte[]]$Bytes,
        [ref]$Offset
    )
    $Start = $Offset.Value
    $idx = $Start
    while ($idx -lt $Bytes.Length -and $Bytes[$idx] -ne 0) {
        $idx++
    }
    $Str = ""
    if ($idx -gt $Start) {
        $Str = [System.Text.Encoding]::UTF8.GetString($Bytes, $Start, $idx - $Start)
    }
    $Offset.Value = [Math]::Min($idx + 1, $Bytes.Length)
    return $Str
}

function Read-BinaryVdfMap {
    param(
        [byte[]]$Bytes,
        [ref]$Offset
    )
    $Map = [ordered]@{}
    while ($Offset.Value -lt $Bytes.Length) {
        $Type = $Bytes[$Offset.Value]
        $Offset.Value++
        if ($Type -eq 0x08) {
            break
        }
        $Key = Read-BinaryVdfNullString -Bytes $Bytes -Offset $Offset
        switch ($Type) {
            0x00 {
                $Map[$Key] = Read-BinaryVdfMap -Bytes $Bytes -Offset $Offset
            }
            0x01 {
                $Map[$Key] = Read-BinaryVdfNullString -Bytes $Bytes -Offset $Offset
            }
            0x02 {
                if ($Offset.Value + 4 -le $Bytes.Length) {
                    $Map[$Key] = [BitConverter]::ToInt32($Bytes, $Offset.Value)
                    $Offset.Value += 4
                } else {
                    $Offset.Value = $Bytes.Length
                }
            }
            0x07 {
                if ($Offset.Value + 8 -le $Bytes.Length) {
                    $Map[$Key] = [BitConverter]::ToUInt64($Bytes, $Offset.Value)
                    $Offset.Value += 8
                } else {
                    $Offset.Value = $Bytes.Length
                }
            }
            default {
                # Unknown binary VDF type; stop parsing this map
                $Offset.Value = $Bytes.Length
                break
            }
        }
    }
    return $Map
}

function Get-SteamShortcuts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string[]]$Libraries = @(),

        [Parameter(Mandatory=$false)]
        [string[]]$AdditionalVdfPaths = @()
    )

    if (-not $Libraries -or $Libraries.Count -eq 0) {
        $Libraries = Get-SteamLibraries
    }

    $CandidateVdfs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Lib in $Libraries) {
        $UserdataDir = Join-Path $Lib "userdata"
        if (Test-Path -LiteralPath $UserdataDir -ErrorAction SilentlyContinue) {
            $VdfFiles = Get-ChildItem -Path $UserdataDir -Filter "shortcuts.vdf" -Recurse -File -ErrorAction SilentlyContinue
            foreach ($Vf in $VdfFiles) {
                [void]$CandidateVdfs.Add($Vf.FullName)
            }
        }
    }

    foreach ($ExtraVdf in $AdditionalVdfPaths) {
        if (-not [string]::IsNullOrWhiteSpace($ExtraVdf) -and (Test-Path -LiteralPath $ExtraVdf -ErrorAction SilentlyContinue)) {
            if ((Get-Item -LiteralPath $ExtraVdf).PSIsContainer) {
                $FoundVdfs = Get-ChildItem -LiteralPath $ExtraVdf -Filter "shortcuts.vdf" -Recurse -File -ErrorAction SilentlyContinue
                foreach ($Vf in $FoundVdfs) {
                    [void]$CandidateVdfs.Add($Vf.FullName)
                }
            } else {
                [void]$CandidateVdfs.Add($ExtraVdf)
            }
        }
    }

    $Shortcuts = [System.Collections.Generic.List[PSCustomObject]]::new()
    $SeenKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($VdfPath in $CandidateVdfs) {
        try {
            $Bytes = [System.IO.File]::ReadAllBytes($VdfPath)
            if (-not $Bytes -or $Bytes.Length -lt 4) { continue }
            $Offset = 0
            $RootMap = Read-BinaryVdfMap -Bytes $Bytes -Offset ([ref]$Offset)

            $ShortcutsMap = $null
            foreach ($RootKey in $RootMap.Keys) {
                if ($RootKey -ieq "shortcuts") {
                    $ShortcutsMap = $RootMap[$RootKey]
                    break
                }
            }
            if (-not $ShortcutsMap) { continue }

            foreach ($EntryKey in $ShortcutsMap.Keys) {
                $Entry = $ShortcutsMap[$EntryKey]
                if (-not ($Entry -is [System.Collections.IDictionary])) { continue }

                $GetProp = {
                    param($Dict, [string]$PropName)
                    foreach ($K in $Dict.Keys) {
                        if ($K -ieq $PropName) { return $Dict[$K] }
                    }
                    return $null
                }

                $AppId = & $GetProp $Entry "appid"
                $AppName = [string](& $GetProp $Entry "AppName")
                $ExeRaw = [string](& $GetProp $Entry "Exe")
                $StartDirRaw = [string](& $GetProp $Entry "StartDir")
                $Icon = [string](& $GetProp $Entry "icon")
                $ShortcutPath = [string](& $GetProp $Entry "ShortcutPath")
                $LaunchOptions = [string](& $GetProp $Entry "LaunchOptions")
                $TagsMap = & $GetProp $Entry "tags"

                $ExeClean = ($ExeRaw -replace '^"+|"+$', '').Trim()
                $StartDirClean = ($StartDirRaw -replace '^"+|"+$', '').Trim()
                if (-not $AppName -and -not $ExeClean) { continue }

                $TagList = @()
                if ($TagsMap -and ($TagsMap -is [System.Collections.IDictionary])) {
                    foreach ($TK in $TagsMap.Keys) {
                        if ($TagsMap[$TK]) { $TagList += [string]$TagsMap[$TK] }
                    }
                }

                $DedupKey = "$AppName|$ExeClean"
                if ($SeenKeys.Add($DedupKey)) {
                    $Shortcuts.Add([PSCustomObject]@{
                        app_id         = if ($null -ne $AppId) { [int]$AppId } else { 0 }
                        app_name       = $AppName
                        exe            = $ExeClean
                        start_dir      = $StartDirClean
                        icon           = $Icon
                        shortcut_path  = $ShortcutPath
                        launch_options = $LaunchOptions
                        tags           = $TagList
                        vdf_path       = $VdfPath
                    })
                }
            }
        } catch {
            Write-Verbose "Failed to parse shortcuts.vdf at '$VdfPath': $($_.Exception.Message)"
        }
    }

    return @($Shortcuts.ToArray())
}

function ConvertTo-BinaryVdfShortcutsBytes {
    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyCollection()]
        [object[]]$Shortcuts
    )

    $Mem = New-Object System.IO.MemoryStream
    $WriteByte = { param([byte]$B) $Mem.WriteByte($B) }
    $WriteString = {
        param([string]$S)
        if (-not [string]::IsNullOrEmpty($S)) {
            $Buf = [System.Text.Encoding]::UTF8.GetBytes($S)
            $Mem.Write($Buf, 0, $Buf.Length)
        }
        $Mem.WriteByte(0x00)
    }
    $WriteStringProp = {
        param([string]$Key, [string]$Val)
        $Mem.WriteByte(0x01)
        & $WriteString $Key
        & $WriteString $Val
    }
    $WriteInt32Prop = {
        param([string]$Key, [int]$Val)
        $Mem.WriteByte(0x02)
        & $WriteString $Key
        $Buf = [BitConverter]::GetBytes($Val)
        $Mem.Write($Buf, 0, 4)
    }

    # Root map: "shortcuts"
    & $WriteByte 0x00
    & $WriteString "shortcuts"

    for ($i = 0; $i -lt $Shortcuts.Count; $i++) {
        $Sc = $Shortcuts[$i]
        $AppName = if ($Sc.app_name) { [string]$Sc.app_name } elseif ($Sc.AppName) { [string]$Sc.AppName } elseif ($Sc.name) { [string]$Sc.name } else { "Shortcut $i" }
        $ExeClean = if ($Sc.exe) { ([string]$Sc.exe -replace '^"+|"+$', '').Trim() } elseif ($Sc.Exe) { ([string]$Sc.Exe -replace '^"+|"+$', '').Trim() } else { "" }
        $StartDirClean = if ($Sc.start_dir) { ([string]$Sc.start_dir -replace '^"+|"+$', '').Trim() } elseif ($Sc.StartDir) { ([string]$Sc.StartDir -replace '^"+|"+$', '').Trim() } elseif ($ExeClean) { Split-Path -Parent $ExeClean } else { "" }
        $Icon = if ($Sc.icon) { [string]$Sc.icon } elseif ($Sc.Icon) { [string]$Sc.Icon } else { "" }
        $ShortcutPath = if ($Sc.shortcut_path) { [string]$Sc.shortcut_path } elseif ($Sc.ShortcutPath) { [string]$Sc.ShortcutPath } else { "" }
        $LaunchOptions = if ($Sc.launch_options) { [string]$Sc.launch_options } elseif ($Sc.LaunchOptions) { [string]$Sc.LaunchOptions } else { "" }
        $AppId = if ($Sc.app_id -and [int]$Sc.app_id -ne 0) {
            [int]$Sc.app_id
        } elseif ($Sc.AppId -and [int]$Sc.AppId -ne 0) {
            [int]$Sc.AppId
        } else {
            ([Math]::Abs("$ExeClean|$AppName".GetHashCode()) -bor 0x80000000)
        }
        $Tags = if ($Sc.tags) { @($Sc.tags) } elseif ($Sc.Tags) { @($Sc.Tags) } else { @() }

        $ExeQuoted = if ($ExeClean) { "`"$ExeClean`"" } else { "" }
        $StartDirQuoted = if ($StartDirClean) { "`"$StartDirClean`"" } else { "" }

        # Entry map "$i"
        & $WriteByte 0x00
        & $WriteString "$i"

        & $WriteInt32Prop "appid" $AppId
        & $WriteStringProp "AppName" $AppName
        & $WriteStringProp "Exe" $ExeQuoted
        & $WriteStringProp "StartDir" $StartDirQuoted
        & $WriteStringProp "icon" $Icon
        & $WriteStringProp "ShortcutPath" $ShortcutPath
        & $WriteStringProp "LaunchOptions" $LaunchOptions
        & $WriteInt32Prop "IsHidden" 0
        & $WriteInt32Prop "AllowDesktopConfig" 1
        & $WriteInt32Prop "AllowOverlay" 1
        & $WriteInt32Prop "OpenVR" 0
        & $WriteInt32Prop "Devkit" 0
        & $WriteStringProp "DevkitGameID" ""
        & $WriteInt32Prop "DevkitOverrideAppID" 0
        & $WriteInt32Prop "LastPlayTime" 0
        & $WriteStringProp "FlatpakAppID" ""

        # Nested map: "tags"
        & $WriteByte 0x00
        & $WriteString "tags"
        for ($t = 0; $t -lt $Tags.Count; $t++) {
            & $WriteStringProp "$t" ([string]$Tags[$t])
        }
        & $WriteByte 0x08

        # End of entry map "$i"
        & $WriteByte 0x08
    }

    # End of "shortcuts" map and root map
    & $WriteByte 0x08
    & $WriteByte 0x08

    $ResultBytes = $Mem.ToArray()
    $Mem.Dispose()
    return $ResultBytes
}

function Register-SteamShortcuts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyCollection()]
        [object[]]$Shortcuts,

        [Parameter(Mandatory=$false)]
        [string[]]$TargetVdfPaths = @(),

        [switch]$Simulation = $false
    )

    if (-not $Shortcuts -or $Shortcuts.Count -eq 0) {
        return [PSCustomObject]@{
            RegisteredCount = 0
            UpdatedFiles    = @()
        }
    }

    $ResolvedTargets = [System.Collections.Generic.List[string]]::new()
    if ($TargetVdfPaths -and $TargetVdfPaths.Count -gt 0) {
        foreach ($Tp in $TargetVdfPaths) {
            if (-not [string]::IsNullOrWhiteSpace($Tp)) {
                $ResolvedTargets.Add($Tp)
            }
        }
    } else {
        $Libraries = Get-SteamLibraries
        foreach ($Lib in $Libraries) {
            $UserdataDir = Join-Path $Lib "userdata"
            if (Test-Path -LiteralPath $UserdataDir -ErrorAction SilentlyContinue) {
                $UserDirs = Get-ChildItem -LiteralPath $UserdataDir -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^\d+$' -and $_.Name -ne '0' }
                foreach ($UDir in $UserDirs) {
                    $ConfigDir = Join-Path $UDir.FullName "config"
                    $VdfFile = Join-Path $ConfigDir "shortcuts.vdf"
                    if (-not $ResolvedTargets.Contains($VdfFile)) {
                        $ResolvedTargets.Add($VdfFile)
                    }
                }
            }
        }
    }

    $TotalRegistered = 0
    $UpdatedFiles = [System.Collections.Generic.List[string]]::new()

    foreach ($VdfFile in $ResolvedTargets) {
        $Existing = @()
        if (Test-Path -LiteralPath $VdfFile -ErrorAction SilentlyContinue) {
            $Existing = @(Get-SteamShortcuts -AdditionalVdfPaths @($VdfFile))
        }

        $Merged = [System.Collections.Generic.List[object]]::new()
        foreach ($Ex in $Existing) {
            $Merged.Add($Ex)
        }

        $AddedToFile = 0
        foreach ($Sc in $Shortcuts) {
            $ScName = if ($Sc.app_name) { [string]$Sc.app_name } elseif ($Sc.AppName) { [string]$Sc.AppName } elseif ($Sc.name) { [string]$Sc.name } else { "" }
            $ScExe = if ($Sc.exe) { ([string]$Sc.exe -replace '^"+|"+$', '').Trim() } elseif ($Sc.Exe) { ([string]$Sc.Exe -replace '^"+|"+$', '').Trim() } else { "" }
            if (-not $ScName -and -not $ScExe) { continue }

            $AlreadyExists = $Merged | Where-Object {
                ($ScName -and $_.app_name -ieq $ScName) -or
                ($ScExe -and $_.exe -ieq $ScExe)
            }
            if (-not $AlreadyExists) {
                $Merged.Add($Sc)
                $AddedToFile++
                $TotalRegistered++
            }
        }

        if ($AddedToFile -gt 0 -and -not $Simulation) {
            $ParentDir = Split-Path -Parent $VdfFile
            if ($ParentDir -and -not (Test-Path -LiteralPath $ParentDir)) {
                New-Item -ItemType Directory -Path $ParentDir -Force | Out-Null
            }
            $Bytes = ConvertTo-BinaryVdfShortcutsBytes -Shortcuts $Merged.ToArray()
            [System.IO.File]::WriteAllBytes($VdfFile, $Bytes)
            $UpdatedFiles.Add($VdfFile)
        } elseif ($AddedToFile -gt 0 -and $Simulation) {
            $UpdatedFiles.Add($VdfFile)
        }
    }

    return [PSCustomObject]@{
        RegisteredCount = $TotalRegistered
        UpdatedFiles    = $UpdatedFiles.ToArray()
    }
}

