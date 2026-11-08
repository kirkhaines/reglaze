<#
.SYNOPSIS
    Configures Default Audio Endpoints (Speakers/Mic), Master Volume, Cameras, Gaming Graphics, and Multi-Monitor Layout.
.DESCRIPTION
    Applies audio_and_devices and display preferences from windows_settings in reglaze.yaml.
#>
[CmdletBinding()]
param (
    [string]$DefaultSpeakers = $null,
    [string]$DefaultMicrophone = $null,
    [string]$DefaultCamera = $null,
    [string[]]$DisabledCameras = @(),
    [ValidateRange(0, 100)]
    [int]$MasterVolumePercent = 50,
    [bool]$MasterMuted = $false,
    [bool]$GameModeEnabled = $true,
    [bool]$HardwareGpuScheduling = $true,
    [PSCustomObject[]]$Monitors = @()
)

Write-Host "Applying Audio Endpoints, Camera, and Display settings..." -ForegroundColor Cyan

# 1. Default Audio Endpoints (Speakers & Microphone) and Master Volume via CoreAudio COM
try {
    if (-not ("Reglaze.CoreAudioConfig" -as [type])) {
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

    [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection {
        int GetCount(out uint pcDevices);
        int Item(uint nDevice, out IMMDevice ppDevice);
    }

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        int EnumAudioEndpoints(int dataFlow, int dwStateMask, out IMMDeviceCollection ppDevices);
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

    [Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPolicyConfig {
        int GetMixFormat(string pszDeviceName, IntPtr ppFormat);
        int GetDeviceFormat(string pszDeviceName, bool bDefault, IntPtr ppFormat);
        int ResetDeviceFormat(string pszDeviceName);
        int SetDeviceFormat(string pszDeviceName, IntPtr pEndpointFormat, IntPtr MixFormat);
        int GetProcessingPeriod(string pszDeviceName, bool bDefault, IntPtr pmftDefaultPeriod, IntPtr pmftMinimumPeriod);
        int SetProcessingPeriod(string pszDeviceName, IntPtr pmftPeriod);
        int GetShareMode(string pszDeviceName, IntPtr pMode);
        int SetShareMode(string pszDeviceName, IntPtr mode);
        int GetPropertyValue(string pszDeviceName, bool bFxStore, IntPtr key, IntPtr pv);
        int SetPropertyValue(string pszDeviceName, bool bFxStore, IntPtr key, IntPtr pv);
        int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, int role);
        int SetEndpointVisibility(string pszDeviceName, bool bVisible);
    }

    [ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")]
    class PolicyConfigClientComObject { }

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

    public static class CoreAudioConfig {
        public static bool SetDefaultEndpointByName(int dataFlow, string targetFriendlyName) {
            if (string.IsNullOrWhiteSpace(targetFriendlyName)) return false;
            try {
                var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
                IMMDeviceCollection collection;
                if (enumerator.EnumAudioEndpoints(dataFlow, 1, out collection) != 0 || collection == null) return false;
                uint count;
                collection.GetCount(out count);
                var pk = new PROPERTYKEY { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 14 };
                for (uint i = 0; i < count; i++) {
                    IMMDevice dev;
                    if (collection.Item(i, out dev) != 0 || dev == null) continue;
                    IPropertyStore store;
                    if (dev.OpenPropertyStore(0, out store) != 0 || store == null) continue;
                    PROPVARIANT pv;
                    if (store.GetValue(ref pk, out pv) == 0 && pv.vt == 31 && pv.pwszVal != IntPtr.Zero) {
                        string name = Marshal.PtrToStringUni(pv.pwszVal);
                        if (name != null && (name.Equals(targetFriendlyName, StringComparison.OrdinalIgnoreCase) || name.IndexOf(targetFriendlyName, StringComparison.OrdinalIgnoreCase) >= 0)) {
                            string devId;
                            dev.GetId(out devId);
                            var policy = (IPolicyConfig)(new PolicyConfigClientComObject());
                            policy.SetDefaultEndpoint(devId, 0); // eConsole
                            policy.SetDefaultEndpoint(devId, 1); // eMultimedia
                            policy.SetDefaultEndpoint(devId, 2); // eCommunications
                            return true;
                        }
                    }
                }
            } catch {}
            return false;
        }

        public static void SetMasterVolume(int volumePercent, bool muted) {
            try {
                var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
                IMMDevice dev;
                if (enumerator.GetDefaultAudioEndpoint(0, 0, out dev) != 0 || dev == null) return;
                Guid iid = typeof(IAudioEndpointVolume).GUID;
                object obj;
                if (dev.Activate(ref iid, 23, IntPtr.Zero, out obj) != 0 || obj == null) return;
                var vol = (IAudioEndpointVolume)obj;
                Guid ctx = Guid.Empty;
                float scalar = Math.Max(0.0f, Math.Min(1.0f, volumePercent / 100.0f));
                vol.SetMasterVolumeLevelScalar(scalar, ref ctx);
                vol.SetMute(muted, ref ctx);
            } catch {}
        }
    }
}
'@ -ErrorAction SilentlyContinue
    }

    if ("Reglaze.CoreAudioConfig" -as [type]) {
        if (-not [string]::IsNullOrWhiteSpace($DefaultSpeakers)) {
            if ([Reglaze.CoreAudioConfig]::SetDefaultEndpointByName(0, $DefaultSpeakers)) {
                Write-Host "  [+] Default Speakers set to: $DefaultSpeakers" -ForegroundColor Green
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($DefaultMicrophone)) {
            if ([Reglaze.CoreAudioConfig]::SetDefaultEndpointByName(1, $DefaultMicrophone)) {
                Write-Host "  [+] Default Microphone set to: $DefaultMicrophone" -ForegroundColor Green
            }
        }
        [Reglaze.CoreAudioConfig]::SetMasterVolume($MasterVolumePercent, $MasterMuted)
        Write-Host "  [+] Master Volume: ${MasterVolumePercent}% (Muted: $MasterMuted)" -ForegroundColor Green
    }
} catch {}

# 2. Disable Unused Secondary Cameras so Preferred Default Camera Takes Precedence
if ($DisabledCameras -and $DisabledCameras.Count -gt 0 -and (Get-Command "Get-PnpDevice" -ErrorAction SilentlyContinue)) {
    foreach ($CamName in $DisabledCameras) {
        $CamDevs = @(Get-PnpDevice -Class Camera, Image -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -ieq $CamName -and $_.Status -eq "OK" })
        foreach ($Cam in $CamDevs) {
            Disable-PnpDevice -InstanceId $Cam.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "  [+] Disabled secondary camera: $CamName" -ForegroundColor Green
        }
    }
}

# 3. Game Mode & Hardware-Accelerated GPU Scheduling
$GameBarKey = "HKCU:\Software\Microsoft\GameBar"
if (-not (Test-Path $GameBarKey)) { New-Item -Path $GameBarKey -Force | Out-Null }
Set-ItemProperty -Path $GameBarKey -Name "AutoGameModeEnabled" -Value $(if ($GameModeEnabled) { 1 } else { 0 }) -Type DWord

$GfxKey = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
if (Test-Path $GfxKey) {
    Set-ItemProperty -Path $GfxKey -Name "HwSchMode" -Value $(if ($HardwareGpuScheduling) { 2 } else { 1 }) -Type DWord -ErrorAction SilentlyContinue
}
Write-Host "  [+] Game Mode=$GameModeEnabled, Hardware GPU Scheduling=$HardwareGpuScheduling" -ForegroundColor Green

# =============================================================================
# [HITL-ID]: HITL-M5-05
# [HITL-TARGET]: Win32 Multi-Monitor Positioning & Topology (EnumDisplayDevices / ChangeDisplaySettingsEx)
# [HITL-STATUS]: VERIFIED
# [HITL-DESCRIPTION]: Applies multi-monitor spatial coordinates (position_x, position_y), resolution, refresh rate, and primary display designation using Win32 User32 Display Configuration APIs.
# [HITL-TEST-SNIPPET]:
#   Add-Type -AssemblyName System.Windows.Forms
#   [System.Windows.Forms.Screen]::AllScreens | Select-Object DeviceName, Primary, Bounds
# [HITL-LAST-INPUT]: Live workstation verification on dual-monitor setup (GSM LG ULTRAGEAR 2560x1440 Primary at 0,0; ACI PA249 1920x1200 Secondary at -1920,235)
# [HITL-LAST-RESULT]: Screen.AllScreens and WmiMonitorID verified; paired via EnumDisplayDevices (EDD_GET_DEVICE_INTERFACE_NAME)
# [HITL-PATTERN]: Stage each display with CDS_UPDATEREGISTRY | CDS_NORESET (and CDS_SET_PRIMARY for primary), fallback to DM_POSITION-only if refresh rate/mode is rejected, then commit atomically via ChangeDisplaySettingsEx(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero).
# [HITL-AVOID]: Calling ChangeDisplaySettingsEx without CDS_NORESET per monitor (causes intermediate topology rejection when primary monitor is shifted).
# =============================================================================
if ($Monitors -and @($Monitors).Count -gt 0) {
    try {
        if (-not ("Reglaze.DisplayTopology" -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Reglaze {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceKey;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmDeviceName;
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public int dmDisplayOrientation;
        public int dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel;
        public int dmPelsWidth;
        public int dmPelsHeight;
        public int dmDisplayFlags;
        public int dmDisplayFrequency;
        public int dmICMMethod;
        public int dmICMIntent;
        public int dmMediaType;
        public int dmDitherType;
        public int dmReserved1;
        public int dmReserved2;
        public int dmPanningWidth;
        public int dmPanningHeight;
    }

    public static class DisplayTopology {
        [DllImport("user32.dll", CharSet = CharSet.Ansi)]
        public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

        [DllImport("user32.dll", CharSet = CharSet.Ansi)]
        public static extern bool EnumDisplaySettingsEx(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode, uint dwFlags);

        [DllImport("user32.dll", CharSet = CharSet.Ansi)]
        public static extern int ChangeDisplaySettingsEx(string lpszDeviceName, ref DEVMODE lpDevMode, IntPtr hwnd, uint dwFlags, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Ansi)]
        public static extern int ChangeDisplaySettingsEx(string lpszDeviceName, IntPtr lpDevMode, IntPtr hwnd, uint dwFlags, IntPtr lParam);

        public const int ENUM_CURRENT_SETTINGS = -1;
        public const int DISPLAY_DEVICE_ATTACHED_TO_DESKTOP = 0x00000001;
        public const int DM_POSITION = 0x00000020;
        public const int DM_PELSWIDTH = 0x00080000;
        public const int DM_PELSHEIGHT = 0x00100000;
        public const int DM_DISPLAYFREQUENCY = 0x00400000;
        public const uint CDS_UPDATEREGISTRY = 0x00000001;
        public const uint CDS_SET_PRIMARY = 0x00000010;
        public const uint CDS_NORESET = 0x10000000;

        public static int StageMonitor(string deviceName, int posX, int posY, int width, int height, int refreshHz, bool isPrimary) {
            DEVMODE dm = new DEVMODE();
            dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            if (!EnumDisplaySettingsEx(deviceName, ENUM_CURRENT_SETTINGS, ref dm, 0)) {
                return -100;
            }

            uint flags = CDS_UPDATEREGISTRY | CDS_NORESET;
            if (isPrimary) {
                flags |= CDS_SET_PRIMARY;
            }

            // Attempt 1: Full mode (position + resolution + refresh rate)
            DEVMODE dmFull = dm;
            dmFull.dmPositionX = posX;
            dmFull.dmPositionY = posY;
            dmFull.dmFields = DM_POSITION;
            if (width > 0 && height > 0) {
                dmFull.dmPelsWidth = width;
                dmFull.dmPelsHeight = height;
                dmFull.dmFields |= (DM_PELSWIDTH | DM_PELSHEIGHT);
            }
            if (refreshHz > 0) {
                dmFull.dmDisplayFrequency = refreshHz;
                dmFull.dmFields |= DM_DISPLAYFREQUENCY;
            }
            int res = ChangeDisplaySettingsEx(deviceName, ref dmFull, IntPtr.Zero, flags, IntPtr.Zero);
            if (res == 0) return 0;

            // Attempt 2: Position + resolution only (keep current refresh rate)
            if (width > 0 && height > 0) {
                DEVMODE dmRes = dm;
                dmRes.dmPositionX = posX;
                dmRes.dmPositionY = posY;
                dmRes.dmPelsWidth = width;
                dmRes.dmPelsHeight = height;
                dmRes.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT;
                res = ChangeDisplaySettingsEx(deviceName, ref dmRes, IntPtr.Zero, flags, IntPtr.Zero);
                if (res == 0) return 0;
            }

            // Attempt 3: Position only
            DEVMODE dmPos = dm;
            dmPos.dmPositionX = posX;
            dmPos.dmPositionY = posY;
            dmPos.dmFields = DM_POSITION;
            return ChangeDisplaySettingsEx(deviceName, ref dmPos, IntPtr.Zero, flags, IntPtr.Zero);
        }

        public static int CommitTopology() {
            return ChangeDisplaySettingsEx(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero);
        }
    }
}
'@ -ErrorAction SilentlyContinue
        }

        if ("Reglaze.DisplayTopology" -as [type]) {
            # Build map of WmiMonitorID PnP instance prefixes (e.g. AUS27F6 -> "AUS ASUS PA278QV")
            $WmiMonMap = @{}
            $MonIds = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue)
            foreach ($MId in $MonIds) {
                $Mfg = if ($MId.ManufacturerName) { ([char[]]($MId.ManufacturerName | Where-Object { $_ -ne 0 })) -join '' } else { "" }
                $UName = if ($MId.UserFriendlyName) { ([char[]]($MId.UserFriendlyName | Where-Object { $_ -ne 0 })) -join '' } else { "" }
                $FullHw = ("$Mfg $UName").Trim()
                if ($MId.InstanceName -match '^DISPLAY\\([^\\]+)\\([^\\]+)') {
                    $KeyToken = ($Matches[1] + "\" + ($Matches[2] -replace '_0$', '')).ToUpperInvariant()
                    $WmiMonMap[$KeyToken] = $FullHw
                    $WmiMonMap[$Matches[1].ToUpperInvariant()] = $FullHw
                }
            }

            # Enumerate connected GDI display adapters (\\.\DISPLAY1, \\.\DISPLAY2, ...)
            $ConnectedDisplays = [System.Collections.Generic.List[PSCustomObject]]::new()
            for ($dIdx = 0; $dIdx -lt 16; $dIdx++) {
                $AdapterDev = New-Object Reglaze.DISPLAY_DEVICE
                $AdapterDev.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($AdapterDev)
                if (-not [Reglaze.DisplayTopology]::EnumDisplayDevices($null, [uint32]$dIdx, [ref]$AdapterDev, 0)) {
                    break
                }
                if (($AdapterDev.StateFlags -band [Reglaze.DisplayTopology]::DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) -eq 0) {
                    continue
                }
                $MonDev = New-Object Reglaze.DISPLAY_DEVICE
                $MonDev.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($MonDev)
                $DetectedHwId = ""
                $PnpDeviceId = ""
                if ([Reglaze.DisplayTopology]::EnumDisplayDevices($AdapterDev.DeviceName, 0, [ref]$MonDev, 0)) {
                    $PnpDeviceId = [string]$MonDev.DeviceID
                    if ($PnpDeviceId -match '^MONITOR\\([^\\]+)\\') {
                        $MonCode = $Matches[1].ToUpperInvariant()
                        if ($WmiMonMap.ContainsKey($MonCode)) {
                            $DetectedHwId = $WmiMonMap[$MonCode]
                        } else {
                            $DetectedHwId = $MonCode
                        }
                    }
                }
                $ConnectedDisplays.Add([PSCustomObject]@{
                    DeviceName   = $AdapterDev.DeviceName
                    HardwareId   = $DetectedHwId
                    PnpDeviceId  = $PnpDeviceId
                    DeviceString = $AdapterDev.DeviceString
                    Assigned     = $false
                })
            }

            if ($ConnectedDisplays.Count -gt 0) {
                # Sort configured monitors so Primary monitor (0,0) is staged first
                $SortedMonitors = @($Monitors | Sort-Object { if ($_.is_primary) { 0 } else { 1 } })
                $StagedCount = 0

                foreach ($TargetMon in $SortedMonitors) {
                    $NormTargetDev = if ([string]$TargetMon.device_name -match '(?i)(DISPLAY\d+)') { "\\.\$($Matches[1].ToUpperInvariant())" } else { "" }
                    $TargetHwId = ([string]$TargetMon.hardware_id).Trim()

                    # 1. Match by exact HardwareId (e.g. "AUS ASUS PA278QV")
                    $MatchedDisp = $ConnectedDisplays | Where-Object { -not $_.Assigned -and $_.HardwareId -and $TargetHwId -and ($_.HardwareId -ieq $TargetHwId) } | Select-Object -First 1
                    # 2. Match by PnP 3-letter manufacturer prefix or substring
                    if (-not $MatchedDisp -and $TargetHwId) {
                        $MfgPrefix = ($TargetHwId -split '\s+')[0]
                        $MatchedDisp = $ConnectedDisplays | Where-Object {
                            -not $_.Assigned -and (
                                ($_.HardwareId -and $_.HardwareId.IndexOf($TargetHwId, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                                ($MfgPrefix -and $_.PnpDeviceId -match "MONITOR\\$([regex]::Escape($MfgPrefix))")
                            )
                        } | Select-Object -First 1
                    }
                    # 3. Fallback to normalized DeviceName (\\.\DISPLAY1)
                    if (-not $MatchedDisp -and $NormTargetDev) {
                        $MatchedDisp = $ConnectedDisplays | Where-Object { -not $_.Assigned -and ($_.DeviceName -ieq $NormTargetDev) } | Select-Object -First 1
                    }

                    if ($MatchedDisp) {
                        $MatchedDisp.Assigned = $true
                        $PosX = if ($null -ne $TargetMon.position_x) { [int]$TargetMon.position_x } else { 0 }
                        $PosY = if ($null -ne $TargetMon.position_y) { [int]$TargetMon.position_y } else { 0 }
                        $Width = if ($null -ne $TargetMon.width) { [int]$TargetMon.width } else { 0 }
                        $Height = if ($null -ne $TargetMon.height) { [int]$TargetMon.height } else { 0 }
                        $Refresh = if ($null -ne $TargetMon.refresh_rate_hz) { [int]$TargetMon.refresh_rate_hz } else { 0 }
                        $IsPrim = [bool]$TargetMon.is_primary

                        $StageRes = [Reglaze.DisplayTopology]::StageMonitor($MatchedDisp.DeviceName, $PosX, $PosY, $Width, $Height, $Refresh, $IsPrim)
                        if ($StageRes -eq 0) {
                            $StagedCount++
                            Write-Host "  [+] Staged display $($MatchedDisp.DeviceName) ($($MatchedDisp.HardwareId)): ${Width}x${Height}@${Refresh}Hz at ($PosX, $PosY) [Primary=$IsPrim]" -ForegroundColor Green
                        } else {
                            Write-Warning "  [!] Could not stage display $($MatchedDisp.DeviceName) ($TargetHwId): ChangeDisplaySettingsEx returned $StageRes"
                        }
                    }
                }

                if ($StagedCount -gt 0) {
                    $CommitRes = [Reglaze.DisplayTopology]::CommitTopology()
                    if ($CommitRes -eq 0) {
                        Write-Host "  [+] Multi-monitor display positioning committed ($StagedCount monitor(s))." -ForegroundColor Green
                    } else {
                        Write-Warning "  [!] ChangeDisplaySettingsEx commit returned code: $CommitRes"
                    }
                }
            }
        }
    } catch {
        Write-Warning "  [!] Failed to apply multi-monitor positioning: $($_.Exception.Message)"
    }
}

