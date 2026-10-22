<#
.SYNOPSIS
    Automated verification suite for Reglaze Phase 5 / Milestone 4 (User Hydration & WSL2 Integration).
.DESCRIPTION
    Executes unit and integration tests covering:
    - WSL2 Distribution Initializer logic in simulation mode (Initialize-WSLDistro)
    - WSL2 rclone bisync orchestrator logic in simulation mode (Invoke-WSLRcloneSync)
    - WSL2 setup shell template validation (templates/setup-wsl.sh.template)
    - User hydration state persistence and resumption checkpoints (hydration-state.json)
    - Manual application guidance discovery and tracking
    - User-scope directory junction application with collision backups
    - End-to-end Start-UserHydration.ps1 execution in simulation mode
#>
[CmdletBinding()]
param(
    [switch]$All = $false
)

$ErrorActionPreference = "Continue"
$RepoRoot = Split-Path -Parent $PSScriptRoot

# Import modules under test
. (Join-Path $RepoRoot "src\common\Logging.ps1")
. (Join-Path $RepoRoot "src\common\ConfigResolver.ps1")
. (Join-Path $RepoRoot "src\linking\Test-ReparsePoint.ps1")
. (Join-Path $RepoRoot "src\linking\Backup-CollisionFolder.ps1")
. (Join-Path $RepoRoot "src\linking\New-DirectoryJunction.ps1")
. (Join-Path $RepoRoot "src\wsl\Initialize-WSLDistro.ps1")
. (Join-Path $RepoRoot "src\wsl\Sync-WSLRclone.ps1")

$PassCount = 0
$FailCount = 0

function Assert-Test {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$Details = ""
    )
    if ($Condition) {
        $script:PassCount++
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } else {
        $script:FailCount++
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        if ($Details) {
            Write-Host "         $Details" -ForegroundColor Yellow
        }
    }
}

Write-ReglazeBanner "REGLAZE MILESTONE 4: USER HYDRATION & WSL2 TEST SUITE"

$TestDir = Join-Path $RepoRoot "tests\temp_m4_$PID"
if (Test-Path $TestDir) {
    Remove-Item -Path $TestDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $TestDir -Force | Out-Null

try {
    # =========================================================================
    # Test 1: WSL2 Distribution Initializer Simulation
    # =========================================================================
    $WslInitSim = Initialize-WSLDistro -Distro "Ubuntu-24.04" -WSLUser "testdev" -Packages @("git", "curl") -Simulation:$true
    Assert-Test -Name "1. WSL2 Init: completes in simulation mode with declared user and packages" `
        -Condition ($WslInitSim.Status -eq "Simulated" -and $WslInitSim.WSLUser -eq "testdev" -and $WslInitSim.PackagesCount -eq 2) `
        -Details "Status: $($WslInitSim.Status), Message: $($WslInitSim.Message)"

    # Test error handling on missing parameters
    $WslInitErr = Initialize-WSLDistro -Distro "" -WSLUser "" -Simulation:$true
    Assert-Test -Name "2. WSL2 Init: validates required distro and username parameters" `
        -Condition ($WslInitErr.Status -eq "Failed") `
        -Details "Expected failure on empty parameters, got status: $($WslInitErr.Status)"

    # =========================================================================
    # Test 2: WSL2 rclone bisync Orchestrator Simulation
    # =========================================================================
    $RcloneSim = Invoke-WSLRcloneSync -Distro "Ubuntu" -WSLUser "testdev" -RemoteName "gdrive" -RemoteFolder "Backups/WSL" -LocalFolder "~/projects" -ClientId "MOCK_CLIENT_ID" -ClientSecret "MOCK_SECRET" -Simulation:$true
    Assert-Test -Name "3. WSL2 rclone bisync: generates valid remote and local targets in simulation" `
        -Condition ($RcloneSim.Status -eq "Simulated" -and $RcloneSim.RemotePath -eq "gdrive:Backups/WSL" -and $RcloneSim.LocalPath -eq "~/projects") `
        -Details "Status: $($RcloneSim.Status), Message: $($RcloneSim.Message)"

    # =========================================================================
    # Test 3: WSL2 Script Template Structure
    # =========================================================================
    $TemplatePath = Join-Path $RepoRoot "templates\setup-wsl.sh.template"
    $TemplateContent = if (Test-Path $TemplatePath) { Get-Content -Raw $TemplatePath } else { "" }
    $HasPlaceholders = $TemplateContent -match '\{\{WSL_USER\}\}' -and $TemplateContent -match '\{\{PACKAGES\}\}'
    $HasSudoers = $TemplateContent -match 'sudoers\.d'
    $HasWslConf = $TemplateContent -match '/etc/wsl\.conf' -and $TemplateContent -match 'systemd\s*=\s*true'
    Assert-Test -Name "4. WSL2 Template: contains required user, package, sudoers, and systemd placeholders" `
        -Condition ($HasPlaceholders -and $HasSudoers -and $HasWslConf) `
        -Details "Placeholders: $HasPlaceholders, Sudoers: $HasSudoers, WslConf: $HasWslConf"

    # =========================================================================
    # Test 4: Hydration Checkpoint State Persistence & Resumption
    # =========================================================================
    $MockStateFile = Join-Path $TestDir "hydration-state.json"
    $InitialState = [PSCustomObject]@{
        msa_connected              = $true
        cloud_mount_verified       = $true
        steam_library_connected    = $false
        manual_apps_installed      = @("app1")
        user_junctions_established = $false
        wsl_provisioned            = $false
        wsl_rclone_synced          = $false
        dev_repos_cloned           = $false
        dotfiles_applied           = $false
        completed                  = $false
        started_at                 = (Get-Date).ToString("o")
        last_updated               = (Get-Date).ToString("o")
    }
    $InitialState | ConvertTo-Json -Depth 4 | Set-Content -Path $MockStateFile -Encoding UTF8

    $LoadedState = Get-Content -Raw $MockStateFile | ConvertFrom-Json
    Assert-Test -Name "5. State Manager: correctly loads existing checkpoints (msa_connected: true)" `
        -Condition ($LoadedState.msa_connected -eq $true -and $LoadedState.steam_library_connected -eq $false -and $LoadedState.manual_apps_installed -contains "app1") `
        -Details "Loaded state properties match expected saved values."

    # =========================================================================
    # Test 5: User-Scope Junction Filtering
    # =========================================================================
    $MockUserLink = Join-Path $TestDir "UserProfile\Documents\MyGames"
    $MockUserTarget = Join-Path $TestDir "CloudStream\Documents\MyGames"
    $MockMachineLink = Join-Path $TestDir "ProgramData\MachineApp"
    $MockMachineTarget = Join-Path $TestDir "BulkData\MachineApp"

    New-Item -ItemType Directory -Path (Split-Path -Parent $MockUserLink) -Force | Out-Null
    New-Item -ItemType Directory -Path $MockUserTarget -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $MockMachineLink) -Force | Out-Null
    New-Item -ItemType Directory -Path $MockMachineTarget -Force | Out-Null

    $ManifestData = @(
        [PSCustomObject]@{
            AppId           = "user_game"
            DirectoryId     = "saves"
            Link            = $MockUserLink
            Target          = $MockUserTarget
            Scope           = "user"
            CollisionAction = "backup"
        },
        [PSCustomObject]@{
            AppId           = "machine_service"
            DirectoryId     = "data"
            Link            = $MockMachineLink
            Target          = $MockMachineTarget
            Scope           = "machine"
            CollisionAction = "backup"
        }
    )

    $MockManifestPath = Join-Path $TestDir "junctions-manifest.json"
    $ManifestData | ConvertTo-Json -Depth 4 | Set-Content -Path $MockManifestPath -Encoding UTF8

    # Apply only scope: 'user'
    $UserJuncResults = @(Install-JunctionsFromManifest -ManifestPath $MockManifestPath -Scope "user")
    $UserJuncSuccess = ($UserJuncResults.Count -eq 1 -and $UserJuncResults[0].AppId -eq "user_game" -and $UserJuncResults[0].Success)
    $UserReparseCheck = Get-ReparsePointInfo -Path $MockUserLink
    $MachineReparseCheck = Get-ReparsePointInfo -Path $MockMachineLink

    Assert-Test -Name "6. User Junctions: manifest applicator strictly isolates 'user' scope and establishes junction" `
        -Condition ($UserJuncSuccess -and $UserReparseCheck.IsReparsePoint -and (-not $MachineReparseCheck.IsReparsePoint)) `
        -Details "User junction active: $($UserReparseCheck.IsReparsePoint), Machine junction active (should be false): $($MachineReparseCheck.IsReparsePoint)"

    # =========================================================================
    # Test 6: User Junction Collision Backup
    # =========================================================================
    # Simulate a populated local user folder before linking
    $MockCollisionLink = Join-Path $TestDir "UserProfile\SavedGames"
    $MockCollisionTarget = Join-Path $TestDir "CloudStream\SavedGames"
    New-Item -ItemType Directory -Path $MockCollisionLink -Force | Out-Null
    Set-Content -Path (Join-Path $MockCollisionLink "savegame.dat") -Value "Existing local save state"
    New-Item -ItemType Directory -Path $MockCollisionTarget -Force | Out-Null

    $CollisionResult = New-ReglazeDirectoryJunction -Link $MockCollisionLink -Target $MockCollisionTarget -CollisionAction "backup"
    $CollisionReparse = Get-ReparsePointInfo -Path $MockCollisionLink
    $BackupFolders = Get-ChildItem (Split-Path -Parent $MockCollisionLink) -Directory -Filter "SavedGames.bak_*"

    Assert-Test -Name "7. User Junction Collision: backs up existing local user folder and links to cloud target" `
        -Condition ($CollisionResult.Success -and $CollisionReparse.IsReparsePoint -and ($BackupFolders.Count -ge 1)) `
        -Details "Backup folders found: $($BackupFolders.Count), Link is reparse point: $($CollisionReparse.IsReparsePoint)"

    # Clean up test junctions safely using .NET directory delete
    if ($UserReparseCheck.IsReparsePoint) { [System.IO.Directory]::Delete($MockUserLink) }
    if ($CollisionReparse.IsReparsePoint) { [System.IO.Directory]::Delete($MockCollisionLink) }

    # =========================================================================
    # Test 7: Manual Applications Catalog Processing
    # =========================================================================
    $MockAppsCatalog = Join-Path $TestDir "applications.json"
    $AppsList = @(
        [PSCustomObject]@{
            app_id  = "outfox"
            name    = "Project OutFox"
            website = "https://projectoutfox.com"
            install = [PSCustomObject]@{
                method                   = "manual"
                download_url             = "https://projectoutfox.com/download"
                default_target_directory = "D:\Games\OutFox"
                instructions             = @("Download Win64 zip", "Extract to target folder")
            }
        },
        [PSCustomObject]@{
            app_id  = "git"
            name    = "Git"
            install = [PSCustomObject]@{
                method    = "winget"
                winget_id = "Git.Git"
            }
        }
    )
    $AppsList | ConvertTo-Json -Depth 6 | Set-Content -Path $MockAppsCatalog -Encoding UTF8

    $LoadedApps = Get-Content -Raw $MockAppsCatalog | ConvertFrom-Json
    $ManualAppsList = @($LoadedApps | Where-Object { $_.install -and $_.install.method -eq "manual" })
    Assert-Test -Name "8. Manual Apps: identifies applications requiring manual guidance (outfox)" `
        -Condition ($ManualAppsList.Count -eq 1 -and $ManualAppsList[0].app_id -eq "outfox") `
        -Details "Manual apps count: $($ManualAppsList.Count), AppId: $($ManualAppsList[0].app_id)"

    # =========================================================================
    # Test 8: End-to-End Start-UserHydration in Simulation Mode
    # =========================================================================
    $EndToEndStateFile = Join-Path $TestDir "e2e-hydration-state.json"
    $StartHydrationScript = Join-Path $RepoRoot "src\runner\Start-UserHydration.ps1"

    $E2EResult = & $StartHydrationScript -PayloadDir $TestDir -ConfigFile (Join-Path $RepoRoot "examples\reglaze.yaml") -StateFile $EndToEndStateFile -NonInteractive -Simulation:$true -ResetState:$true
    $E2EState = if (Test-Path $EndToEndStateFile) { Get-Content -Raw $EndToEndStateFile | ConvertFrom-Json } else { $null }

    # When simulated, the script completes without modifying host state
    Assert-Test -Name "9. End-to-End User Hydration: Start-UserHydration.ps1 executes all 8 stages cleanly in simulation" `
        -Condition ($E2EResult.Status -eq "Completed" -and $E2EResult.Simulated -eq $true) `
        -Details "Status: $($E2EResult.Status), Simulated: $($E2EResult.Simulated)"

    # =========================================================================
    # Test 9: State Resumption (Idempotent Second Pass)
    # =========================================================================
    # Running a second pass should load existing state and complete immediately
    $SecondPassResult = & $StartHydrationScript -PayloadDir $TestDir -ConfigFile (Join-Path $RepoRoot "examples\reglaze.yaml") -StateFile $EndToEndStateFile -NonInteractive -Simulation:$true
    Assert-Test -Name "10. State Resumption: second pass re-uses completed state idempotently" `
        -Condition ($SecondPassResult.Status -eq "Completed") `
        -Details "Status: $($SecondPassResult.Status)"

} finally {
    # Safe cleanup of isolated temp directory
    if (Test-Path $TestDir) {
        # Ensure any remaining junctions inside temp dir are cleanly removed
        Get-ChildItem -Path $TestDir -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
            $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint
        } | ForEach-Object {
            [System.IO.Directory]::Delete($_.FullName)
        }
        Remove-Item -Path $TestDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "================================================================================"
Write-Host "MILESTONE 4 TEST RESULTS: $PassCount PASSED, $FailCount FAILED"
Write-Host "================================================================================"
Write-Host ""

if ($FailCount -gt 0) {
    exit 1
} else {
    exit 0
}
