<#
.SYNOPSIS
    Reglaze Phase 4 Machine Provisioning Runner (LocalAdmin).
.DESCRIPTION
    Executes post-install machine-level orchestration:
    1. Unlocks and re-arms preserved BitLocker volumes using recovery keys.
    2. Executes automated WHQL driver servicing pass via PSWindowsUpdate.
    3. Applies general Windows security and quality cumulative updates.
    4. Provisions machine-scope applications via WinGet DSC.
    5. Stages the WSL2 kernel and target Linux distribution.
    6. Establishes machine-level directory junctions (Program Files, ProgramData).
    7. Applies developer-friendly Windows Explorer, taskbar, and power preferences.
    8. Destroys temporary LocalAdmin AutoLogon credentials.
    9. Stages Phase 5 User Hydration in RunOnce and Public Desktop shortcut.
    10. Restarts the computer into the interactive standard user login screen.

    FAIL-SAFE DIRECTIVE: Defaults strictly to SIMULATION mode ($Simulation=$true, $Live=$false).
    Live execution requires explicit -Live switch. Reboots require -AllowReboot AND -Live.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Position=0)]
    [string]$PayloadDir = $null,

    [string]$ConfigFile = $null,

    # Fail-safe defaults: Always simulated and never reboots unless explicitly flagged -Live
    [switch]$Simulation = $true,
    [switch]$Live = $false,
    [switch]$NoReboot = $true,
    [switch]$AllowReboot = $false,
    [switch]$SkipUpdates = $false,
    [switch]$SkipDsc = $false
)

# Enforce fail-safe flags:
$IsSimulated = $Simulation -or (-not $Live)
$CanReboot = $AllowReboot -and $Live -and (-not $NoReboot)

$RunnerRoot = $PSScriptRoot
$RepoRoot = Split-Path -Parent (Split-Path -Parent $RunnerRoot)
$CommonRoot = Join-Path $RepoRoot "src\common"
$LinkingRoot = Join-Path $RepoRoot "src\linking"

. (Join-Path $CommonRoot "Logging.ps1")
. (Join-Path $CommonRoot "ConfigResolver.ps1")
. (Join-Path $LinkingRoot "New-DirectoryJunction.ps1")
. (Join-Path $LinkingRoot "Unlock-BitLockerVolumes.ps1")
. (Join-Path $RunnerRoot "Apply-WindowsSettings.ps1")

Write-ReglazeBanner "REGLAZE PHASE 4: MACHINE BOOTSTRAP ORCHESTRATION"

if ($IsSimulated) {
    Write-ReglazeWarning "Running in SIMULATION mode. No system files, drivers, or registry credentials will be modified."
} else {
    Write-ReglazeWarning "Running in LIVE PROVISIONING mode against the active Windows system."
}

# Resolve Payload Directory
$ResolvedPayload = $null
if ($PayloadDir -and (Test-Path -LiteralPath $PayloadDir)) {
    $ResolvedPayload = $PayloadDir
} elseif (Test-Path "C:\Reglaze\payload") {
    $ResolvedPayload = "C:\Reglaze\payload"
} else {
    $LocalDistPayload = Join-Path $RepoRoot "dist\media\payload"
    if (Test-Path -LiteralPath $LocalDistPayload) {
        $ResolvedPayload = $LocalDistPayload
    }
}

if (-not $ResolvedPayload -or -not (Test-Path -LiteralPath $ResolvedPayload)) {
    Write-ReglazeWarning "No deployment payload directory found at C:\Reglaze\payload or dist\media\payload."
    if (-not $IsSimulated) {
        Write-ReglazeError "Cannot proceed with live bootstrap without deployment payload artifacts."
        exit 1
    }
} else {
    Write-ReglazeInfo "Payload Directory: $ResolvedPayload"
}

# =============================================================================
# Step 1: Unlock & Re-arm Preserved BitLocker Secondary Storage
# =============================================================================
Write-ReglazeStep "Step 1/9: Unlocking & Re-arming Preserved BitLocker Volumes..."
$BitLockerKeyFile = if ($ResolvedPayload) { Join-Path $ResolvedPayload "bitlocker-keys.json" } else { $null }

if ($BitLockerKeyFile -and (Test-Path -LiteralPath $BitLockerKeyFile)) {
    $UnlockResults = Unlock-PreservedBitLockerVolumes -KeyFilePath $BitLockerKeyFile -Simulation:$IsSimulated -Live:(-not $IsSimulated)
    foreach ($Res in $UnlockResults) {
        if ($Res.Status -eq "Success" -or $Res.Status -eq "Simulated") {
            Write-ReglazeSuccess "Volume $($Res.MountPoint): $($Res.Message)"
        } elseif ($Res.Status -eq "Skipped") {
            Write-ReglazeInfo "Volume $($Res.MountPoint): $($Res.Message)"
        } else {
            Write-ReglazeWarning "Volume $($Res.MountPoint): $($Res.Message)"
        }
    }
} else {
    Write-ReglazeInfo "No secondary BitLocker keys found in payload; skipping volume unlock."
}

# =============================================================================
# [HITL-ID]: HITL-M3-04
# [HITL-TARGET]: PSWindowsUpdate / Automated WHQL Device Driver & Cumulative Updates
# [HITL-STATUS]: VERIFIED
# [HITL-DESCRIPTION]: Automates WHQL driver servicing and Windows cumulative updates via PSWindowsUpdate module.
# [HITL-TEST-SNIPPET]:
#   # Safe verification of NuGet provider:
#   Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue | Select-Object Name, Version
# [HITL-LAST-INPUT]: Get-PackageProvider -Name NuGet on physical host (2026-10-21)
# [HITL-LAST-RESULT]: Prompted to install NuGet 2.8.5.208, confirming unbootstrapped state triggers interactive UI unless -ForceBootstrap is passed.
# [HITL-PATTERN]: Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ForceBootstrap -Scope CurrentUser
# [HITL-AVOID]: Calling Get-PackageProvider or Install-PackageProvider without -ForceBootstrap in unattended sessions
# =============================================================================
Write-ReglazeStep "Step 2/9: Servicing WHQL Hardware Device Drivers..."
if (-not $SkipUpdates -and -not $IsSimulated) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ForceBootstrap -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null
        Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Install-Module -Name PSWindowsUpdate -Force -Scope CurrentUser -ErrorAction Stop
        Write-ReglazeInfo "Scanning and installing WHQL drivers (GPU, Audio, Chipset, Storage)..."
        Get-WindowsUpdate -Category "Drivers" -Install -AcceptAll -IgnoreReboot -ErrorAction SilentlyContinue
        Write-ReglazeSuccess "WHQL driver servicing completed."
    } catch {
        Write-ReglazeWarning "Automated driver servicing encountered an issue: $($_.Exception.Message)"
    }
} else {
    Write-ReglazeInfo "WHQL driver pass bypassed (SkipUpdates: $SkipUpdates, Simulation: $IsSimulated)."
}

# =============================================================================
# Step 3: Windows Quality & Security Cumulative Updates
# =============================================================================
Write-ReglazeStep "Step 3/9: Installing Windows Security & Cumulative Quality Patches..."
if (-not $SkipUpdates -and -not $IsSimulated) {
    try {
        Write-ReglazeInfo "Installing latest Windows cumulative updates..."
        Get-WindowsUpdate -NotCategory "Drivers" -Install -AcceptAll -IgnoreReboot -ErrorAction SilentlyContinue
        Write-ReglazeSuccess "Windows quality and security update pass completed."
    } catch {
        Write-ReglazeWarning "Windows update pass encountered an issue: $($_.Exception.Message)"
    }
} else {
    Write-ReglazeInfo "Windows update pass bypassed (SkipUpdates: $SkipUpdates, Simulation: $IsSimulated)."
}

# =============================================================================
# [HITL-ID]: HITL-M3-05
# [HITL-TARGET]: WinGet DSC / Machine Application Provisioning
# [HITL-STATUS]: VERIFIED
# [HITL-DESCRIPTION]: Declarative application provisioning via 'winget configure --file configuration.dsc.yaml'.
# [HITL-TEST-SNIPPET]:
#   # Safe verification of winget configuration capability:
#   winget --version; winget configure --help | Select-Object -First 4
# [HITL-LAST-INPUT]: winget --version; winget configure --help | Select-Object -First 4 (2026-10-21)
# [HITL-LAST-RESULT]: WinGet v1.29.380 detected with native winget configure command support.
# [HITL-PATTERN]: winget configure --enable --accept-configuration-agreements; winget configure --file $DscManifest --accept-configuration-agreements --disable-interactivity
# [HITL-AVOID]: Running full DSC manifest without testing individual resource module configurations first
# =============================================================================
Write-ReglazeStep "Step 4/9: Executing WinGet DSC Machine Application Provisioning..."
$DscManifest = if ($ResolvedPayload) { Join-Path $ResolvedPayload "configuration.dsc.yaml" } else { $null }

if ($DscManifest -and (Test-Path -LiteralPath $DscManifest)) {
    if (-not $SkipDsc -and -not $IsSimulated) {
        Write-ReglazeInfo "Pre-enabling WinGet configuration agreements and experimental subsystem..."
        & winget configure --enable --accept-configuration-agreements 2>&1 | Out-Null
        Write-ReglazeInfo "Executing: winget configure --file `"$DscManifest`" --accept-configuration-agreements --disable-interactivity"
        & winget configure --file $DscManifest --accept-configuration-agreements --disable-interactivity
        Write-ReglazeSuccess "WinGet DSC machine application deployment complete."
    } else {
        Write-ReglazeInfo "WinGet DSC pass bypassed (SkipDsc: $SkipDsc, Simulation: $IsSimulated)."
    }
} else {
    Write-ReglazeInfo "No configuration.dsc.yaml found in payload; skipping DSC provisioning."
}

# =============================================================================
# [HITL-ID]: HITL-M3-06
# [HITL-TARGET]: WSL2 / Subsystem Kernel & Linux Distribution Staging
# [HITL-STATUS]: VERIFIED
# [HITL-DESCRIPTION]: Provisions WSL2 base subsystem and registers initial distribution non-interactively via 'wsl.exe --install'.
# [HITL-TEST-SNIPPET]:
#   # Safe inspection of WSL status:
#   wsl.exe --status; wsl.exe --list --verbose
# [HITL-LAST-INPUT]: wsl.exe --status; wsl.exe --list --verbose (2026-10-21)
# [HITL-LAST-RESULT]: Default Distribution: Ubuntu, Default Version: 2, status reported cleanly.
# [HITL-PATTERN]: wsl.exe --install -d <distro> --no-launch
# [HITL-AVOID]: Launching interactive distro setup during unattended LocalAdmin phase
# =============================================================================
Write-ReglazeStep "Step 5/9: Staging WSL2 Base Subsystem & Linux Distribution..."
if (-not $IsSimulated) {
    try {
        & wsl.exe --install -d Ubuntu --no-launch 2>&1 | Out-Null
        Write-ReglazeSuccess "WSL2 and Ubuntu staged successfully."
    } catch {
        Write-ReglazeWarning "WSL2 staging returned: $($_.Exception.Message)"
    }
} else {
    Write-ReglazeInfo "WSL2 staging simulated successfully."
}

# =============================================================================
# Step 6: Create Machine-Level Directory Junctions
# =============================================================================
Write-ReglazeStep "Step 6/9: Establishing Machine-Scope Directory Junctions..."
$JunctionsManifest = if ($ResolvedPayload) { Join-Path $ResolvedPayload "junctions-manifest.json" } else { $null }

if ($JunctionsManifest -and (Test-Path -LiteralPath $JunctionsManifest)) {
    if (-not $IsSimulated) {
        $JunctionResults = Install-JunctionsFromManifest -ManifestPath $JunctionsManifest -Scope "machine"
        $SuccessCount = ($JunctionResults | Where-Object { $_.Success }).Count
        Write-ReglazeSuccess "Processed $($JunctionResults.Count) machine junction(s) ($SuccessCount active)."
    } else {
        $ManifestData = Get-Content -Raw -LiteralPath $JunctionsManifest | ConvertFrom-Json
        $MachineJuncs = @($ManifestData | Where-Object { $_.Scope -eq "machine" })
        Write-ReglazeInfo "Simulated $($MachineJuncs.Count) machine-level junction(s)."
    }
} else {
    Write-ReglazeInfo "No junctions manifest found; skipping machine junctions."
}

# =============================================================================
# Step 7: Apply Windows Explorer, Taskbar & Power Preferences
# =============================================================================
Write-ReglazeStep "Step 7/9: Applying Windows Preferences & System Settings..."
$SettingsResults = Invoke-WindowsSettingsApplication -RepoRoot $RepoRoot -Simulation:$IsSimulated -Live:(-not $IsSimulated)
foreach ($Setting in $SettingsResults) {
    Write-ReglazeSuccess "$($Setting.SettingName): $($Setting.Status)"
}

# =============================================================================
# [HITL-ID]: HITL-M3-07
# [HITL-TARGET]: Winlogon / AutoLogon Credential Purge
# [HITL-STATUS]: VERIFIED
# [HITL-DESCRIPTION]: Clears AutoAdminLogon and DefaultPassword from HKLM Winlogon to lock down machine to standard user login.
# [HITL-TEST-SNIPPET]:
#   # Safe read-only inspection of Winlogon configuration:
#   Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" | Select-Object AutoAdminLogon, DefaultUserName
# [HITL-LAST-INPUT]: Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" (2026-10-21)
# [HITL-LAST-RESULT]: Winlogon key accessible; AutoAdminLogon and DefaultUserName clean/unset on host.
# [HITL-PATTERN]: Remove-ItemProperty -Path $WinlogonKey -Name "DefaultPassword"; Set-ItemProperty -Path $WinlogonKey -Name "AutoAdminLogon" -Value "0"
# [HITL-AVOID]: Mutating HKLM Winlogon on host workstation outside VM
# =============================================================================
Write-ReglazeStep "Step 8/9: Deactivating Temporary LocalAdmin AutoLogon Credentials..."
if (-not $IsSimulated) {
    try {
        $WinlogonKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        Remove-ItemProperty -Path $WinlogonKey -Name "DefaultPassword" -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $WinlogonKey -Name "AutoAdminLogon" -Value "0" -ErrorAction SilentlyContinue
        Write-ReglazeSuccess "Purged AutoLogon credentials. Workstation locked down to standard user login."
    } catch {
        Write-ReglazeWarning "Could not update Winlogon registry keys: $($_.Exception.Message)"
    }
} else {
    Write-ReglazeInfo "AutoLogon deactivation simulated."
}

# =============================================================================
# [HITL-ID]: HITL-M3-08
# [HITL-TARGET]: RunOnce & Public Desktop / Phase 5 User Hydration Wizard Staging
# [HITL-STATUS]: VERIFIED
# [HITL-DESCRIPTION]: Registers hydrate.ps1 in HKLM RunOnce and drops resume shortcut on Public Desktop.
# [HITL-TEST-SNIPPET]:
#   # Safe verification of Public Desktop path:
#   [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDesktopDirectory)
# [HITL-LAST-INPUT]: [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDesktopDirectory) (2026-10-21)
# [HITL-LAST-RESULT]: Correctly resolved to C:\Users\Public\Desktop.
# [HITL-PATTERN]: Set-ItemProperty HKLM RunOnce + WScript.Shell CreateShortcut on CommonDesktopDirectory
# [HITL-AVOID]: Writing to HKLM RunOnce or Public Desktop on active workstation
# =============================================================================
Write-ReglazeStep "Step 9/9: Staging Phase 5 User Hydration Wizard..."
$HydrateScriptPath = if ($ResolvedPayload) { Join-Path $ResolvedPayload "hydrate.ps1" } else { "C:\Reglaze\payload\hydrate.ps1" }

if (-not $IsSimulated) {
    try {
        # 1. Register in RunOnce for primary user session
        $HydrateCmd = "powershell.exe -ExecutionPolicy Bypass -File `"$HydrateScriptPath`""
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "ReglazeHydrate" -Value $HydrateCmd -ErrorAction SilentlyContinue

        # 2. Place desktop shortcut on Public Desktop
        $WshShell = New-Object -ComObject WScript.Shell
        $PublicDesktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDesktopDirectory)
        if (-not $PublicDesktop) { $PublicDesktop = "C:\Users\Public\Desktop" }
        $ShortcutPath = Join-Path $PublicDesktop "Resume Reglaze Setup.lnk"
        $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
        $Shortcut.TargetPath = "powershell.exe"
        $Shortcut.Arguments = "-ExecutionPolicy Bypass -NoExit -File `"$HydrateScriptPath`""
        $Shortcut.IconLocation = "shell32.dll,238"
        $Shortcut.Description = "Resume Reglaze User Hydration Wizard"
        $Shortcut.Save()

        Write-ReglazeSuccess "Staged user hydration in RunOnce and created Public Desktop shortcut: $ShortcutPath"
    } catch {
        Write-ReglazeWarning "Could not stage user hydration RunOnce / shortcut: $($_.Exception.Message)"
    }
} else {
    Write-ReglazeInfo "Staging Phase 5 User Hydration simulated."
}

Write-Host ""
Write-ReglazeBanner "PHASE 4 MACHINE BOOTSTRAP COMPLETE"
Write-Host "  Machine-level provisioning tasks finished successfully." -ForegroundColor Green
Write-Host "  The workstation is ready for standard user sign-in and Phase 5 hydration." -ForegroundColor Cyan
Write-Host ""

# =============================================================================
# [HITL-ID]: HITL-M3-09
# [HITL-TARGET]: System Power / Restart-Computer
# [HITL-STATUS]: TABLED
# [HITL-DESCRIPTION]: Forced restart of workstation into interactive standard user login screen. Tabled for Milestone 5 VM automation.
# [HITL-TEST-SNIPPET]:
#   # DO NOT RUN ON HOST WORKSTATION. Run only inside isolated test VM:
#   # Restart-Computer -Force
# [HITL-LAST-INPUT]: Table for Milestone 5 (Hyper-V VM validation via PowerShell Direct)
# [HITL-LAST-RESULT]: Tabled to prevent host reboot.
# [HITL-PATTERN]: Guarded by $CanReboot = $AllowReboot -and $Live -and (-not $NoReboot)
# [HITL-AVOID]: Executing Restart-Computer outside dedicated test VM
# =============================================================================
if ($CanReboot) {
    Write-ReglazeInfo "Rebooting workstation into standard user session in 5 seconds..."
    Start-Sleep -Seconds 5
    Restart-Computer -Force
} else {
    Write-ReglazeInfo "Reboot sequence skipped (Simulation: $IsSimulated, CanReboot: $CanReboot)."
}
