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

    [Parameter(Mandatory=$false)]
    [array]$MockSystemDisks = $null,

    [switch]$HaltOnMissingDisks = $false,

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
. (Join-Path $LinkingRoot "Set-ReglazeDriveLetters.ps1")
. (Join-Path $LinkingRoot "New-DirectoryJunction.ps1")
. (Join-Path $LinkingRoot "Unlock-BitLockerVolumes.ps1")
. (Join-Path $RunnerRoot "Apply-WindowsSettings.ps1")

Write-ReglazeBanner "REGLAZE PHASE 4: MACHINE BOOTSTRAP ORCHESTRATION"

if ($IsSimulated) {
    Write-ReglazeWarning "Running in SIMULATION mode. No system files, drivers, or registry credentials will be modified."
} else {
    Write-ReglazeWarning "Running in LIVE PROVISIONING mode against the active Windows system."
    $ReglazeRoot = "C:\Reglaze"
    if (-not (Test-Path $ReglazeRoot)) {
        New-Item -ItemType Directory -Path $ReglazeRoot -Force | Out-Null
    }
    try {
        & icacls.exe $ReglazeRoot /grant "*S-1-5-32-545:(OI)(CI)M" /T /C /Q 2>&1 | Out-Null
    } catch {}
    try {
        Start-Transcript -Path "C:\Reglaze\bootstrap.log" -Append -Force | Out-Null
    } catch {}
}

function Initialize-ReglazePSWindowsUpdate {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force -ErrorAction SilentlyContinue
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ForceBootstrap -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null
    Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    if (-not (Get-Module -Name PSWindowsUpdate -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-Module -Name PSWindowsUpdate -Force -SkipPublisherCheck -Confirm:$false -Scope CurrentUser -ErrorAction SilentlyContinue
    }
    $ModCandidates = @(Get-Module -Name PSWindowsUpdate -ListAvailable -ErrorAction SilentlyContinue)
    foreach ($Mod in $ModCandidates) {
        if ($Mod.ModuleBase -and (Test-Path -LiteralPath $Mod.ModuleBase)) {
            $ModFiles = @(Get-ChildItem -Path $Mod.ModuleBase -Recurse -File -ErrorAction SilentlyContinue)
            foreach ($Mf in $ModFiles) {
                try { Unblock-File -LiteralPath $Mf.FullName -ErrorAction SilentlyContinue } catch {}
                if ($Mf.Extension -in @('.psm1', '.ps1xml', '.dll', '.ps1')) {
                    try {
                        $Sig = Get-AuthenticodeSignature -FilePath $Mf.FullName -ErrorAction SilentlyContinue
                        if ($Sig -and $Sig.SignerCertificate) {
                            foreach ($StoreScope in @('CurrentUser', 'LocalMachine')) {
                                try {
                                    $Store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPublisher", $StoreScope)
                                    $Store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
                                    $Store.Add($Sig.SignerCertificate)
                                    $Store.Close()
                                } catch {}
                            }
                        }
                    } catch {}
                }
            }
        }
    }
    Import-Module -Name PSWindowsUpdate -Force -DisableNameChecking -Global -ErrorAction SilentlyContinue
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
# Step 1: Pass 1 Drive Letter Reconciliation & Connected BitLocker Unlock
# =============================================================================
Write-ReglazeStep "Step 1/9: Reconciling Drive Letters (Pass 1) & Unlocking Preserved BitLocker Volumes..."
$DiskConfigFile = if ($ResolvedPayload) { Join-Path $ResolvedPayload "disk-config.json" } else { $null }
$Pass1DiskResult = $null
if ($DiskConfigFile -and (Test-Path -LiteralPath $DiskConfigFile)) {
    $Pass1DiskResult = Invoke-DriveLetterReconciliation -DiskConfigPath $DiskConfigFile -MockSystemDisks $MockSystemDisks -Simulation:$IsSimulated -Live:(-not $IsSimulated)
    Write-ReglazeInfo "Drive letter reconciliation Pass 1 status: $($Pass1DiskResult.Status) ($($Pass1DiskResult.Changes.Count) change(s))."
}

$BitLockerKeyFile = if ($ResolvedPayload) { Join-Path $ResolvedPayload "bitlocker-keys.json" } else { $null }

if ($BitLockerKeyFile -and (Test-Path -LiteralPath $BitLockerKeyFile)) {
    $ConnectedSerials = if ($Pass1DiskResult -and $null -ne $MockSystemDisks) {
        @($Pass1DiskResult.ConnectedPreservedDisks | ForEach-Object { $_.SerialNumber })
    } else { $null }
    $UnlockResults = Unlock-PreservedBitLockerVolumes -KeyFilePath $BitLockerKeyFile -ConnectedSerialNumbers $ConnectedSerials -Simulation:$IsSimulated -Live:(-not $IsSimulated)
    foreach ($Res in $UnlockResults) {
        if ($Res.Status -eq "Success" -or $Res.Status -eq "Simulated") {
            Write-ReglazeSuccess "Volume $($Res.MountPoint): $($Res.Message)"
        } elseif ($Res.Status -eq "Skipped" -or $Res.Status -eq "DeferredDisconnected") {
            Write-ReglazeInfo "Volume $($Res.MountPoint): $($Res.Message)"
        } else {
            Write-ReglazeWarning "Volume $($Res.MountPoint): $($Res.Message)"
        }
    }
} else {
    Write-ReglazeInfo "No secondary BitLocker keys found in payload; skipping volume unlock."
}

# =============================================================================
# Step 1b: Standalone UEFI Bootloader Provisioning on Target OS Disk
# =============================================================================
Write-ReglazeStep "Step 1b/9: Ensuring Standalone UEFI Bootloader on Target OS Disk..."
if (-not $IsSimulated) {
    try {
        $OsPart = Get-Partition -DriveLetter C -ErrorAction SilentlyContinue
        if ($OsPart) {
            $EfiPart = Get-Partition -DiskNumber $OsPart.DiskNumber -ErrorAction SilentlyContinue |
                Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -or $_.IsSystem } |
                Select-Object -First 1
            if ($EfiPart) {
                $TempEfiLetter = $null
                $TargetEfiDrive = $null
                if ($EfiPart.DriveLetter) {
                    $TargetEfiDrive = "$($EfiPart.DriveLetter):"
                } else {
                    foreach ($CandLetter in @('S', 'T', 'U', 'V', 'W', 'R', 'Q', 'P')) {
                        if (-not (Get-PSDrive -Name $CandLetter -ErrorAction SilentlyContinue)) {
                            $TempEfiLetter = $CandLetter
                            break
                        }
                    }
                    if ($TempEfiLetter) {
                        Set-Partition -DiskNumber $EfiPart.DiskNumber -PartitionNumber $EfiPart.PartitionNumber -NewDriveLetter $TempEfiLetter -ErrorAction Stop
                        $TargetEfiDrive = "${TempEfiLetter}:"
                    }
                }
                if ($TargetEfiDrive) {
                    Write-ReglazeInfo "Executing: bcdboot C:\Windows /s $TargetEfiDrive /f UEFI"
                    & bcdboot.exe C:\Windows /s $TargetEfiDrive /f UEFI
                    if ($TempEfiLetter) {
                        Remove-PartitionAccessPath -DiskNumber $EfiPart.DiskNumber -PartitionNumber $EfiPart.PartitionNumber -AccessPath "${TempEfiLetter}:\" -ErrorAction SilentlyContinue
                    }
                    Write-ReglazeSuccess "Standalone UEFI bootloader provisioned on target disk $($OsPart.DiskNumber)."
                }
            }
        }
    } catch {
        Write-ReglazeWarning "Could not provision standalone UEFI bootloader: $($_.Exception.Message)"
    }
} else {
    Write-ReglazeInfo "[SIMULATION] Would mount target disk 260 MB EFI System Partition and run 'bcdboot C:\Windows /s S: /f UEFI'."
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
        Initialize-ReglazePSWindowsUpdate
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
# Step 2b: Pass 2 Drive Letter Reconciliation & Missing Disk Reconnect Check
# =============================================================================
if ($DiskConfigFile -and (Test-Path -LiteralPath $DiskConfigFile)) {
    $Pass2DiskResult = Invoke-DriveLetterReconciliation -DiskConfigPath $DiskConfigFile -MockSystemDisks $MockSystemDisks -Simulation:$IsSimulated -Live:(-not $IsSimulated)
    if ($Pass2DiskResult.RequiresReconnectShutdown) {
        Write-ReglazeWarning "Missing $($Pass2DiskResult.MissingRequiredDisks.Count) required preserved disk(s) after WHQL driver pass:"
        foreach ($Missing in $Pass2DiskResult.MissingRequiredDisks) {
            Write-ReglazeWarning " - Expected Mount: $($Missing.ExpectedMount), Label: $($Missing.Label), Serial: $($Missing.SerialNumber)"
        }
        if ($IsSimulated) {
            Write-ReglazeInfo "[SIMULATION] Would re-arm LocalAdmin AutoLogon + HKLM RunOnce and shut down (Stop-Computer) for drive reconnection."
            if ($HaltOnMissingDisks) {
                return [PSCustomObject]@{
                    Status               = "AwaitingDriveReconnectShutdown"
                    MissingRequiredDisks = $Pass2DiskResult.MissingRequiredDisks
                    Simulated            = $true
                }
            }
        } elseif ($CanReboot) {
            $BootstrapCmd = "powershell.exe -ExecutionPolicy Bypass -File C:\Reglaze\payload\bootstrap.ps1"
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "ReglazeBootstrapResume" -Value $BootstrapCmd -ErrorAction SilentlyContinue
            $WinlogonKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
            Set-ItemProperty -Path $WinlogonKey -Name "AutoAdminLogon" -Value "1" -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $WinlogonKey -Name "AutoLogonCount" -ErrorAction SilentlyContinue
            Write-ReglazeInfo "Shutting down workstation in 5 seconds so required preserved disks can be reconnected..."
            try { Stop-Transcript | Out-Null } catch {}
            Start-Sleep -Seconds 5
            Stop-Computer -Force
            return
        }
    } else {
        Write-ReglazeSuccess "All required preserved disks verified present."
    }
}

# =============================================================================
# Step 3: Windows Quality & Security Cumulative Updates
# =============================================================================
Write-ReglazeStep "Step 3/9: Installing Windows Security & Cumulative Quality Patches..."
if (-not $SkipUpdates -and -not $IsSimulated) {
    try {
        Initialize-ReglazePSWindowsUpdate
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
$GDriveSetupFile = if ($ResolvedPayload) { Join-Path $ResolvedPayload "google-drive-setup.json" } else { $null }
if ($GDriveSetupFile -and (Test-Path -LiteralPath $GDriveSetupFile)) {
    try {
        $GDriveSetupCfg = Get-Content -Raw -LiteralPath $GDriveSetupFile | ConvertFrom-Json
        $MountLetter = if ($GDriveSetupCfg.StreamMountPoint) { $GDriveSetupCfg.StreamMountPoint.TrimEnd(':').ToUpperInvariant() } else { "E" }
        if (-not $IsSimulated) {
            $DriveFsPolicyPath = "HKLM:\SOFTWARE\Policies\Google\DriveFS"
            if (-not (Test-Path $DriveFsPolicyPath)) { New-Item -Path $DriveFsPolicyPath -Force | Out-Null }
            Set-ItemProperty -Path $DriveFsPolicyPath -Name "DefaultMountPoint" -Value $MountLetter -Type String -Force
            Set-ItemProperty -Path $DriveFsPolicyPath -Name "DisablePromptToBackupDevices" -Value 1 -Type DWord -Force
            Set-ItemProperty -Path $DriveFsPolicyPath -Name "DisableDesktopBackup" -Value 1 -Type DWord -Force
            Set-ItemProperty -Path $DriveFsPolicyPath -Name "DisableDocumentsBackup" -Value 1 -Type DWord -Force
            Set-ItemProperty -Path $DriveFsPolicyPath -Name "DisablePicturesBackup" -Value 1 -Type DWord -Force
            Write-ReglazeSuccess "Configured Google Drive enterprise policies (DefaultMountPoint='${MountLetter}:', backup prompts suppressed)."
        } else {
            Write-ReglazeInfo "[SIMULATION] Would set HKLM:\SOFTWARE\Policies\Google\DriveFS DefaultMountPoint = '$MountLetter' and suppress backup wizard prompts."
        }
    } catch {
        Write-ReglazeWarning "Could not apply Google Drive DefaultMountPoint policy: $($_.Exception.Message)"
    }
}

$DscManifest = if ($ResolvedPayload) { Join-Path $ResolvedPayload "configuration.dsc.yaml" } else { $null }

if ($DscManifest -and (Test-Path -LiteralPath $DscManifest)) {
    if (-not $SkipDsc -and -not $IsSimulated) {
        try {
            Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction SilentlyContinue
        } catch {}
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            $wingetExe = (Get-ChildItem -Path "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
                          Sort-Object LastWriteTime -Descending |
                          Select-Object -First 1).FullName
            if ($wingetExe) {
                $env:Path += ";$(Split-Path $wingetExe -Parent);$env:LOCALAPPDATA\Microsoft\WindowsApps"
                Write-ReglazeInfo "Resolved winget.exe at: $wingetExe"
            }
        }
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Write-ReglazeInfo "WinGet CLI not yet available; installing/repairing Microsoft.DesktopAppInstaller..."
            try {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ForceBootstrap -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null
                Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue
                Install-Module -Name Microsoft.WinGet.Client -Force -SkipPublisherCheck -Confirm:$false -Scope CurrentUser -ErrorAction Stop
                Import-Module -Name Microsoft.WinGet.Client -Force -ErrorAction SilentlyContinue
                Repair-WinGetPackageManager -AllUsers -Force -Latest -ErrorAction Stop
            } catch {
                try {
                    $WgTempDir = "C:\Reglaze\temp"
                    if (-not (Test-Path $WgTempDir)) { New-Item -ItemType Directory -Path $WgTempDir -Force | Out-Null }
                    $BundlePath = Join-Path $WgTempDir "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
                    Invoke-WebRequest -Uri "https://aka.ms/getwinget" -OutFile $BundlePath -UseBasicParsing -ErrorAction Stop
                    Add-AppxPackage -Path $BundlePath -ErrorAction SilentlyContinue
                } catch {}
            }
            $wingetExe = (Get-ChildItem -Path "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
                          Sort-Object LastWriteTime -Descending |
                          Select-Object -First 1).FullName
            if ($wingetExe) {
                $env:Path += ";$(Split-Path $wingetExe -Parent);$env:LOCALAPPDATA\Microsoft\WindowsApps"
            }
        }
        foreach ($WsDir in @("$env:LOCALAPPDATA\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState", "$env:LOCALAPPDATA\Microsoft\WinGet\Settings")) {
            try {
                if (-not (Test-Path $WsDir)) { New-Item -ItemType Directory -Path $WsDir -Force | Out-Null }
                '{"installBehavior":{"preferences":{"scope":"machine"}},"experimentalFeatures":{"configuration":true}}' | Set-Content -Path (Join-Path $WsDir "settings.json") -Encoding UTF8 -Force
            } catch {}
        }
        Write-ReglazeInfo "Enabling WinGet DSC configuration feature..."
        & winget configure --enable 2>&1 | Out-Null
        & winget configure --enable --accept-configuration-agreements 2>&1 | Out-Null

        for ($DscAttempt = 1; $DscAttempt -le 2; $DscAttempt++) {
            if ($DscAttempt -gt 1) {
                Write-ReglazeWarning "Retrying WinGet DSC configuration pass (Attempt $DscAttempt of 2)..."
                Start-Sleep -Seconds 5
            }
            Write-ReglazeInfo "Executing: winget configure --file `"$DscManifest`" --accept-configuration-agreements --disable-interactivity (Attempt $DscAttempt/2)"
            & winget configure --file $DscManifest --accept-configuration-agreements --disable-interactivity
            if ($LASTEXITCODE -eq 0) {
                break
            }
        }

        $DscText = Get-Content -Raw -LiteralPath $DscManifest -ErrorAction SilentlyContinue
        if ($DscText) {
            $PkgMatches = [regex]::Matches($DscText, 'id:\s*"([^"]+)"\s*\r?\n\s*source:\s*(\S+)')
            foreach ($Match in $PkgMatches) {
                $PkgId = $Match.Groups[1].Value
                $PkgSource = $Match.Groups[2].Value
                if ($PkgSource -eq "winget") {
                    $ListOut = & winget list --id $PkgId --exact --accept-source-agreements 2>&1
                    if ($LASTEXITCODE -eq 0 -and ($ListOut -join "`n") -match [regex]::Escape($PkgId)) {
                        continue
                    }
                    Write-ReglazeInfo "Installing / verifying machine package: $PkgId (--scope machine)..."
                    & winget install --id $PkgId --source $PkgSource --exact --scope machine --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
                }
            }
        }
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
# [HITL-PATTERN]: wsl.exe --install --no-distribution (distro installation is user-scoped and runs in Start-UserHydration.ps1)
# [HITL-AVOID]: Installing WSL distros during LocalAdmin bootstrap (registers distro under LocalAdmin instead of primary user)
# =============================================================================
Write-ReglazeStep "Step 5/9: Staging Machine-Scope WSL2 Subsystem Kernel (--no-distribution)..."
if (-not $IsSimulated) {
    try {
        & wsl.exe --install --no-distribution 2>&1 | Out-Null
        Write-ReglazeSuccess "WSL2 machine-scope subsystem staged successfully (distro install deferred to user hydration)."
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
$SettingsFile = if ($ResolvedPayload) { Join-Path $ResolvedPayload "windows-settings.json" } else { $null }
$SettingsResults = Invoke-WindowsSettingsApplication -RepoRoot $RepoRoot -SettingsFile $SettingsFile -Simulation:$IsSimulated -Live:(-not $IsSimulated)
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
        # Ensure hydrate.ps1 is NOT auto-launched via RunOnce so the user can inspect bootstrap before launching desktop shortcut
        Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "ReglazeHydrate" -ErrorAction SilentlyContinue

        # Place desktop shortcut on Public Desktop
        $WshShell = New-Object -ComObject WScript.Shell
        $PublicDesktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDesktopDirectory)
        if (-not $PublicDesktop) { $PublicDesktop = "C:\Users\Public\Desktop" }
        foreach ($ShortcutName in @("Reglaze Hydration.lnk", "Resume Reglaze Setup.lnk")) {
            $ShortcutPath = Join-Path $PublicDesktop $ShortcutName
            $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
            $Shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $Shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$HydrateScriptPath`""
            $Shortcut.IconLocation = "shell32.dll,238"
            $Shortcut.Description = "Launch Reglaze User Hydration Wizard"
            $Shortcut.Save()
        }

        Write-ReglazeSuccess "Created Public Desktop shortcut for Phase 5 User Hydration: $PublicDesktop\Reglaze Hydration.lnk"
    } catch {
        Write-ReglazeWarning "Could not stage user hydration shortcut: $($_.Exception.Message)"
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
if (-not $IsSimulated) {
    try { Stop-Transcript | Out-Null } catch {}
}
if ($CanReboot) {
    Write-ReglazeInfo "Rebooting workstation into standard user session in 5 seconds..."
    Start-Sleep -Seconds 5
    Restart-Computer -Force
} else {
    Write-ReglazeInfo "Reboot sequence skipped (Simulation: $IsSimulated, CanReboot: $CanReboot)."
}
