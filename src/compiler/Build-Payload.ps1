<#
.SYNOPSIS
    Payload artifact generator and assembler for Reglaze.
.DESCRIPTION
    Compiles and generates the complete media payload directory:
    - bitlocker-keys.json: Extracted BitLocker recovery keys for secondary/preserved volumes
    - junctions-manifest.json: Pre-computed junction mapping table with collision backup rules
    - bootstrap.ps1: Phase 4 machine script running under LocalAdmin (BitLocker, WHQL drivers, Windows Updates, WinGet DSC, WSL2, RunOnce staging)
    - hydrate.ps1: Phase 5 interactive user hydration script with state checkpoints and HITL steps
    - setup-wsl.sh: Non-interactive WSL2 provisioning script
    - configuration.dsc.yaml: WinGet DSC manifest
    - applications.json: Cached reference catalog
#>
[CmdletBinding()]
param()

$CompilerRoot = $PSScriptRoot
$CommonRoot = Join-Path (Split-Path -Parent $CompilerRoot) "common"
. (Join-Path $CommonRoot "Logging.ps1")
. (Join-Path $CommonRoot "Catalog.ps1")
. (Join-Path $CompilerRoot "Resolve-Variables.ps1")
. (Join-Path $CompilerRoot "Build-WinGetDSC.ps1")

function Build-ReglazePayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Blueprint,

        [Parameter(Mandatory=$false)]
        [PSCustomObject]$AuditReference = $null,

        [Parameter(Mandatory=$false)]
        [string]$RepoRoot = $null,

        [Parameter(Mandatory=$true)]
        [string]$PayloadDir
    )

    if (-not $RepoRoot) {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }

    if (-not (Test-Path $PayloadDir)) {
        New-Item -ItemType Directory -Path $PayloadDir -Force | Out-Null
    }

    # Stage modular Windows settings scripts
    $WindowsDataDir = Join-Path $RepoRoot "data\windows"
    $PayloadWindowsDir = Join-Path $PayloadDir "windows"
    if (Test-Path $WindowsDataDir) {
        if (-not (Test-Path $PayloadWindowsDir)) {
            New-Item -ItemType Directory -Path $PayloadWindowsDir -Force | Out-Null
        }
        Copy-Item -Path (Join-Path $WindowsDataDir "*") -Destination $PayloadWindowsDir -Force
    }

    # Extract & compile Windows settings configuration
    $WinSettings = $null
    if ($Blueprint.windows_settings) {
        $WinSettings = $Blueprint.windows_settings
    } elseif ($Blueprint.system -and $Blueprint.system.windows_settings) {
        $WinSettings = $Blueprint.system.windows_settings
    } elseif ($AuditReference -and $AuditReference.detected_windows_settings) {
        $WinSettings = $AuditReference.detected_windows_settings
    } else {
        $WinSettings = [PSCustomObject]@{
            explorer = [PSCustomObject]@{
                show_hidden_files    = $true
                show_file_extensions = $true
                launch_to            = "ThisPC"
            }
            taskbar = [PSCustomObject]@{
                alignment       = "Left"
                search_mode     = "IconOnly"
                widgets_visible = $false
                chat_visible    = $false
            }
            power = [PSCustomObject]@{
                active_scheme_name = "High Performance"
                ac_sleep_minutes   = 0
            }
        }
    }
    $WinSettingsPath = Join-Path $PayloadDir "windows-settings.json"
    $WinSettings | ConvertTo-Json -Depth 4 | Set-Content -Path $WinSettingsPath -Encoding UTF8

    $VarMap = Get-BlueprintVariables -Blueprint $Blueprint
    $PrimaryUser = if ($Blueprint.system.users.primary_user.username) { $Blueprint.system.users.primary_user.username } else { "User" }

    # Add standard user environment variables to resolution map for pre-computing paths
    $VarMap["USERPROFILE"] = "C:\Users\$PrimaryUser"
    $VarMap["APPDATA"] = "C:\Users\$PrimaryUser\AppData\Roaming"
    $VarMap["LOCALAPPDATA"] = "C:\Users\$PrimaryUser\AppData\Local"
    $VarMap["PROGRAMFILES"] = "C:\Program Files"
    $VarMap["PROGRAMFILES(X86)"] = "C:\Program Files (x86)"
    $VarMap["PROGRAMDATA"] = "C:\ProgramData"

    # =========================================================================
    # 1. Generate WinGet DSC Manifest (configuration.dsc.yaml)
    # =========================================================================
    $DscPath = Join-Path $PayloadDir "configuration.dsc.yaml"
    Build-WinGetDSCManifest -Blueprint $Blueprint -RepoRoot $RepoRoot -OutputPath $DscPath | Out-Null

    # =========================================================================
    # 2. Extract BitLocker Recovery Keys (bitlocker-keys.json)
    # =========================================================================
    $BitLockerEntries = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ($AuditReference -and $AuditReference.bitlocker_recovery_keys) {
        $BKeys = $AuditReference.bitlocker_recovery_keys
        $KeyProps = if ($BKeys -is [System.Collections.IDictionary]) { $BKeys.Keys } else { $BKeys.PSObject.Properties.Name }
        foreach ($Prop in $KeyProps) {
            $VolObj = if ($BKeys -is [System.Collections.IDictionary]) { $BKeys[$Prop] } else { $BKeys.$Prop }
            $Mount = if ($VolObj.MountPoint) { $VolObj.MountPoint } else { $Prop }
            # Skip C: drive since C: is wiped and reinstalled with fresh encryption post-install
            if ($Mount -and $Mount -notlike "C*") {
                $BitLockerEntries.Add([PSCustomObject]@{
                    MountPoint       = $Mount
                    VolumeType       = if ($VolObj.VolumeType) { $VolObj.VolumeType } else { "Data" }
                    RecoveryPassword = $VolObj.RecoveryPassword
                    RecoveryKeyId    = $VolObj.RecoveryKeyId
                })
            }
        }
    }
    $BitLockerPath = Join-Path $PayloadDir "bitlocker-keys.json"
    $BitLockerJson = if ($BitLockerEntries.Count -eq 0) { "[]" } else { $BitLockerEntries | ConvertTo-Json -Depth 4 }
    $BitLockerJson | Set-Content -Path $BitLockerPath -Encoding UTF8

    # =========================================================================
    # 3. Generate Pre-Computed Junctions Manifest (junctions-manifest.json)
    # =========================================================================
    $JunctionsList = [System.Collections.Generic.List[PSCustomObject]]::new()
    $Catalog = Get-ReglazeCatalog -RepoRoot $RepoRoot

    if ($Blueprint.applications) {
        $AppProps = @($Blueprint.applications.PSObject.Properties)
        foreach ($Prop in $AppProps) {
            $AppId = $Prop.Name
            $AppConfig = $Prop.Value
            $CatalogApp = $Catalog | Where-Object { $_.app_id -eq $AppId } | Select-Object -First 1

            if ($CatalogApp -and $CatalogApp.directories) {
                foreach ($Dir in $CatalogApp.directories) {
                    $ConfiguredTarget = $null
                    $ConfiguredLink = $null

                    if ($AppConfig.directories -and $AppConfig.directories.$($Dir.id)) {
                        $DirConf = $AppConfig.directories.$($Dir.id)
                        $ConfiguredTarget = $DirConf.target
                        if ($DirConf.link) { $ConfiguredLink = $DirConf.link }
                    }

                    if (-not $ConfiguredLink) {
                        $ConfiguredLink = $Dir.default_path
                    }

                    if ($ConfiguredTarget) {
                        $ResolvedLink = Resolve-VariableString -InputString $ConfiguredLink -VariableMap $VarMap
                        $ResolvedTarget = Resolve-VariableString -InputString $ConfiguredTarget -VariableMap $VarMap

                        # Determine scope: machine vs user
                        $Scope = "user"
                        if ($ResolvedLink -like "C:\ProgramData*" -or $ResolvedLink -like "C:\Program Files*") {
                            $Scope = "machine"
                        }

                        $StorageType = if ($Dir.recommended_storage) { $Dir.recommended_storage } else { "streaming" }

                        $JunctionsList.Add([PSCustomObject]@{
                            AppId            = $AppId
                            DirectoryId      = $Dir.id
                            Description      = $Dir.description
                            Link             = $ResolvedLink
                            Target           = $ResolvedTarget
                            Scope            = $Scope
                            StorageType      = $StorageType
                            SafeForStream    = [bool]$Dir.safe_for_stream
                            CollisionAction  = "backup"
                        })
                    }
                }
            }
        }
    }

    # Inspect custom directory mappings
    if ($Blueprint.custom -and $Blueprint.custom -is [System.Collections.IEnumerable]) {
        foreach ($CustomApp in $Blueprint.custom) {
            if ($CustomApp.directories) {
                foreach ($CustDir in $CustomApp.directories) {
                    if ($CustDir.link -and $CustDir.target) {
                        $ResolvedLink = Resolve-VariableString -InputString $CustDir.link -VariableMap $VarMap
                        $ResolvedTarget = Resolve-VariableString -InputString $CustDir.target -VariableMap $VarMap
                        $Scope = if ($ResolvedLink -like "C:\ProgramData*" -or $ResolvedLink -like "C:\Program Files*") { "machine" } else { "user" }
                        $StorageType = if ($CustDir.storage_type) { $CustDir.storage_type } else { "streaming" }

                        $JunctionsList.Add([PSCustomObject]@{
                            AppId            = "custom"
                            DirectoryId      = if ($CustDir.name) { ($CustDir.name -replace '[^a-zA-Z0-9_]', '_').ToLower() } else { "custom_dir" }
                            Description      = if ($CustDir.name) { $CustDir.name } else { "Custom Directory Junction" }
                            Link             = $ResolvedLink
                            Target           = $ResolvedTarget
                            Scope            = $Scope
                            StorageType      = $StorageType
                            SafeForStream    = $true
                            CollisionAction  = "backup"
                        })
                    }
                }
            }
        }
    }

    $JunctionsPath = Join-Path $PayloadDir "junctions-manifest.json"
    $JunctionsJson = if ($JunctionsList.Count -eq 0) { "[]" } else { $JunctionsList | ConvertTo-Json -Depth 4 }
    $JunctionsJson | Set-Content -Path $JunctionsPath -Encoding UTF8

    # =========================================================================
    # 4. Generate Machine Bootstrap Runner (bootstrap.ps1)
    # =========================================================================
    $UpdatesDrivers = if ($Blueprint.system.updates -and $null -ne $Blueprint.system.updates.drivers) { [bool]$Blueprint.system.updates.drivers } else { $true }
    $UpdatesWindows = if ($Blueprint.system.updates -and $null -ne $Blueprint.system.updates.windows_updates) { [bool]$Blueprint.system.updates.windows_updates } else { $true }

    $BootstrapScript = @"
<#
.SYNOPSIS
    Reglaze Phase 4 Machine Bootstrap Runner.
.DESCRIPTION
    Executes automatically under LocalAdmin account upon initial post-install boot.
    Configures BitLocker, executes automated WHQL driver updates, applies general
    Windows updates, executes WinGet DSC application provisioning, stages WSL2,
    creates machine-scope directory junctions, destroys auto-logon credentials,
    and stages user hydration in RunOnce.
#>
[CmdletBinding()]
param()

`$ErrorActionPreference = "Continue"
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "               REGLAZE PHASE 4: MACHINE BOOTSTRAP RUNNER                       " -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan

`$PayloadDir = Split-Path -Parent `$MyInvocation.MyCommand.Path

# 1. Unlock & Re-arm Preserved BitLocker Volumes
`$BitLockerKeyFile = Join-Path `$PayloadDir "bitlocker-keys.json"
if (Test-Path `$BitLockerKeyFile) {
    Write-Host "[1/8] Unlocking and re-arming preserved BitLocker volumes..." -ForegroundColor Yellow
    `$BitLockerPayload = Get-Content -Raw `$BitLockerKeyFile | ConvertFrom-Json
    foreach (`$Vol in `$BitLockerPayload) {
        if (`$Vol.MountPoint -and `$Vol.RecoveryPassword) {
            try {
                Write-Host " - Unlocking `$(`$Vol.MountPoint)..."
                Unlock-BitLocker -MountPoint `$Vol.MountPoint -RecoveryPassword `$Vol.RecoveryPassword -ErrorAction Stop
                Enable-BitLockerAutoUnlock -MountPoint `$Vol.MountPoint -ErrorAction SilentlyContinue
                Write-Host "   Successfully unlocked and enabled auto-unlock for `$(`$Vol.MountPoint)." -ForegroundColor Green
            } catch {
                Write-Warning "   Failed to auto-unlock `$(`$Vol.MountPoint): `$(`$_.Exception.Message)"
            }
        }
    }
}

# 2. Automated WHQL Driver Updates (Chipset, Audio, Network, GPU)
if ($($UpdatesDrivers.ToString().ToLower())) {
    Write-Host "[2/8] Running automated WHQL driver servicing pass..." -ForegroundColor Yellow
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null
        Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Install-Module -Name PSWindowsUpdate -Force -Scope CurrentUser -ErrorAction Stop
        Write-Host " - Scanning and installing WHQL device drivers..."
        Get-WindowsUpdate -Category "Drivers" -Install -AcceptAll -IgnoreReboot -ErrorAction SilentlyContinue
        Write-Host "   WHQL driver pass completed." -ForegroundColor Green
    } catch {
        Write-Warning "   Driver update pass encountered an issue: `$(`$_.Exception.Message). Continuing installation."
    }
} else {
    Write-Host "[2/8] Automated driver servicing pass skipped by configuration." -ForegroundColor DarkGray
}

# 3. General Windows Quality and Security Updates
if ($($UpdatesWindows.ToString().ToLower())) {
    Write-Host "[3/8] Running general Windows update pass..." -ForegroundColor Yellow
    try {
        Write-Host " - Installing quality & security patches..."
        Get-WindowsUpdate -NotCategory "Drivers" -Install -AcceptAll -IgnoreReboot -ErrorAction SilentlyContinue
        Write-Host "   General Windows update pass completed." -ForegroundColor Green
    } catch {
        Write-Warning "   Windows update pass encountered an issue: `$(`$_.Exception.Message). Continuing installation."
    }
} else {
    Write-Host "[3/8] General Windows updates skipped by configuration." -ForegroundColor DarkGray
}

# 4. Execute WinGet DSC Configuration (Machine Scope Application Deployment)
Write-Host "[4/8] Executing WinGet DSC application provisioning..." -ForegroundColor Yellow
`$DscManifest = Join-Path `$PayloadDir "configuration.dsc.yaml"
if (Test-Path `$DscManifest) {
    Write-Host " - Running: winget configure --file `"`$DscManifest`" --accept-configuration-agreements --disable-interactivity"
    & winget configure --file `$DscManifest --accept-configuration-agreements --disable-interactivity
    Write-Host "   WinGet DSC deployment pass completed." -ForegroundColor Green
} else {
    Write-Warning "   WinGet DSC configuration manifest not found at `$DscManifest."
}

# 5. Stage WSL2 Base Kernel and Ubuntu Distro
Write-Host "[5/8] Staging WSL2 subsystem and Ubuntu distribution..." -ForegroundColor Yellow
try {
    & wsl.exe --install -d Ubuntu --no-launch
    Write-Host "   WSL2 staged successfully." -ForegroundColor Green
} catch {
    Write-Warning "   WSL2 staging returned: `$(`$_.Exception.Message)"
}

# 6. Create Machine-Level Junctions
Write-Host "[6/8] Creating machine-level directory junctions..." -ForegroundColor Yellow
`$JunctionsManifest = Join-Path `$PayloadDir "junctions-manifest.json"
if (Test-Path `$JunctionsManifest) {
    `$Junctions = Get-Content -Raw `$JunctionsManifest | ConvertFrom-Json
    foreach (`$Junc in `$Junctions) {
        if (`$Junc.Scope -eq "machine") {
            `$Link = `$Junc.Link
            `$Target = `$Junc.Target
            Write-Host " - Junction: `$Link -> `$Target"
            if (-not (Test-Path `$Target)) {
                New-Item -ItemType Directory -Path `$Target -Force | Out-Null
            }
            if (Test-Path `$Link) {
                `$Item = Get-Item `$Link -Force
                if (-not (`$Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    `$BackupPath = "`$Link.bak_`$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                    Move-Item -Path `$Link -Destination `$BackupPath -Force
                    Write-Host "   Collision detected: Backed up existing directory to `$BackupPath." -ForegroundColor Yellow
                } else {
                    Remove-Item -Path `$Link -Force
                }
            }
            `$ParentDir = Split-Path -Parent `$Link
            if (-not (Test-Path `$ParentDir)) { New-Item -ItemType Directory -Path `$ParentDir -Force | Out-Null }
            cmd.exe /c mklink /J "`$Link" "`$Target" | Out-Null
        }
    }
}

# 7. Apply Windows Explorer, Taskbar & Power Preferences
Write-Host "[7/9] Applying Windows system preferences & options..." -ForegroundColor Yellow
`$WinSettingsFile = Join-Path `$PayloadDir "windows-settings.json"
`$WinScriptsDir = Join-Path `$PayloadDir "windows"
if (Test-Path `$WinSettingsFile) {
    try {
        `$WinCfg = Get-Content -Raw `$WinSettingsFile | ConvertFrom-Json
        # Explorer
        `$ExpScript = Join-Path `$WinScriptsDir "explorer-folder-options.ps1"
        if (Test-Path `$ExpScript) {
            & `$ExpScript -ShowHiddenFiles:([bool]`$WinCfg.explorer.show_hidden_files) -ShowFileExtensions:([bool]`$WinCfg.explorer.show_file_extensions) -LaunchTo `$WinCfg.explorer.launch_to
        }
        # Taskbar
        `$TbScript = Join-Path `$WinScriptsDir "taskbar-system-tray.ps1"
        if (Test-Path `$TbScript) {
            & `$TbScript -TaskbarAlignment `$WinCfg.taskbar.alignment -SearchMode `$WinCfg.taskbar.search_mode -HideWidgets:(-not [bool]`$WinCfg.taskbar.widgets_visible) -HideChat:(-not [bool]`$WinCfg.taskbar.chat_visible)
        }
        # Power
        `$PwrScript = Join-Path `$WinScriptsDir "performance-power.ps1"
        if (Test-Path `$PwrScript) {
            `$Plan = (`$WinCfg.power.active_scheme_name -replace '\s+', '')
            & `$PwrScript -PowerPlan `$Plan -AcSleepTimeoutMinutes ([int]`$WinCfg.power.ac_sleep_minutes)
        }
        Write-Host "   Windows preferences applied successfully." -ForegroundColor Green
    } catch {
        Write-Warning "   Could not apply Windows preferences: `$(`$_.Exception.Message)"
    }
}

# 8. Destroy AutoLogon Credentials
Write-Host "[8/9] Destroying temporary LocalAdmin AutoLogon credentials..." -ForegroundColor Yellow
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "DefaultPassword" -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "AutoAdminLogon" -Value "0" -ErrorAction SilentlyContinue
Write-Host "   AutoLogon deactivated." -ForegroundColor Green

# 9. Schedule Phase 5 Hydration on User Logon & Stage Desktop Shortcut
Write-Host "[9/9] Scheduling Phase 5 User Hydration..." -ForegroundColor Yellow
`$HydrateCmd = "powershell.exe -ExecutionPolicy Bypass -File C:\Reglaze\payload\hydrate.ps1"
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "ReglazeHydrate" -Value `$HydrateCmd -ErrorAction SilentlyContinue

# Create shortcut on Public Desktop for easy manual launch/resumption
try {
    `$WshShell = New-Object -ComObject WScript.Shell
    `$ShortcutPath = "C:\Users\Public\Desktop\Reglaze Hydration.lnk"
    `$Shortcut = `$WshShell.CreateShortcut(`$ShortcutPath)
    `$Shortcut.TargetPath = "powershell.exe"
    `$Shortcut.Arguments = "-ExecutionPolicy Bypass -NoExit -File C:\Reglaze\payload\hydrate.ps1"
    `$Shortcut.IconLocation = "shell32.dll,238"
    `$Shortcut.Description = "Resume Reglaze User Hydration Wizard"
    `$Shortcut.Save()
    Write-Host "   Created desktop shortcut: `$ShortcutPath" -ForegroundColor Green
} catch {
    Write-Warning "   Could not create public desktop shortcut: `$(`$_.Exception.Message)"
}

Write-Host ""
Write-Host "================================================================================" -ForegroundColor Green
Write-Host "   PHASE 4 MACHINE BOOTSTRAP COMPLETE! REBOOTING INTO USER SESSION...           " -ForegroundColor Green
Write-Host "================================================================================" -ForegroundColor Green
Start-Sleep -Seconds 3
Restart-Computer -Force
"@

    $BootstrapPath = Join-Path $PayloadDir "bootstrap.ps1"
    $BootstrapScript | Set-Content -Path $BootstrapPath -Encoding UTF8

    # =========================================================================
    # 5. Generate User Hydration Runner (hydrate.ps1) with State Checkpoints
    # =========================================================================
    $StreamSentinel = if ($VarMap.ContainsKey("STREAM")) { $VarMap["STREAM"] } else { "E:\My Drive" }
    $DataDrive = if ($VarMap.ContainsKey("DATA_DRIVE")) { $VarMap["DATA_DRIVE"] } else { "D:" }

    $HydrateScript = @"
<#
.SYNOPSIS
    Reglaze Phase 5 User Hydration & Interactive Wizard.
.DESCRIPTION
    Runs in the primary user session. Manages state persistence via C:\Reglaze\hydrate-state.json
    so users can safely exit and resume at any point. Walks through Microsoft Account sign-in,
    cloud virtual mount verification, Steam library auto-discovery, manual app installations,
    user-scope directory junctions, WSL2 user hydration, and dev repositories.
#>
[CmdletBinding()]
param(
    [switch]`$ResetState = `$false
)

`$ErrorActionPreference = "Continue"
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "            REGLAZE PHASE 5: USER HYDRATION & STATE LINKING WIZARD              " -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan

`$PayloadDir = Split-Path -Parent `$MyInvocation.MyCommand.Path
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

# --- STEP 1: Microsoft Account Connection ---
if (`$State.CompletedSteps -notcontains "microsoft_account") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 1: Microsoft Account Sign-In (Optional)" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "If you wish to link this standard account to your Microsoft Account for store and"
    Write-Host "digital license sync, open Windows Settings -> Accounts -> Your Info."
    `$PromptMSA = Read-Host "Would you like to open Windows Accounts settings now? (y/N)"
    if (`$PromptMSA -match '^[Yy]') {
        Start-Process "ms-settings:yourinfo"
        Write-Host "Settings opened. Complete your sign-in, then return here."
        Read-Host "Press [Enter] when ready to proceed to Step 2..."
    }
    Save-HydrateState "microsoft_account"
} else {
    Write-Host "[✓] Step 1: Microsoft Account (Already completed)" -ForegroundColor DarkGray
}

# --- STEP 2: Cloud Virtual Mount Verification (Google Drive) ---
if (`$State.CompletedSteps -notcontains "cloud_mount") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 2: Sign in to Cloud Storage (Google Drive for Desktop)" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    `$SentinelPath = "$StreamSentinel"
    Write-Host "Directory junctions require your cloud storage virtual stream to be mounted at:"
    Write-Host "  `$SentinelPath" -ForegroundColor Cyan
    Write-Host ""

    # Launch Google Drive client if not running
    if (-not (Get-Process "GoogleDriveFS" -ErrorAction SilentlyContinue)) {
        `$GDFPath = "C:\Program Files\Google\Drive File Stream\launch.bat"
        if (Test-Path `$GDFPath) {
            Start-Process `$GDFPath
        } else {
            Start-Process "powershell.exe" "-Command Start-Process 'shell:AppsFolder\Google.GoogleDrive'" -ErrorAction SilentlyContinue
        }
    }

    Write-Host "Please sign in to Google Drive for Desktop in the browser/client."
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
    Save-HydrateState "cloud_mount"
} else {
    Write-Host "[✓] Step 2: Cloud Storage Mount (Already completed)" -ForegroundColor DarkGray
}

# --- STEP 3: Game Managers & Multi-Library Discovery / Fresh Installs ---
if (`$State.CompletedSteps -notcontains "steam_signin") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 3: Steam Multi-Library Rediscovery & Fresh Game Installs" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    `$SteamExe = "`$env:ProgramFiles(x86)\Steam\steam.exe"

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

    # Inspect games declared in applications catalog or blueprint
    `$CatalogFile = Join-Path `$PayloadDir "applications.json"
    if (Test-Path `$CatalogFile) {
        `$CatApps = Get-Content -Raw `$CatalogFile | ConvertFrom-Json
        `$SteamGames = `$CatApps | Where-Object { `$_.install -and (`$_.install.method -eq "steam" -or `$_.install.steam_id) }
        foreach (`$Game in `$SteamGames) {
            `$SId = `$Game.install.steam_id
            `$GName = if (`$Game.name) { `$Game.name } else { `$Game.app_id }
            if (`$SId) {
                # Check if game is in ANY discovered library
                `$FoundLib = `$null
                foreach (`$Lib in `$DiscoveredLibs) {
                    `$Mf = Join-Path `$Lib "steamapps\appmanifest_`$SId.acf"
                    if (Test-Path `$Mf) {
                        `$FoundLib = `$Lib
                        break
                    }
                }
                if (`$FoundLib) {
                    Write-Host " [✓] Game '`$GName' (`$SId) present in reattached library: `$FoundLib" -ForegroundColor Green
                } else {
                    Write-Host " [+] Game '`$GName' (`$SId) not found in any library. Triggering fresh install..." -ForegroundColor Cyan
                    try {
                        Start-Process "steam://install/`$SId"
                    } catch {
                        Write-Warning "Could not trigger steam://install/`$SId"
                    }
                }
            }
        }
    }
    Save-HydrateState "steam_signin"
} else {
    Write-Host "[✓] Step 3: Steam Multi-Library & Game Provisioning (Already completed)" -ForegroundColor DarkGray
}

# --- STEP 4: Manual Application Installs Walkthrough ---
if (`$State.CompletedSteps -notcontains "manual_installs") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 4: Manual Application Installation Guidance" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    `$CatalogFile = Join-Path `$PayloadDir "applications.json"
    if (Test-Path `$CatalogFile) {
        `$CatApps = Get-Content -Raw `$CatalogFile | ConvertFrom-Json
        `$ManualApps = `$CatApps | Where-Object { `$_.install -and `$_.install.method -eq "manual" }
        if (`$ManualApps) {
            foreach (`$MApp in `$ManualApps) {
                Write-Host ""
                Write-Host "  [Application: `$(`$MApp.name)]" -ForegroundColor Green
                if (`$MApp.website) { Write-Host "   Official URL: `$(`$MApp.website)" }
                if (`$MApp.install.download_url) { Write-Host "   Download:     `$(`$MApp.install.download_url)" }
                if (`$MApp.install.default_target_directory) { Write-Host "   Target Dir:   `$(`$MApp.install.default_target_directory)" }
                if (`$MApp.install.instructions) {
                    Write-Host "   Instructions:"
                    foreach (`$Inst in `$MApp.install.instructions) {
                        Write-Host "    - `$Inst"
                    }
                }
                Read-Host "Press [Enter] when you have completed or skipped `$(`$MApp.name)..."
            }
        } else {
            Write-Host "No manual installation applications detected." -ForegroundColor DarkGray
        }
    }
    Save-HydrateState "manual_installs"
} else {
    Write-Host "[✓] Step 4: Manual Applications (Already completed)" -ForegroundColor DarkGray
}

# --- STEP 5: User-Level Directory Junctions ---
if (`$State.CompletedSteps -notcontains "user_junctions") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 5: Creating User-Level Directory Junctions (AppData, Saves, Configs)" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    `$JunctionsManifest = Join-Path `$PayloadDir "junctions-manifest.json"
    if (Test-Path `$JunctionsManifest) {
        `$Junctions = Get-Content -Raw `$JunctionsManifest | ConvertFrom-Json
        `$UserJuncs = `$Junctions | Where-Object { `$_.Scope -eq "user" }
        Write-Host "Linking `$(`$UserJuncs.Count) user-scope directory junction(s)..."

        foreach (`$Junc in `$UserJuncs) {
            `$Link = `$Junc.Link
            `$Target = `$Junc.Target
            Write-Host " - [`$(`$Junc.AppId)`] `$Link -> `$Target"

            # Ensure cloud target directory exists
            if (-not (Test-Path `$Target)) {
                try {
                    New-Item -ItemType Directory -Path `$Target -Force | Out-Null
                    Write-Host "   Created target folder: `$Target" -ForegroundColor DarkGray
                } catch {
                    Write-Warning "   Could not create target `$Target: `$(`$_.Exception.Message)"
                }
            }

            # Handle existing collision
            if (Test-Path `$Link) {
                `$Item = Get-Item `$Link -Force
                if (-not (`$Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    `$BackupPath = "`$Link.bak_`$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                    try {
                        [System.IO.Directory]::Move(`$Link, `$BackupPath)
                        Write-Host "   Collision: Backed up existing directory to `$BackupPath." -ForegroundColor Yellow
                    } catch {
                        Write-Warning "   Could not backup existing folder `$Link: `$(`$_.Exception.Message)"
                    }
                } else {
                    [System.IO.Directory]::Delete(`$Link)
                }
            }

            # Create Junction
            `$ParentDir = Split-Path -Parent `$Link
            if (-not (Test-Path `$ParentDir)) { New-Item -ItemType Directory -Path `$ParentDir -Force | Out-Null }
            cmd.exe /c mklink /J "`$Link" "`$Target" | Out-Null
        }
        Write-Host "[SUCCESS] All user directory junctions created successfully!" -ForegroundColor Green
    }
    Save-HydrateState "user_junctions"
} else {
    Write-Host "[✓] Step 5: User Junctions (Already completed)" -ForegroundColor DarkGray
}

# --- STEP 6: Non-Interactive WSL2 Setup ---
if (`$State.CompletedSteps -notcontains "wsl_setup") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 6: Non-Interactive WSL2 Subsystem Configuration" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    `$WslScript = Join-Path `$PayloadDir "setup-wsl.sh"
    if (Test-Path `$WslScript) {
        Write-Host "Executing non-interactive setup-wsl.sh inside Ubuntu distro..."
        try {
            & wsl.exe -d Ubuntu -u root -- /bin/bash /mnt/c/Reglaze/payload/setup-wsl.sh
            Write-Host "[SUCCESS] WSL2 environment provisioned!" -ForegroundColor Green
        } catch {
            Write-Warning "WSL setup encountered an error: `$(`$_.Exception.Message)"
        }
    } else {
        Write-Host "No setup-wsl.sh script found; skipping WSL2 customization." -ForegroundColor DarkGray
    }
    Save-HydrateState "wsl_setup"
} else {
    Write-Host "[✓] Step 6: WSL2 Environment (Already completed)" -ForegroundColor DarkGray
}

# --- STEP 7: Developer Repositories & Dotfiles ---
if (`$State.CompletedSteps -notcontains "dev_repos") {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  STEP 7: Developer Repositories & Dotfiles Configuration" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "Verifying chezmoi and git developer repositories..."
    if (Get-Command "chezmoi" -ErrorAction SilentlyContinue) {
        Write-Host "Chezmoi detected. Ready for dotfiles init/apply."
    } else {
        Write-Host "Chezmoi not found in PATH; developer can run 'chezmoi init' when ready." -ForegroundColor DarkGray
    }
    Save-HydrateState "dev_repos"
} else {
    Write-Host "[✓] Step 7: Dev Repositories (Already completed)" -ForegroundColor DarkGray
}

# --- STEP 8: Cleanup and Unregister ---
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
"@

    $HydratePath = Join-Path $PayloadDir "hydrate.ps1"
    $HydrateScript | Set-Content -Path $HydratePath -Encoding UTF8

    $PrimaryUser = if ($Blueprint.system -and $Blueprint.system.users -and $Blueprint.system.users.primary_user -and $Blueprint.system.users.primary_user.username) {
        $Blueprint.system.users.primary_user.username
    } else {
        "User"
    }
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

    # =========================================================================
    # 7. Copy Cached Applications Catalog (applications.json)
    # =========================================================================
    $CatalogJsonPath = Join-Path $PayloadDir "applications.json"
    $Catalog | ConvertTo-Json -Depth 6 | Set-Content -Path $CatalogJsonPath -Encoding UTF8

    return [PSCustomObject]@{
        PayloadDir          = $PayloadDir
        DscPath             = $DscPath
        BitLockerPath       = $BitLockerPath
        JunctionsPath       = $JunctionsPath
        BootstrapPath       = $BootstrapPath
        HydratePath         = $HydratePath
        WslScriptPath       = $WslPath
        CatalogPath         = $CatalogJsonPath
        WindowsSettingsPath = $WinSettingsPath
        JunctionCount       = $JunctionsList.Count
        BitLockerKeyCount   = $BitLockerEntries.Count
    }
}
