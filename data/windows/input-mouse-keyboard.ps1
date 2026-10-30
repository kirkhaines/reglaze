<#
.SYNOPSIS
    Configures Windows Mouse speed/precision and Keyboard repeat rate/delay/layouts.
.DESCRIPTION
    Applies user hardware input preferences from windows_settings.input in reglaze.yaml.
#>
[CmdletBinding()]
param (
    [ValidateRange(1, 20)]
    [int]$MouseSpeed = 10,
    [bool]$EnhancePointerPrecision = $true,
    [bool]$SwapMouseButtons = $false,
    [int]$WheelScrollLines = 3,
    [ValidateRange(0, 3)]
    [int]$KeyboardRepeatDelay = 1,
    [ValidateRange(0, 31)]
    [int]$KeyboardRepeatSpeed = 31,
    [bool]$NumLockOnStartup = $true,
    [string[]]$InputLanguages = @()
)

Write-Host "Applying Mouse and Keyboard Input settings..." -ForegroundColor Cyan

$MouseKey = "HKCU:\Control Panel\Mouse"
$DeskKey  = "HKCU:\Control Panel\Desktop"
$KbKey    = "HKCU:\Control Panel\Keyboard"

# 1. Mouse Speed & Pointer Precision
Set-ItemProperty -Path $MouseKey -Name "MouseSensitivity" -Value "$MouseSpeed" -Type String
if ($EnhancePointerPrecision) {
    Set-ItemProperty -Path $MouseKey -Name "MouseSpeed" -Value "1" -Type String
    Set-ItemProperty -Path $MouseKey -Name "MouseThreshold1" -Value "6" -Type String
    Set-ItemProperty -Path $MouseKey -Name "MouseThreshold2" -Value "10" -Type String
} else {
    Set-ItemProperty -Path $MouseKey -Name "MouseSpeed" -Value "0" -Type String
    Set-ItemProperty -Path $MouseKey -Name "MouseThreshold1" -Value "0" -Type String
    Set-ItemProperty -Path $MouseKey -Name "MouseThreshold2" -Value "0" -Type String
}
Set-ItemProperty -Path $MouseKey -Name "SwapMouseButtons" -Value $(if ($SwapMouseButtons) { "1" } else { "0" }) -Type String
Set-ItemProperty -Path $DeskKey  -Name "WheelScrollLines" -Value "$WheelScrollLines" -Type String

if (-not ("Reglaze.InputNative" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Reglaze {
    public static class InputNative {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, int[] pvParam, uint fWinIni);
    }
}
'@ -ErrorAction SilentlyContinue
}
if ("Reglaze.InputNative" -as [type]) {
    # SPI_SETMOUSESPEED = 0x0071, SPI_SETMOUSE = 0x0004, SPI_SETWHEELSCROLLLINES = 0x0069
    [void][Reglaze.InputNative]::SystemParametersInfo(0x0071, 0, [IntPtr]$MouseSpeed, 0x02)
    $AccelParams = if ($EnhancePointerPrecision) { @(6, 10, 1) } else { @(0, 0, 0) }
    [void][Reglaze.InputNative]::SystemParametersInfo(0x0004, 0, $AccelParams, 0x02)
    [void][Reglaze.InputNative]::SystemParametersInfo(0x0069, [uint32]$WheelScrollLines, [IntPtr]::Zero, 0x02)
}
Write-Host "  [+] Mouse Speed=$MouseSpeed, EnhancePointerPrecision=$EnhancePointerPrecision, ScrollLines=$WheelScrollLines" -ForegroundColor Green

# 2. Keyboard Repeat Delay, Repeat Rate, NumLock, and Input Languages
Set-ItemProperty -Path $KbKey -Name "KeyboardDelay" -Value "$KeyboardRepeatDelay" -Type String
Set-ItemProperty -Path $KbKey -Name "KeyboardSpeed" -Value "$KeyboardRepeatSpeed" -Type String
Set-ItemProperty -Path $KbKey -Name "InitialKeyboardIndicators" -Value $(if ($NumLockOnStartup) { "2" } else { "0" }) -Type String
Write-Host "  [+] Keyboard Delay=$KeyboardRepeatDelay, Speed=$KeyboardRepeatSpeed, NumLock=$NumLockOnStartup" -ForegroundColor Green

if ($InputLanguages -and $InputLanguages.Count -gt 0 -and (Get-Command "New-WinUserLanguageList" -ErrorAction SilentlyContinue)) {
    try {
        $LangListObj = New-WinUserLanguageList -Language $InputLanguages[0]
        for ($i = 1; $i -lt $InputLanguages.Count; $i++) {
            $LangListObj.Add($InputLanguages[$i])
        }
        Set-WinUserLanguageList -LanguageList $LangListObj -Force -ErrorAction SilentlyContinue
        Write-Host "  [+] Input Languages: $($InputLanguages -join ', ')" -ForegroundColor Green
    } catch {}
}

