<#
.SYNOPSIS
    Generates Phase 5 User Hydration scripts (hydrate.ps1, hydrate-helpers.ps1, and setup-wsl.sh) for Reglaze.
.DESCRIPTION
    Modularizes the generated Phase 5 payload into:
    - hydrate.ps1: Top-level interactive user hydration orchestrator with explicit dependency &
      step-ordering documentation, highlighted Browser & Password Manager Authentication Bootstrap,
      and idempotent checkpointing (C:\Reglaze\hydrate-state.json).
    - hydrate-helpers.ps1: Called subscript containing the implementation mechanics for preserved
      disk verification, user personalization & display topology, Browser & Password Manager
      authentication bootstrap, Known User Shell Folders relocation, user-scope WinGet packages,
      Google Drive mount & sync folder migration, Steam library discovery & bulk game installation,
      manual application walkthroughs, user directory junctions & shell pins, and user-scope WSL2
      distribution installation.
    - setup-wsl.sh: Non-interactive Linux root provisioner for user creation, sudoers, /etc/wsl.conf,
      and apt package installation.
#>
[CmdletBinding()]
param()

function Build-ReglazeHydrateScripts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Blueprint,

        [Parameter(Mandatory=$true)]
        [string]$PayloadDir,

        [Parameter(Mandatory=$true)]
        [hashtable]$VarMap
    )

    $StreamSentinel = if ($VarMap.ContainsKey("STREAM")) { $VarMap["STREAM"] } else { "E:\My Drive" }
    $WslDistro = if ($Blueprint.wsl2 -and $Blueprint.wsl2.distro) { [string]$Blueprint.wsl2.distro } else { "Ubuntu" }
    $PrimaryUser = if ($Blueprint.system -and $Blueprint.system.users -and $Blueprint.system.users.primary_user -and $Blueprint.system.users.primary_user.username) {
        $Blueprint.system.users.primary_user.username
    } else {
        "User"
    }

    # =========================================================================
    # 1. Generate Helper Subscript: hydrate-helpers.ps1
    # =========================================================================
    $HydrateHelpersScript = @"
<#
.SYNOPSIS
    Reglaze Phase 5 User Hydration Helper Subscript (hydrate-helpers.ps1).
.DESCRIPTION
    Contains the modular step worker functions called by hydrate.ps1 inside the
    primary user's interactive desktop session:
    - Read-JsonArray: PowerShell 5.1-safe JSON array reader.
    - Invoke-PreservedDisksVerification: Verifies required preserved drives are mounted.
    - Invoke-UserPersonalizationSettings: Applies user-scoped Theme, Input, Audio/Display
      topology, Taskbar/Tray/Clock, and HKCU Ergonomics (Clipboard History & Default Terminal).
    - Invoke-BrowserAuthBootstrap: Guides the user through the Foundational Authentication
      Bootstrap (Default Browser + Chrome Profile Sync + chrome://history/syncedTabs +
      Password Manager extension such as Bitwarden) before downstream OAuth/login steps.
    - Invoke-UserShellFoldersRelocation: Applies Explorer folder options (including HKCU
      SharingWizardOn) and relocates Known User Shell Folders (Desktop, Documents, Downloads,
      Pictures, Music, Videos) in the primary user's HKCU hive.
    - Invoke-UserScopeWinGetPackages: Installs user-scoped and deferred WinGet packages
      from user-packages.json under the primary user account.
    - Invoke-GoogleDriveMountAndMigration: Launches Google Drive for Desktop, displays the
      setup checklist, waits for the virtual streaming mount sentinel, and migrates OS-drive
      synced folders from 'Other computers\<Name>'.
    - Invoke-SteamDiscoveryAndProvisioning: Discovers preserved Steam libraries, launches
      Steam for authentication, restores non-Steam shortcuts, and orchestrates bulk or
      individual game installations.
    - Invoke-ManualAppsWalkthrough: Walks through manual-install applications.
    - Invoke-UserJunctionsAndPins: Creates user-scope directory junctions and file symlinks
      from junctions-manifest.json, re-applies cloud-hosted desktop wallpaper if needed,
      and applies Quick Access pins, Taskbar pins, User PATH additions, and Steam libraries.
    - Invoke-UserWslProvisioning: Installs the WSL2 distribution in the primary user's
      HKCU scope (wsl.exe --install -d <Distro> --no-launch) and runs setup-wsl.sh.
#>
[CmdletBinding()]
param()

# PowerShell 5.1-safe JSON array reader (prevents @(ConvertFrom-Json) from wrapping Object[] inside a 1-element array)
function Read-JsonArray ([string]`$Path) {
    if (-not (Test-Path -LiteralPath `$Path)) { return @() }
    `$Parsed = Get-Content -Raw -LiteralPath `$Path -Encoding UTF8 | ConvertFrom-Json
    if (`$null -eq `$Parsed) { return @() }
    if (`$Parsed -is [System.Array] -or (`$Parsed -is [System.Collections.IEnumerable] -and -not (`$Parsed -is [string]) -and -not (`$Parsed -is [System.Collections.IDictionary]))) {
        `$List = [System.Collections.Generic.List[object]]::new()
        foreach (`$Elem in `$Parsed) { `$List.Add(`$Elem) }
        return `$List.ToArray()
    }
    return @(`$Parsed)
}

function Invoke-PreservedDisksVerification ([string]`$PayloadDir) {
    `$DiskConfigFile = Join-Path `$PayloadDir "disk-config.json"
    if (Test-Path `$DiskConfigFile) {
        `$DiskCfg = Get-Content -Raw `$DiskConfigFile | ConvertFrom-Json
        foreach (`$PD in `$DiskCfg.PreservedDisks) {
            if (`$PD.Required -and `$PD.ExpectedMount -and -not (Test-Path "`$(`$PD.ExpectedMount)\")) {
                Write-Warning "Required preserved disk '`$(`$PD.Label)' (`$(`$PD.ExpectedMount)) is not currently mounted!"
            }
        }
    }
}

function Invoke-UserPersonalizationSettings ([PSCustomObject]`$WinCfg, [string]`$WinScriptsDir) {
    if (-not `$WinCfg) { return }
    try {
        `$ThemeScript = Join-Path `$WinScriptsDir "theme-personalization.ps1"
        if ((Test-Path `$ThemeScript) -and `$WinCfg.theme) {
            & `$ThemeScript -AppsMode `$WinCfg.theme.apps_mode -SystemMode `$WinCfg.theme.system_mode -Transparency:([bool]`$WinCfg.theme.transparency) -AccentColor `$WinCfg.theme.accent_color -AccentOnTaskbar:([bool]`$WinCfg.theme.accent_on_taskbar) -AccentOnTitlebars:([bool]`$WinCfg.theme.accent_on_titlebars) -WallpaperPath `$WinCfg.theme.wallpaper_path -WallpaperStyle ([int]`$WinCfg.theme.wallpaper_style)
        }
        `$InputScript = Join-Path `$WinScriptsDir "input-mouse-keyboard.ps1"
        if ((Test-Path `$InputScript) -and `$WinCfg.input) {
            & `$InputScript -MouseSpeed ([int]`$WinCfg.input.mouse.speed) -EnhancePointerPrecision:([bool]`$WinCfg.input.mouse.enhance_pointer_precision) -SwapMouseButtons:([bool]`$WinCfg.input.mouse.swap_buttons) -WheelScrollLines ([int]`$WinCfg.input.mouse.wheel_scroll_lines) -KeyboardRepeatDelay ([int]`$WinCfg.input.keyboard.repeat_delay) -KeyboardRepeatSpeed ([int]`$WinCfg.input.keyboard.repeat_speed) -NumLockOnStartup:([bool]`$WinCfg.input.keyboard.numlock_on_startup) -InputLanguages @(`$WinCfg.input.keyboard.input_languages)
        }
        `$AudioScript = Join-Path `$WinScriptsDir "audio-display.ps1"
        if (Test-Path `$AudioScript) {
            `$AudDev = if (`$WinCfg.audio_and_devices) { `$WinCfg.audio_and_devices } else { `$WinCfg.audio_and_display }
            `$DispCfg = if (`$WinCfg.display) { `$WinCfg.display } else { `$WinCfg.audio_and_display }
            `$GameMode = if (`$DispCfg -and `$null -ne `$DispCfg.game_mode_enabled) { [bool]`$DispCfg.game_mode_enabled } else { `$true }
            `$HwGpu = if (`$DispCfg -and `$null -ne `$DispCfg.hardware_gpu_scheduling) { [bool]`$DispCfg.hardware_gpu_scheduling } else { `$true }
            `$Mons = if (`$DispCfg -and `$DispCfg.monitors) { @(`$DispCfg.monitors) } else { @() }
            if (`$AudDev -or `$Mons.Count -gt 0) {
                & `$AudioScript -Scope "User" -DefaultSpeakers `$AudDev.default_speakers -DefaultMicrophone `$AudDev.default_microphone -DefaultCamera `$AudDev.default_camera -DisabledCameras @(`$AudDev.disabled_cameras) -MasterVolumePercent ([int]`$AudDev.master_volume_percent) -MasterMuted:([bool]`$AudDev.master_muted) -GameModeEnabled:`$GameMode -HardwareGpuScheduling:`$HwGpu -Monitors `$Mons
            }
        }
        `$TbScript = Join-Path `$WinScriptsDir "taskbar-system-tray.ps1"
        if ((Test-Path `$TbScript) -and `$WinCfg.taskbar) {
            `$TbArgs = @{
                TaskbarAlignment   = `$WinCfg.taskbar.alignment
                SearchMode         = `$WinCfg.taskbar.search_mode
                HideWidgets        = (-not [bool]`$WinCfg.taskbar.widgets_visible)
                HideChat           = (-not [bool]`$WinCfg.taskbar.chat_visible)
                ShowSecondsInClock = ([bool]`$WinCfg.taskbar.show_seconds_in_clock)
                EndTaskEnabled     = ([bool]`$WinCfg.taskbar.end_task_enabled)
                PromotedTrayIcons  = @(`$WinCfg.taskbar.promoted_tray_icons)
            }
            if (`$WinCfg.clock_and_region) {
                if (`$WinCfg.clock_and_region.short_time_format) { `$TbArgs["ShortTimeFormat"] = [string]`$WinCfg.clock_and_region.short_time_format }
                if (`$WinCfg.clock_and_region.long_time_format)  { `$TbArgs["LongTimeFormat"]  = [string]`$WinCfg.clock_and_region.long_time_format }
                if (`$WinCfg.clock_and_region.short_date_format) { `$TbArgs["ShortDateFormat"] = [string]`$WinCfg.clock_and_region.short_date_format }
                if (`$null -ne `$WinCfg.clock_and_region.use_24_hour_clock) { `$TbArgs["Use24HourClock"] = [bool]`$WinCfg.clock_and_region.use_24_hour_clock }
            }
            & `$TbScript @TbArgs
        }
        `$PwrScript = Join-Path `$WinScriptsDir "performance-power.ps1"
        if ((Test-Path `$PwrScript) -and `$WinCfg.system_ergonomics) {
            `$Plan = (`$WinCfg.power.active_scheme_name -replace '\s+', '')
            `$AcDisp = if (`$null -ne `$WinCfg.power.ac_display_minutes) { [int]`$WinCfg.power.ac_display_minutes } else { 30 }
            & `$PwrScript -Scope "User" -PowerPlan `$Plan -AcSleepTimeoutMinutes ([int]`$WinCfg.power.ac_sleep_minutes) -AcDisplayTimeoutMinutes `$AcDisp -ClipboardHistoryEnabled:([bool]`$WinCfg.system_ergonomics.clipboard_history_enabled) -DefaultTerminal `$WinCfg.system_ergonomics.default_terminal
        }
        Write-Host "[SUCCESS] Personalization, display positioning, mouse/keyboard, and taskbar preferences applied." -ForegroundColor Green
    } catch {
        Write-Warning "Could not apply some personalization settings: `$(`$_.Exception.Message)"
    }
}

function Invoke-BrowserAuthBootstrap {
    Write-Host "================================================================================" -ForegroundColor Cyan
    Write-Host "  FOUNDATIONAL AUTHENTICATION BOOTSTRAP (BROWSER + PASSWORD MANAGER)" -ForegroundColor Cyan
    Write-Host "================================================================================" -ForegroundColor Cyan
    Write-Host "Why this step is different from ordinary application installs:" -ForegroundColor Yellow
    Write-Host "  Your primary browser (e.g., Chrome) and password manager (e.g., Bitwarden) are"
    Write-Host "  installed as machine binaries during Phase 4, but their user authentication and"
    Write-Host "  extension unlock MUST happen here at the start of Phase 5 BEFORE Cloud Storage"
    Write-Host "  (Step 6), Steam (Step 7), and Manual App Downloads (Step 8), which all depend on"
    Write-Host "  browser OAuth popups, autofill credentials, and 2FA/TOTP codes."
    Write-Host ""
    Write-Host "Recommended Browser & Password Manager Checklist:" -ForegroundColor Cyan
    Write-Host "  1. Set your preferred browser (e.g., Google Chrome) as the Windows Default Browser."
    Write-Host "  2. Sign into your browser profile to sync bookmarks, extensions, and settings."
    Write-Host "     * PASSKEY TIP: If Google prompts for a Windows Hello passkey from your previous" -ForegroundColor Yellow
    Write-Host "       Windows install, click 'Try another way' to use your phone, authenticator, or password." -ForegroundColor Yellow
    Write-Host "  3. Sign into and unlock your password manager extension (e.g., Bitwarden)."
    Write-Host "  4. To restore open tabs from your previous installation, navigate to:" -ForegroundColor Green
    Write-Host "       chrome://history/syncedTabs" -ForegroundColor Green
    Write-Host "     and click 'Open all' next to your previous computer." -ForegroundColor Green
    Write-Host ""
    `$ChromeExe = "C:\Program Files\Google\Chrome\Application\chrome.exe"
    `$PromptBrowser = Read-Host "Launch browser and Windows Default Apps settings now? (Y/n)"
    if ([string]::IsNullOrWhiteSpace(`$PromptBrowser) -or `$PromptBrowser -match '^[Yy]') {
        if (Test-Path `$ChromeExe) {
            Start-Process -FilePath `$ChromeExe -ArgumentList "--make-default-browser", "chrome://history/syncedTabs" -ErrorAction SilentlyContinue
        }
        Start-Process "ms-settings:defaultapps" -ErrorAction SilentlyContinue
        Read-Host "Press [Enter] once you have set your default browser and signed into your profile/password manager..."
    }
}

function Invoke-UserShellFoldersRelocation ([PSCustomObject]`$WinCfg, [string]`$WinScriptsDir) {
    if (-not `$WinCfg) { return }
    try {
        `$ExpScript = Join-Path `$WinScriptsDir "explorer-folder-options.ps1"
        if (Test-Path `$ExpScript) {
            `$SharingWiz = if (`$WinCfg.network -and `$null -ne `$WinCfg.network.sharing_wizard_enabled) { [bool]`$WinCfg.network.sharing_wizard_enabled } else { `$null }
            & `$ExpScript -ShowHiddenFiles:([bool]`$WinCfg.explorer.show_hidden_files) -ShowFileExtensions:([bool]`$WinCfg.explorer.show_file_extensions) -LaunchTo `$WinCfg.explorer.launch_to -HideRecentFromQuickAccess:([bool]`$WinCfg.explorer.hide_recent_in_quick_access) -ClassicContextMenu:([bool]`$WinCfg.explorer.classic_context_menu) -SharingWizardEnabled `$SharingWiz -UserShellFolders `$WinCfg.user_shell_folders
            Write-Host "[SUCCESS] User Shell Folders and Explorer folder options applied." -ForegroundColor Green
        }
    } catch {
        Write-Warning "Could not apply User Shell Folders: `$(`$_.Exception.Message)"
    }
}

function Invoke-UserScopeWinGetPackages ([string]`$PayloadDir) {
    `$UserPackagesFile = Join-Path `$PayloadDir "user-packages.json"
    `$UserPackages = Read-JsonArray `$UserPackagesFile
    if (`$UserPackages.Count -gt 0) {
        Write-Host "Found `$(`$UserPackages.Count) user-scoped / deferred WinGet package(s) to install in current user context:" -ForegroundColor Cyan
        for (`$idx = 0; `$idx -lt `$UserPackages.Count; `$idx++) {
            `$UPkg = `$UserPackages[`$idx]
            `$PkgId = `$UPkg.PackageId
            `$PkgSrc = if (`$UPkg.Source) { `$UPkg.Source } else { "winget" }
            `$PkgName = if (`$UPkg.AppName) { `$UPkg.AppName } else { `$PkgId }
            Write-Host " [`$(`$idx + 1)/`$(`$UserPackages.Count)] Installing user package: `$PkgName (`$PkgId)..." -ForegroundColor Cyan
            `$ListCheck = & winget list --id `$PkgId --exact --accept-source-agreements 2>&1
            if (`$LASTEXITCODE -eq 0 -and (`$ListCheck -join "``n") -match [regex]::Escape(`$PkgId)) {
                Write-Host "   [OK] `$PkgId is already installed." -ForegroundColor Green
                continue
            }
            & winget install --id `$PkgId --source `$PkgSrc --exact --scope user --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
            if (`$LASTEXITCODE -ne 0 -and `$LASTEXITCODE -ne -1978335189) {
                Write-Host "   Retrying `$PkgId with default user-session scope..." -ForegroundColor DarkGray
                & winget install --id `$PkgId --source `$PkgSrc --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
            }
            if (`$LASTEXITCODE -eq 0 -or `$LASTEXITCODE -eq -1978335189) {
                Write-Host "   [+] Installed `$PkgName (`$PkgId)." -ForegroundColor Green
            } else {
                Write-Warning "   Package `$PkgId returned exit code `$LASTEXITCODE."
            }
        }
    } else {
        Write-Host "No user-scoped WinGet packages queued." -ForegroundColor DarkGray
    }
}

function Invoke-GoogleDriveMountAndMigration ([string]`$PayloadDir, [string]`$SentinelPath) {
    `$StreamRoot = ([System.IO.Path]::GetPathRoot(`$SentinelPath)).TrimEnd('\')
    `$GDriveSetupFile = Join-Path `$PayloadDir "google-drive-setup.json"
    `$GDriveSetup = if (Test-Path `$GDriveSetupFile) { Get-Content -Raw `$GDriveSetupFile | ConvertFrom-Json } else { `$null }

    if (`$GDriveSetup) {
        # Pre-create local synced directories on physical disks
        foreach (`$SDir in @(`$GDriveSetup.SyncDirectories)) {
            if (`$SDir.LocalPath -and -not (Test-Path `$SDir.LocalPath)) {
                New-Item -ItemType Directory -Path `$SDir.LocalPath -Force | Out-Null
            }
        }
        Write-Host "Google Drive Setup Checklist (Profile: `$(`$GDriveSetup.Profile)):" -ForegroundColor Cyan
        Write-Host "  [WHAT TO DO / WHAT NOT TO DO DURING GOOGLE DRIVE SETUP]" -ForegroundColor Yellow
        foreach (`$InstLine in @(`$GDriveSetup.RenderedInstructions)) {
            Write-Host "  * `$InstLine"
        }
        if (`$GDriveSetup.SyncDirectories -and @(`$GDriveSetup.SyncDirectories).Count -gt 0) {
            Write-Host ""
            Write-Host "  Pre-created Sync Folders to add in Google Drive Preferences -> 'Folders from your computer':" -ForegroundColor Green
            foreach (`$SDir in @(`$GDriveSetup.SyncDirectories)) {
                `$DiskNote = if (`$SDir.IsOnPreservedDisk) { " [Preserved Drive - re-attach in Drive, no copy needed]" } else { " [OS Drive - will copy from cloud backup]" }
                Write-Host "    + `$(`$SDir.LocalPath) (Cloud folder: `$(`$SDir.CloudFolder))`$DiskNote" -ForegroundColor Green
            }
        } else {
            Write-Host ""
            Write-Host "  IMPORTANT: No local Sync folders are configured in this blueprint." -ForegroundColor Yellow
            Write-Host "  DO NOT create or add any folders under 'Folders from your computer' in Google Drive Preferences." -ForegroundColor Yellow
        }
        Write-Host ""
    } else {
        Write-Host "Directory junctions require your cloud storage virtual stream to be mounted at:"
        Write-Host "  `$SentinelPath" -ForegroundColor Cyan
        Write-Host "  * DO NOT select Desktop, Documents, or Pictures for backup during Google Drive onboarding." -ForegroundColor Yellow
        Write-Host "  * DO configure Google Drive ('My Drive') to 'Stream files' (NOT 'Mirror files')." -ForegroundColor Yellow
        Write-Host ""
    }

    # Launch Google Drive client if not running
    if (-not (Get-Process "GoogleDriveFS" -ErrorAction SilentlyContinue)) {
        `$GDFPath = "C:\Program Files\Google\Drive File Stream\launch.bat"
        if (Test-Path `$GDFPath) {
            Start-Process `$GDFPath
        } else {
            `$GdfExe = Get-ChildItem -Path "C:\Program Files\Google\Drive File Stream\*\GoogleDriveFS.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
            if (`$GdfExe) {
                Start-Process `$GdfExe.FullName
            } else {
                Start-Process "powershell.exe" "-Command Start-Process 'shell:AppsFolder\Google.GoogleDrive'" -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Host "Waiting for sentinel directory: `$SentinelPath..." -ForegroundColor Yellow
    `$WaitCount = 0
    while (-not (Test-Path `$SentinelPath)) {
        Start-Sleep -Seconds 3
        `$WaitCount++
        if (`$WaitCount -ge 5 -and (`$WaitCount % 5 -eq 0)) {
            `$ManualChoice = Read-Host "Sentinel not yet found. Press [Enter] to keep waiting, or type 'skip' to bypass:"
            if (`$ManualChoice -eq 'skip') {
                Write-Warning "Skipping cloud sentinel verification by user request."
                break
            }
        }
    }

    if (Test-Path `$SentinelPath) {
        Write-Host "[SUCCESS] Cloud streaming mount verified at `$SentinelPath!" -ForegroundColor Green
    }

    # Migrate (copy/move) files from previous computer's synced folders ONLY for non-preserved (OS drive) folders
    if (`$GDriveSetup -and `$GDriveSetup.SyncDirectories -and @(`$GDriveSetup.SyncDirectories).Count -gt 0 -and `$GDriveSetup.MigrationMode -ne "skip") {
        Write-Host ""
        Read-Host "Ensure you have added your synced folder(s) under Google Drive Preferences -> 'Folders from your computer', then press [Enter] to continue..."

        # Resolve the actual Google Drive 'Other computers\<Name>' container path
        `$OtherComputersRoot = Join-Path `$StreamRoot "Other computers"
        `$ResolvedCompDir = `$null
        if (Test-Path -LiteralPath `$OtherComputersRoot) {
            `$CandidateNames = @(`$GDriveSetup.SourceComputerName, "My Computer", "My Laptop") | Select-Object -Unique
            foreach (`$CName in `$CandidateNames) {
                if (`$CName) {
                    `$CandPath = Join-Path `$OtherComputersRoot `$CName
                    if (Test-Path -LiteralPath `$CandPath) {
                        `$ResolvedCompDir = `$CandPath
                        break
                    }
                }
            }
            if (-not `$ResolvedCompDir) {
                `$SubCompDirs = @(Get-ChildItem -LiteralPath `$OtherComputersRoot -Directory -ErrorAction SilentlyContinue)
                if (`$SubCompDirs.Count -eq 1) {
                    `$ResolvedCompDir = `$SubCompDirs[0].FullName
                    Write-Host "Auto-detected Google Drive computer folder: `$ResolvedCompDir" -ForegroundColor Cyan
                } elseif (`$SubCompDirs.Count -gt 1) {
                    Write-Host "Available Google Drive computer backup folders under `${OtherComputersRoot}:" -ForegroundColor Cyan
                    for (`$ci = 0; `$ci -lt `$SubCompDirs.Count; `$ci++) {
                        Write-Host "  [`$(`$ci + 1)] `$(`$SubCompDirs[`$ci].Name)"
                    }
                    `$Pick = Read-Host "Select computer folder number to copy OS-drive sync folders from (default: 1)"
                    `$PickIdx = if (`$Pick -match '^\d+$' -and [int]`$Pick -ge 1 -and [int]`$Pick -le `$SubCompDirs.Count) { [int]`$Pick - 1 } else { 0 }
                    `$ResolvedCompDir = `$SubCompDirs[`$PickIdx].FullName
                }
            }
        }

        foreach (`$SDir in @(`$GDriveSetup.SyncDirectories)) {
            `$DstLocalPath = `$SDir.LocalPath
            `$LocalRoot = if (`$DstLocalPath) { ([System.IO.Path]::GetPathRoot(`$DstLocalPath)).TrimEnd('\') } else { "" }
            `$IsPreserved = (`$SDir.IsOnPreservedDisk -eq `$true) -or (`$LocalRoot -and `$LocalRoot -inotlike "C*")
            if (`$IsPreserved -and (Test-Path -LiteralPath `$DstLocalPath)) {
                Write-Host " - [SKIP] '`$(`$SDir.CloudFolder)' (`$DstLocalPath) is on a preserved drive; skipping cloud file copy." -ForegroundColor DarkGray
                continue
            }

            `$SrcStreamPath = if (`$ResolvedCompDir) {
                Join-Path `$ResolvedCompDir `$SDir.CloudFolder
            } else {
                `$SDir.SourceComputerStreamPath
            }

            if (`$SrcStreamPath -and (Test-Path -LiteralPath `$SrcStreamPath)) {
                Write-Host " - Migrating (`$(`$GDriveSetup.MigrationMode)) '`$(`$SDir.CloudFolder)' from `$SrcStreamPath -> `$DstLocalPath..." -ForegroundColor Yellow
                if (-not (Test-Path -LiteralPath `$DstLocalPath)) {
                    New-Item -ItemType Directory -Path `$DstLocalPath -Force | Out-Null
                }
                if (`$GDriveSetup.MigrationMode -eq "move") {
                    Get-ChildItem -LiteralPath `$SrcStreamPath -Force | ForEach-Object {
                        Move-Item -LiteralPath `$_.FullName -Destination `$DstLocalPath -Force -ErrorAction Continue
                    }
                } else {
                    Copy-Item -Path (Join-Path `$SrcStreamPath "*") -Destination `$DstLocalPath -Recurse -Force -ErrorAction Continue
                }
                Write-Host "   Completed migration for '`$(`$SDir.CloudFolder)'." -ForegroundColor Green
            } else {
                Write-Host " - Previous computer folder not found at '`$SrcStreamPath' (skipping automatic copy for '`$(`$SDir.CloudFolder)')." -ForegroundColor DarkGray
            }
        }
    }
}

function Invoke-SteamDiscoveryAndProvisioning ([string]`$PayloadDir) {
    `$SteamExe = "`${env:ProgramFiles(x86)}\Steam\steam.exe"

    # Discover all Steam libraries across all drives
    `$DiscoveredLibs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    `$Drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
    foreach (`$Drv in `$Drives) {
        if (`$Drv.Root) {
            foreach (`$Sub in @("SteamLibrary", "Steam", "Games\SteamLibrary", "Games\Steam")) {
                `$Cand = Join-Path `$Drv.Root `$Sub
                if ((Test-Path `$Cand) -and (Test-Path (Join-Path `$Cand "steamapps"))) {
                    `$DiscoveredLibs.Add(`$Cand) | Out-Null
                }
            }
        }
    }
    if (`$DiscoveredLibs.Count -gt 0) {
        Write-Host "Discovered `$(`$DiscoveredLibs.Count) Steam library folder(s) across drives:" -ForegroundColor Green
        foreach (`$Lib in `$DiscoveredLibs) {
            Write-Host " - `$Lib" -ForegroundColor Cyan
        }
    }

    if (Test-Path `$SteamExe) {
        Write-Host "Launching Steam for user sign-in and Steam Guard verification..."
        Start-Process `$SteamExe
        Read-Host "Press [Enter] when signed in to Steam to proceed..."
    } else {
        Write-Host "Steam client not found at `$SteamExe; skipping launch." -ForegroundColor DarkGray
    }

    # Re-register manually added non-Steam game shortcuts (shortcuts.vdf) if present in payload
    `$ShortcutsPayloadFile = Join-Path `$PayloadDir "steam-shortcuts.json"
    if ((Test-Path `$ShortcutsPayloadFile) -and (Get-Command Register-SteamShortcuts -ErrorAction SilentlyContinue)) {
        try {
            `$SavedShortcuts = Read-JsonArray `$ShortcutsPayloadFile
            if (`$SavedShortcuts.Count -gt 0) {
                `$RegRes = Register-SteamShortcuts -Shortcuts `$SavedShortcuts
                if (`$RegRes -and `$RegRes.RegisteredCount -gt 0) {
                    Write-Host "Re-registered `$(`$RegRes.RegisteredCount) non-Steam game shortcut(s) in Steam userdata (restart Steam later to see them in Library)." -ForegroundColor Green
                }
            }
        } catch {
            Write-Warning "Could not re-register non-Steam game shortcuts: `$(`$_.Exception.Message)"
        }
    }

    # Inspect games declared in applications catalog or blueprint (using PS 5.1-safe Read-JsonArray)
    `$CatalogFile = Join-Path `$PayloadDir "applications.json"
    if (Test-Path `$CatalogFile) {
        `$CatApps = Read-JsonArray `$CatalogFile
        `$SteamGames = @(`$CatApps | Where-Object { `$_.install -and (`$_.install.method -eq "steam" -or `$_.install.steam_id) })
        `$UninstalledGames = @()
        foreach (`$Game in `$SteamGames) {
            `$SId = `$Game.install.steam_id
            `$GName = if (`$Game.name) { `$Game.name } else { `$Game.app_id }
            if (`$SId) {
                `$FoundLib = `$null
                foreach (`$Lib in `$DiscoveredLibs) {
                    `$Mf = Join-Path `$Lib "steamapps\appmanifest_`$SId.acf"
                    if (Test-Path `$Mf) {
                        `$FoundLib = `$Lib
                        break
                    }
                }
                if (`$FoundLib) {
                    Write-Host " [V] Game '`$GName' (`$SId) present in reattached library: `$FoundLib" -ForegroundColor Green
                } else {
                    `$UninstalledGames += [PSCustomObject]@{
                        SId   = `$SId
                        GName = `$GName
                    }
                }
            }
        }

        if (`$UninstalledGames.Count -gt 0) {
            Write-Host ""
            Write-Host "Steam games configured for installation (`$(`$UninstalledGames.Count)):" -ForegroundColor Cyan
            foreach (`$UGame in `$UninstalledGames) {
                Write-Host "  * `$(`$UGame.GName) (AppID: `$(`$UGame.SId))" -ForegroundColor White
            }
            Write-Host ""
            Write-Host "Recommended Bulk Installation via Steam Collection:" -ForegroundColor Yellow
            Write-Host "  1. In Steam's left navigation panel, open your Base Install collection (or create one)."
            Write-Host "  2. Select all games in the collection (click first game, Shift+Click last game)."
            Write-Host "  3. Right-click the selection and click 'Install selected...' to install them in bulk."
            Write-Host ""
            `$UseLinks = Read-Host "If you haven't set up a collection, would you like to iterate over these apps and launch steam://install links individually? (y/N)"
            if (`$UseLinks -match '^[Yy]') {
                for (`$i = 0; `$i -lt `$UninstalledGames.Count; `$i++) {
                    `$UGame = `$UninstalledGames[`$i]
                    Write-Host " [`$(`$i + 1)/`$(`$UninstalledGames.Count)] Triggering Steam install for '`$(`$UGame.GName)' (`$(`$UGame.SId))..." -ForegroundColor Cyan
                    try {
                        Start-Process "steam://install/`$(`$UGame.SId)"
                        if (`$i -lt (`$UninstalledGames.Count - 1)) {
                            Read-Host "Press [Enter] after confirming the install prompt in Steam to queue the next game"
                        } else {
                            Read-Host "Press [Enter] after confirming the final install prompt in Steam to continue"
                        }
                    } catch {
                        Write-Warning "Could not trigger steam://install/`$(`$UGame.SId)"
                    }
                }
            }
        }
    }
}

function Invoke-ManualAppsWalkthrough ([string]`$PayloadDir) {
    `$CatalogFile = Join-Path `$PayloadDir "applications.json"
    if (-not (Test-Path `$CatalogFile)) { return }

    `$CatApps = Read-JsonArray `$CatalogFile
    `$ManualApps = @(`$CatApps | Where-Object { `$_.install -and `$_.install.method -eq "manual" })
    if (`$ManualApps.Count -gt 0) {
        foreach (`$MApp in `$ManualApps) {
            Write-Host ""
            Write-Host "  [Application: `$(`$MApp.name)]" -ForegroundColor Green
            if (`$MApp.website) { Write-Host "   Official URL: `$(`$MApp.website)" }
            if (`$MApp.install.download_url) { Write-Host "   Download:     `$(`$MApp.install.download_url)" }
            if (`$MApp.install.default_target_directory) { Write-Host "   Target Dir:   `$(`$MApp.install.default_target_directory)" }
            if (`$MApp.install.instructions) {
                Write-Host "   Instructions:"
                foreach (`$Inst in @(`$MApp.install.instructions)) {
                    Write-Host "    - `$Inst"
                }
            }
            Read-Host "Press [Enter] when you have completed or skipped `$(`$MApp.name)..."
        }
    } else {
        Write-Host "No manual installation applications detected." -ForegroundColor DarkGray
    }
}

function Invoke-UserJunctionsAndPins ([string]`$PayloadDir, [PSCustomObject]`$WinCfg, [string]`$WinScriptsDir) {
    `$JunctionsManifest = Join-Path `$PayloadDir "junctions-manifest.json"
    if (Test-Path `$JunctionsManifest) {
        `$Junctions = Read-JsonArray `$JunctionsManifest
        `$UserJuncs = @(`$Junctions | Where-Object { `$_.Scope -eq "user" })
        Write-Host "Linking `$(`$UserJuncs.Count) user-scope directory junction(s)..."
        `$FailedJuncs = 0

        foreach (`$Junc in `$UserJuncs) {
            `$Link = `$Junc.Link
            `$Target = `$Junc.Target
            `$IsFile = (`$Junc.ItemType -eq "file")
            Write-Host " - [`$(`$Junc.AppId)] `$Link -> `$Target (type: `$(if (`$IsFile) { 'file' } else { 'directory' }))"

            if (`$IsFile) {
                `$TargetFile = if (Test-Path -LiteralPath `$Target -PathType Container) {
                    Join-Path `$Target (Split-Path `$Link -Leaf)
                } elseif (`$Target.EndsWith((Split-Path `$Link -Leaf), [System.StringComparison]::OrdinalIgnoreCase)) {
                    `$Target
                } elseif (Test-Path -LiteralPath (Join-Path `$Target (Split-Path `$Link -Leaf))) {
                    Join-Path `$Target (Split-Path `$Link -Leaf)
                } else {
                    Join-Path `$Target (Split-Path `$Link -Leaf)
                }
                `$TargetParent = Split-Path -Parent `$TargetFile
                if (`$TargetParent -and -not (Test-Path -LiteralPath `$TargetParent)) {
                    try {
                        New-Item -ItemType Directory -Path `$TargetParent -Force | Out-Null
                    } catch {}
                }
            } else {
                if (-not (Test-Path -LiteralPath `$Target)) {
                    try {
                        New-Item -ItemType Directory -Path `$Target -Force | Out-Null
                        Write-Host "   Created target folder: `$Target" -ForegroundColor DarkGray
                    } catch {
                        Write-Warning "   Could not create target `${Target}: `$(`$_.Exception.Message)"
                    }
                }
            }

            if (Test-Path -LiteralPath `$Link) {
                `$Item = Get-Item -LiteralPath `$Link -Force
                if (-not (`$Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    `$BackupPath = "`$Link.bak_`$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                    `$MovedOk = `$false
                    for (`$MoveTry = 1; `$MoveTry -le 2; `$MoveTry++) {
                        try {
                            if (`$Item -is [System.IO.DirectoryInfo]) {
                                [System.IO.Directory]::Move(`$Link, `$BackupPath)
                            } else {
                                [System.IO.File]::Move(`$Link, `$BackupPath)
                            }
                            `$MovedOk = `$true
                            Write-Host "   Collision: Backed up existing file/directory to `$BackupPath." -ForegroundColor Yellow
                            break
                        } catch {
                            if (`$MoveTry -eq 1) {
                                Write-Warning "   Path '`$Link' is locked by a running application (e.g., Chrome, Antigravity, or Steam)."
                                `$CloseChoice = Read-Host "   Please close [`$(`$Junc.AppId)] and press [Enter] to retry (or type 'skip' to skip this junction)"
                                if (`$CloseChoice -eq 'skip') { break }
                            } else {
                                Write-Warning "   Could not backup existing `${Link}: `$(`$_.Exception.Message)"
                            }
                        }
                    }
                    if (-not `$MovedOk) {
                        `$FailedJuncs++
                        continue
                    }
                } else {
                    try {
                        if ((Get-Item -LiteralPath `$Link -Force) -is [System.IO.DirectoryInfo]) {
                            [System.IO.Directory]::Delete(`$Link)
                        } else {
                            [System.IO.File]::Delete(`$Link)
                        }
                    } catch {
                        Write-Warning "   Could not remove existing reparse point `${Link}: `$(`$_.Exception.Message)"
                        `$FailedJuncs++
                        continue
                    }
                }
            }

            `$ParentDir = Split-Path -Parent `$Link
            if (-not (Test-Path -LiteralPath `$ParentDir)) { New-Item -ItemType Directory -Path `$ParentDir -Force | Out-Null }

            if (`$IsFile) {
                `$MkOut = & cmd.exe /c "mklink ``"`$Link``" ``"`$TargetFile``"" 2>&1
                if (`$LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath `$Link)) {
                    Write-Warning "   Failed to create file symbolic link: `$MkOut"
                    `$FailedJuncs++
                } else {
                    Write-Host "   [+] Created file symbolic link: `$Link -> `$TargetFile" -ForegroundColor Green
                }
            } else {
                `$MkOut = & cmd.exe /c "mklink /J ``"`$Link``" ``"`$Target``"" 2>&1
                if (`$LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath `$Link)) {
                    Write-Warning "   Failed to create directory junction: `$MkOut"
                    `$FailedJuncs++
                }
            }
        }
        if (`$FailedJuncs -eq 0) {
            Write-Host "[SUCCESS] All user directory junctions created successfully!" -ForegroundColor Green
        } else {
            Write-Warning "`$FailedJuncs user junction(s) could not be linked. Close any locking applications and re-run with -ResetState if needed."
        }
    }

    if (`$WinCfg) {
        # Re-apply desktop wallpaper if it resides on a cloud mount (%STREAM%) or synced/junction path that wasn't mounted during Step 1
        try {
            `$ThemeScript = Join-Path `$WinScriptsDir "theme-personalization.ps1"
            if ((Test-Path `$ThemeScript) -and `$WinCfg.theme -and `$WinCfg.theme.wallpaper_path -and (Test-Path -LiteralPath `$WinCfg.theme.wallpaper_path)) {
                & `$ThemeScript -AppsMode `$WinCfg.theme.apps_mode -SystemMode `$WinCfg.theme.system_mode -Transparency:([bool]`$WinCfg.theme.transparency) -AccentColor `$WinCfg.theme.accent_color -AccentOnTaskbar:([bool]`$WinCfg.theme.accent_on_taskbar) -AccentOnTitlebars:([bool]`$WinCfg.theme.accent_on_titlebars) -WallpaperPath `$WinCfg.theme.wallpaper_path -WallpaperStyle ([int]`$WinCfg.theme.wallpaper_style)
            }
        } catch {}

        # Apply declarative Taskbar and Quick Access pins + App PATH entries + Steam Library VDF
        try {
            `$ShellPinsScript = Join-Path `$WinScriptsDir "shell-pins.ps1"
            if (Test-Path `$ShellPinsScript) {
                & `$ShellPinsScript -QuickAccessPins @(`$WinCfg.explorer.quick_access_pins) -TaskbarPinnedApps @(`$WinCfg.taskbar.pinned_apps) -StartMenuPinnedApps @(`$WinCfg.start_menu.pinned_apps) -AppPathEntries @(`$WinCfg.app_path_entries) -SteamLibraries @(`$WinCfg.steam_libraries)
            }
        } catch {
            Write-Warning "Could not apply shell pins: `$(`$_.Exception.Message)"
        }
    }
}

function Invoke-UserWslProvisioning ([string]`$PayloadDir, [string]`$WslDistroName) {
    `$WslScript = Join-Path `$PayloadDir "setup-wsl.sh"
    if (-not (Test-Path `$WslScript)) {
        Write-Host "No setup-wsl.sh script found; skipping WSL2 customization." -ForegroundColor DarkGray
        return `$true
    }

    try {
        # WSL distributions are user-scoped (HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss);
        # install inside the primary user session if not yet registered
        `$DistroListRaw = (& wsl.exe --list --quiet 2>`$null) -join "``n"
        `$DistroListClean = `$DistroListRaw -replace "``0", ""
        `$EscDistro = [regex]::Escape(`$WslDistroName)
        if (`$DistroListClean -notmatch "(?m)^`$EscDistro\s*\z" -and `$DistroListClean -notmatch "(?m)^`$EscDistro\r?\n") {
            Write-Host "Installing user-scope WSL2 distribution '`$WslDistroName' (--no-launch)..." -ForegroundColor Cyan
            & wsl.exe --install -d `$WslDistroName --no-launch
            # Re-check registration; if legacy Store Appx launcher is present and rootfs not yet unpacked, initialize as root
            `$DistroListAfter = ((& wsl.exe --list --quiet 2>`$null) -join "``n") -replace "``0", ""
            if (`$DistroListAfter -notmatch "(?m)^`$EscDistro\s*\z" -and `$DistroListAfter -notmatch "(?m)^`$EscDistro\r?\n") {
                `$LauncherName = (`$WslDistroName -replace '[^a-zA-Z0-9]', '').ToLower() + ".exe"
                `$DistroAppx = Get-Command `$LauncherName -ErrorAction SilentlyContinue
                if (`$DistroAppx) {
                    Write-Host "Initializing '`$WslDistroName' root filesystem via `$LauncherName..." -ForegroundColor Cyan
                    & `$LauncherName install --root 2>&1 | Out-Null
                }
            }
        } else {
            Write-Host " [V] WSL2 distribution '`$WslDistroName' is already registered for user." -ForegroundColor Green
        }
        Write-Host "Executing non-interactive setup-wsl.sh inside '`$WslDistroName' distro as root..."
        & wsl.exe -d `$WslDistroName -u root -- /bin/bash -c "tr -d '\r' < /mnt/c/Reglaze/payload/setup-wsl.sh | /bin/bash"
        if (`$LASTEXITCODE -eq 0) {
            # Restart WSL instance so /etc/wsl.conf (default user & systemd=true) takes effect immediately
            & wsl.exe --terminate `$WslDistroName 2>`$null | Out-Null
            Write-Host "[SUCCESS] WSL2 distribution '`$WslDistroName' installed and provisioned!" -ForegroundColor Green
            return `$true
        } else {
            Write-Warning "WSL setup script exited with code `$LASTEXITCODE. Ensure '`$WslDistroName' is installed ('wsl --install -d `$WslDistroName') and re-run hydration."
            return `$false
        }
    } catch {
        Write-Warning "WSL setup encountered an error: `$(`$_.Exception.Message)"
        return `$false
    }
}
"@

    $HydrateHelpersPath = Join-Path $PayloadDir "hydrate-helpers.ps1"
    $HydrateHelpersScript | Set-Content -Path $HydrateHelpersPath -Encoding UTF8

    # =========================================================================
    # 2. Generate Top-Level Orchestrator: hydrate.ps1
    # =========================================================================
    $HydrateScript = @"
<#
.SYNOPSIS
    Reglaze Phase 5 User Hydration and State Linking Wizard (hydrate.ps1).
.DESCRIPTION
    Executes inside the primary user's interactive session ('$PrimaryUser') when launched
    from the 'Reglaze Hydration' desktop shortcut. Delegates step implementations to
    hydrate-helpers.ps1 and persists checkpoints to C:\Reglaze\hydrate-state.json so the
    user can safely interrupt and resume at any point.

    STEP ORDERING & DEPENDENCY CHAIN:
      [Step 0]  Preserved Disk Mount Verification
                -> Verifies preserved secondary drives (D:, F:) reconciled in Phase 4 are
                   online before any User Shell Folders or junctions reference them.
      [Step 1]  User-Scope Windows Personalization, Display Topology, Input & Taskbar
                -> Runs FIRST in the interactive desktop session so multi-monitor layout
                   (ChangeDisplaySettingsEx), Dark Mode, mouse speed, and taskbar preferences
                   are comfortable before the user performs interactive sign-ins.
      [Step 2]  Microsoft Account (MSA) Connection (Optional)
                -> Links the local user account to MSA for Store/digital license sync if desired.
      [Step 3]  FOUNDATIONAL AUTHENTICATION BOOTSTRAP (Default Browser, Profile Sync & Password Manager)
                -> Highlighted as distinct from ordinary application installs: sets the Default
                   Browser (e.g. Chrome), syncs the user's browser profile, restores prior open
                   tabs (chrome://history/syncedTabs), and unlocks the password manager extension
                   (e.g. Bitwarden). MUST run BEFORE Steps 6, 7, and 8 because Google Drive OAuth,
                   Steam login/Steam Guard, and manual web downloads depend on browser auth and
                   password manager credentials.
      [Step 4]  Relocate Windows User Shell Folders & Explorer Folder Options
                -> Relocates Known Folders (Desktop, Documents, Downloads, Pictures, Music, Videos)
                   and sets HKCU Explorer options (including SharingWizardOn). MUST run in Phase 5
                   under '$PrimaryUser' (never in Phase 4 under LocalAdmin) and BEFORE Step 9
                   (User Junctions).
      [Step 5]  User-Scope WinGet Package Installations (user-packages.json)
                -> Installs per-user WinGet packages (%LOCALAPPDATA%) and any packages automatically
                   deferred from Phase 4 because their installers rejected machine/admin context.
                   MUST run BEFORE Step 9 so app directories exist before junctions are linked.
      [Step 6]  Google Drive Virtual Mount Verification & Synced Folder Migration
                -> Depends on Step 3 (Browser OAuth). Launches Google Drive for Desktop, waits for
                   the virtual streaming mount sentinel ('$StreamSentinel'), and migrates OS-drive
                   synced folders from 'Other computers\<Name>'. MUST complete BEFORE Step 9 so
                   %STREAM% and %SYNC_*% junction targets exist on disk.
      [Step 7]  Steam Multi-Library Rediscovery, Non-Steam Shortcuts & Bulk Game Installs
                -> Depends on Step 3 (Password Manager for login). Discovers preserved Steam
                   libraries, restores shortcuts.vdf, and installs games via Steam Collection or
                   steam://install links. MUST complete BEFORE Step 9 so game folders (e.g. Beat
                   Saber) and Steam userdata exist before junctions are linked.
      [Step 8]  Manual Application Installation Guidance
                -> Depends on Step 3 (Browser & Password Manager). Walks through manual-install
                   apps BEFORE Step 9 links their configuration/plugin directories.
      [Step 9]  User-Scope Directory Junctions, Cloud Wallpaper Re-Application & Shell Pins
                -> Depends on Steps 0, 4, 5, 6, 7, and 8. Links all user-scope junctions and
                   symlinks from junctions-manifest.json, re-applies desktop wallpaper if hosted
                   on a newly mounted cloud/junction path, and applies Quick Access pins, Taskbar
                   pins, User PATH additions, and Steam library registrations.
      [Step 10] User-Scope WSL2 Distribution Installation & Non-Interactive Provisioning
                -> WSL distributions are registered per-user in HKCU:\Software\Microsoft\Windows\
                   CurrentVersion\Lxss. Installs '$WslDistro' (--no-launch) under '$PrimaryUser'
                   and executes setup-wsl.sh as root to configure the default Linux user and packages.
      [Step 11] Developer Repositories & Dotfiles Verification
#>
[CmdletBinding()]
param(
    [switch]`$ResetState = `$false
)

`$ErrorActionPreference = "Continue"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
`$TranscriptFile = "C:\Reglaze\hydrate.log"
try {
    `$TranscriptDir = Split-Path -Parent `$TranscriptFile
    if (-not (Test-Path `$TranscriptDir)) { New-Item -ItemType Directory -Path `$TranscriptDir -Force | Out-Null }
    Start-Transcript -Path `$TranscriptFile -Append -Force | Out-Null
} catch {
    try {
        `$FallbackLog = Join-Path `$env:LOCALAPPDATA "Reglaze\hydrate.log"
        `$FallbackDir = Split-Path -Parent `$FallbackLog
        if (-not (Test-Path `$FallbackDir)) { New-Item -ItemType Directory -Path `$FallbackDir -Force | Out-Null }
        Start-Transcript -Path `$FallbackLog -Append -Force | Out-Null
    } catch {}
}

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "            REGLAZE PHASE 5: USER HYDRATION AND STATE LINKING WIZARD            " -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "Transcript log: `$TranscriptFile" -ForegroundColor DarkGray

# Ensure WinGet AppX execution alias is registered for the standard user account
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction SilentlyContinue
    `$env:Path += ";`$env:LOCALAPPDATA\Microsoft\WindowsApps"
}

`$PayloadDir = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$GameLibHelper = Join-Path `$PayloadDir "GameLibraries.ps1"
`$HydrateHelpers = Join-Path `$PayloadDir "hydrate-helpers.ps1"
if (Test-Path `$GameLibHelper) { . `$GameLibHelper }
if (Test-Path `$HydrateHelpers) { . `$HydrateHelpers }

`$StateFile = "C:\Reglaze\hydrate-state.json"
`$State = [PSCustomObject]@{
    CompletedSteps = @()
    StartedAt = (Get-Date).ToString("o")
}

if ((Test-Path `$StateFile) -and -not `$ResetState) {
    try {
        `$State = Get-Content -Raw `$StateFile | ConvertFrom-Json
        if (-not `$State.CompletedSteps) { `$State.CompletedSteps = @() }
        Write-Host "Loaded existing hydration state. Completed steps: `$(`$State.CompletedSteps -join ', ')" -ForegroundColor DarkCyan
    } catch {
        Write-Warning "Could not parse state file; starting fresh."
    }
}

function Save-HydrateState {
    param([string]`$StepName)
    if (`$State.CompletedSteps -notcontains `$StepName) {
        `$State.CompletedSteps += `$StepName
    }
    `$StateDir = Split-Path -Parent `$StateFile
    if (-not (Test-Path `$StateDir)) { New-Item -ItemType Directory -Path `$StateDir -Force | Out-Null }
    `$State | ConvertTo-Json -Depth 3 | Set-Content -Path `$StateFile -Encoding UTF8
    Write-Host "[Checkpoint: Saved step '`$StepName']" -ForegroundColor DarkGray
}

`$WinSettingsFile = Join-Path `$PayloadDir "windows-settings.json"
`$WinScriptsDir = Join-Path `$PayloadDir "windows"
`$WinCfg = if (Test-Path `$WinSettingsFile) {
    try { Get-Content -Raw -LiteralPath `$WinSettingsFile -Encoding UTF8 | ConvertFrom-Json } catch { `$null }
} else { `$null }

# =============================================================================
# STEP 0: Verify Preserved Disk Mounts
# DEPENDENCY: Must run before User Shell Folders (Step 4) or User Junctions
# (Step 9) reference preserved drive letters (D:, F:).
# =============================================================================
Invoke-PreservedDisksVerification -PayloadDir `$PayloadDir

# =============================================================================
# STEP 1: User-Scope Windows Personalization, Display Positioning, Input & Taskbar
# DEPENDENCY: Runs FIRST in the interactive desktop session so multi-monitor
# topology, dark theme, mouse speed, and taskbar settings are immediately active
# while the user completes subsequent interactive sign-in steps.
# =============================================================================
if (`$State.CompletedSteps -notcontains "personalization") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 1: Applying Windows Personalization, Display Layout, Input & Taskbar" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Invoke-UserPersonalizationSettings -WinCfg `$WinCfg -WinScriptsDir `$WinScriptsDir
    Save-HydrateState "personalization"
} else {
    Write-Host "[V] Step 1: Windows Personalization & Display Layout (Already completed)" -ForegroundColor DarkGray
}

# =============================================================================
# STEP 2: Microsoft Account Connection (Optional)
# DEPENDENCY: Optional account linking before Store/app sign-ins.
# =============================================================================
if (`$State.CompletedSteps -notcontains "microsoft_account") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 2: Microsoft Account Sign-In (Optional)" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "If you wish to link this standard account to your Microsoft Account for store and"
    Write-Host "digital license sync, open Windows Settings -> Accounts -> Your Info."
    Write-Host "  [TIP] If prompted for a Windows Hello passkey from your old Windows installation," -ForegroundColor Cyan
    Write-Host "        select 'Other ways to sign in' / 'Use a different device' or your authenticator." -ForegroundColor Cyan
    `$PromptMSA = Read-Host "Would you like to open Windows Accounts settings now? (y/N)"
    if (`$PromptMSA -match '^[Yy]') {
        Start-Process "ms-settings:yourinfo"
        Write-Host "Settings opened. Complete your sign-in, then return here."
        Read-Host "Press [Enter] when ready to proceed..."
    }
    Save-HydrateState "microsoft_account"
} else {
    Write-Host "[V] Step 2: Microsoft Account (Already completed)" -ForegroundColor DarkGray
}

# =============================================================================
# STEP 3: FOUNDATIONAL AUTHENTICATION BOOTSTRAP (Browser & Password Manager)
# DEPENDENCY: Highlighted as an authentication prerequisite rather than a normal
# app install. Must complete BEFORE Google Drive (Step 6), Steam (Step 7), and
# Manual Apps (Step 8) so browser OAuth, synced tabs, and Bitwarden credentials
# are unlocked and ready for every downstream sign-in.
# =============================================================================
if (`$State.CompletedSteps -notcontains "browser_setup") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 3: Default Browser, Profile Sync & Password Manager Auth Bootstrap" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Invoke-BrowserAuthBootstrap
    Save-HydrateState "browser_setup"
} else {
    Write-Host "[V] Step 3: Browser & Password Manager Auth Bootstrap (Already completed)" -ForegroundColor DarkGray
}

# =============================================================================
# STEP 4: Relocate Windows User Shell Folders & Explorer Folder Options
# DEPENDENCY: Must run in Phase 5 under '$PrimaryUser' (never under LocalAdmin)
# and BEFORE Step 9 (User Junctions) so Known Folder paths (Desktop, Documents,
# Downloads, Pictures, Music, Videos) are established first.
# =============================================================================
if (`$State.CompletedSteps -notcontains "user_shell_folders") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 4: Relocating Windows User Shell Folders (Documents, Downloads, etc.)" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Invoke-UserShellFoldersRelocation -WinCfg `$WinCfg -WinScriptsDir `$WinScriptsDir
    Save-HydrateState "user_shell_folders"
} else {
    Write-Host "[V] Step 4: User Shell Folders & Explorer Options (Already completed)" -ForegroundColor DarkGray
}

# =============================================================================
# STEP 5: User-Scope WinGet Package Installations (user-packages.json)
# DEPENDENCY: Installs packages that require the primary user's %LOCALAPPDATA%
# context (or were deferred from Phase 4). Must run BEFORE Step 9 so installed
# application directories exist before user junctions are linked.
# =============================================================================
if (`$State.CompletedSteps -notcontains "user_packages") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 5: Installing User-Scope WinGet Applications" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Invoke-UserScopeWinGetPackages -PayloadDir `$PayloadDir
    Save-HydrateState "user_packages"
} else {
    Write-Host "[V] Step 5: User-Scope WinGet Packages (Already completed)" -ForegroundColor DarkGray
}

# =============================================================================
# STEP 6: Cloud Virtual Mount and Synced Folders Setup (Google Drive)
# DEPENDENCY: Requires Step 3 (Default Browser & Password Manager ready for
# Google OAuth) and Step 4 in Phase 4 (HKLM DriveFS DefaultMountPoint policy).
# Must complete BEFORE Step 9 (User Junctions) so '$StreamSentinel' (%STREAM%)
# and synced folders (%SYNC_*%) exist on disk before junctions point to them.
# =============================================================================
if (`$State.CompletedSteps -notcontains "cloud_mount") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 6: Google Drive Streaming Mount and Synced Folder Migration" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Invoke-GoogleDriveMountAndMigration -PayloadDir `$PayloadDir -SentinelPath "$StreamSentinel"
    Save-HydrateState "cloud_mount"
} else {
    Write-Host "[V] Step 6: Cloud Storage Mount and Sync Migration (Already completed)" -ForegroundColor DarkGray
}

# =============================================================================
# STEP 7: Steam Multi-Library Discovery, Non-Steam Shortcuts & Bulk Game Installs
# DEPENDENCY: Requires Step 3 (Password Manager for Steam login) and Step 0
# (preserved drives mounted). Must complete BEFORE Step 9 (User Junctions) so
# Steam userdata and game directories (e.g. Beat Saber CustomLevels) exist.
# =============================================================================
if (`$State.CompletedSteps -notcontains "steam_signin") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 7: Steam Multi-Library Rediscovery and Game Installations" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Invoke-SteamDiscoveryAndProvisioning -PayloadDir `$PayloadDir
    Save-HydrateState "steam_signin"
} else {
    Write-Host "[V] Step 7: Steam Multi-Library and Game Provisioning (Already completed)" -ForegroundColor DarkGray
}

# =============================================================================
# STEP 8: Manual Application Installs Walkthrough
# DEPENDENCY: Requires Step 3 (Browser & Password Manager for web downloads).
# Must complete BEFORE Step 9 so manually installed app directories exist before
# their settings/plugins junctions are created.
# =============================================================================
if (`$State.CompletedSteps -notcontains "manual_installs") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 8: Manual Application Installation Guidance" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Invoke-ManualAppsWalkthrough -PayloadDir `$PayloadDir
    Save-HydrateState "manual_installs"
} else {
    Write-Host "[V] Step 8: Manual Applications (Already completed)" -ForegroundColor DarkGray
}

# =============================================================================
# STEP 9: User-Level Directory Junctions, Cloud Wallpaper & Shell Pins
# DEPENDENCY: Must run AFTER Steps 0, 4, 5, 6, 7, and 8 so all preserved drives,
# Known User Shell Folders, user-scope apps, Google Drive (%STREAM% / %SYNC_*%),
# Steam libraries, and manual apps are present on disk before linking junctions
# and pinning folders/apps to Quick Access and Taskbar.
# =============================================================================
if (`$State.CompletedSteps -notcontains "user_junctions") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 9: Creating User-Level Directory Junctions and Shell Pins" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Invoke-UserJunctionsAndPins -PayloadDir `$PayloadDir -WinCfg `$WinCfg -WinScriptsDir `$WinScriptsDir
    Save-HydrateState "user_junctions"
} else {
    Write-Host "[V] Step 9: User Junctions and Shell Pins (Already completed)" -ForegroundColor DarkGray
}

# =============================================================================
# STEP 10: User-Scope WSL2 Distro Installation & Non-Interactive Setup
# DEPENDENCY: Requires Phase 4 Step 5 (machine-wide WSL2 kernel staged via
# 'wsl --install --no-distribution'). Because WSL distributions are registered
# per-user in HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss, installing
# '$WslDistro' MUST happen here under '$PrimaryUser'.
# =============================================================================
if (`$State.CompletedSteps -notcontains "wsl_setup") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 10: User-Scope WSL2 Distribution Installation & Provisioning" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    `$WslDistroName = "$WslDistro"
    if (Invoke-UserWslProvisioning -PayloadDir `$PayloadDir -WslDistroName `$WslDistroName) {
        Save-HydrateState "wsl_setup"
    }
} else {
    Write-Host "[V] Step 10: WSL2 Environment (Already completed)" -ForegroundColor DarkGray
}

# =============================================================================
# STEP 11: Developer Repositories and Dotfiles
# =============================================================================
if (`$State.CompletedSteps -notcontains "dev_repos") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 11: Developer Repositories and Dotfiles Configuration" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "Verifying chezmoi and git developer repositories..."
    if (Get-Command "chezmoi" -ErrorAction SilentlyContinue) {
        Write-Host "Chezmoi detected. Ready for dotfiles init/apply."
    } else {
        Write-Host "Chezmoi not found in PATH; developer can run 'chezmoi init' when ready." -ForegroundColor DarkGray
    }
    Save-HydrateState "dev_repos"
} else {
    Write-Host "[V] Step 11: Dev Repositories (Already completed)" -ForegroundColor DarkGray
}

# =============================================================================
# FINALIZATION: Cleanup Startup Registration
# =============================================================================
Write-Host ""
Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Green
Write-Host "  FINALIZING HYDRATION" -ForegroundColor Green
Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Green

# Unregister from RunOnce so it does not launch on next reboot
Remove-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "ReglazeHydrate" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "ReglazeHydrate" -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "================================================================================" -ForegroundColor Green
Write-Host "    REGLAZE HYDRATION COMPLETE! YOUR WORKSTATION IS FULLY PROVISIONED.          " -ForegroundColor Green
Write-Host "================================================================================" -ForegroundColor Green
Write-Host "Note: You can re-run this wizard anytime via the 'Reglaze Hydration' desktop shortcut."
Write-Host ""
try { Stop-Transcript | Out-Null } catch {}
"@

    $HydratePath = Join-Path $PayloadDir "hydrate.ps1"
    $HydrateScript | Set-Content -Path $HydratePath -Encoding UTF8

    # =========================================================================
    # 3. Generate Non-Interactive WSL2 Setup Script: setup-wsl.sh
    # =========================================================================
    $WslDefaultUser = if ($Blueprint.wsl2 -and $Blueprint.wsl2.default_user -and $Blueprint.wsl2.default_user -ne "developer") {
        $Blueprint.wsl2.default_user
    } else {
        $PrimaryUser.ToLower()
    }
    $WslPackages = @()
    if ($Blueprint.wsl2 -and $Blueprint.wsl2.packages) {
        $WslPackages = @($Blueprint.wsl2.packages)
    }
    if ($WslPackages.Count -eq 0) {
        $WslPackages = @("build-essential", "git", "curl", "zsh", "rclone", "unzip")
    }
    $WslPackagesStr = $WslPackages -join " "

    $WslScript = @"
#!/usr/bin/env bash
# Non-interactive WSL2 root setup script for Reglaze
set -e

WSL_USER="$WslDefaultUser"
PACKAGES="$WslPackagesStr"

echo "=== Reglaze WSL2 Non-Interactive Provisioner ==="
echo "Configuring primary user: `$WSL_USER"

# 1. Create default user if not already present
if ! id -u "`$WSL_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "`$WSL_USER"
    echo "`$WSL_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/99-`$WSL_USER"
    chmod 0440 "/etc/sudoers.d/99-`$WSL_USER"
    echo "Created user `$WSL_USER with passwordless sudo."
fi

# 2. Configure /etc/wsl.conf to boot into default user
cat << 'EOF' > /etc/wsl.conf
[user]
default = $WslDefaultUser

[boot]
systemd = true

[interop]
enabled = true
appendWindowsPath = true
EOF

# 3. Update repositories and install declared packages
echo "Installing WSL2 packages: `$PACKAGES"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends `$PACKAGES || true

echo "=== WSL2 Provisioning Completed Successfully ==="
"@

    $WslPath = Join-Path $PayloadDir "setup-wsl.sh"
    # Ensure UNIX-style LF line endings
    $WslScript = $WslScript.Replace("`r`n", "`n")
    [System.IO.File]::WriteAllText($WslPath, $WslScript, [System.Text.UTF8Encoding]::new($false))

    return [PSCustomObject]@{
        HydratePath        = $HydratePath
        HydrateHelpersPath = $HydrateHelpersPath
        WslScriptPath      = $WslPath
    }
}

