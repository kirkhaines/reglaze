<#
.SYNOPSIS
    Audits current Windows Explorer, Taskbar, Start Menu, Theme, Clock, Input (Mouse/Keyboard),
    Power, Audio/Camera Endpoints, Multi-Monitor Layout, and Developer/Shell Ergonomics.
.DESCRIPTION
    Performs strictly read-only inspection of registry hives, Shell COM namespaces,
    CoreAudio endpoints, Display CCD/CimInstance, and PnP devices to populate
    audit-reference.json and scaffold windows_settings in reglaze.yaml.
#>
[CmdletBinding()]
param()

$Settings = @{
    explorer = @{
        show_hidden_files           = $false
        show_file_extensions        = $false
        launch_to                   = "QuickAccess"
        hide_recent_in_quick_access = $false
        classic_context_menu        = $false
        quick_access_pins           = @()
    }
    taskbar = @{
        alignment             = "Center"
        search_mode           = "Box"
        widgets_visible       = $true
        chat_visible          = $true
        show_seconds_in_clock = $false
        end_task_enabled      = $false
        pinned_apps           = @()
        promoted_tray_icons   = @()
    }
    start_menu = @{
        pinned_apps = @()
    }
    theme = @{
        apps_mode           = "Dark"
        system_mode         = "Dark"
        transparency        = $true
        accent_color        = $null
        accent_on_taskbar   = $false
        accent_on_titlebars = $false
        wallpaper_path      = $null
        wallpaper_style     = 10
    }
    clock_and_region = @{
        short_time_format = "h:mm tt"
        long_time_format  = "h:mm:ss tt"
        short_date_format = "M/d/yyyy"
        use_24_hour_clock = $false
    }
    input = @{
        mouse = @{
            speed                     = 10
            enhance_pointer_precision = $true
            swap_buttons              = $false
            wheel_scroll_lines        = 3
        }
        keyboard = @{
            repeat_delay       = 1
            repeat_speed       = 31
            numlock_on_startup = $true
            input_languages    = @("en-US")
        }
    }
    power = @{
        active_scheme_name = "Balanced"
        ac_sleep_minutes   = 30
        ac_display_minutes = 15
    }
    audio_and_devices = @{
        default_speakers      = $null
        default_microphone    = $null
        default_camera        = $null
        disabled_cameras      = @()
        master_volume_percent = 50
        master_muted          = $false
    }
    display = @{
        game_mode_enabled       = $true
        hardware_gpu_scheduling = $true
        monitors                = @()
    }
    system_ergonomics = @{
        clipboard_history_enabled = $false
        long_paths_enabled        = $false
        ssh_agent_startup         = "Disabled"
        ssh_keys_unmapped_warning = $false
        default_browser_prog_id   = $null
        default_terminal          = "Conhost"
    }
}

# 1. Explorer & Taskbar Registry Settings
try {
    $Adv = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -ErrorAction SilentlyContinue
    if ($Adv) {
        $Settings.explorer.show_hidden_files = ($Adv.Hidden -eq 1)
        $Settings.explorer.show_file_extensions = ($Adv.HideFileExt -eq 0)
        $Settings.explorer.launch_to = if ($Adv.LaunchTo -eq 1) { "ThisPC" } else { "QuickAccess" }
        $Settings.explorer.hide_recent_in_quick_access = ($Adv.ShowRecent -eq 0 -or $Adv.Start_TrackDocs -eq 0)

        $Settings.taskbar.alignment = if ($Adv.TaskbarAl -eq 0) { "Left" } else { "Center" }
        if ($null -ne $Adv.TaskbarDa) {
            $Settings.taskbar.widgets_visible = ($Adv.TaskbarDa -ne 0)
        }
        if ($null -ne $Adv.TaskbarMn) {
            $Settings.taskbar.chat_visible = ($Adv.TaskbarMn -ne 0)
        }
        if ($null -ne $Adv.ShowSecondsInSystemClock) {
            $Settings.taskbar.show_seconds_in_clock = ($Adv.ShowSecondsInSystemClock -eq 1)
        }
    }

    $DevSettings = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings" -ErrorAction SilentlyContinue
    if ($DevSettings -and $null -ne $DevSettings.TaskbarEndTask) {
        $Settings.taskbar.end_task_enabled = ($DevSettings.TaskbarEndTask -eq 1)
    }

    $ClassicCtxKey = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
    $Settings.explorer.classic_context_menu = (Test-Path -LiteralPath $ClassicCtxKey)

    $Search = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" -ErrorAction SilentlyContinue
    if ($Search -and $null -ne $Search.SearchboxTaskbarMode) {
        $Settings.taskbar.search_mode = switch ($Search.SearchboxTaskbarMode) {
            0 { "Hidden" }
            1 { "IconOnly" }
            default { "Box" }
        }
    }
} catch {}

# 2. Quick Access Pinned Folders, Taskbar Pinned Apps & Start Menu Pinned Apps
$ShellApp = $null
try {
    $ShellApp = New-Object -ComObject Shell.Application -ErrorAction SilentlyContinue
} catch {}

try {
    if ($ShellApp) {
        # Build set of the 6 default Windows user folders (both %USERPROFILE%\<Folder> and relocated User Shell Folders)
        $DefaultQaFolders = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($SubName in @("Desktop", "Downloads", "Documents", "Pictures", "Music", "Videos")) {
            if ($env:USERPROFILE) {
                [void]$DefaultQaFolders.Add((Join-Path $env:USERPROFILE $SubName).TrimEnd('\'))
            }
        }
        $UsfReg = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction SilentlyContinue
        if ($UsfReg) {
            foreach ($UsfProp in @("Desktop", "Personal", "{374DE290-123F-4565-9164-39C4925E467B}", "My Pictures", "My Music", "My Video")) {
                $RawUsf = $UsfReg.$UsfProp
                if (-not [string]::IsNullOrWhiteSpace($RawUsf)) {
                    $ExpUsf = [Environment]::ExpandEnvironmentVariables($RawUsf).TrimEnd('\')
                    [void]$DefaultQaFolders.Add($ExpUsf)
                }
            }
        }

        $QaNamespace = $ShellApp.Namespace("shell:::{679f85cb-0220-4080-b29b-5540cc05aab6}")
        if ($QaNamespace) {
            $QaPins = [System.Collections.Generic.List[string]]::new()
            $SeenQa = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($Item in $QaNamespace.Items()) {
                try {
                    if ($Item.IsFolder -and $Item.Path -and (Test-Path -LiteralPath $Item.Path -ErrorAction SilentlyContinue)) {
                        $NormQa = $Item.Path.TrimEnd('\')
                        if (-not $DefaultQaFolders.Contains($NormQa) -and $SeenQa.Add($NormQa)) {
                            $QaPins.Add($Item.Path)
                        }
                    }
                } catch {}
            }
            $Settings.explorer.quick_access_pins = $QaPins.ToArray()
        }
    }
} catch {}

try {
    $UserPinnedRoot = Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned"
    $TaskbarPinDir = Join-Path $UserPinnedRoot "TaskBar"
    $ImplicitPinDir = Join-Path $UserPinnedRoot "ImplicitAppShortcuts"

    $LnkFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    if (Test-Path -LiteralPath $TaskbarPinDir) {
        foreach ($F in (Get-ChildItem -LiteralPath $TaskbarPinDir -Filter "*.lnk" -File -Force -ErrorAction SilentlyContinue)) {
            $LnkFiles.Add($F)
        }
    }
    if (Test-Path -LiteralPath $ImplicitPinDir) {
        foreach ($F in (Get-ChildItem -LiteralPath $ImplicitPinDir -Filter "*.lnk" -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            $LnkFiles.Add($F)
        }
    }

    if ($LnkFiles.Count -gt 0) {
        $WshShell = New-Object -ComObject WScript.Shell -ErrorAction SilentlyContinue
        $PinnedTargets = [System.Collections.Generic.List[string]]::new()
        $SeenPinned = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($Lnk in $LnkFiles) {
            $ResolvedTarget = $null

            # Method 1: WScript.Shell CreateShortcut
            if ($WshShell) {
                try {
                    $Sc = $WshShell.CreateShortcut($Lnk.FullName)
                    if ($Sc -and -not [string]::IsNullOrWhiteSpace($Sc.TargetPath)) {
                        $ResolvedTarget = $Sc.TargetPath.Trim()
                    }
                } catch {}
            }

            # Method 2: Shell.Application ShellLinkObject fallback
            if ([string]::IsNullOrWhiteSpace($ResolvedTarget) -and $ShellApp) {
                try {
                    $DirNs = $ShellApp.Namespace($Lnk.DirectoryName)
                    if ($DirNs) {
                        $FolderItem = $DirNs.ParseName($Lnk.Name)
                        if ($FolderItem -and $FolderItem.IsLink) {
                            $ShellLink = $FolderItem.GetLink
                            if ($ShellLink -and -not [string]::IsNullOrWhiteSpace($ShellLink.Path) -and $ShellLink.Path -notmatch '^::\{') {
                                $ResolvedTarget = $ShellLink.Path.Trim()
                            }
                        }
                    }
                } catch {}
            }

            # Method 3: Raw .lnk binary executable path extraction (for custom AppUserModelID/MSI shortcuts like Steam)
            if ([string]::IsNullOrWhiteSpace($ResolvedTarget)) {
                try {
                    $Bytes = [System.IO.File]::ReadAllBytes($Lnk.FullName)
                    $AsciiText = [System.Text.Encoding]::ASCII.GetString($Bytes)
                    $UnicodeText = [System.Text.Encoding]::Unicode.GetString($Bytes)
                    foreach ($CandidateText in @($UnicodeText, $AsciiText)) {
                        $MatchesExe = [regex]::Matches($CandidateText, '[A-Za-z]:\\[^\x00-\x1F"<>|?*]+?\.exe')
                        foreach ($M in $MatchesExe) {
                            if (Test-Path -LiteralPath $M.Value -ErrorAction SilentlyContinue) {
                                $ResolvedTarget = $M.Value
                                break
                            }
                        }
                        if (-not [string]::IsNullOrWhiteSpace($ResolvedTarget)) { break }
                    }
                } catch {}
            }

            # Method 4: BaseName fallback
            if ([string]::IsNullOrWhiteSpace($ResolvedTarget)) {
                $ResolvedTarget = $Lnk.BaseName
            }

            if (-not [string]::IsNullOrWhiteSpace($ResolvedTarget) -and $SeenPinned.Add($ResolvedTarget)) {
                $PinnedTargets.Add($ResolvedTarget)
            }
        }
        $Settings.taskbar.pinned_apps = $PinnedTargets.ToArray()
    }
} catch {}

try {
    # Promoted System Tray Icons (Windows 11 22H2+ NotifyIconSettings)
    $NotifyRoot = "HKCU:\Control Panel\NotifyIconSettings"
    if (Test-Path -LiteralPath $NotifyRoot) {
        $PromotedList = [System.Collections.Generic.List[string]]::new()
        foreach ($SubKey in (Get-ChildItem -LiteralPath $NotifyRoot -ErrorAction SilentlyContinue)) {
            $Props = Get-ItemProperty -LiteralPath $SubKey.PSPath -ErrorAction SilentlyContinue
            if ($Props -and $Props.IsPromoted -eq 1 -and $Props.ExecutablePath) {
                $ExeLeaf = Split-Path -Leaf $Props.ExecutablePath
                if ($ExeLeaf -and -not $PromotedList.Contains($ExeLeaf)) {
                    $PromotedList.Add($ExeLeaf)
                }
            }
        }
        $Settings.taskbar.promoted_tray_icons = $PromotedList.ToArray()
    }
} catch {}

try {
    # Start Menu Pins via Export-StartLayout (read-only export to temp file), filtering out default Windows 11 inbox pins
    $IsDefaultStartPin = {
        param([string]$PinVal)
        if ([string]::IsNullOrWhiteSpace($PinVal)) { return $true }
        $Trimmed = $PinVal.Trim()

        # Default Windows 11 packagedAppId / AUMID inbox pins
        if ($Trimmed -match '^(Microsoft\.WindowsStore|windows\.immersivecontrolpanel|Microsoft\.Windows\.Photos|Microsoft\.GamingApp|Microsoft\.XboxGamingOverlay|Microsoft\.XboxApp|Microsoft\.MicrosoftSolitaireCollection|Microsoft\.Paint|7EE7776C\.LinkedInforWindows|Microsoft\.WindowsCalculator|Microsoft\.WindowsAlarms|Microsoft\.WindowsNotepad|Microsoft\.ScreenSketch|Microsoft\.OutlookforWindows|Microsoft\.Todos|Clipchamp\.Clipchamp|Microsoft\.BingNews|Microsoft\.BingWeather|Microsoft\.YourPhone|Microsoft\.GetHelp|Microsoft\.WindowsFeedbackHub|Microsoft\.WindowsSoundRecorder|Microsoft\.WindowsCamera|Microsoft\.ZuneMusic|Microsoft\.ZuneVideo|Microsoft\.PowerAutomateDesktop|Microsoft\.MicrosoftStickyNotes|Microsoft\.MicrosoftOfficeHub|Microsoft\.Copilot|Microsoft\.365Copilot|MicrosoftCorporationII\.QuickAssist|Microsoft\.WindowsTerminal|Microsoft\.WindowsMaps|Microsoft\.People|Microsoft\.WindowsCommunicationsApps)_') {
            return $true
        }

        # Default Windows 11 desktopAppLink / desktopAppId inbox pins (Microsoft Edge, File Explorer)
        $Leaf = Split-Path -Leaf $Trimmed -ErrorAction SilentlyContinue
        if ($Leaf -match '^(Microsoft Edge\.lnk|File Explorer\.lnk|Windows Explorer\.lnk)$') {
            return $true
        }
        if ($Trimmed -match '^(MSEdge|Microsoft\.Windows\.Explorer|Microsoft\.AutoGenerated\.)') {
            return $true
        }

        return $false
    }

    if (Get-Command "Export-StartLayout" -ErrorAction SilentlyContinue) {
        $TempStartJson = Join-Path $env:TEMP "reglaze_startlayout_$((Get-Random)).json"
        Export-StartLayout -Path $TempStartJson -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $TempStartJson) {
            $StartObj = Get-Content -Raw -LiteralPath $TempStartJson -ErrorAction SilentlyContinue | ConvertFrom-Json
            Remove-Item -LiteralPath $TempStartJson -Force -ErrorAction SilentlyContinue
            if ($StartObj -and $StartObj.pinnedList) {
                $StartPins = [System.Collections.Generic.List[string]]::new()
                foreach ($Pin in $StartObj.pinnedList) {
                    $CandidatePin = $null
                    if ($Pin.desktopAppLink) {
                        $CandidatePin = [Environment]::ExpandEnvironmentVariables($Pin.desktopAppLink)
                    } elseif ($Pin.desktopAppId) {
                        $CandidatePin = $Pin.desktopAppId
                    } elseif ($Pin.packagedAppId) {
                        $CandidatePin = $Pin.packagedAppId
                    }
                    if ($CandidatePin -and -not (& $IsDefaultStartPin $CandidatePin)) {
                        $StartPins.Add($CandidatePin)
                    }
                }
                $Settings.start_menu.pinned_apps = $StartPins.ToArray()
            }
        }
    }
} catch {}

# 3. Theme, Personalization & Wallpaper
try {
    $Pers = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -ErrorAction SilentlyContinue
    if ($Pers) {
        $Settings.theme.apps_mode = if ($Pers.AppsUseLightTheme -eq 1) { "Light" } else { "Dark" }
        $Settings.theme.system_mode = if ($Pers.SystemUsesLightTheme -eq 1) { "Light" } else { "Dark" }
        if ($null -ne $Pers.EnableTransparency) {
            $Settings.theme.transparency = ($Pers.EnableTransparency -ne 0)
        }
        if ($null -ne $Pers.ColorPrevalence) {
            $Settings.theme.accent_on_taskbar = ($Pers.ColorPrevalence -eq 1)
        }
    }

    $Dwm = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\DWM" -ErrorAction SilentlyContinue
    if ($Dwm) {
        if ($null -ne $Dwm.AccentColor) {
            $Settings.theme.accent_color = ("0x{0:X8}" -f ([uint32]$Dwm.AccentColor))
        }
        if ($null -ne $Dwm.ColorPrevalence) {
            $Settings.theme.accent_on_titlebars = ($Dwm.ColorPrevalence -eq 1)
        }
    }

    $Desk = Get-ItemProperty -Path "HKCU:\Control Panel\Desktop" -ErrorAction SilentlyContinue
    if ($Desk) {
        if (-not [string]::IsNullOrWhiteSpace($Desk.WallPaper)) {
            $Settings.theme.wallpaper_path = $Desk.WallPaper
        }
        if ($Desk.WallpaperStyle -match '^\d+$') {
            $Settings.theme.wallpaper_style = [int]$Desk.WallpaperStyle
        }
    }
} catch {}

# 4. Clock & Regional Formats
try {
    $Intl = Get-ItemProperty -Path "HKCU:\Control Panel\International" -ErrorAction SilentlyContinue
    if ($Intl) {
        if ($Intl.sShortTime) { $Settings.clock_and_region.short_time_format = $Intl.sShortTime }
        if ($Intl.sTimeFormat) { $Settings.clock_and_region.long_time_format = $Intl.sTimeFormat }
        if ($Intl.sShortDate) { $Settings.clock_and_region.short_date_format = $Intl.sShortDate }
        $Settings.clock_and_region.use_24_hour_clock = ($Intl.iTime -eq "1" -or $Intl.sShortTime -cmatch "H")
    }
} catch {}

# 5. Mouse & Keyboard Input
try {
    $MouseReg = Get-ItemProperty -Path "HKCU:\Control Panel\Mouse" -ErrorAction SilentlyContinue
    if ($MouseReg) {
        if ($MouseReg.MouseSensitivity -match '^\d+$') {
            $Settings.input.mouse.speed = [int]$MouseReg.MouseSensitivity
        }
        if ($null -ne $MouseReg.MouseSpeed) {
            $Settings.input.mouse.enhance_pointer_precision = ($MouseReg.MouseSpeed -ne "0")
        }
        if ($null -ne $MouseReg.SwapMouseButtons) {
            $Settings.input.mouse.swap_buttons = ($MouseReg.SwapMouseButtons -eq "1")
        }
    }
    $DeskReg = Get-ItemProperty -Path "HKCU:\Control Panel\Desktop" -ErrorAction SilentlyContinue
    if ($DeskReg -and $DeskReg.WheelScrollLines -match '^\d+$') {
        $Settings.input.mouse.wheel_scroll_lines = [int]$DeskReg.WheelScrollLines
    }

    $KbReg = Get-ItemProperty -Path "HKCU:\Control Panel\Keyboard" -ErrorAction SilentlyContinue
    if ($KbReg) {
        if ($KbReg.KeyboardDelay -match '^\d+$') {
            $Settings.input.keyboard.repeat_delay = [int]$KbReg.KeyboardDelay
        }
        if ($KbReg.KeyboardSpeed -match '^\d+$') {
            $Settings.input.keyboard.repeat_speed = [int]$KbReg.KeyboardSpeed
        }
        if ($null -ne $KbReg.InitialKeyboardIndicators) {
            $Settings.input.keyboard.numlock_on_startup = ($KbReg.InitialKeyboardIndicators -eq "2")
        }
    }

    if (Get-Command "Get-WinUserLanguageList" -ErrorAction SilentlyContinue) {
        $Langs = @(Get-WinUserLanguageList -ErrorAction SilentlyContinue | ForEach-Object { $_.LanguageTag } | Where-Object { $_ })
        if ($Langs.Count -gt 0) {
            $Settings.input.keyboard.input_languages = $Langs
        }
    }
} catch {}

# 6. Power Profile & Timeouts (Standby + Display)
try {
    $ActiveOut = & powercfg /getactivescheme 2>$null
    if ($ActiveOut -match '\(([^)]+)\)\s*$') {
        $Settings.power.active_scheme_name = $Matches[1].Trim()
    }

    $SleepQuery = & powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>$null
    if ($SleepQuery) {
        $AcLine = $SleepQuery | Where-Object { $_ -match "Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)" } | Select-Object -First 1
        if ($AcLine -match "0x([0-9a-fA-F]+)") {
            $Seconds = [Convert]::ToInt32($Matches[1], 16)
            $Settings.power.ac_sleep_minutes = [int][Math]::Round($Seconds / 60)
        }
    }

    $DispQuery = & powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 2>$null
    if ($DispQuery) {
        $AcDispLine = $DispQuery | Where-Object { $_ -match "Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)" } | Select-Object -First 1
        if ($AcDispLine -match "0x([0-9a-fA-F]+)") {
            $DispSeconds = [Convert]::ToInt32($Matches[1], 16)
            $Settings.power.ac_display_minutes = [int][Math]::Round($DispSeconds / 60)
        }
    }
} catch {}

# 7. Audio Endpoints (Default Speakers, Default Mic, Master Volume) & Cameras
try {
    if (-not ("Reglaze.CoreAudioAudit" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Reglaze {
    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
        int OpenPropertyStore(int stgmAccess, out IPropertyStore ppProperties);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
        int GetState(out int pdwState);
    }

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        int EnumAudioEndpoints(int dataFlow, int dwStateMask, out IntPtr ppDevices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppEndpoint);
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject { }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROPERTYKEY {
        public Guid fmtid;
        public int pid;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct PROPVARIANT {
        [FieldOffset(0)] public short vt;
        [FieldOffset(8)] public IntPtr pwszVal;
    }

    [Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        int GetCount(out int cProps);
        int GetAt(int iProp, out PROPERTYKEY pkey);
        int GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
    }

    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume {
        int RegisterControlChangeNotify(IntPtr pNotify);
        int UnregisterControlChangeNotify(IntPtr pNotify);
        int GetChannelCount(out int pnChannelCount);
        int SetMasterVolumeLevel(float fLevelDB, ref Guid pguidEventContext);
        int SetMasterVolumeLevelScalar(float fLevel, ref Guid pguidEventContext);
        int GetMasterVolumeLevel(out float pfLevelDB);
        int GetMasterVolumeLevelScalar(out float pfLevel);
        int SetChannelVolumeLevel(uint nChannel, float fLevelDB, ref Guid pguidEventContext);
        int SetChannelVolumeLevelScalar(uint nChannel, float fLevel, ref Guid pguidEventContext);
        int GetChannelVolumeLevel(uint nChannel, out float pfLevelDB);
        int GetChannelVolumeLevelScalar(uint nChannel, out float pfLevel);
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, ref Guid pguidEventContext);
        int GetMute(out bool pbMute);
    }

    public static class CoreAudioAudit {
        public static string GetDefaultEndpointName(int dataFlow) {
            try {
                var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
                IMMDevice dev;
                if (enumerator.GetDefaultAudioEndpoint(dataFlow, 0, out dev) != 0 || dev == null) return null;
                IPropertyStore store;
                if (dev.OpenPropertyStore(0, out store) != 0 || store == null) return null;
                var pk = new PROPERTYKEY { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 14 };
                PROPVARIANT pv;
                if (store.GetValue(ref pk, out pv) == 0 && pv.vt == 31 && pv.pwszVal != IntPtr.Zero) {
                    return Marshal.PtrToStringUni(pv.pwszVal);
                }
            } catch {}
            return null;
        }

        public static void GetMasterVolume(out int volumePercent, out bool muted) {
            volumePercent = 50;
            muted = false;
            try {
                var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
                IMMDevice dev;
                if (enumerator.GetDefaultAudioEndpoint(0, 0, out dev) != 0 || dev == null) return;
                Guid iid = typeof(IAudioEndpointVolume).GUID;
                object obj;
                if (dev.Activate(ref iid, 23, IntPtr.Zero, out obj) != 0 || obj == null) return;
                var vol = (IAudioEndpointVolume)obj;
                float scalar;
                if (vol.GetMasterVolumeLevelScalar(out scalar) == 0) {
                    volumePercent = (int)Math.Round(scalar * 100.0f);
                }
                vol.GetMute(out muted);
            } catch {}
        }
    }
}
'@ -ErrorAction SilentlyContinue
    }

    if ("Reglaze.CoreAudioAudit" -as [type]) {
        $SpkName = [Reglaze.CoreAudioAudit]::GetDefaultEndpointName(0) # eRender = 0
        $MicName = [Reglaze.CoreAudioAudit]::GetDefaultEndpointName(1) # eCapture = 1
        if ($SpkName) { $Settings.audio_and_devices.default_speakers = $SpkName }
        if ($MicName) { $Settings.audio_and_devices.default_microphone = $MicName }

        $VolPct = 50
        $IsMuted = $false
        [Reglaze.CoreAudioAudit]::GetMasterVolume([ref]$VolPct, [ref]$IsMuted)
        $Settings.audio_and_devices.master_volume_percent = $VolPct
        $Settings.audio_and_devices.master_muted = $IsMuted
    }
} catch {}

try {
    if (Get-Command "Get-PnpDevice" -ErrorAction SilentlyContinue) {
        $CamDevices = @(Get-PnpDevice -Class Camera, Image -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName })
        $ActiveCams = @($CamDevices | Where-Object { $_.Status -eq "OK" } | Select-Object -ExpandProperty FriendlyName -Unique)
        $DisabledCams = @($CamDevices | Where-Object { $_.Status -in @("Error", "Degraded", "Unknown") -and $_.Problem -eq "CM_PROB_DISABLED" } | Select-Object -ExpandProperty FriendlyName -Unique)
        if ($ActiveCams.Count -gt 0) {
            $Settings.audio_and_devices.default_camera = $ActiveCams[0]
        }
        $Settings.audio_and_devices.disabled_cameras = $DisabledCams
    }
} catch {}

# 8. Display & Multi-Monitor Layout
try {
    $GameBar = Get-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -ErrorAction SilentlyContinue
    if ($GameBar -and $null -ne $GameBar.AutoGameModeEnabled) {
        $Settings.display.game_mode_enabled = ($GameBar.AutoGameModeEnabled -ne 0)
    }
    $GfxDrivers = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -ErrorAction SilentlyContinue
    if ($GfxDrivers -and $null -ne $GfxDrivers.HwSchMode) {
        $Settings.display.hardware_gpu_scheduling = ($GfxDrivers.HwSchMode -eq 2)
    }

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $Screens = [System.Windows.Forms.Screen]::AllScreens
    $MonIds = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue)
    $VideoCtrls = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue)
    $DefaultRefresh = if ($VideoCtrls.Count -gt 0 -and $VideoCtrls[0].CurrentRefreshRate) { [int]$VideoCtrls[0].CurrentRefreshRate } else { 60 }

    $MonitorEntries = [System.Collections.Generic.List[PSCustomObject]]::new()
    for ($i = 0; $i -lt $Screens.Count; $i++) {
        $Scr = $Screens[$i]
        $HwId = $Scr.DeviceName
        if ($i -lt $MonIds.Count -and $MonIds[$i]) {
            $Mfg = if ($MonIds[$i].ManufacturerName) { ([char[]]($MonIds[$i].ManufacturerName | Where-Object { $_ -ne 0 })) -join '' } else { "" }
            $NameChars = if ($MonIds[$i].UserFriendlyName) { ([char[]]($MonIds[$i].UserFriendlyName | Where-Object { $_ -ne 0 })) -join '' } else { "" }
            if ($Mfg -or $NameChars) {
                $HwId = ("$Mfg $NameChars").Trim()
            }
        }
        $MonitorEntries.Add([PSCustomObject]@{
            device_name     = $Scr.DeviceName
            hardware_id     = $HwId
            width           = [int]$Scr.Bounds.Width
            height          = [int]$Scr.Bounds.Height
            refresh_rate_hz = $DefaultRefresh
            position_x      = [int]$Scr.Bounds.X
            position_y      = [int]$Scr.Bounds.Y
            is_primary      = [bool]$Scr.Primary
        })
    }
    $Settings.display.monitors = $MonitorEntries.ToArray()
} catch {}

# 9. System & Developer Ergonomics (Clipboard History, LongPaths, SSH Agent, Default Browser/Terminal)
try {
    $Clip = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Clipboard" -ErrorAction SilentlyContinue
    if ($Clip -and $null -ne $Clip.EnableClipboardHistory) {
        $Settings.system_ergonomics.clipboard_history_enabled = ($Clip.EnableClipboardHistory -eq 1)
    }

    $FsCtrl = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -ErrorAction SilentlyContinue
    if ($FsCtrl -and $null -ne $FsCtrl.LongPathsEnabled) {
        $Settings.system_ergonomics.long_paths_enabled = ($FsCtrl.LongPathsEnabled -eq 1)
    }

    $SshSvc = Get-Service -Name "ssh-agent" -ErrorAction SilentlyContinue
    if ($SshSvc) {
        $Settings.system_ergonomics.ssh_agent_startup = [string]$SshSvc.StartType
    }

    $SshDir = Join-Path $env:USERPROFILE ".ssh"
    if (Test-Path -LiteralPath $SshDir -ErrorAction SilentlyContinue) {
        $SshItem = Get-Item -LiteralPath $SshDir -Force -ErrorAction SilentlyContinue
        $IsJunction = ($null -ne $SshItem -and (($SshItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0))
        if (-not $IsJunction -and $SshDir -like "C:\*") {
            $Settings.system_ergonomics.ssh_keys_unmapped_warning = $true
        }
    }

    $HttpsChoice = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice" -ErrorAction SilentlyContinue
    if ($HttpsChoice -and $HttpsChoice.ProgId) {
        $Settings.system_ergonomics.default_browser_prog_id = $HttpsChoice.ProgId
    }

    $ConsoleStartup = Get-ItemProperty -Path "HKCU:\Console\%%Startup" -ErrorAction SilentlyContinue
    if ($ConsoleStartup -and $ConsoleStartup.DelegationConsole -eq "{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}") {
        $Settings.system_ergonomics.default_terminal = "WindowsTerminal"
    }
} catch {}

return [PSCustomObject]$Settings
