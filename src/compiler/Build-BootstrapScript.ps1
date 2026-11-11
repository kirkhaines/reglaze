<#
.SYNOPSIS
    Generates Phase 4 Machine Bootstrap scripts (bootstrap.ps1 and bootstrap-helpers.ps1) for Reglaze.
.DESCRIPTION
    Modularizes the generated Phase 4 payload into:
    - bootstrap.ps1: Top-level step orchestrator with explicit dependency & ordering documentation
      and idempotent state checkpointing (C:\Reglaze\bootstrap-state.json).
    - bootstrap-helpers.ps1: Called subscript containing the implementation mechanics for UEFI
      bootloader provisioning, PSWindowsUpdate certificate/module initialization, WinGet CLI
      bootstrap & DSC execution, deferred user package queuing, machine directory junctions,
      deferred junction ACL grants, and machine-scope Windows settings.
#>
[CmdletBinding()]
param()

function Build-ReglazeBootstrapScripts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Blueprint,

        [Parameter(Mandatory=$true)]
        [string]$PayloadDir,

        [Parameter(Mandatory=$true)]
        [string]$StreamMountPoint,

        [Parameter(Mandatory=$true)]
        [string]$StreamDriveLetter,

        [Parameter(Mandatory=$true)]
        [string]$PrimaryUser
    )

    $UpdatesDrivers = if ($Blueprint.system.updates -and $null -ne $Blueprint.system.updates.drivers) { [bool]$Blueprint.system.updates.drivers } else { $true }
    $UpdatesWindows = if ($Blueprint.system.updates -and $null -ne $Blueprint.system.updates.windows_updates) { [bool]$Blueprint.system.updates.windows_updates } else { $true }
    $LocalAdminUser = if ($Blueprint.system.users.local_admin.username) { $Blueprint.system.users.local_admin.username } else { "LocalAdmin" }
    $PrimaryIsAdmin = if ($Blueprint.system -and $Blueprint.system.users -and $Blueprint.system.users.primary_user -and $null -ne $Blueprint.system.users.primary_user.is_admin) { [bool]$Blueprint.system.users.primary_user.is_admin } else { $false }
    $PrimaryGroup = if ($PrimaryIsAdmin) { "Administrators" } else { "Users" }

    # =========================================================================
    # 1. Generate Helper Subscript: bootstrap-helpers.ps1
    # =========================================================================
    $BootstrapHelpersScript = @"
<#
.SYNOPSIS
    Reglaze Phase 4 Machine Bootstrap Helper Subscript (bootstrap-helpers.ps1).
.DESCRIPTION
    Contains the mechanical worker functions called by bootstrap.ps1 during elevated
    LocalAdmin provisioning:
    - Initialize-PSWindowsUpdate: Bootstraps NuGet, installs PSWindowsUpdate, trusts its
      Authenticode publisher certificate in TrustedPublisher, and imports it globally.
    - Invoke-StandaloneEfiBootloader: Ensures the target OS disk (C:) has a self-contained
      UEFI bootloader on its 260 MB EFI System Partition via bcdboot.exe.
    - Resolve-WinGetBinary / Initialize-WinGetEnvironment: Registers AppInstaller, resolves
      winget.exe, repairs/downloads the MSIX bundle if absent on fresh bare-metal installs,
      and configures machine-scope WinGet settings.
    - Add-DeferredUserPackage: Queues packages that reject machine/admin context into
      user-packages.json so Phase 5 hydrate.ps1 installs them in the primary user session.
    - Invoke-WinGetDscProvisioning: Executes winget configure against configuration.dsc.yaml
      and verifies each machine-scope package, including foundational Browser & Password Manager
      packages needed early in Phase 5.
    - Invoke-MachineJunctionsAndPermissions: Creates machine-scope junctions (C:\ProgramData,
      C:\Program Files*) and grants BUILTIN\Users modify permissions on parent folders of
      deferred Phase 5 junctions (e.g. Steam\userdata) so the non-admin user can link them.
    - Invoke-MachineWindowsSettings: Applies strictly machine-scoped Windows settings (Power,
      Hardware GPU Scheduling, PnP Cameras, Network/Firewall/hosts, and HKLM Start Menu policy).
#>
[CmdletBinding()]
param()

function Initialize-PSWindowsUpdate {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ForceBootstrap -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null
    Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    if (-not (Get-Module -Name PSWindowsUpdate -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-Module -Name PSWindowsUpdate -Force -SkipPublisherCheck -Confirm:`$false -Scope CurrentUser -ErrorAction SilentlyContinue
    }
    # Trust the PSWindowsUpdate Authenticode publisher certificate and unblock module files so Import-Module never prompts for untrusted publisher
    `$ModCandidates = @(Get-Module -Name PSWindowsUpdate -ListAvailable -ErrorAction SilentlyContinue)
    foreach (`$Mod in `$ModCandidates) {
        if (`$Mod.ModuleBase -and (Test-Path -LiteralPath `$Mod.ModuleBase)) {
            `$ModFiles = @(Get-ChildItem -Path `$Mod.ModuleBase -Recurse -File -ErrorAction SilentlyContinue)
            foreach (`$Mf in `$ModFiles) {
                try { Unblock-File -LiteralPath `$Mf.FullName -ErrorAction SilentlyContinue } catch {}
                if (`$Mf.Extension -in @('.psm1', '.ps1xml', '.dll', '.ps1')) {
                    try {
                        `$Sig = Get-AuthenticodeSignature -FilePath `$Mf.FullName -ErrorAction SilentlyContinue
                        if (`$Sig -and `$Sig.SignerCertificate) {
                            foreach (`$StoreScope in @('CurrentUser', 'LocalMachine')) {
                                try {
                                    `$Store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPublisher", `$StoreScope)
                                    `$Store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
                                    `$Store.Add(`$Sig.SignerCertificate)
                                    `$Store.Close()
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

function Invoke-StandaloneEfiBootloader {
    try {
        `$OsPart = Get-Partition -DriveLetter C -ErrorAction SilentlyContinue
        if (`$OsPart) {
            `$EfiPart = Get-Partition -DiskNumber `$OsPart.DiskNumber -ErrorAction SilentlyContinue |
                Where-Object { `$_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -or `$_.IsSystem } |
                Select-Object -First 1
            if (`$EfiPart) {
                `$TempEfiLetter = `$null
                `$TargetEfiDrive = `$null
                if (`$EfiPart.DriveLetter) {
                    `$TargetEfiDrive = "`$(`$EfiPart.DriveLetter):"
                } else {
                    foreach (`$CandLetter in @('S', 'T', 'U', 'V', 'W', 'R', 'Q', 'P')) {
                        if (-not (Get-PSDrive -Name `$CandLetter -ErrorAction SilentlyContinue)) {
                            `$TempEfiLetter = `$CandLetter
                            break
                        }
                    }
                    if (`$TempEfiLetter) {
                        Set-Partition -DiskNumber `$EfiPart.DiskNumber -PartitionNumber `$EfiPart.PartitionNumber -NewDriveLetter `$TempEfiLetter -ErrorAction Stop
                        `$TargetEfiDrive = "`${TempEfiLetter}:"
                    }
                }
                if (`$TargetEfiDrive) {
                    Write-Host " - Running bcdboot C:\Windows /s `$TargetEfiDrive /f UEFI (Disk `$(`$OsPart.DiskNumber), Partition `$(`$EfiPart.PartitionNumber))..."
                    & bcdboot.exe C:\Windows /s `$TargetEfiDrive /f UEFI
                    if (`$TempEfiLetter) {
                        Remove-PartitionAccessPath -DiskNumber `$EfiPart.DiskNumber -PartitionNumber `$EfiPart.PartitionNumber -AccessPath "`${TempEfiLetter}:\" -ErrorAction SilentlyContinue
                    }
                    Write-Host "   Standalone UEFI bootloader provisioned on target disk." -ForegroundColor Green
                }
            } else {
                Write-Warning "   No EFI System Partition detected on OS Disk `$(`$OsPart.DiskNumber); skipping bcdboot."
            }
        }
    } catch {
        Write-Warning "   Could not provision standalone UEFI bootloader: `$(`$_.Exception.Message)"
    }
}

function Resolve-WinGetBinary {
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction SilentlyContinue
    } catch {}
    `$wingetExe = (Get-ChildItem -Path "`$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending |
                  Select-Object -First 1).FullName
    if (`$wingetExe) {
        `$wgDir = Split-Path `$wingetExe -Parent
        if (`$env:Path -notlike "*`$wgDir*") {
            `$env:Path += ";`$wgDir;`$env:LOCALAPPDATA\Microsoft\WindowsApps"
        }
    } elseif (`$env:Path -notlike "*`$env:LOCALAPPDATA\Microsoft\WindowsApps*") {
        `$env:Path += ";`$env:LOCALAPPDATA\Microsoft\WindowsApps"
    }
    return (Get-Command winget -ErrorAction SilentlyContinue)
}

function Initialize-WinGetEnvironment {
    `$WingetCmd = Resolve-WinGetBinary
    if (-not `$WingetCmd) {
        Write-Host " - WinGet CLI not yet available on fresh OS; installing/repairing Microsoft.DesktopAppInstaller..." -ForegroundColor Yellow
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        try {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ForceBootstrap -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null
            Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            Install-Module -Name Microsoft.WinGet.Client -Force -SkipPublisherCheck -Confirm:`$false -Scope CurrentUser -ErrorAction Stop
            Import-Module -Name Microsoft.WinGet.Client -Force -ErrorAction SilentlyContinue
            Repair-WinGetPackageManager -AllUsers -Force -Latest -ErrorAction Stop
        } catch {
            Write-Host "   Repair-WinGetPackageManager fallback: downloading official WinGet MSIX bundle (https://aka.ms/getwinget)..." -ForegroundColor DarkCyan
            try {
                `$WgTempDir = "C:\Reglaze\temp"
                if (-not (Test-Path `$WgTempDir)) { New-Item -ItemType Directory -Path `$WgTempDir -Force | Out-Null }
                `$VcLibsPath = Join-Path `$WgTempDir "Microsoft.VCLibs.x64.14.00.Desktop.appx"
                `$UiXamlPath = Join-Path `$WgTempDir "Microsoft.UI.Xaml.2.8.x64.appx"
                `$BundlePath = Join-Path `$WgTempDir "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
                Invoke-WebRequest -Uri "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx" -OutFile `$VcLibsPath -UseBasicParsing -ErrorAction SilentlyContinue
                Invoke-WebRequest -Uri "https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx" -OutFile `$UiXamlPath -UseBasicParsing -ErrorAction SilentlyContinue
                Invoke-WebRequest -Uri "https://aka.ms/getwinget" -OutFile `$BundlePath -UseBasicParsing -ErrorAction Stop
                if (Test-Path `$VcLibsPath) { Add-AppxPackage -Path `$VcLibsPath -ErrorAction SilentlyContinue }
                if (Test-Path `$UiXamlPath) { Add-AppxPackage -Path `$UiXamlPath -ErrorAction SilentlyContinue }
                if (Test-Path `$BundlePath) {
                    Add-AppxPackage -Path `$BundlePath -ErrorAction SilentlyContinue
                    `$Deps = @(`$VcLibsPath, `$UiXamlPath) | Where-Object { Test-Path `$_ }
                    Add-AppxProvisionedPackage -Online -PackagePath `$BundlePath -DependencyPackagePath `$Deps -SkipLicense -ErrorAction SilentlyContinue | Out-Null
                }
            } catch {
                Write-Warning "   Could not download/install WinGet MSIX bundle: `$(`$_.Exception.Message)"
            }
        }
        `$WingetCmd = Resolve-WinGetBinary
    }

    # Enforce machine-wide installer preference and enable DSC configuration in WinGet settings
    foreach (`$WsDir in @("`$env:LOCALAPPDATA\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState", "`$env:LOCALAPPDATA\Microsoft\WinGet\Settings")) {
        try {
            if (-not (Test-Path `$WsDir)) { New-Item -ItemType Directory -Path `$WsDir -Force | Out-Null }
            '{"installBehavior":{"preferences":{"scope":"machine"}},"experimentalFeatures":{"configuration":true,"configuration03":true}}' | Set-Content -Path (Join-Path `$WsDir "settings.json") -Encoding UTF8 -Force
        } catch {}
    }

    if (`$WingetCmd) {
        Write-Host " - WinGet CLI ready at: `$(`$WingetCmd.Source)" -ForegroundColor Green
        return `$WingetCmd.Source
    }
    Write-Warning " - WinGet CLI could not be resolved; package installations may be skipped."
    return "winget"
}

function Add-DeferredUserPackage ([string]`$PackageId, [string]`$Source = "winget", [string]`$UserPackagesFile) {
    if (-not `$UserPackagesFile) {
        `$UserPackagesFile = Join-Path `$PSScriptRoot "user-packages.json"
    }
    `$ExistingList = @()
    if (Test-Path `$UserPackagesFile) {
        try {
            `$RawJson = Get-Content -Raw -LiteralPath `$UserPackagesFile | ConvertFrom-Json
            if (`$RawJson) { `$ExistingList = @(`$RawJson) }
        } catch {}
    }
    if (-not (`$ExistingList | Where-Object { `$_.PackageId -ieq `$PackageId })) {
        `$ExistingList += [PSCustomObject]@{
            AppId     = `$PackageId
            AppName   = `$PackageId
            PackageId = `$PackageId
            Source    = `$Source
            Scope     = "user"
        }
        `$OutJson = ConvertTo-Json -InputObject @(`$ExistingList) -Depth 4
        `$OutJson | Set-Content -Path `$UserPackagesFile -Encoding UTF8 -Force
    }
}

function Invoke-WinGetDscProvisioning ([string]`$PayloadDir) {
    `$winget = Initialize-WinGetEnvironment
    `$UserPackagesFile = Join-Path `$PayloadDir "user-packages.json"
    `$DscManifest = Join-Path `$PayloadDir "configuration.dsc.yaml"

    if (Test-Path `$DscManifest) {
        Write-Host "Enabling WinGet DSC configuration feature..." -ForegroundColor Yellow
        & `$winget configure --enable
        & `$winget configure --enable --accept-configuration-agreements

        for (`$DscAttempt = 1; `$DscAttempt -le 2; `$DscAttempt++) {
            if (`$DscAttempt -gt 1) {
                Write-Host "   Retrying WinGet DSC configuration pass (Attempt `$DscAttempt of 2)..." -ForegroundColor Yellow
                Start-Sleep -Seconds 5
            }
            Write-Host " - Running: winget configure --file ``"`$DscManifest``" --accept-configuration-agreements --disable-interactivity (Attempt `$DscAttempt/2)"
            & `$winget configure --file "`$DscManifest" --accept-configuration-agreements --disable-interactivity
            if (`$LASTEXITCODE -eq 0) {
                break
            }
        }

        # Verify each machine package; never fall back to user scope under LocalAdmin
        `$DscText = Get-Content -Raw -LiteralPath `$DscManifest -ErrorAction SilentlyContinue
        if (`$DscText) {
            `$PkgMatches = [regex]::Matches(`$DscText, 'id:\s*"([^"]+)"\s*\r?\n\s*source:\s*(\S+)')
            foreach (`$Match in `$PkgMatches) {
                `$PkgId = `$Match.Groups[1].Value
                `$PkgSource = `$Match.Groups[2].Value
                if (`$PkgSource -eq "winget" -or `$PkgSource -eq "msstore") {
                    `$ListOut = & `$winget list --id `$PkgId --exact --accept-source-agreements 2>&1
                    if (`$LASTEXITCODE -eq 0 -and (`$ListOut -join "`n") -match [regex]::Escape(`$PkgId)) {
                        Write-Host " - [OK] Machine package verified installed: `$PkgId" -ForegroundColor Green
                        continue
                    }

                    Write-Host " - Installing machine-wide package: `$PkgId (--scope machine)..."
                    & `$winget install --id `$PkgId --source `$PkgSource --scope machine --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
                    # 0 = Installed, -1978335189 (0x8A15002B) = Already installed / no applicable update
                    if (`$LASTEXITCODE -eq 0 -or `$LASTEXITCODE -eq -1978335189) {
                        Write-Host "   [+] Installed machine package: `$PkgId" -ForegroundColor Green
                    } elseif (`$LASTEXITCODE -eq -1978335216 -or `$LASTEXITCODE -eq -1978335146) {
                        # Do NOT fall back to user scope under LocalAdmin; queue for hydrate.ps1 inside primary user session
                        Write-Host "   [DEFERRED] Package `$PkgId lacks a dedicated machine-scope installer or refuses admin context (exit `$LASTEXITCODE); queuing to user-packages.json for user hydration." -ForegroundColor Yellow
                        Add-DeferredUserPackage -PackageId `$PkgId -Source `$PkgSource -UserPackagesFile `$UserPackagesFile
                    } else {
                        Write-Warning "   Package `$PkgId returned exit code `$LASTEXITCODE; queuing to user-packages.json for retry during user hydration."
                        Add-DeferredUserPackage -PackageId `$PkgId -Source `$PkgSource -UserPackagesFile `$UserPackagesFile
                    }
                }
            }
        }
        Write-Host "   WinGet DSC deployment pass completed." -ForegroundColor Green
    } else {
        Write-Warning "   WinGet DSC configuration manifest not found at `$DscManifest."
    }
}

function Invoke-MachineJunctionsAndPermissions ([string]`$PayloadDir) {
    `$JunctionsManifest = Join-Path `$PayloadDir "junctions-manifest.json"
    if (-not (Test-Path `$JunctionsManifest)) { return }

    `$Junctions = @(Get-Content -Raw `$JunctionsManifest | ConvertFrom-Json)
    foreach (`$Junc in `$Junctions) {
        if (`$Junc.Scope -eq "machine") {
            `$Link = `$Junc.Link
            `$Target = `$Junc.Target
            `$IsFile = (`$Junc.ItemType -eq "file")
            Write-Host " - Link: `$Link -> `$Target"
            if (`$IsFile) {
                `$TargetFile = if (Test-Path -LiteralPath `$Target -PathType Container) {
                    Join-Path `$Target (Split-Path `$Link -Leaf)
                } elseif (`$Target.EndsWith((Split-Path `$Link -Leaf), [System.StringComparison]::OrdinalIgnoreCase)) {
                    `$Target
                } else {
                    Join-Path `$Target (Split-Path `$Link -Leaf)
                }
                `$TargetParent = Split-Path -Parent `$TargetFile
                if (`$TargetParent -and -not (Test-Path -LiteralPath `$TargetParent)) {
                    New-Item -ItemType Directory -Path `$TargetParent -Force | Out-Null
                }
            } else {
                if (-not (Test-Path -LiteralPath `$Target)) {
                    New-Item -ItemType Directory -Path `$Target -Force | Out-Null
                }
            }
            if (Test-Path `$Link) {
                `$Item = Get-Item `$Link -Force
                if (-not (`$Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    `$BackupPath = "`$Link.bak_`$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                    Move-Item -Path `$Link -Destination `$BackupPath -Force
                    Write-Host "   Collision detected: Backed up existing to `$BackupPath." -ForegroundColor Yellow
                } else {
                    Remove-Item -Path `$Link -Force
                }
            }
            `$ParentDir = Split-Path -Parent `$Link
            if (-not (Test-Path `$ParentDir)) { New-Item -ItemType Directory -Path `$ParentDir -Force | Out-Null }
            if (`$IsFile) {
                cmd.exe /c "mklink ``"`$Link``" ``"`$TargetFile``"" | Out-Null
            } else {
                cmd.exe /c "mklink /J ``"`$Link``" ``"`$Target``"" | Out-Null
            }
        } elseif (`$Junc.Scope -eq "user" -and `$Junc.RequiresElevation -eq `$true) {
            # Grant BUILTIN\Users modify permissions on parent folders under C:\Program Files* or C:\ProgramData*
            # so non-admin user hydration (hydrate.ps1 Step 9) can link deferred junctions (e.g. Steam\userdata).
            try {
                `$DeferredParent = Split-Path -Parent `$Junc.Link
                if (`$DeferredParent -and -not (Test-Path -LiteralPath `$DeferredParent)) {
                    New-Item -ItemType Directory -Path `$DeferredParent -Force -ErrorAction SilentlyContinue | Out-Null
                }
                if (`$DeferredParent -and (Test-Path -LiteralPath `$DeferredParent)) {
                    & icacls.exe `$DeferredParent /grant "*S-1-5-32-545:(OI)(CI)M" /T /C /Q 2>&1 | Out-Null
                    Write-Host " - Granted BUILTIN\Users modify ACL on '`$DeferredParent' for deferred Phase 5 junction." -ForegroundColor DarkCyan
                }
            } catch {}
        }
    }
}

function Invoke-MachineWindowsSettings ([string]`$PayloadDir) {
    `$WinSettingsFile = Join-Path `$PayloadDir "windows-settings.json"
    `$WinScriptsDir = Join-Path `$PayloadDir "windows"
    if (-not (Test-Path `$WinSettingsFile)) { return }

    try {
        `$WinCfg = Get-Content -Raw `$WinSettingsFile | ConvertFrom-Json

        # 1. Machine-Scope Power & Ergonomics (PowerPlan, AC timeouts, HKLM LongPathsEnabled, ssh-agent service)
        `$PwrScript = Join-Path `$WinScriptsDir "performance-power.ps1"
        if (Test-Path `$PwrScript) {
            `$Plan = (`$WinCfg.power.active_scheme_name -replace '\s+', '')
            `$AcDisp = if (`$null -ne `$WinCfg.power.ac_display_minutes) { [int]`$WinCfg.power.ac_display_minutes } else { 30 }
            `$LongPaths = if (`$WinCfg.system_ergonomics -and `$null -ne `$WinCfg.system_ergonomics.long_paths_enabled) { [bool]`$WinCfg.system_ergonomics.long_paths_enabled } else { `$null }
            `$SshStartup = if (`$WinCfg.system_ergonomics -and `$WinCfg.system_ergonomics.ssh_agent_startup) { [string]`$WinCfg.system_ergonomics.ssh_agent_startup } else { `$null }
            & `$PwrScript -Scope "Machine" -PowerPlan `$Plan -AcSleepTimeoutMinutes ([int]`$WinCfg.power.ac_sleep_minutes) -AcDisplayTimeoutMinutes `$AcDisp -LongPathsEnabled `$LongPaths -SshAgentStartup `$SshStartup
        }

        # 2. Machine-Scope Audio/Display Hardware (PnP DisabledCameras & HKLM HardwareGpuScheduling)
        `$AudioScript = Join-Path `$WinScriptsDir "audio-display.ps1"
        if ((Test-Path `$AudioScript) -and (`$WinCfg.audio_and_devices -or `$WinCfg.audio_and_display -or `$WinCfg.display)) {
            `$AudDev = if (`$WinCfg.audio_and_devices) { `$WinCfg.audio_and_devices } else { `$WinCfg.audio_and_display }
            `$DispCfg = if (`$WinCfg.display) { `$WinCfg.display } else { `$WinCfg.audio_and_display }
            `$HwGpu = if (`$DispCfg -and `$null -ne `$DispCfg.hardware_gpu_scheduling) { [bool]`$DispCfg.hardware_gpu_scheduling } else { `$true }
            `$DisCams = if (`$AudDev -and `$AudDev.disabled_cameras) { @(`$AudDev.disabled_cameras) } else { @() }
            & `$AudioScript -Scope "Machine" -DisabledCameras `$DisCams -HardwareGpuScheduling:`$HwGpu
        }

        # 3. Machine-Scope Network, Sharing, Adapters, Hosts & Firewall Rules
        `$NetScript = Join-Path `$WinScriptsDir "network-firewall.ps1"
        if ((Test-Path `$NetScript) -and `$WinCfg.network) {
            & `$NetScript -SharingWizardEnabled:([bool]`$WinCfg.network.sharing_wizard_enabled) -NetworkCategory `$WinCfg.network.network_category -NetworkDiscoveryEnabled:([bool]`$WinCfg.network.network_discovery_enabled) -FileAndPrinterSharingEnabled:([bool]`$WinCfg.network.file_and_printer_sharing_enabled) -PasswordProtectedSharing:([bool]`$WinCfg.network.password_protected_sharing) -Adapters @(`$WinCfg.network.adapters) -HostsEntries @(`$WinCfg.network.hosts_entries) -FirewallRules @(`$WinCfg.network.firewall_rules)
        }

        # 4. Machine-Scope Start Menu Pins Policy (HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start)
        `$ShellPinsScript = Join-Path `$WinScriptsDir "shell-pins.ps1"
        if ((Test-Path `$ShellPinsScript) -and `$WinCfg.start_menu -and `$WinCfg.start_menu.pinned_apps) {
            & `$ShellPinsScript -StartMenuPinnedApps @(`$WinCfg.start_menu.pinned_apps)
        }

        Write-Host "   Machine-level Windows preferences applied successfully." -ForegroundColor Green
    } catch {
        Write-Warning "   Could not apply machine-level Windows preferences: `$(`$_.Exception.Message)"
    }
}
"@

    $BootstrapHelpersPath = Join-Path $PayloadDir "bootstrap-helpers.ps1"
    $BootstrapHelpersScript | Set-Content -Path $BootstrapHelpersPath -Encoding UTF8

    # =========================================================================
    # 2. Generate Top-Level Orchestrator: bootstrap.ps1
    # =========================================================================
    $BootstrapScript = @"
<#
.SYNOPSIS
    Reglaze Phase 4 Machine Bootstrap Runner (bootstrap.ps1).
.DESCRIPTION
    Executes automatically under the temporary elevated LocalAdmin account upon first
    post-install boot. Delegates mechanical helpers to bootstrap-helpers.ps1 and enforces
    strict step-by-step dependency ordering:

    STEP ORDERING & DEPENDENCY CHAIN:
      [Step 1]  Pass 1 Drive Letter Reconciliation & Connected BitLocker Unlock
                -> MUST run first so preserved drives (D:, F:) are mounted at their canonical
                   letters and the USB installer is moved off reserved letters (e.g. E:) before
                   any paths are referenced.
      [Step 1b] Standalone UEFI Bootloader Provisioning (bcdboot)
                -> Ensures the target OS disk's 260 MB EFI System Partition has a self-contained
                   UEFI bootloader even if Windows Setup reused an existing EFI partition on a
                   secondary drive.
      [Step 2]  Automated WHQL Hardware Driver Servicing (PSWindowsUpdate)
                -> MUST run before Pass 2 disk reconciliation, network config, and GPU settings
                   so storage controllers, NICs, and display adapters are enumerated by Windows.
      [Step 2b] Pass 2 Drive Letter Reconciliation & Missing Disk Reconnect Check
                -> Verifies all required preserved disks are online after storage drivers load;
                   if any were physically unplugged during WinPE for safety, re-arms LocalAdmin
                   AutoLogon + RunOnce and powers down cleanly for drive reconnection.
      [Step 3]  General Windows Security & Quality Cumulative Updates
                -> Patches the base OS prior to WinGet DSC and WSL2 kernel installation.
      [Step 4]  Google Drive Enterprise Policy & WinGet DSC Machine Application Provisioning
                -> Sets HKLM DriveFS DefaultMountPoint and backup suppression BEFORE Google Drive
                   is installed; provisions machine-scope apps (including Default Browser & Password
                   Manager needed for Phase 5 authentication bootstrap). Apps that reject machine
                   or admin context are queued to user-packages.json for Phase 5.
      [Step 5]  Machine-Scope WSL2 Subsystem Kernel Staging (wsl --install --no-distribution)
                -> Installs only the machine-wide WSL2 kernel/platform. Linux distributions are
                   registered per-user (HKCU) and MUST be deferred to Phase 5 (hydrate.ps1).
      [Step 6]  Machine-Scope Directory Junctions & Deferred Junction ACL Grants
                -> Links C:\ProgramData and C:\Program Files* paths whose targets reside on
                   preserved local drives, and grants BUILTIN\Users modify permissions on parent
                   folders of deferred Phase 5 junctions (e.g. Steam\userdata).
      [Step 7]  Machine-Scope Windows System Settings
                -> Applies only HKLM/system settings (Power, LongPathsEnabled, ssh-agent, PnP
                   cameras, Hardware GPU Scheduling, Network/Firewall, Start Menu HKLM policy).
                   User-specific HKCU settings and User Shell Folders are strictly deferred to
                   Phase 5 so C:\Users\$PrimaryUser is never pre-created before first login.
      [Step 8]  Primary User Account Verification & AutoLogon Credential Purge
                -> Ensures '$PrimaryUser' exists and purges LocalAdmin AutoLogon credentials.
      [Step 9]  Stage Phase 5 User Hydration Desktop Shortcut & Reboot
                -> Places 'Reglaze Hydration.lnk' on the Public Desktop (without RunOnce
                   auto-launch) and reboots to the standard user login screen.
#>
[CmdletBinding()]
param()

`$ErrorActionPreference = "Continue"
`$ReglazeRoot = "C:\Reglaze"
if (-not (Test-Path `$ReglazeRoot)) {
    New-Item -ItemType Directory -Path `$ReglazeRoot -Force | Out-Null
}
# Grant Modify permissions on C:\Reglaze to BUILTIN\Users (S-1-5-32-545) so standard user hydration can write logs and checkpoints
try {
    & icacls.exe `$ReglazeRoot /grant "*S-1-5-32-545:(OI)(CI)M" /T /C /Q 2>&1 | Out-Null
} catch {}

# Enable Developer Mode for unprivileged symbolic links and set RemoteSigned policy for standard users
try {
    `$DevRegPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
    if (-not (Test-Path `$DevRegPath)) { New-Item -Path `$DevRegPath -Force | Out-Null }
    Set-ItemProperty -Path `$DevRegPath -Name "AllowDevelopmentWithoutDevLicense" -Value 1 -Type DWord -Force
    Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy RemoteSigned -Force -ErrorAction SilentlyContinue
} catch {}
`$TranscriptFile = "C:\Reglaze\bootstrap.log"
try {
    Start-Transcript -Path `$TranscriptFile -Append -Force | Out-Null
} catch {}

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "               REGLAZE PHASE 4: MACHINE BOOTSTRAP RUNNER                       " -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "Transcript log: `$TranscriptFile" -ForegroundColor DarkGray

`$PayloadDir = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$StateFile = "C:\Reglaze\bootstrap-state.json"
`$DiskConfigFile = Join-Path `$PayloadDir "disk-config.json"
`$BitLockerKeyFile = Join-Path `$PayloadDir "bitlocker-keys.json"
`$DriveLetterScript = Join-Path `$PayloadDir "Set-ReglazeDriveLetters.ps1"
`$BitLockerScript = Join-Path `$PayloadDir "Unlock-BitLockerVolumes.ps1"
`$BootstrapHelpers = Join-Path `$PayloadDir "bootstrap-helpers.ps1"

if (Test-Path `$DriveLetterScript) { . `$DriveLetterScript }
if (Test-Path `$BitLockerScript) { . `$BitLockerScript }
if (Test-Path `$BootstrapHelpers) { . `$BootstrapHelpers }

`$BootstrapState = [PSCustomObject]@{
    CompletedSteps = @()
    StartedAt      = (Get-Date).ToString("o")
}
if (Test-Path `$StateFile) {
    try {
        `$BootstrapState = Get-Content -Raw `$StateFile | ConvertFrom-Json
        if (-not `$BootstrapState.CompletedSteps) { `$BootstrapState.CompletedSteps = @() }
        Write-Host "Resumed Phase 4 bootstrap state. Completed steps: `$(`$BootstrapState.CompletedSteps -join ', ')" -ForegroundColor DarkCyan
    } catch {}
}

function Save-BootstrapStep ([string]`$StepName) {
    if (`$BootstrapState.CompletedSteps -notcontains `$StepName) {
        `$BootstrapState.CompletedSteps += `$StepName
    }
    `$StateDir = Split-Path -Parent `$StateFile
    if (-not (Test-Path `$StateDir)) { New-Item -ItemType Directory -Path `$StateDir -Force | Out-Null }
    `$BootstrapState | ConvertTo-Json -Depth 4 | Set-Content -Path `$StateFile -Encoding UTF8
}

# =============================================================================
# [1/9] Pass 1 Drive Letter Reconciliation & Connected BitLocker Unlock
# DEPENDENCY: Must run FIRST before any step references preserved drive letters
# (D:, F:) or reserved cloud mount letters ($StreamMountPoint).
# =============================================================================
Write-Host "[1/9] Reconciling drive letters (Pass 1) and unlocking connected BitLocker volumes..." -ForegroundColor Yellow
`$Pass1Disks = `$null
if (Get-Command Invoke-DriveLetterReconciliation -ErrorAction SilentlyContinue) {
    `$Pass1Disks = Invoke-DriveLetterReconciliation -DiskConfigPath `$DiskConfigFile -Simulation:`$false -Live:`$true
}
if ((Test-Path `$BitLockerKeyFile) -and (Get-Command Unlock-PreservedBitLockerVolumes -ErrorAction SilentlyContinue)) {
    `$ConnectedSerials = if (`$Pass1Disks -and `$Pass1Disks.ConnectedPreservedDisks) {
        @(`$Pass1Disks.ConnectedPreservedDisks | ForEach-Object { `$_.SerialNumber })
    } else { `$null }
    Unlock-PreservedBitLockerVolumes -KeyFilePath `$BitLockerKeyFile -ConnectedSerialNumbers `$ConnectedSerials -Simulation:`$false -Live:`$true | Out-Null
}
Save-BootstrapStep "pass1_disks_and_bitlocker"

# =============================================================================
# [1b/9] Standalone UEFI Bootloader Provisioning on Target OS Disk
# DEPENDENCY: Ensures the target OS disk (C:) can boot standalone from its own
# 260 MB EFI System Partition.
# =============================================================================
if (`$BootstrapState.CompletedSteps -notcontains "efi_bootloader") {
    Write-Host "[1b/9] Ensuring standalone UEFI bootloader on target OS disk EFI partition..." -ForegroundColor Yellow
    Invoke-StandaloneEfiBootloader
    Save-BootstrapStep "efi_bootloader"
}

# =============================================================================
# [2/9] Automated WHQL Driver Updates (Chipset, Storage, Audio, Network, GPU)
# DEPENDENCY: Must run BEFORE Pass 2 disk verification (Step 2b) and hardware/network
# settings (Step 7) so all storage controllers, NICs, and GPUs are online.
# =============================================================================
if (`$BootstrapState.CompletedSteps -notcontains "whql_drivers") {
    if (`$$($UpdatesDrivers.ToString().ToLower())) {
        Write-Host "[2/9] Running automated WHQL driver servicing pass..." -ForegroundColor Yellow
        try {
            Initialize-PSWindowsUpdate
            Write-Host " - Scanning and installing WHQL device drivers..."
            Get-WindowsUpdate -Category "Drivers" -Install -AcceptAll -IgnoreReboot -ErrorAction SilentlyContinue
            Write-Host "   WHQL driver pass completed." -ForegroundColor Green
        } catch {
            Write-Warning "   Driver update pass encountered an issue: `$(`$_.Exception.Message). Continuing installation."
        }
    } else {
        Write-Host "[2/9] Automated driver servicing pass skipped by configuration." -ForegroundColor DarkGray
    }
    Save-BootstrapStep "whql_drivers"
}

# =============================================================================
# [2b/9] Pass 2 Drive Letter Reconciliation & Missing Disk Reconnect Check
# DEPENDENCY: Runs AFTER WHQL storage drivers load; must verify all required
# preserved disks are connected before machine junctions (Step 6) are created.
# =============================================================================
Write-Host "[2b/9] Verifying required preserved disks and reconciling drive letters (Pass 2)..." -ForegroundColor Yellow
if (Get-Command Invoke-DriveLetterReconciliation -ErrorAction SilentlyContinue) {
    `$Pass2Disks = Invoke-DriveLetterReconciliation -DiskConfigPath `$DiskConfigFile -Simulation:`$false -Live:`$true
    while (`$Pass2Disks.RequiresReconnectShutdown) {
        Write-Host ""
        Write-Host "================================================================================" -ForegroundColor Yellow
        Write-Host "  ACTION REQUIRED: PRESERVED DRIVE(S) DISCONNECTED" -ForegroundColor Yellow
        Write-Host "================================================================================" -ForegroundColor Yellow
        Write-Host "The following preserved disk(s) are required by your configuration:" -ForegroundColor White
        foreach (`$Missing in `$Pass2Disks.MissingRequiredDisks) {
            Write-Host "  - Expected Mount: `$(`$Missing.ExpectedMount) | Label: `$(`$Missing.Label) | Serial: `$(`$Missing.SerialNumber)" -ForegroundColor Cyan
        }
        Write-Host ""
        Write-Host "Options:"
        Write-Host "  [P] Power down (shut down) now so you can safely reconnect SATA/NVMe drives (Recommended)"
        Write-Host "      (Reglaze will automatically log back in and resume Phase 4 when powered on)"
        Write-Host "  [R] Re-scan storage bus now (if you just connected an external/hot-plug drive)"
        Write-Host "  [C] Continue without missing drives (not recommended)"
        `$Choice = Read-Host "Select an option [P/R/C] (default: P)"
        if ([string]::IsNullOrWhiteSpace(`$Choice) -or `$Choice -match '^[Pp]') {
            `$BootstrapCmd = "powershell.exe -ExecutionPolicy Bypass -File ``"C:\Reglaze\payload\bootstrap.ps1``""
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "ReglazeBootstrapResume" -Value `$BootstrapCmd -ErrorAction SilentlyContinue
            `$WinlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
            Set-ItemProperty -Path `$WinlogonPath -Name "AutoAdminLogon" -Value "1" -ErrorAction SilentlyContinue
            Set-ItemProperty -Path `$WinlogonPath -Name "DefaultUserName" -Value "$LocalAdminUser" -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path `$WinlogonPath -Name "AutoLogonCount" -ErrorAction SilentlyContinue
            Save-BootstrapStep "awaiting_drive_reconnect"
            Write-Host "Shutting down workstation for drive reconnection..." -ForegroundColor Yellow
            try { Stop-Transcript | Out-Null } catch {}
            Start-Sleep -Seconds 3
            Stop-Computer -Force
            exit 0
        } elseif (`$Choice -match '^[Rr]') {
            Update-HostStorageCache -ErrorAction SilentlyContinue
            `$Pass2Disks = Invoke-DriveLetterReconciliation -DiskConfigPath `$DiskConfigFile -Simulation:`$false -Live:`$true
        } else {
            Write-Warning "Proceeding without missing required disks by user override."
            break
        }
    }

    if ((Test-Path `$BitLockerKeyFile) -and (Get-Command Unlock-PreservedBitLockerVolumes -ErrorAction SilentlyContinue)) {
        Unlock-PreservedBitLockerVolumes -KeyFilePath `$BitLockerKeyFile -Simulation:`$false -Live:`$true | Out-Null
    }
}
Save-BootstrapStep "pass2_disks_verified"

# =============================================================================
# [3/9] General Windows Quality and Security Updates
# DEPENDENCY: Applies cumulative OS patches before WinGet DSC & WSL2 staging.
# =============================================================================
if (`$BootstrapState.CompletedSteps -notcontains "windows_updates") {
    if (`$$($UpdatesWindows.ToString().ToLower())) {
        Write-Host "[3/9] Running general Windows update pass..." -ForegroundColor Yellow
        try {
            Initialize-PSWindowsUpdate
            Write-Host " - Installing quality and security patches..."
            Get-WindowsUpdate -NotCategory "Drivers" -Install -AcceptAll -IgnoreReboot -ErrorAction SilentlyContinue
            Write-Host "   General Windows update pass completed." -ForegroundColor Green
        } catch {
            Write-Warning "   Windows update pass encountered an issue: `$(`$_.Exception.Message). Continuing installation."
        }
    } else {
        Write-Host "[3/9] General Windows updates skipped by configuration." -ForegroundColor DarkGray
    }
    Save-BootstrapStep "windows_updates"
}

# =============================================================================
# [4/9] Google Drive Enterprise Policy & WinGet DSC Machine Application Provisioning
# DEPENDENCY:
#   1. HKLM DriveFS policy MUST be written before Google Drive is installed/launched so
#      it mounts at '$StreamMountPoint' and suppresses Desktop/Documents backup prompts.
#   2. Machine-scope applications (including Browser & Password Manager prerequisites for
#      Phase 5 authentication bootstrap) are installed system-wide before machine junctions
#      (Step 6) are linked. Packages requiring user scope are deferred to user-packages.json.
# =============================================================================
Write-Host "[4/9] Configuring Google Drive streaming & backup suppression policies ($StreamMountPoint) and running WinGet DSC..." -ForegroundColor Yellow
try {
    `$DrivePolicyPath = "HKLM:\SOFTWARE\Policies\Google\DriveFS"
    New-Item -Path `$DrivePolicyPath -Force | Out-Null
    Set-ItemProperty -Path `$DrivePolicyPath -Name "DefaultMountPoint" -Value "$StreamDriveLetter" -Type String -Force
    Set-ItemProperty -Path `$DrivePolicyPath -Name "DisablePromptToBackupDevices" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path `$DrivePolicyPath -Name "DisableDesktopBackup" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path `$DrivePolicyPath -Name "DisableDocumentsBackup" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path `$DrivePolicyPath -Name "DisablePicturesBackup" -Value 1 -Type DWord -Force
    Write-Host " - Configured DriveFS DefaultMountPoint ('${StreamDriveLetter}:') and backup suppression policies." -ForegroundColor Green
} catch {
    Write-Warning "   Could not set DriveFS policies: `$(`$_.Exception.Message)"
}

Invoke-WinGetDscProvisioning -PayloadDir `$PayloadDir
Save-BootstrapStep "winget_dsc"

# =============================================================================
# [5/9] Stage Machine-Scope WSL2 Subsystem Kernel (--no-distribution)
# DEPENDENCY: Only the machine-wide WSL2 kernel/platform is installed here under
# LocalAdmin. Linux distributions are registered per-user in HKCU and MUST be
# installed in Phase 5 (hydrate.ps1 Step 10) under '$PrimaryUser'.
# =============================================================================
Write-Host "[5/9] Staging machine-scope WSL2 subsystem kernel (--no-distribution)..." -ForegroundColor Yellow
try {
    & wsl.exe --install --no-distribution
    Write-Host "   WSL2 subsystem kernel staged successfully (distro installation deferred to user hydration)." -ForegroundColor Green
} catch {
    Write-Warning "   WSL2 staging returned: `$(`$_.Exception.Message)"
}
Save-BootstrapStep "wsl_staged"

# =============================================================================
# [6/9] Create Machine-Level Directory Junctions & Grant Deferred Junction ACLs
# DEPENDENCY: Runs AFTER preserved drives are verified (Step 2b) and machine apps
# are installed (Step 4). Also grants BUILTIN\Users modify permissions on parent
# folders of deferred Phase 5 junctions (e.g. Steam\userdata) so '$PrimaryUser'
# can create them without elevation in Phase 5.
# =============================================================================
Write-Host "[6/9] Creating machine-level directory junctions..." -ForegroundColor Yellow
Invoke-MachineJunctionsAndPermissions -PayloadDir `$PayloadDir
Save-BootstrapStep "machine_junctions"

# =============================================================================
# [7/9] Apply Machine-Scope System Preferences (Power, Hardware, Network & Start Policy)
# DEPENDENCY: Runs AFTER WHQL drivers (Step 2). Only machine-wide HKLM/system settings
# are applied here; user-specific HKCU settings and User Shell Folders are deferred to
# hydrate.ps1 so C:\Users\$PrimaryUser is never pre-created before first login.
# =============================================================================
Write-Host "[7/9] Applying machine-level power, audio/display hardware, and network preferences..." -ForegroundColor Yellow
Invoke-MachineWindowsSettings -PayloadDir `$PayloadDir
Save-BootstrapStep "machine_settings"

# =============================================================================
# [8/9] Ensure Primary User Account Exists & Purge AutoLogon Credentials
# DEPENDENCY: Must run AFTER all reboots/resumes of LocalAdmin are complete so
# the workstation boots to the standard login screen for '$PrimaryUser'.
# =============================================================================
Write-Host "Ensuring primary user account '$PrimaryUser' exists..." -ForegroundColor Yellow
if (-not (Get-LocalUser -Name "$PrimaryUser" -ErrorAction SilentlyContinue)) {
    try {
        New-LocalUser -Name "$PrimaryUser" -NoPassword -Description "Reglaze Standard Daily Driver" -FullName "$PrimaryUser" | Out-Null
        Add-LocalGroupMember -Group "$PrimaryGroup" -Member "$PrimaryUser" -ErrorAction SilentlyContinue
        Write-Host "   Created primary user '$PrimaryUser' (Group: $PrimaryGroup)." -ForegroundColor Green
    } catch {
        Write-Warning "   Could not create primary user '$PrimaryUser': `$(`$_.Exception.Message)"
    }
}

Write-Host "[8/9] Destroying temporary LocalAdmin AutoLogon credentials..." -ForegroundColor Yellow
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "DefaultPassword" -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "AutoAdminLogon" -Value "0" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "ReglazeBootstrapResume" -ErrorAction SilentlyContinue
Write-Host "   AutoLogon deactivated." -ForegroundColor Green

# =============================================================================
# [9/9] Stage Phase 5 Hydration Desktop Shortcut & Reboot into User Session
# DEPENDENCY: Places 'Reglaze Hydration.lnk' on C:\Users\Public\Desktop so it
# appears on '$PrimaryUser''s desktop upon first sign-in. Does NOT register in
# RunOnce so the user can sign in and launch hydration when ready.
# =============================================================================
Write-Host "[9/9] Staging Phase 5 User Hydration desktop shortcut..." -ForegroundColor Yellow
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "ReglazeHydrate" -ErrorAction SilentlyContinue

try {
    `$WshShell = New-Object -ComObject WScript.Shell
    `$ShortcutPath = "C:\Users\Public\Desktop\Reglaze Hydration.lnk"
    `$Shortcut = `$WshShell.CreateShortcut(`$ShortcutPath)
    `$Shortcut.TargetPath = "`$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    `$Shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -NoExit -File ``"C:\Reglaze\payload\hydrate.ps1``""
    `$Shortcut.IconLocation = "shell32.dll,238"
    `$Shortcut.Description = "Launch Reglaze User Hydration Wizard"
    `$Shortcut.Save()
    Write-Host "   Created desktop shortcut: `$ShortcutPath" -ForegroundColor Green
} catch {
    Write-Warning "   Could not create public desktop shortcut: `$(`$_.Exception.Message)"
}

Save-BootstrapStep "completed"
Write-Host ""
Write-Host "================================================================================" -ForegroundColor Green
Write-Host "   PHASE 4 MACHINE BOOTSTRAP COMPLETE! REBOOTING INTO USER SESSION...           " -ForegroundColor Green
Write-Host "================================================================================" -ForegroundColor Green
try { Stop-Transcript | Out-Null } catch {}
Start-Sleep -Seconds 3
Restart-Computer -Force
"@

    $BootstrapPath = Join-Path $PayloadDir "bootstrap.ps1"
    $BootstrapScript | Set-Content -Path $BootstrapPath -Encoding UTF8

    return [PSCustomObject]@{
        BootstrapPath        = $BootstrapPath
        BootstrapHelpersPath = $BootstrapHelpersPath
    }
}

