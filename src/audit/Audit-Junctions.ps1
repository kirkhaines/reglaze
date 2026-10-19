<#
.SYNOPSIS
    NTFS Directory Junction discovery module for Reglaze.
.DESCRIPTION
    Scans candidate directories across user profiles, AppData, Documents, and Steam
    libraries for existing directory junctions, extracting source and target paths,
    and correlating findings against the Reglaze application catalog.
#>


. (Join-Path (Join-Path $PSScriptRoot "..") "common\Catalog.ps1")

function Get-JunctionsAudit {
    [CmdletBinding()]
    param(
        [string]$RepoRoot = $null,
        [string[]]$AdditionalPaths = @()
    )

    $Catalog = Get-ReglazeCatalog -RepoRoot $RepoRoot
    $DetectedJunctions = @()
    $SeenSources = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # 1. Candidate search directories
    $CandidateRoots = @(
        $env:USERPROFILE,
        $env:APPDATA,
        $env:LOCALAPPDATA,
        (Join-Path $env:USERPROFILE "AppData\LocalLow"),
        (Join-Path $env:USERPROFILE "Documents"),
        (Join-Path $env:USERPROFILE "Pictures"),
        "${env:ProgramFiles(x86)}\Steam\steamapps\common"
    ) + $AdditionalPaths

    # Check for preserved data drives (e.g. D:\SteamLibrary, D:\Games)
    foreach ($Drive in (Get-PSDrive -PSProvider FileSystem)) {
        if ($Drive.Name -ne "C") {
            $Root = "$($Drive.Name):\"
            $CandidateRoots += (Join-Path $Root "SteamLibrary\steamapps\common")
            $CandidateRoots += (Join-Path $Root "Games")
            $CandidateRoots += (Join-Path $Root "Sync")
        }
    }

    # Helper function to inspect an item
    function Test-ItemForJunction($Item) {
        if ($Item.LinkType -eq 'Junction' -or $Item.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
            $Source = $Item.FullName
            if ($SeenSources.Contains($Source)) { return }
            $SeenSources.Add($Source) | Out-Null

            $Target = if ($Item.Target) { [string]($Item.Target | Select-Object -First 1) } else { "" }

            # If Target is empty, use fsutil reparsepoint query fallback
            if (-not $Target) {
                try {
                    $FsutilOut = fsutil reparsepoint query $Source 2>$null
                    if ($FsutilOut -match "Substitute Name:\s*(?<tgt>.*)") {
                        $Target = $Matches['tgt'].Trim().Replace("\??\", "")
                    }
                } catch {}
            }

            # Correlate against application catalog
            $MatchedAppId = $null
            $MatchedDirId = $null

            foreach ($App in $Catalog) {
                if ($App.directories) {
                    foreach ($Dir in $App.directories) {
                        # Expand environment variables in catalog default_path for comparison
                        $ExpandedDefault = [System.Environment]::ExpandEnvironmentVariables($Dir.default_path)
                        if ($Source -eq $ExpandedDefault -or $Source -like "*\$($Dir.id)*") {
                            $MatchedAppId = $App.app_id
                            $MatchedDirId = $Dir.id
                            break
                        }
                    }
                }
                if ($MatchedAppId) { break }
            }

            $script:DetectedJunctions += [PSCustomObject]@{
                source_path          = $Source
                target_path          = $Target
                matched_app_id       = $MatchedAppId
                matched_directory_id = $MatchedDirId
            }
        }
    }

    # Scan shallowly (depth 2) across candidates to preserve speed
    foreach ($Root in $CandidateRoots) {
        if ($Root -and (Test-Path $Root)) {
            try {
                # Check root directory itself
                $RootItem = Get-Item -LiteralPath $Root -Force -ErrorAction SilentlyContinue
                if ($RootItem) { Test-ItemForJunction $RootItem }

                # Scan children (depth 1)
                $Level1 = Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue
                foreach ($Dir1 in $Level1) {
                    Test-ItemForJunction $Dir1

                    # Scan grandchildren (depth 2)
                    $Level2 = Get-ChildItem -LiteralPath $Dir1.FullName -Directory -Force -ErrorAction SilentlyContinue
                    foreach ($Dir2 in $Level2) {
                        Test-ItemForJunction $Dir2
                    }
                }
            } catch {
                # Ignore access denied errors during recursive probe
            }
        }
    }

    return $DetectedJunctions
}

