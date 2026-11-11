<#
.SYNOPSIS
    Configures declarative File Explorer Quick Access pins, Taskbar pins, Start Menu pins,
    per-application user PATH additions, and preserved Steam library registrations.
.DESCRIPTION
    SCOPE & ORDERING DEPENDENCY:
      - Section 3 (StartMenuPinnedApps) writes to HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start
        (ConfigureStartPins). Because HKLM PolicyManager requires elevation and is evaluated when initializing
        a user's Start Menu, StartMenuPinnedApps should be invoked in Phase 4 (Machine Bootstrap under LocalAdmin).
      - Sections 1, 2, 4, and 5 (QuickAccessPins, TaskbarPinnedApps, AppPathEntries, SteamLibraries) operate
        in User Scope (HKCU / %APPDATA% / %LOCALAPPDATA%) and depend on installed applications, mounted cloud
        storage (%STREAM%), relocated User Shell Folders, Steam installation, and User Directory Junctions.
        Therefore, they must run in Phase 5 (hydrate.ps1 Step 9) AFTER applications and junctions exist on disk.
#>
[CmdletBinding()]
param (
    [string[]]$QuickAccessPins = @(),
    [string[]]$TaskbarPinnedApps = @(),
    [string[]]$StartMenuPinnedApps = @(),
    [string[]]$AppPathEntries = @(),
    [string[]]$SteamLibraries = @()
)

Write-Host "Applying declarative Shell Pins, User PATH additions, and Steam Library registrations..." -ForegroundColor Cyan

# 1. File Explorer Quick Access Pinned Folders
if ($QuickAccessPins -and $QuickAccessPins.Count -gt 0) {
    try {
        $ShellApp = New-Object -ComObject Shell.Application -ErrorAction SilentlyContinue
        if ($ShellApp) {
            foreach ($FolderPin in $QuickAccessPins) {
                $ExpandedFolder = [Environment]::ExpandEnvironmentVariables($FolderPin)
                if (Test-Path -LiteralPath $ExpandedFolder) {
                    $FolderNs = $ShellApp.Namespace($ExpandedFolder)
                    if ($FolderNs -and $FolderNs.Self) {
                        $FolderNs.Self.InvokeVerb("pintohome")
                        Write-Host "  [+] Pinned to Quick Access: $ExpandedFolder" -ForegroundColor Green
                    }
                }
            }
        }
    } catch {}
}

# 2. Taskbar Pinned Apps (Declarative XML Layout & TaskBar Shortcut Creation)
if ($TaskbarPinnedApps -and $TaskbarPinnedApps.Count -gt 0) {
    try {
        $TaskbarPinDir = Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
        if (-not (Test-Path -LiteralPath $TaskbarPinDir)) {
            New-Item -ItemType Directory -Path $TaskbarPinDir -Force | Out-Null
        }
        $WshShell = New-Object -ComObject WScript.Shell -ErrorAction SilentlyContinue
        $XmlPins = [System.Collections.Generic.List[string]]::new()

        foreach ($AppTarget in $TaskbarPinnedApps) {
            $ExpandedTarget = [Environment]::ExpandEnvironmentVariables($AppTarget)
            if (Test-Path -LiteralPath $ExpandedTarget) {
                $AppName = [System.IO.Path]::GetFileNameWithoutExtension($ExpandedTarget)
                $LnkPath = Join-Path $TaskbarPinDir "${AppName}.lnk"
                if ($WshShell -and -not (Test-Path -LiteralPath $LnkPath)) {
                    $Sc = $WshShell.CreateShortcut($LnkPath)
                    $Sc.TargetPath = $ExpandedTarget
                    $Sc.WorkingDirectory = (Split-Path -Parent $ExpandedTarget)
                    $Sc.Save()
                }
                $EscXmlPath = [System.Security.SecurityElement]::Escape($ExpandedTarget)
                $XmlPins.Add("        <taskbar:DesktopApp DesktopApplicationLinkPath=`"$EscXmlPath`" />")
            } elseif ($AppTarget -match '!') {
                $EscAumid = [System.Security.SecurityElement]::Escape($AppTarget)
                $XmlPins.Add("        <taskbar:UWA AppUserModelID=`"$EscAumid`" />")
            }
        }

        if ($XmlPins.Count -gt 0) {
            $LayoutXmlDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Shell"
            if (-not (Test-Path -LiteralPath $LayoutXmlDir)) {
                New-Item -ItemType Directory -Path $LayoutXmlDir -Force | Out-Null
            }
            $LayoutXmlPath = Join-Path $LayoutXmlDir "LayoutModification.xml"
            $XmlContent = @(
                '<?xml version="1.0" encoding="utf-8"?>',
                '<LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" Version="1">',
                '  <CustomTaskbarLayoutCollection PinListPlacement="Replace">',
                '    <defaultlayout:TaskbarLayout>',
                '      <taskbar:TaskbarPinList>'
            ) + $XmlPins.ToArray() + @(
                '      </taskbar:TaskbarPinList>',
                '    </defaultlayout:TaskbarLayout>',
                '  </CustomTaskbarLayoutCollection>',
                '</LayoutModificationTemplate>'
            )
            [System.IO.File]::WriteAllLines($LayoutXmlPath, $XmlContent, (New-Object System.Text.UTF8Encoding($false)))
            Write-Host "  [+] Generated declarative Taskbar layout ($($XmlPins.Count) pin(s)): $LayoutXmlPath" -ForegroundColor Green
        }
    } catch {}
}

# 3. Start Menu Pinned Apps (Declarative ConfigureStartPins Policy JSON)
if ($StartMenuPinnedApps -and $StartMenuPinnedApps.Count -gt 0) {
    try {
        $PinObjects = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($SmTarget in $StartMenuPinnedApps) {
            $ExpandedSm = [Environment]::ExpandEnvironmentVariables($SmTarget)
            if ($SmTarget -match '!') {
                $PinObjects.Add([PSCustomObject]@{ packagedAppId = $SmTarget })
            } elseif ($ExpandedSm -like "*.lnk") {
                $PinObjects.Add([PSCustomObject]@{ desktopAppLink = $ExpandedSm })
            } else {
                $PinObjects.Add([PSCustomObject]@{ desktopAppId = $ExpandedSm })
            }
        }
        $StartJson = ([PSCustomObject]@{ pinnedList = $PinObjects.ToArray() }) | ConvertTo-Json -Compress -Depth 4
        $StartPolicyKey = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"
        if (-not (Test-Path -LiteralPath $StartPolicyKey)) {
            New-Item -Path $StartPolicyKey -Force -ErrorAction SilentlyContinue | Out-Null
        }
        if (Test-Path -LiteralPath $StartPolicyKey) {
            Set-ItemProperty -LiteralPath $StartPolicyKey -Name "ConfigureStartPins" -Value $StartJson -Type String -ErrorAction SilentlyContinue
            Set-ItemProperty -LiteralPath $StartPolicyKey -Name "ConfigureStartPins_ProviderSet" -Value 1 -Type DWord -ErrorAction SilentlyContinue
            Write-Host "  [+] Configured declarative Start Menu pins ($($PinObjects.Count) pin(s))" -ForegroundColor Green
        }
    } catch {}
}

# 4. Per-Application User PATH Additions
if ($AppPathEntries -and $AppPathEntries.Count -gt 0) {
    try {
        $EnvKey = "HKCU:\Environment"
        $CurrentUserPath = (Get-ItemProperty -Path $EnvKey -Name "Path" -ErrorAction SilentlyContinue).Path
        $ExistingParts = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($CurrentUserPath)) {
            foreach ($Seg in ($CurrentUserPath -split ';')) {
                if (-not [string]::IsNullOrWhiteSpace($Seg)) {
                    $ExistingParts.Add($Seg.Trim())
                }
            }
        }

        $AddedCount = 0
        foreach ($NewEntry in $AppPathEntries) {
            $ExpandedEntry = [Environment]::ExpandEnvironmentVariables($NewEntry).Trim()
            if ([string]::IsNullOrWhiteSpace($ExpandedEntry)) { continue }
            $AlreadyPresent = $ExistingParts | Where-Object { $_.TrimEnd('\') -ieq $ExpandedEntry.TrimEnd('\') }
            if (-not $AlreadyPresent) {
                $ExistingParts.Add($ExpandedEntry)
                $AddedCount++
                Write-Host "  [+] Added to user PATH: $ExpandedEntry" -ForegroundColor Green
            }
        }

        if ($AddedCount -gt 0) {
            $UpdatedPath = ($ExistingParts -join ';')
            Set-ItemProperty -Path $EnvKey -Name "Path" -Value $UpdatedPath -Type ExpandString
            $env:Path = "$env:Path;$($AppPathEntries -join ';')"
        }
    } catch {}
}

# 5. Re-attach Preserved Steam Library Folders in libraryfolders.vdf
if ($SteamLibraries -and $SteamLibraries.Count -gt 0) {
    try {
        $CandidateVdfPaths = @(
            "${env:ProgramFiles(x86)}\Steam\steamapps\libraryfolders.vdf",
            "${env:ProgramFiles}\Steam\steamapps\libraryfolders.vdf"
        )
        foreach ($VdfPath in $CandidateVdfPaths) {
            if (Test-Path -LiteralPath $VdfPath) {
                $VdfContent = Get-Content -Raw -LiteralPath $VdfPath -ErrorAction SilentlyContinue
                $MaxIdx = 0
                foreach ($M in [regex]::Matches($VdfContent, '"(\d+)"\s*\{')) {
                    $IdxVal = [int]$M.Groups[1].Value
                    if ($IdxVal -gt $MaxIdx) { $MaxIdx = $IdxVal }
                }

                $Modified = $false
                foreach ($LibPath in $SteamLibraries) {
                    $ExpandedLib = [Environment]::ExpandEnvironmentVariables($LibPath).TrimEnd('\')
                    if (-not (Test-Path -LiteralPath $ExpandedLib)) { continue }
                    $EscVdfPath = $ExpandedLib -replace '\\', '\\'
                    if ($VdfContent -notmatch [regex]::Escape($EscVdfPath)) {
                        $MaxIdx++
                        $NewBlock = "`t`"$MaxIdx`"`r`n`t{`r`n`t`t`"path`"`t`t`"$EscVdfPath`"`r`n`t}`r`n}"
                        $VdfContent = $VdfContent -replace '\}\s*$', $NewBlock
                        $Modified = $true
                        Write-Host "  [+] Registered preserved Steam library: $ExpandedLib" -ForegroundColor Green
                    }
                }
                if ($Modified) {
                    [System.IO.File]::WriteAllText($VdfPath, $VdfContent, (New-Object System.Text.UTF8Encoding($false)))
                }
                break
            }
        }
    } catch {}
}

