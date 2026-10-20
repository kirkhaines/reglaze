<#
.SYNOPSIS
    Comprehensive application discovery module for Reglaze.
.DESCRIPTION
    Discovers installed software via both WinGet and the Windows Add/Remove Programs (ARP)
    registry hives (64-bit, 32-bit WoW64, and per-user HKCU). De-duplicates entries and
    correlates findings against the Reglaze application catalog.
#>


. (Join-Path (Join-Path $PSScriptRoot "..") "common\Catalog.ps1")

function Get-InstalledApplicationsAudit {
    [CmdletBinding()]
    param(
        [string]$RepoRoot = $null
    )

    $Catalog = Get-ReglazeCatalog -RepoRoot $RepoRoot

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
                                
                                # Match against catalog: exact winget_id or name
                                $MatchedApp = $Catalog | Where-Object { 
                                    ($_.winget_id -and $_.winget_id -eq $Id)
                                } | Select-Object -First 1

                                if (-not $MatchedApp) {
                                    $MatchedApp = $Catalog | Where-Object {
                                        $_.name -and ($Name -eq $_.name -or $Name -like "*$($_.name)*")
                                    } | Sort-Object { $_.name.Length } -Descending | Select-Object -First 1
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

    # 2. Query Add/Remove Programs (ARP) Registry Hives
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

            # Check if this app is already claimed by WinGet
            $AlreadyInWinGet = $WinGetPackages | Where-Object { 
                $_.name -eq $DisplayName -or 
                ($_.id -and $DisplayName -like "*$($_.id)*")
            }

            if (-not $AlreadyInWinGet) {
                # Attempt to match with catalog (exact match first, then longest name match)
                $MatchedApp = $Catalog | Where-Object {
                    $DisplayName -eq $_.name -or
                    ($_.app_id -and $DisplayName -eq $_.app_id) -or
                    ($_.winget_id -and $DisplayName -eq $_.winget_id)
                } | Select-Object -First 1

                if (-not $MatchedApp) {
                    $MatchedApp = $Catalog | Where-Object {
                        ($_.name -and $DisplayName -like "*$($_.name)*") -or
                        ($_.app_id -and $DisplayName -like "*$($_.app_id)*")
                    } | Sort-Object { if ($_.name) { $_.name.Length } else { $_.app_id.Length } } -Descending | Select-Object -First 1
                }

                # Skip driver-only subcomponents and internal runtime noise unless explicitly cataloged
                $IsArpNoise = ($DisplayName -match "^(Adobe Genuine Service|Microsoft Windows Application Compatibility Fix Database|vs_CoreEditorFonts|Windows SDK AddOn|.*HD Audio Driver.*|.*USB Audio Drivers.*|.*FrameView SDK.*)")
                if ($IsArpNoise -and -not $MatchedApp) {
                    continue
                }

                $NonWinGetApps += [PSCustomObject]@{
                    display_name     = $DisplayName
                    display_version  = if ($Entry.DisplayVersion) { "$($Entry.DisplayVersion)".Trim() } else { "Unknown" }
                    publisher        = if ($Entry.Publisher) { "$($Entry.Publisher)".Trim() } else { "Unknown" }
                    install_location = if ($Entry.InstallLocation) { "$($Entry.InstallLocation)".Trim() } else { $null }
                    registry_hive    = $Target.Hive
                    matched_app_id   = if ($MatchedApp) { $MatchedApp.app_id } else { $null }
                }
            }
        }
    }

    return [PSCustomObject]@{
        installed_winget_packages        = $WinGetPackages
        detected_non_winget_applications = $NonWinGetApps
    }
}

