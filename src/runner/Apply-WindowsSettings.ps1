<#
.SYNOPSIS
    Applies modular Windows system settings, personalization, input, audio/display, shell pins,
    and network/firewall configurations for Reglaze.
.DESCRIPTION
    Executes scripts from data/windows/ (Explorer folder options, Taskbar/tray/clock,
    Power & developer ergonomics, Theme/wallpaper, Mouse/keyboard input, Audio/camera/display,
    Network/sharing/firewall, and declarative Shell pins/PATH/Steam libraries).
#>
[CmdletBinding()]
param()

# =============================================================================
# [HITL-ID]: HITL-M3-03
# [HITL-TARGET]: Windows Preferences / Explorer, Taskbar, Theme, Input, Audio, Network & Power Registry Settings
# [HITL-STATUS]: VERIFIED
# [HITL-DESCRIPTION]: Modular PowerShell scripts in data/windows/ modifying Explorer folder options, Taskbar, Theme, Input, Audio, Network, and Power schemes.
# [HITL-TEST-SNIPPET]:
#   # Non-destructive audit snippet to run manually:
#   Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" | Select-Object TaskbarAl, HideFileExt, Hidden
# [HITL-LAST-INPUT]: Read-only query of Explorer Advanced & powercfg on physical host (2026-10-21)
# [HITL-LAST-RESULT]: TaskbarAl=1 (Center verified), HideFileExt=0, Hidden=1, active power scheme High Performance.
# [HITL-PATTERN]: Registry reads and powercfg queries execute unprivileged; live writes require -Live flag.
# [HITL-AVOID]: Mutating host HKCU/HKLM registry or power schemes outside VM or simulation
# =============================================================================

function Invoke-WindowsSettingsApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$RepoRoot = $null,

        [Parameter(Mandatory=$false)]
        [PSCustomObject]$Settings = $null,

        [Parameter(Mandatory=$false)]
        [string]$SettingsFile = $null,

        [ValidateSet("All", "Phase4", "Phase5")]
        [string]$Phase = "All",

        [switch]$Simulation = $true,
        [switch]$Live = $false
    )

    # Fail-safe: Always simulated unless explicitly flagged -Live
    $IsSimulated = $Simulation -or (-not $Live)

    if (-not $RepoRoot) {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }

    $WindowsSettingsDir = Join-Path $RepoRoot "data\windows"
    if (-not (Test-Path -LiteralPath $WindowsSettingsDir)) {
        $CandidateWindows = Join-Path $RepoRoot "windows"
        if (Test-Path -LiteralPath $CandidateWindows) {
            $WindowsSettingsDir = $CandidateWindows
        }
    }

    $Results = [System.Collections.Generic.List[PSCustomObject]]::new()

    if (-not (Test-Path -LiteralPath $WindowsSettingsDir)) {
        return $Results
    }

    # Resolve Settings if not provided
    if (-not $Settings) {
        $CandidateSettingsFiles = @(
            $SettingsFile,
            (Join-Path $RepoRoot "windows-settings.json"),
            (Join-Path $RepoRoot "payload\windows-settings.json"),
            "C:\Reglaze\payload\windows-settings.json"
        )
        foreach ($Candidate in $CandidateSettingsFiles) {
            if ($Candidate -and (Test-Path -LiteralPath $Candidate)) {
                try {
                    $Settings = Get-Content -Raw -LiteralPath $Candidate -Encoding UTF8 | ConvertFrom-Json
                    break
                } catch {}
            }
        }
    }

    # Scope mapping:
    # - Phase4 (Machine Scope / LocalAdmin): Power plan & timeouts, LongPathsEnabled (HKLM), ssh-agent service,
    #   camera disabling (PnP), Hardware GPU Scheduling (HKLM), Network/Firewall/hosts, and Start Menu pins policy (HKLM).
    # - Phase5 (User Scope / primary_user): Explorer options & User Shell Folders (HKCU), Taskbar/Tray/Clock (HKCU),
    #   Clipboard History & Default Terminal (HKCU), Theme/Accent/Wallpaper (HKCU), Mouse/Keyboard/Input languages (HKCU),
    #   CoreAudio endpoints/volume, Game Mode (HKCU), Multi-Monitor layout, and Quick Access/Taskbar pins + User PATH + Steam libraries.
    $Scripts = @(
        @{ Name = "ExplorerFolderOptions"; File = "explorer-folder-options.ps1"; Phase = "Phase5"; Phases = @("Phase5") },
        @{ Name = "TaskbarSystemTray";     File = "taskbar-system-tray.ps1";     Phase = "Phase5"; Phases = @("Phase5") },
        @{ Name = "PerformancePower";      File = "performance-power.ps1";      Phase = "Phase4"; Phases = @("Phase4", "Phase5") },
        @{ Name = "ThemePersonalization";  File = "theme-personalization.ps1";  Phase = "Phase5"; Phases = @("Phase5") },
        @{ Name = "InputMouseKeyboard";    File = "input-mouse-keyboard.ps1";    Phase = "Phase5"; Phases = @("Phase5") },
        @{ Name = "AudioDisplay";          File = "audio-display.ps1";          Phase = "Phase4"; Phases = @("Phase4", "Phase5") },
        @{ Name = "NetworkFirewall";       File = "network-firewall.ps1";       Phase = "Phase4"; Phases = @("Phase4") },
        @{ Name = "ShellPins";             File = "shell-pins.ps1";             Phase = "Phase5"; Phases = @("Phase4", "Phase5") }
    )

    foreach ($Item in $Scripts) {
        if ($Phase -ne "All" -and ($Item.Phases -notcontains $Phase)) {
            continue
        }

        $ScriptPath = Join-Path $WindowsSettingsDir $Item.File
        $Entry = [PSCustomObject]@{
            SettingName = $Item.Name
            ScriptPath  = $ScriptPath
            Status      = "Pending"
            Message     = ""
        }

        if (Test-Path -LiteralPath $ScriptPath) {
            if ($IsSimulated) {
                $Entry.Status = "Simulated"
                $Entry.Message = "Simulated application of $($Item.File)"
            } else {
                try {
                    $ScriptArgs = @{}
                    if ($Item.Name -eq "ExplorerFolderOptions" -and $Settings) {
                        if ($Settings.explorer) {
                            if ($null -ne $Settings.explorer.show_hidden_files) {
                                $ScriptArgs["ShowHiddenFiles"] = [bool]$Settings.explorer.show_hidden_files
                            }
                            if ($null -ne $Settings.explorer.show_file_extensions) {
                                $ScriptArgs["ShowFileExtensions"] = [bool]$Settings.explorer.show_file_extensions
                            }
                            if ($Settings.explorer.launch_to) {
                                $ScriptArgs["LaunchTo"] = [string]$Settings.explorer.launch_to
                            }
                            if ($null -ne $Settings.explorer.hide_recent_in_quick_access) {
                                $ScriptArgs["HideRecentFromQuickAccess"] = [bool]$Settings.explorer.hide_recent_in_quick_access
                            }
                            if ($null -ne $Settings.explorer.classic_context_menu) {
                                $ScriptArgs["ClassicContextMenu"] = [bool]$Settings.explorer.classic_context_menu
                            }
                        }
                        if ($Settings.network -and $null -ne $Settings.network.sharing_wizard_enabled) {
                            $ScriptArgs["SharingWizardEnabled"] = [bool]$Settings.network.sharing_wizard_enabled
                        }
                        if ($Settings.user_shell_folders -and $Phase -ne "Phase4" -and $env:USERNAME -notmatch '^LocalAdmin$') {
                            $ScriptArgs["UserShellFolders"] = $Settings.user_shell_folders
                        }
                    } elseif ($Item.Name -eq "TaskbarSystemTray" -and $Settings) {
                        if ($Settings.taskbar) {
                            if ($Settings.taskbar.alignment) {
                                $ScriptArgs["TaskbarAlignment"] = [string]$Settings.taskbar.alignment
                            }
                            if ($Settings.taskbar.search_mode) {
                                $ScriptArgs["SearchMode"] = [string]$Settings.taskbar.search_mode
                            }
                            if ($null -ne $Settings.taskbar.widgets_visible) {
                                $ScriptArgs["HideWidgets"] = (-not [bool]$Settings.taskbar.widgets_visible)
                            }
                            if ($null -ne $Settings.taskbar.chat_visible) {
                                $ScriptArgs["HideChat"] = (-not [bool]$Settings.taskbar.chat_visible)
                            }
                            if ($null -ne $Settings.taskbar.show_seconds_in_clock) {
                                $ScriptArgs["ShowSecondsInClock"] = [bool]$Settings.taskbar.show_seconds_in_clock
                            }
                            if ($null -ne $Settings.taskbar.end_task_enabled) {
                                $ScriptArgs["EndTaskEnabled"] = [bool]$Settings.taskbar.end_task_enabled
                            }
                            if ($Settings.taskbar.promoted_tray_icons) {
                                $ScriptArgs["PromotedTrayIcons"] = @($Settings.taskbar.promoted_tray_icons)
                            }
                        }
                        if ($Settings.clock_and_region) {
                            if ($Settings.clock_and_region.short_time_format) {
                                $ScriptArgs["ShortTimeFormat"] = [string]$Settings.clock_and_region.short_time_format
                            }
                            if ($Settings.clock_and_region.long_time_format) {
                                $ScriptArgs["LongTimeFormat"] = [string]$Settings.clock_and_region.long_time_format
                            }
                            if ($Settings.clock_and_region.short_date_format) {
                                $ScriptArgs["ShortDateFormat"] = [string]$Settings.clock_and_region.short_date_format
                            }
                            if ($null -ne $Settings.clock_and_region.use_24_hour_clock) {
                                $ScriptArgs["Use24HourClock"] = [bool]$Settings.clock_and_region.use_24_hour_clock
                            }
                        }
                    } elseif ($Item.Name -eq "PerformancePower" -and $Settings) {
                        $ScriptArgs["Scope"] = if ($Phase -eq "Phase4") { "Machine" } elseif ($Phase -eq "Phase5") { "User" } else { "All" }
                        if ($Settings.power) {
                            if ($Settings.power.active_scheme_name) {
                                $Plan = ($Settings.power.active_scheme_name -replace '\s+', '')
                                if ($Plan -in @("HighPerformance", "Balanced", "UltimatePerformance")) {
                                    $ScriptArgs["PowerPlan"] = $Plan
                                }
                            }
                            if ($null -ne $Settings.power.ac_sleep_minutes) {
                                $ScriptArgs["AcSleepTimeoutMinutes"] = [int]$Settings.power.ac_sleep_minutes
                            }
                            if ($null -ne $Settings.power.ac_display_minutes) {
                                $ScriptArgs["AcDisplayTimeoutMinutes"] = [int]$Settings.power.ac_display_minutes
                            }
                        }
                        if ($Settings.system_ergonomics) {
                            if ($null -ne $Settings.system_ergonomics.clipboard_history_enabled) {
                                $ScriptArgs["ClipboardHistoryEnabled"] = [bool]$Settings.system_ergonomics.clipboard_history_enabled
                            }
                            if ($null -ne $Settings.system_ergonomics.long_paths_enabled) {
                                $ScriptArgs["LongPathsEnabled"] = [bool]$Settings.system_ergonomics.long_paths_enabled
                            }
                            if ($Settings.system_ergonomics.ssh_agent_startup) {
                                $ScriptArgs["SshAgentStartup"] = [string]$Settings.system_ergonomics.ssh_agent_startup
                            }
                            if ($Settings.system_ergonomics.default_terminal) {
                                $ScriptArgs["DefaultTerminal"] = [string]$Settings.system_ergonomics.default_terminal
                            }
                        }
                    } elseif ($Item.Name -eq "ThemePersonalization" -and $Settings -and $Settings.theme) {
                        if ($Settings.theme.apps_mode) { $ScriptArgs["AppsMode"] = [string]$Settings.theme.apps_mode }
                        if ($Settings.theme.system_mode) { $ScriptArgs["SystemMode"] = [string]$Settings.theme.system_mode }
                        if ($null -ne $Settings.theme.transparency) { $ScriptArgs["Transparency"] = [bool]$Settings.theme.transparency }
                        if ($Settings.theme.accent_color) { $ScriptArgs["AccentColor"] = [string]$Settings.theme.accent_color }
                        if ($null -ne $Settings.theme.accent_on_taskbar) { $ScriptArgs["AccentOnTaskbar"] = [bool]$Settings.theme.accent_on_taskbar }
                        if ($null -ne $Settings.theme.accent_on_titlebars) { $ScriptArgs["AccentOnTitlebars"] = [bool]$Settings.theme.accent_on_titlebars }
                        if ($Settings.theme.wallpaper_path) { $ScriptArgs["WallpaperPath"] = [string]$Settings.theme.wallpaper_path }
                        if ($null -ne $Settings.theme.wallpaper_style) { $ScriptArgs["WallpaperStyle"] = [int]$Settings.theme.wallpaper_style }
                    } elseif ($Item.Name -eq "InputMouseKeyboard" -and $Settings -and $Settings.input) {
                        if ($Settings.input.mouse) {
                            if ($null -ne $Settings.input.mouse.speed) { $ScriptArgs["MouseSpeed"] = [int]$Settings.input.mouse.speed }
                            if ($null -ne $Settings.input.mouse.enhance_pointer_precision) { $ScriptArgs["EnhancePointerPrecision"] = [bool]$Settings.input.mouse.enhance_pointer_precision }
                            if ($null -ne $Settings.input.mouse.swap_buttons) { $ScriptArgs["SwapMouseButtons"] = [bool]$Settings.input.mouse.swap_buttons }
                            if ($null -ne $Settings.input.mouse.wheel_scroll_lines) { $ScriptArgs["WheelScrollLines"] = [int]$Settings.input.mouse.wheel_scroll_lines }
                        }
                        if ($Settings.input.keyboard) {
                            if ($null -ne $Settings.input.keyboard.repeat_delay) { $ScriptArgs["KeyboardRepeatDelay"] = [int]$Settings.input.keyboard.repeat_delay }
                            if ($null -ne $Settings.input.keyboard.repeat_speed) { $ScriptArgs["KeyboardRepeatSpeed"] = [int]$Settings.input.keyboard.repeat_speed }
                            if ($null -ne $Settings.input.keyboard.numlock_on_startup) { $ScriptArgs["NumLockOnStartup"] = [bool]$Settings.input.keyboard.numlock_on_startup }
                            if ($Settings.input.keyboard.input_languages) { $ScriptArgs["InputLanguages"] = @($Settings.input.keyboard.input_languages) }
                        }
                    } elseif ($Item.Name -eq "AudioDisplay" -and $Settings) {
                        $ScriptArgs["Scope"] = if ($Phase -eq "Phase4") { "Machine" } elseif ($Phase -eq "Phase5") { "User" } else { "All" }
                        if ($Settings.audio_and_devices) {
                            if ($Settings.audio_and_devices.default_speakers) { $ScriptArgs["DefaultSpeakers"] = [string]$Settings.audio_and_devices.default_speakers }
                            if ($Settings.audio_and_devices.default_microphone) { $ScriptArgs["DefaultMicrophone"] = [string]$Settings.audio_and_devices.default_microphone }
                            if ($Settings.audio_and_devices.default_camera) { $ScriptArgs["DefaultCamera"] = [string]$Settings.audio_and_devices.default_camera }
                            if ($Settings.audio_and_devices.disabled_cameras) { $ScriptArgs["DisabledCameras"] = @($Settings.audio_and_devices.disabled_cameras) }
                            if ($null -ne $Settings.audio_and_devices.master_volume_percent) { $ScriptArgs["MasterVolumePercent"] = [int]$Settings.audio_and_devices.master_volume_percent }
                            if ($null -ne $Settings.audio_and_devices.master_muted) { $ScriptArgs["MasterMuted"] = [bool]$Settings.audio_and_devices.master_muted }
                        }
                        if ($Settings.display) {
                            if ($null -ne $Settings.display.game_mode_enabled) { $ScriptArgs["GameModeEnabled"] = [bool]$Settings.display.game_mode_enabled }
                            if ($null -ne $Settings.display.hardware_gpu_scheduling) { $ScriptArgs["HardwareGpuScheduling"] = [bool]$Settings.display.hardware_gpu_scheduling }
                            if ($Settings.display.monitors) { $ScriptArgs["Monitors"] = @($Settings.display.monitors) }
                        }
                    } elseif ($Item.Name -eq "NetworkFirewall" -and $Settings -and $Settings.network) {
                        $Net = $Settings.network
                        if ($null -ne $Net.sharing_wizard_enabled) { $ScriptArgs["SharingWizardEnabled"] = [bool]$Net.sharing_wizard_enabled }
                        if ($Net.network_category) { $ScriptArgs["NetworkCategory"] = [string]$Net.network_category }
                        if ($null -ne $Net.network_discovery_enabled) { $ScriptArgs["NetworkDiscoveryEnabled"] = [bool]$Net.network_discovery_enabled }
                        if ($null -ne $Net.file_and_printer_sharing_enabled) { $ScriptArgs["FileAndPrinterSharingEnabled"] = [bool]$Net.file_and_printer_sharing_enabled }
                        if ($null -ne $Net.password_protected_sharing) { $ScriptArgs["PasswordProtectedSharing"] = [bool]$Net.password_protected_sharing }
                        if ($Net.adapters) { $ScriptArgs["Adapters"] = @($Net.adapters) }
                        if ($Net.hosts_entries) { $ScriptArgs["HostsEntries"] = @($Net.hosts_entries) }
                        if ($Net.firewall_rules) { $ScriptArgs["FirewallRules"] = @($Net.firewall_rules) }
                    } elseif ($Item.Name -eq "ShellPins" -and $Settings) {
                        if ($Phase -in @("All", "Phase5")) {
                            if ($Settings.explorer -and $Settings.explorer.quick_access_pins) {
                                $ScriptArgs["QuickAccessPins"] = @($Settings.explorer.quick_access_pins)
                            }
                            if ($Settings.taskbar -and $Settings.taskbar.pinned_apps) {
                                $ScriptArgs["TaskbarPinnedApps"] = @($Settings.taskbar.pinned_apps)
                            }
                            if ($Settings.app_path_entries) {
                                $ScriptArgs["AppPathEntries"] = @($Settings.app_path_entries)
                            }
                            if ($Settings.steam_libraries) {
                                $ScriptArgs["SteamLibraries"] = @($Settings.steam_libraries)
                            }
                        }
                        if ($Phase -in @("All", "Phase4")) {
                            if ($Settings.start_menu -and $Settings.start_menu.pinned_apps) {
                                $ScriptArgs["StartMenuPinnedApps"] = @($Settings.start_menu.pinned_apps)
                            }
                        }
                    }

                    & $ScriptPath @ScriptArgs
                    $Entry.Status = "Applied"
                    $Entry.Message = "Successfully executed $($Item.File)"
                } catch {
                    $Entry.Status = "Failed"
                    $Entry.Message = $_.Exception.Message
                }
            }
        } else {
            $Entry.Status = "NotFound"
            $Entry.Message = "Script not found at $ScriptPath"
        }

        $Results.Add($Entry)
    }

    return $Results
}
