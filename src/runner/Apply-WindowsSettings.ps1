<#
.SYNOPSIS
    Applies modular Windows system settings and user preferences for Reglaze.
.DESCRIPTION
    Executes scripts from data/windows/ (Explorer folder options, taskbar/tray,
    performance power plan) to configure a developer-friendly Windows environment.
#>
[CmdletBinding()]
param()

# =============================================================================
# [HITL-ID]: HITL-M3-03
# [HITL-TARGET]: Windows Preferences / Explorer, Taskbar & Power Registry Settings
# [HITL-STATUS]: VERIFIED
# [HITL-DESCRIPTION]: Modular PowerShell scripts in data/windows/ modifying Explorer folder options, Taskbar alignment/search, and power schemes.
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

        [switch]$Simulation = $true,
        [switch]$Live = $false
    )

    # Fail-safe: Always simulated unless explicitly flagged -Live
    $IsSimulated = $Simulation -or (-not $Live)

    if (-not $RepoRoot) {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }

    $WindowsSettingsDir = Join-Path $RepoRoot "data\windows"
    $Results = [System.Collections.Generic.List[PSCustomObject]]::new()

    if (-not (Test-Path -LiteralPath $WindowsSettingsDir)) {
        return $Results
    }

    $Scripts = @(
        @{ Name = "ExplorerFolderOptions"; File = "explorer-folder-options.ps1" },
        @{ Name = "TaskbarSystemTray";    File = "taskbar-system-tray.ps1" },
        @{ Name = "PerformancePower";     File = "performance-power.ps1" }
    )

    foreach ($Item in $Scripts) {
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
                    & $ScriptPath
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
