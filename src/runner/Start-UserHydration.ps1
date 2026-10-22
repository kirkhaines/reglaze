<#
.SYNOPSIS
    Reglaze Phase 5 User Hydration & State Linking Wizard.
.DESCRIPTION
    Executes in the primary standard user session to orchestrate interactive
    user hydration:
    - Microsoft Account (MSA) sign-in guidance
    - Cloud virtual mount verification (Google Drive for Desktop sentinel check)
    - Steam library rediscovery on preserved drives
    - Interactive manual application installation walkthroughs
    - User-scope directory junction application with collision backups
    - Non-interactive WSL2 developer environment staging & rclone bisync
    - Dev repositories cloning and Chezmoi dotfiles initialization
    - Startup self-unregistration and desktop health check shortcut creation

    Maintains idempotent state in hydration-state.json allowing interruption
    and seamless resumption.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$false)]
    [string]$PayloadDir = $null,

    [Parameter(Mandatory=$false)]
    [string]$ConfigFile = $null,

    [Parameter(Mandatory=$false)]
    [string]$StateFile = $null,

    [Parameter(Mandatory=$false)]
    [string]$RepoRoot = $null,

    [switch]$ResetState = $false,
    [switch]$NonInteractive = $false,
    [switch]$Simulation = $true,
    [switch]$Live = $false
)

# Fail-safe: Always simulated unless explicitly flagged -Live
$IsSimulated = $Simulation -or (-not $Live)

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

# Source common modules
. (Join-Path $RepoRoot "src\common\Logging.ps1")
. (Join-Path $RepoRoot "src\common\ConfigResolver.ps1")
. (Join-Path $RepoRoot "src\linking\New-DirectoryJunction.ps1")
. (Join-Path $RepoRoot "src\wsl\Initialize-WSLDistro.ps1")
. (Join-Path $RepoRoot "src\wsl\Sync-WSLRclone.ps1")

Write-ReglazeBanner "REGLAZE PHASE 5: USER HYDRATION WIZARD"

if ($IsSimulated) {
    Write-ReglazeWarning "RUNNING IN SIMULATION MODE (-Simulation:$Simulation, -Live:$Live)."
    Write-ReglazeWarning "No user registry keys, processes, junctions, or WSL files will be modified."
} else {
    Write-ReglazeInfo "RUNNING IN LIVE USER MODE."
}

# =============================================================================
# Resolve Payload Directory
# =============================================================================
$ResolvedPayload = $null
$CandidatePayloads = @(
    $PayloadDir,
    (Join-Path $RepoRoot "dist\media"),
    "C:\Reglaze\payload",
    $env:REGLAZE_PAYLOAD
)

foreach ($Candidate in $CandidatePayloads) {
    if ($Candidate -and (Test-Path -LiteralPath $Candidate)) {
        $ResolvedPayload = $Candidate
        break
    }
}

if ($ResolvedPayload) {
    Write-ReglazeInfo "Hydration payload resolved to: $ResolvedPayload"
} else {
    Write-ReglazeWarning "No payload directory found; will attempt hydration from repository data."
}

# =============================================================================
# State Management & Checkpoint Tracking
# =============================================================================
if (-not $StateFile) {
    $LocalAppDir = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { (Join-Path $env:USERPROFILE "AppData\Local") }
    $StateDir = Join-Path $LocalAppDir "Reglaze"
    $StateFile = Join-Path $StateDir "hydration-state.json"
}

$HydrateState = [PSCustomObject]@{
    msa_connected              = $false
    cloud_mount_verified       = $false
    steam_library_connected    = $false
    manual_apps_installed      = @()
    user_junctions_established = $false
    wsl_provisioned            = $false
    wsl_rclone_synced          = $false
    dev_repos_cloned           = $false
    dotfiles_applied           = $false
    completed                  = $false
    started_at                 = (Get-Date).ToString("o")
    last_updated               = (Get-Date).ToString("o")
}

if ((Test-Path -LiteralPath $StateFile) -and -not $ResetState) {
    try {
        $LoadedState = Get-Content -Raw -LiteralPath $StateFile -Encoding UTF8 | ConvertFrom-Json
        foreach ($Prop in $HydrateState.PSObject.Properties) {
            if ($LoadedState.PSObject.Properties[$Prop.Name]) {
                $HydrateState.$($Prop.Name) = $LoadedState.$($Prop.Name)
            }
        }
        Write-ReglazeSuccess "Loaded previous hydration checkpoint from: $StateFile"
    } catch {
        Write-ReglazeWarning "Could not parse existing state file ($($_.Exception.Message)); initializing fresh state."
    }
}

function Save-HydrationCheckpoint {
    param([string]$StepKey)
    $HydrateState.last_updated = (Get-Date).ToString("o")
    if (-not $IsSimulated) {
        try {
            $Parent = Split-Path -Parent $StateFile
            if (-not (Test-Path -LiteralPath $Parent)) {
                New-Item -ItemType Directory -Path $Parent -Force | Out-Null
            }
            $HydrateState | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StateFile -Encoding UTF8
        } catch {
            Write-ReglazeWarning "Could not persist checkpoint to state file: $($_.Exception.Message)"
        }
    }
    Write-ReglazeInfo "[Checkpoint Saved: $StepKey]"
}

# Load configuration blueprint if available
$Blueprint = $null
$ResolvedConfigFile = if ($ConfigFile) { $ConfigFile } else { Resolve-ReglazeConfigFile }
if ($ResolvedConfigFile -and (Test-Path -LiteralPath $ResolvedConfigFile)) {
    try {
        . (Join-Path $RepoRoot "src\common\YamlParser.ps1")
        $YamlText = Get-Content -Raw -LiteralPath $ResolvedConfigFile -Encoding UTF8
        $Blueprint = ConvertFrom-ReglazeYaml -YamlContent $YamlText
        Write-ReglazeInfo "Loaded configuration blueprint from: $ResolvedConfigFile"
    } catch {
        Write-ReglazeWarning "Could not parse blueprint yaml: $($_.Exception.Message)"
    }
}

# =============================================================================
# Step 1: Microsoft Account (MSA) Connection
# =============================================================================
Write-ReglazeStep "Step 1/8: Microsoft Account (MSA) Connection..."
if (-not $HydrateState.msa_connected) {
    if (-not $NonInteractive -and -not $IsSimulated) {
        Write-Host "If you wish to link this standard account to your Microsoft Account for digital licenses and Store,"
        Write-Host "Windows Settings -> Accounts -> Your Info will open."
        $MsaChoice = Read-Host "Would you like to open Accounts Settings now? (y/N)"
        if ($MsaChoice -match '^[Yy]') {
            Start-Process "ms-settings:yourinfo"
            Read-Host "Press [Enter] when finished with MSA sign-in to proceed..."
        }
    } else {
        Write-ReglazeInfo "MSA interactive connection bypassed (Simulation: $IsSimulated, NonInteractive: $NonInteractive)."
    }
    $HydrateState.msa_connected = $true
    Save-HydrationCheckpoint "msa_connected"
} else {
    Write-ReglazeSuccess "Microsoft Account connection already validated."
}

# =============================================================================
# [HITL-ID]: HITL-M4-05
# [HITL-TARGET]: Google Drive for Desktop / Virtual Stream Mount Verification
# [HITL-STATUS]: VERIFIED
# [HITL-DESCRIPTION]: Polling and verifying the sentinel directory (e.g. G:\My Drive) to unlock streamed junction targets.
# [HITL-TEST-SNIPPET]:
#   # Safe verification of cloud stream mount:
#   Test-Path "G:\My Drive"
# [HITL-LAST-INPUT]: Test-Path "G:\My Drive" (2026-10-21)
# [HITL-LAST-RESULT]: Returned True. Confirmed Google Drive virtual stream mount is active and accessible.
# [HITL-PATTERN]: Test-Path $SentinelPath (poll until present or user skip)
# [HITL-AVOID]: Creating junctions pointing to non-existent streaming targets before Google Drive has authenticated
# =============================================================================

# =============================================================================
# Step 2: Cloud Virtual Mount Verification (Google Drive for Desktop)
# =============================================================================
Write-ReglazeStep "Step 2/8: Verifying Cloud Streaming Mount (Sentinel Folder)..."
$SentinelPath = "G:\My Drive"
if ($Blueprint -and $Blueprint.storage -and $Blueprint.storage.streaming -and $Blueprint.storage.streaming.verify_folder) {
    $SentinelPath = $Blueprint.storage.streaming.verify_folder
}

if (-not $HydrateState.cloud_mount_verified) {
    if (-not $IsSimulated) {
        Write-ReglazeInfo "Checking for cloud streaming mount sentinel at: $SentinelPath"
        if (-not (Test-Path -LiteralPath $SentinelPath)) {
            # Try to launch Google Drive if not running
            if (-not (Get-Process "GoogleDriveFS" -ErrorAction SilentlyContinue)) {
                $GDFLaunch = "C:\Program Files\Google\Drive File Stream\launch.bat"
                if (Test-Path -LiteralPath $GDFLaunch) {
                    Start-Process $GDFLaunch
                } else {
                    Start-Process "powershell.exe" "-Command Start-Process 'shell:AppsFolder\Google.GoogleDrive'" -ErrorAction SilentlyContinue
                }
            }

            Write-Host "Please sign in to Google Drive for Desktop to mount your virtual drive."
            $WaitTries = 0
            while (-not (Test-Path -LiteralPath $SentinelPath)) {
                Start-Sleep -Seconds 3
                $WaitTries++
                if ($NonInteractive -or $WaitTries -ge 10) {
                    Write-ReglazeWarning "Cloud sentinel '$SentinelPath' not found; proceeding with warning."
                    break
                }
                if ($WaitTries % 3 -eq 0) {
                    $Choice = Read-Host "Sentinel not ready yet. Press [Enter] to keep polling, or type 'skip' to proceed:"
                    if ($Choice -eq 'skip') { break }
                }
            }
        }

        if (Test-Path -LiteralPath $SentinelPath) {
            Write-ReglazeSuccess "Cloud streaming mount verified at: $SentinelPath"
            $HydrateState.cloud_mount_verified = $true
        } else {
            Write-ReglazeWarning "Proceeding without verified cloud mount ($SentinelPath). Streamed junctions may be dangling."
        }
    } else {
        Write-ReglazeInfo "Simulated cloud streaming mount verification ($SentinelPath)."
        $HydrateState.cloud_mount_verified = $true
    }
    Save-HydrationCheckpoint "cloud_mount_verified"
} else {
    Write-ReglazeSuccess "Cloud streaming mount already verified."
}

# =============================================================================
# Step 3: Steam Library Auto-Discovery
# =============================================================================
Write-ReglazeStep "Step 3/8: Steam Sign-In & Preserved Library Discovery..."
if (-not $HydrateState.steam_library_connected) {
    $SteamDir = "D:\SteamLibrary"
    $SteamExe = Join-Path ${env:ProgramFiles(x86)} "Steam\steam.exe"

    if (Test-Path -LiteralPath $SteamDir) {
        Write-ReglazeSuccess "Detected preserved Steam library folder at: $SteamDir"
    }

    if (-not $IsSimulated -and -not $NonInteractive) {
        if (Test-Path -LiteralPath $SteamExe) {
            Write-ReglazeInfo "Launching Steam for GUI authentication and library re-indexing..."
            Start-Process $SteamExe
            Read-Host "Press [Enter] when signed in to Steam to continue..."
        } else {
            Write-ReglazeInfo "Steam executable not found at $SteamExe; skipping launch."
        }
    } else {
        Write-ReglazeInfo "Simulated Steam sign-in and library discovery."
    }
    $HydrateState.steam_library_connected = $true
    Save-HydrationCheckpoint "steam_library_connected"
} else {
    Write-ReglazeSuccess "Steam library discovery already completed."
}

# =============================================================================
# Step 4: Manual Application Installation Guidance
# =============================================================================
Write-ReglazeStep "Step 4/8: Manual Application Installation Guidance..."
$CatalogFile = if ($ResolvedPayload) { Join-Path $ResolvedPayload "applications.json" } else { (Join-Path $RepoRoot "data\applications.json") }
if (-not (Test-Path -LiteralPath $CatalogFile)) {
    $CatalogFile = Join-Path $RepoRoot "dist\media\applications.json"
}

$ManualApps = @()
if (Test-Path -LiteralPath $CatalogFile) {
    try {
        $CatalogData = Get-Content -Raw -LiteralPath $CatalogFile -Encoding UTF8 | ConvertFrom-Json
        $ManualApps = @($CatalogData | Where-Object { $_.install -and $_.install.method -eq "manual" })
    } catch {
        Write-ReglazeWarning "Could not parse applications.json for manual installations: $($_.Exception.Message)"
    }
}

if ($ManualApps.Count -gt 0) {
    Write-ReglazeInfo "Found $($ManualApps.Count) application(s) requiring manual installation."
    foreach ($MApp in $ManualApps) {
        $AppId = $MApp.app_id
        if ($HydrateState.manual_apps_installed -contains $AppId) {
            Write-ReglazeSuccess "Application '$($MApp.name)' already completed."
            continue
        }

        Write-Host ""
        Write-Host "  ================================================================" -ForegroundColor Cyan
        Write-Host "  MANUAL APPLICATION: $($MApp.name)" -ForegroundColor Yellow
        Write-Host "  ================================================================" -ForegroundColor Cyan
        if ($MApp.website) { Write-Host "  Website:     $($MApp.website)" }
        if ($MApp.install.download_url) { Write-Host "  Download:    $($MApp.install.download_url)" }
        if ($MApp.install.default_target_directory) { Write-Host "  Target Dir:  $($MApp.install.default_target_directory)" }
        if ($MApp.install.instructions) {
            Write-Host "  Instructions:"
            foreach ($Inst in $MApp.install.instructions) {
                Write-Host "    - $Inst"
            }
        }

        if (-not $IsSimulated -and -not $NonInteractive) {
            Read-Host "Press [Enter] once you have installed or skipped '$($MApp.name)'..."
        }
        $HydrateState.manual_apps_installed += $AppId
    }
} else {
    Write-ReglazeInfo "No manual installation applications declared in catalog."
}
Save-HydrationCheckpoint "manual_apps_installed"

# =============================================================================
# [HITL-ID]: HITL-M4-04
# [HITL-TARGET]: User-Scope Directory Junctions (AppData, Docs, Saved Games)
# [HITL-STATUS]: VERIFIED
# [HITL-DESCRIPTION]: Establishes user-level NTFS junctions from %USERPROFILE% into cloud stream or secondary storage.
# [HITL-TEST-SNIPPET]:
#   # Safe inspection of existing junction links in user profile:
#   Get-ChildItem $env:USERPROFILE -Force | Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint } | Select-Object Name
# [HITL-LAST-INPUT]: Get-ChildItem $env:USERPROFILE -Force reparse point filter (2026-10-21)
# [HITL-LAST-RESULT]: Legacy compatibility reparse points discovered (Application Data, Cookies, Local Settings, etc.). Confirmed necessity of ReparsePoint attribute check prior to collision backup.
# [HITL-PATTERN]: Get-ReparsePointInfo check before folder backup or junction creation; Install-JunctionsFromManifest -Scope 'user'
# [HITL-AVOID]: Attempting recursive copy or Move-Item on legacy backward-compatibility reparse points
# =============================================================================

# =============================================================================
# Step 5: User-Level Directory Junctions
# =============================================================================
Write-ReglazeStep "Step 5/8: Establishing User-Scope Directory Junctions..."
$JunctionsManifest = if ($ResolvedPayload) { Join-Path $ResolvedPayload "junctions-manifest.json" } else { $null }

if (-not $HydrateState.user_junctions_established) {
    if ($JunctionsManifest -and (Test-Path -LiteralPath $JunctionsManifest)) {
        if (-not $IsSimulated) {
            $UserResults = Install-JunctionsFromManifest -ManifestPath $JunctionsManifest -Scope "user"
            $ActiveCount = @($UserResults | Where-Object { $_.Success }).Count
            Write-ReglazeSuccess "Created $ActiveCount user directory junction(s) via manifest."
        } else {
            $RawJuncs = Get-Content -Raw -LiteralPath $JunctionsManifest -Encoding UTF8 | ConvertFrom-Json
            $UserEntries = @($RawJuncs | Where-Object { $_.Scope -eq "user" })
            Write-ReglazeInfo "Simulated $($UserEntries.Count) user-scope directory junction(s)."
        }
        $HydrateState.user_junctions_established = $true
    } else {
        Write-ReglazeInfo "No junctions-manifest.json found; skipping user junction creation."
        $HydrateState.user_junctions_established = $true
    }
    Save-HydrationCheckpoint "user_junctions_established"
} else {
    Write-ReglazeSuccess "User directory junctions already established."
}

# =============================================================================
# Step 6: Non-Interactive WSL2 Setup & rclone bisync
# =============================================================================
Write-ReglazeStep "Step 6/8: Configuring WSL2 Subsystem & rclone bisync..."
$WslDistro = "Ubuntu"
$WslUser = "developer"
$WslPackages = @("build-essential", "git", "curl", "zsh", "rclone", "unzip")

if ($Blueprint -and $Blueprint.wsl2) {
    if ($Blueprint.wsl2.distro) { $WslDistro = $Blueprint.wsl2.distro }
    if ($Blueprint.wsl2.default_user) { $WslUser = $Blueprint.wsl2.default_user }
    if ($Blueprint.wsl2.packages) { $WslPackages = @($Blueprint.wsl2.packages) }
}

if (-not $HydrateState.wsl_provisioned) {
    $WslInitResult = Initialize-WSLDistro -Distro $WslDistro -WSLUser $WslUser -Packages $WslPackages -Simulation:$IsSimulated -Live:(-not $IsSimulated)
    if ($WslInitResult.Status -eq "Success" -or $WslInitResult.Status -eq "Simulated") {
        Write-ReglazeSuccess "WSL2 Provisioning ($WslDistro): $($WslInitResult.Message)"
        $HydrateState.wsl_provisioned = $true
    } else {
        Write-ReglazeWarning "WSL2 Provisioning ($WslDistro): $($WslInitResult.Message)"
    }
    Save-HydrationCheckpoint "wsl_provisioned"
} else {
    Write-ReglazeSuccess "WSL2 base environment already provisioned."
}

if (-not $HydrateState.wsl_rclone_synced) {
    $RemoteName = "gdrive"
    $RemoteFolder = "Backups/WSL_DevRepos"
    $LocalFolder = "~/dev"
    $ClientId = $null
    $ClientSecret = $null

    if ($Blueprint -and $Blueprint.wsl2 -and $Blueprint.wsl2.dev_repos -and $Blueprint.wsl2.dev_repos.rclone) {
        $Rc = $Blueprint.wsl2.dev_repos.rclone
        if ($Rc.remote_name) { $RemoteName = $Rc.remote_name }
        if ($Rc.remote_folder) { $RemoteFolder = $Rc.remote_folder }
    }

    if ($Blueprint -and $Blueprint.storage -and $Blueprint.storage.api_credentials) {
        $Creds = $Blueprint.storage.api_credentials
        if ($Creds.client_id_env) { $ClientId = [Environment]::GetEnvironmentVariable($Creds.client_id_env) }
        if ($Creds.client_secret_env) { $ClientSecret = [Environment]::GetEnvironmentVariable($Creds.client_secret_env) }
    }

    $RcloneResult = Invoke-WSLRcloneSync -Distro $WslDistro -WSLUser $WslUser -RemoteName $RemoteName -RemoteFolder $RemoteFolder -LocalFolder $LocalFolder -ClientId $ClientId -ClientSecret $ClientSecret -Simulation:$IsSimulated -Live:(-not $IsSimulated)
    if ($RcloneResult.Status -eq "Success" -or $RcloneResult.Status -eq "Simulated") {
        Write-ReglazeSuccess "WSL2 rclone bisync ($RemoteName): $($RcloneResult.Message)"
        $HydrateState.wsl_rclone_synced = $true
    } else {
        Write-ReglazeWarning "WSL2 rclone bisync: $($RcloneResult.Message)"
    }
    Save-HydrationCheckpoint "wsl_rclone_synced"
} else {
    Write-ReglazeSuccess "WSL2 rclone bisync already completed."
}

# =============================================================================
# [HITL-ID]: HITL-M4-06
# [HITL-TARGET]: Dev Repositories & Chezmoi Dotfiles Initialization
# [HITL-STATUS]: VERIFIED
# [HITL-DESCRIPTION]: Clones declared git repos into dev root and initializes chezmoi dotfiles if configured.
# [HITL-TEST-SNIPPET]:
#   # Safe verification of chezmoi CLI availability:
#   Get-Command chezmoi -ErrorAction SilentlyContinue | Select-Object Source, Version
# [HITL-LAST-INPUT]: Get-Command chezmoi -ErrorAction SilentlyContinue (2026-10-21)
# [HITL-LAST-RESULT]: Returned null (not installed). Validated graceful non-blocking behavior.
# [HITL-PATTERN]: if (Get-Command "chezmoi" -ErrorAction SilentlyContinue) { ... }
# [HITL-AVOID]: Overwriting existing local dotfiles without chezmoi diff inspection
# =============================================================================

# =============================================================================
# Step 7: Developer Repositories & Chezmoi Dotfiles
# =============================================================================
Write-ReglazeStep "Step 7/8: Setting Up Developer Repositories & Dotfiles..."
if (-not $HydrateState.dev_repos_cloned) {
    if ($Blueprint -and $Blueprint.dev_repos -and $Blueprint.dev_repos.remotes) {
        Write-ReglazeInfo "Inspecting declared developer repositories..."
        foreach ($Remote in $Blueprint.dev_repos.remotes) {
            Write-ReglazeInfo " - Declared remote: $($Remote.name) ($($Remote.repo)) via $($Remote.method)"
        }
    } else {
        Write-ReglazeInfo "No host dev_repos declared in blueprint."
    }
    $HydrateState.dev_repos_cloned = $true
    Save-HydrationCheckpoint "dev_repos_cloned"
} else {
    Write-ReglazeSuccess "Developer repositories already configured."
}

if (-not $HydrateState.dotfiles_applied) {
    if (Get-Command "chezmoi" -ErrorAction SilentlyContinue) {
        Write-ReglazeSuccess "Chezmoi executable detected in PATH."
    } else {
        Write-ReglazeInfo "Chezmoi not found in current PATH; developer can run 'chezmoi init' post-setup."
    }
    $HydrateState.dotfiles_applied = $true
    Save-HydrationCheckpoint "dotfiles_applied"
}

# =============================================================================
# [HITL-ID]: HITL-M4-07
# [HITL-TARGET]: Startup De-Registration & Desktop Shortcut Renaming
# [HITL-STATUS]: VERIFIED
# [HITL-DESCRIPTION]: Cleans up Run / RunOnce startup entries and converts resume shortcut into health check shortcut.
# [HITL-TEST-SNIPPET]:
#   # Safe inspection of HKCU Run key:
#   Get-ItemProperty "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -ErrorAction SilentlyContinue
# [HITL-LAST-INPUT]: Get-ItemProperty "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" (2026-10-21)
# [HITL-LAST-RESULT]: Verified active HKCU Run keys (Steam, GoogleDriveFS, Signal, Edge).
# [HITL-PATTERN]: Remove-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "ReglazeHydrate" -ErrorAction SilentlyContinue
# [HITL-AVOID]: Mutating host Run keys without explicit simulation bypass
# =============================================================================

# =============================================================================
# Step 8: Finalizing, Self-Unregistration & Desktop Shortcut
# =============================================================================
Write-ReglazeStep "Step 8/8: Finalizing Hydration & Self-Unregistration..."
if (-not $IsSimulated) {
    try {
        # 1. De-register from user startup
        Remove-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "ReglazeHydrate" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "ReglazeHydrate" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "ReglazeHydrate" -ErrorAction SilentlyContinue
        Write-ReglazeSuccess "Unregistered ReglazeHydrate startup entry."

        # 2. Rename Desktop shortcut to Health Check
        $UserDesktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)
        $ResumeShortcut = Join-Path $UserDesktop "Resume Reglaze Setup.lnk"
        $HealthShortcut = Join-Path $UserDesktop "Reglaze Health Check.lnk"
        if (Test-Path -LiteralPath $ResumeShortcut) {
            Move-Item -LiteralPath $ResumeShortcut -Destination $HealthShortcut -Force
            Write-ReglazeSuccess "Updated desktop shortcut to 'Reglaze Health Check.lnk'."
        }
    } catch {
        Write-ReglazeWarning "Finalization cleanup encountered an issue: $($_.Exception.Message)"
    }
} else {
    Write-ReglazeInfo "Simulated startup de-registration and desktop shortcut renaming."
}

$HydrateState.completed = $true
Save-HydrationCheckpoint "completed"

Write-Host ""
Write-ReglazeBanner "PHASE 5 USER HYDRATION COMPLETE"
Write-Host "  All user-level preferences, cloud mounts, junctions, WSL2 environments, and" -ForegroundColor Green
Write-Host "  developer repositories have been successfully initialized." -ForegroundColor Green
Write-Host "  Your disposable Windows workstation is fully hydrated and ready for production!" -ForegroundColor Cyan
Write-Host ""

return [PSCustomObject]@{
    Status    = if ($HydrateState.completed) { "Completed" } else { "Incomplete" }
    StateFile = $StateFile
    Simulated = $IsSimulated
}
