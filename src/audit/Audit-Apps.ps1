<#
.SYNOPSIS
    Comprehensive application discovery module for Reglaze.
.DESCRIPTION
    Discovers installed software via both WinGet and the Windows Add/Remove Programs (ARP)
    registry hives (64-bit, 32-bit WoW64, and per-user HKCU). De-duplicates entries and
    correlates findings against the Reglaze application catalog.
#>


. (Join-Path (Join-Path $PSScriptRoot "..") "common\Catalog.ps1")
. (Join-Path (Join-Path $PSScriptRoot "..") "common\GameLibraries.ps1")

function Get-InstalledApplicationsAudit {
    [CmdletBinding()]
    param(
        [string]$RepoRoot = $null,
        [string]$UserConfigDir = $null,
        [string]$UserCatalogPath = $null
    )

    $Catalog = Get-ReglazeCatalog -RepoRoot $RepoRoot -UserConfigDir $UserConfigDir -UserCatalogPath $UserCatalogPath

    # 1. Query WinGet Packages
    $WinGetPackages = @()
    $WinGetIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if (Get-Command "winget" -ErrorAction SilentlyContinue) {
        try {
            $WingetOutput = & winget list --accept-source-agreements 2>$null
            if ($WingetOutput) {
                # Find separator line (dashes)
                $HeaderIndex = -1
                for ($i = 0; $i -lt $WingetOutput.Count; $i++) {
                    if ($WingetOutput[$i] -match "^-{10,}") {
                        $HeaderIndex = $i
                        break
                    }
                }

                if ($HeaderIndex -gt 0) {
                    $HeaderLine = $WingetOutput[$HeaderIndex - 1]
                    $DashLine = $WingetOutput[$HeaderIndex]

                    # Detect column start positions
                    $IdCol = $HeaderLine.IndexOf("Id")
                    $VerCol = $HeaderLine.IndexOf("Version")
                    $AvailCol = $HeaderLine.IndexOf("Available")
                    $SourceCol = $HeaderLine.IndexOf("Source")

                    for ($i = $HeaderIndex + 1; $i -lt $WingetOutput.Count; $i++) {
                        $Line = $WingetOutput[$i]
                        if ([string]::IsNullOrWhiteSpace($Line) -or $Line.Length -lt $IdCol) { continue }

                        $Name = $Line.Substring(0, [Math]::Min($IdCol, $Line.Length)).Trim()
                        
                        $IdLen = if ($VerCol -gt $IdCol -and $Line.Length -ge $VerCol) { $VerCol - $IdCol } else { $Line.Length - $IdCol }
                        $Id = $Line.Substring($IdCol, [Math]::Min($IdLen, $Line.Length - $IdCol)).Trim()

                        $Version = "Unknown"
                        if ($VerCol -gt 0 -and $Line.Length -ge $VerCol) {
                            $VerLen = if ($AvailCol -gt $VerCol -and $Line.Length -ge $AvailCol) { $AvailCol - $VerCol } else { $Line.Length - $VerCol }
                            $Version = $Line.Substring($VerCol, [Math]::Min($VerLen, $Line.Length - $VerCol)).Trim()
                        }

                        $Source = ""
                        if ($SourceCol -gt 0 -and $Line.Length -ge $SourceCol) {
                            $Source = $Line.Substring($SourceCol).Trim()
                        }

                        # Only include genuine winget packages (ignore ARP dummy fallback IDs)
                        if ($Id -and -not ($Id -like "ARP\*") -and ($Source -eq "winget" -or $Id -match "\.")) {
                            if (-not $WinGetIds.Contains($Id)) {
                                $WinGetIds.Add($Id) | Out-Null
                                
                                # Match against catalog: exact winget_id / package_id or name
                                $MatchedApp = $Catalog | Where-Object { 
                                    ($_.install -and (($_.install.winget_id -and $_.install.winget_id -ieq $Id) -or ($_.install.package_id -and $_.install.package_id -ieq $Id)))
                                } | Select-Object -First 1

                                if (-not $MatchedApp) {
                                    $MatchedApp = $Catalog | Where-Object {
                                        ($_.name -and ($Name -ieq $_.name -or $Name -like "*$($_.name)*" -or $_.name -like "*$($Name)*")) -or
                                        ($_.app_id -and $Name -ieq $_.app_id) -or
                                        ($_.install -and $_.install.winget_id -and ($Id -like "*$($_.install.winget_id)*" -or ($Id -like "Python.*" -and $_.app_id -eq "python3")))
                                    } | Sort-Object { if ($_.name) { $_.name.Length } else { $_.app_id.Length } } -Descending | Select-Object -First 1
                                }

                                # Check if package is internal OS runtime/codec noise
                                $IsSystemNoise = ($Id -match "^(Microsoft\.VCRedist|Microsoft\.VCLibs|Microsoft\.UI\.Xaml|Microsoft\.WindowsAppRuntime|Microsoft\.DotNet\.Native|Microsoft\.CLRTypesSQLServer)") -or
                                                 ($Id -match "^MSIX\\Microsoft\.(AV1VideoExtension|AVCEncoderVideoExtension|HEIFImageExtension|HEVCVideoExtension|MPEG2VideoExtension|VP9VideoExtensions|WebMediaExtensions|WebpImageExtension|RawImageExtension|Services\.Store\.Engagement|NET\.Native\.Framework|WinAppRuntime|Winget\.Source|SecHealthUI|StartExperiencesApp|StorePurchaseApp|ApplicationCompatibilityEnhancements)")

                                if ($IsSystemNoise -and -not $MatchedApp) {
                                    continue
                                }

                                $WinGetPackages += [PSCustomObject]@{
                                    id             = $Id
                                    name           = $Name
                                    version        = $Version
                                    matched_app_id = if ($MatchedApp) { $MatchedApp.app_id } else { $null }
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            Write-Warning "Failed to parse winget output: $($_.Exception.Message)"
        }
    }

    # 2. Discover Game Libraries across all drives & detect installed games first so ARP can de-duplicate Steam games
    $SteamLibs = Get-SteamLibraries
    $SteamGames = Get-SteamInstalledGames -Libraries $SteamLibs

    $GameLibraryEntries = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($Lib in $SteamLibs) {
        $LibGames = @($SteamGames | Where-Object { $_.LibraryPath -eq $Lib })
        $GameLibraryEntries.Add([PSCustomObject]@{
            manager     = "steam"
            path        = $Lib
            game_count  = $LibGames.Count
            games       = @($LibGames | ForEach-Object {
                $GameAppId = $_.SteamId
                $GameTitle = $_.GameName
                $CatalogMatch = $Catalog | Where-Object {
                    ($_.install -and $null -ne $_.install.steam_id -and [int]$_.install.steam_id -eq [int]$GameAppId) -or
                    ($GameTitle -and $_.name -and $_.name -ieq $GameTitle) -or
                    ($GameTitle -and $_.app_id -and $_.app_id -ieq $GameTitle)
                } | Select-Object -First 1
                [PSCustomObject]@{
                    steam_id       = $GameAppId
                    name           = $GameTitle
                    matched_app_id = if ($CatalogMatch) { $CatalogMatch.app_id } else { $null }
                }
            })
        })
    }

    # 3. Query Add/Remove Programs (ARP) Registry Hives
    $RegistryHives = @(
        @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"; Hive = "HKLM_64" },
        @{ Path = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"; Hive = "HKLM_32" },
        @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"; Hive = "HKCU_User" }
    )

    $NonWinGetApps = @()
    $SeenNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Target in $RegistryHives) {
        $Entries = Get-ItemProperty -Path $Target.Path -ErrorAction SilentlyContinue |
            Where-Object { 
                $_.DisplayName -and 
                -not $_.SystemComponent -and 
                -not $_.ParentKeyName -and
                $_.DisplayName -notmatch "^(Security Update|Update for Windows|Hotfix|Package_for_RollupFix)"
            }

        foreach ($Entry in $Entries) {
            $DisplayName = $Entry.DisplayName.Trim()
            if ($SeenNames.Contains($DisplayName)) { continue }
            $SeenNames.Add($DisplayName) | Out-Null

            # Detect if this ARP entry is a Steam game
            $ArpSteamId = $null
            if ($Entry.PSChildName -and $Entry.PSChildName -match "^Steam App (\d+)$") {
                $ArpSteamId = [int]$Matches[1]
            } elseif ($Entry.UninstallString -and $Entry.UninstallString -match "steam://uninstall/(\d+)") {
                $ArpSteamId = [int]$Matches[1]
            }

            # Check if this app is already claimed by WinGet or discovered Steam Libraries
            $AlreadyInWinGet = $WinGetPackages | Where-Object { 
                $_.name -eq $DisplayName -or 
                ($_.id -and $DisplayName -like "*$($_.id)*")
            }
            $AlreadyInSteamLibs = $SteamGames | Where-Object {
                ($null -ne $ArpSteamId -and [int]$_.SteamId -eq $ArpSteamId) -or
                ($_.GameName -and $_.GameName -ieq $DisplayName)
            }

            if (-not $AlreadyInWinGet -and -not $AlreadyInSteamLibs) {
                # Attempt to match with catalog (exact match first, then longest name match)
                $MatchedApp = $Catalog | Where-Object {
                    $DisplayName -ieq $_.name -or
                    ($_.app_id -and $DisplayName -ieq $_.app_id) -or
                    ($_.install -and $_.install.winget_id -and $DisplayName -ieq $_.install.winget_id) -or
                    ($_.install -and $null -ne $_.install.steam_id -and (
                        ($null -ne $ArpSteamId -and [int]$_.install.steam_id -eq $ArpSteamId) -or
                        ($DisplayName -like "*$($_.install.steam_id)*")
                    ))
                } | Select-Object -First 1

                if (-not $MatchedApp) {
                    $MatchedApp = $Catalog | Where-Object {
                        ($_.name -and ($DisplayName -like "*$($_.name)*" -or ($DisplayName -like "Logi*" -and $_.app_id -eq "logitech_ghub") -or ($DisplayName -like "*Visual Studio*" -and $_.app_id -eq "visual_studio"))) -or
                        ($_.app_id -and $DisplayName -like "*$($_.app_id)*")
                    } | Sort-Object { if ($_.name) { $_.name.Length } else { $_.app_id.Length } } -Descending | Select-Object -First 1
                }

                # Skip driver-only subcomponents and internal runtime noise unless explicitly cataloged
                $IsArpNoise = ($DisplayName -match "^(Adobe Genuine Service|Microsoft Windows Application Compatibility Fix Database|vs_CoreEditorFonts|Windows SDK AddOn|.*HD Audio Driver.*|.*USB Audio Drivers.*|.*FrameView SDK.*)")
                if ($IsArpNoise -and -not $MatchedApp) {
                    continue
                }

                $AppRecord = [PSCustomObject]@{
                    display_name     = $DisplayName
                    display_version  = if ($Entry.DisplayVersion) { "$($Entry.DisplayVersion)".Trim() } else { "Unknown" }
                    publisher        = if ($Entry.Publisher) { "$($Entry.Publisher)".Trim() } else { "Unknown" }
                    install_location = if ($Entry.InstallLocation) { "$($Entry.InstallLocation)".Trim() } else { $null }
                    registry_hive    = $Target.Hive
                    matched_app_id   = if ($MatchedApp) { $MatchedApp.app_id } else { $null }
                }
                if ($null -ne $ArpSteamId) {
                    Add-Member -InputObject $AppRecord -MemberType NoteProperty -Name "steam_id" -Value $ArpSteamId -Force
                }
                $NonWinGetApps += $AppRecord
            }
        }
    }

    return [PSCustomObject]@{
        installed_winget_packages        = $WinGetPackages
        detected_non_winget_applications = $NonWinGetApps
        detected_game_libraries          = $GameLibraryEntries
    }
}

