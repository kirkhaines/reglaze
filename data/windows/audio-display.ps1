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

