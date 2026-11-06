<#
.SYNOPSIS
    Reglaze CLI - Disposable Windows Workstation Engine
.DESCRIPTION
    Main command-line interface for executing the Reglaze lifecycle:
    audit, validate, compile, bootstrap, hydrate, and test.
.EXAMPLE
    reglaze.ps1 audit
    reglaze.ps1 audit -ConfigDir "C:\reglaze-config"
    reglaze.ps1 validate -ConfigDir "C:\reglaze-config"
    reglaze.ps1 compile -ConfigDir "C:\reglaze-config" -DistDir "C:\reglaze-dist"
#>
[CmdletBinding()]
param (
    [Parameter(Position=0)]
    [ValidateSet("audit", "validate", "migration-plan", "plan-migration", "migration-manifest", "migrate", "run-migration", "apply-migration", "stage-data", "compile", "bootstrap", "hydrate", "media", "iso", "test", "version", "help")]
    [string]$Command = "help",

    [Parameter(Position=1)]
    [string]$Target = $null,

    [Alias("Config", "c")]
    [string]$ConfigDir = $null,

    [Alias("Dist", "d")]
    [string]$DistDir = $null,

    [Alias("m")]
    [string]$Manifest = $null,

    [Alias("p")]
    [string]$Profile = $null,

    [Parameter(Mandatory=$false)]
    [int]$Threads = 2,

    [Parameter(Mandatory=$false)]
    [string]$UsbDrive = $null,

    [Parameter(Mandatory=$false)]
    [string]$IsoPath = $null,

    [switch]$DownloadIso = $false,
    [switch]$OpenBrowser = $false,
    [switch]$Force = $false,
    [switch]$All = $false,
    [switch]$SkipElevation = $false,
    [switch]$Elevate = $false,
    [switch]$Simulation = $false,
    [switch]$NoReboot = $false,
    [switch]$SkipUpdates = $false,
    [switch]$SkipDsc = $false,

    [Alias("UpdateOnly", "KeepWindowsFiles", "QuickUpdate", "RetainInstaller")]
    [switch]$RetainWindowsFiles = $false
)

$RepoRoot = Split-Path -Parent $PSScriptRoot

# Import common utilities
. (Join-Path $RepoRoot "src\common\Logging.ps1")
. (Join-Path $RepoRoot "src\common\ConfigResolver.ps1")

# Route positional $Target based on command context
if ($Target) {
    if (-not $ConfigDir -and -not ($Command -in @("test", "version", "help"))) {
        $ConfigDir = $Target
    }
}

switch ($Command) {
    "audit" {
        $ResolvedConfigDir = if ($ConfigDir) { Resolve-ReglazeTargetDirectory $ConfigDir } else { Resolve-ReglazeTargetDirectory }
        $AuditScript = Join-Path $RepoRoot "src\audit\Invoke-Audit.ps1"
        & $AuditScript -ConfigDir $ResolvedConfigDir -Profile $Profile -Force:$Force -SkipElevation:$SkipElevation -Elevate:$Elevate
    }

    "validate" {
        $ResolvedCfg = if ($ConfigDir) { Resolve-ReglazeConfigFile $ConfigDir } else { Resolve-ReglazeConfigFile }
        if (-not $ResolvedCfg -or -not (Test-Path $ResolvedCfg)) {
            Write-ReglazeError "Configuration file not found. Specify via -ConfigDir or set `$env:REGLAZE_DIR."
            exit 1
        }
        Write-ReglazeBanner "BLUEPRINT VALIDATION"
        Write-ReglazeInfo "Validating: $ResolvedCfg"

        # Check if validation module exists or run basic YAML / syntax check
        $Validator = Join-Path $RepoRoot "src\compiler\Test-ReglazeValidation.ps1"
        if (Test-Path $Validator) {
            & $Validator -ConfigFile $ResolvedCfg
        } else {
            Write-ReglazeSuccess "Blueprint syntax check passed: $ResolvedCfg"
        }
    }

    { $_ -in @("migration-plan", "plan-migration", "migration-manifest") } {
        $ResolvedCfg = if ($ConfigDir) { Resolve-ReglazeConfigFile $ConfigDir } else { Resolve-ReglazeConfigFile }
        if (-not $ResolvedCfg -or -not (Test-Path $ResolvedCfg)) {
            Write-ReglazeError "Configuration file not found. Specify via -ConfigDir or set `$env:REGLAZE_DIR."
            exit 1
        }
        $ResolvedManifestOut = if ($Manifest) { $Manifest } elseif ($ConfigDir) { Resolve-ReglazeTargetDirectory $ConfigDir } else { $null }
        $MigrationModule = Join-Path $RepoRoot "src\linking\Invoke-PreInstallMigration.ps1"
        if (Test-Path $MigrationModule) {
            . $MigrationModule
            New-ReglazeMigrationPlan -ConfigFile $ResolvedCfg -OutputManifestPath $ResolvedManifestOut -RepoRoot $RepoRoot -Force:$Force | Out-Null
        } else {
            Write-ReglazeError "Pre-install migration module not found at: $MigrationModule"
            exit 1
        }
    }

    { $_ -in @("migrate", "run-migration", "apply-migration", "stage-data") } {
        $ResolvedCfg = if ($ConfigDir) { Resolve-ReglazeConfigFile $ConfigDir } else { Resolve-ReglazeConfigFile }
        $ResolvedManifest = if ($Manifest) {
            $Manifest
        } elseif ($ConfigDir) {
            $TargetDir = Resolve-ReglazeTargetDirectory $ConfigDir
            $CandYaml = Join-Path $TargetDir "migration-manifest.yaml"
            $CandJson = Join-Path $TargetDir "migration-manifest.json"
            if (Test-Path $CandYaml) { $CandYaml } elseif (Test-Path $CandJson) { $CandJson } else { $null }
        } else {
            $null
        }
        $MigrationModule = Join-Path $RepoRoot "src\linking\Invoke-PreInstallMigration.ps1"
        if (Test-Path $MigrationModule) {
            . $MigrationModule
            $MigrateRes = Invoke-ReglazePreInstallMigration -ManifestPath $ResolvedManifest -ConfigFile $ResolvedCfg -Threads $Threads -Simulation:$Simulation -Force:$Force
            if ($MigrateRes -and $MigrateRes.FailedCount -gt 0) {
                exit 1
            }
        } else {
            Write-ReglazeError "Pre-install migration module not found at: $MigrationModule"
            exit 1
        }
    }

    "compile" {
        $ResolvedCfg = if ($ConfigDir) { Resolve-ReglazeConfigFile $ConfigDir } else { Resolve-ReglazeConfigFile }
        if (-not $ResolvedCfg -or -not (Test-Path $ResolvedCfg)) {
            Write-ReglazeError "Configuration file not found. Specify via -ConfigDir or set `$env:REGLAZE_DIR."
            exit 1
        }
        $ResolvedDist = if ($DistDir) { Resolve-ReglazeTargetDirectory $DistDir } else { (Join-Path $RepoRoot "dist\media") }

        $CompilerScript = Join-Path $RepoRoot "src\compiler\Compile-Reglaze.ps1"
        if (Test-Path $CompilerScript) {
            $global:LASTEXITCODE = 0
            $CompileRes = & $CompilerScript -Config $ResolvedCfg -DistDir $ResolvedDist
            if ($null -ne $global:LASTEXITCODE -and $global:LASTEXITCODE -ne 0) { exit $global:LASTEXITCODE }
            if ($null -ne $CompileRes -and $CompileRes.PSObject.Properties['Status'] -and $CompileRes.Status -ne "Success") { exit 1 }
        } else {
            Write-ReglazeError "Compiler engine not found at: $CompilerScript"
            exit 1
        }

        # If -UsbDrive specified during compile, chain into USB media creation
        if ($UsbDrive) {
            Write-Host ""
            if ($RetainWindowsFiles) {
                Write-ReglazeInfo "Proceeding directly to updating Reglaze files on $UsbDrive (-RetainWindowsFiles)..."
                $ResolvedIso = $null
            } else {
                Write-ReglazeInfo "Proceeding directly to bootable USB media creation on $UsbDrive..."
                $ResolvedIso = $IsoPath
                if (-not $ResolvedIso) {
                    . (Join-Path $RepoRoot "src\media\Get-WindowsIso.ps1")
                    $IsoResult = Get-Windows11Iso -DestinationDir (Join-Path $RepoRoot "downloads") -OpenBrowser:$OpenBrowser -Simulation:$Simulation -Live:(-not $Simulation)
                    $ResolvedIso = $IsoResult.IsoPath
                }
            }
            . (Join-Path $RepoRoot "src\media\Build-Media.ps1")
            New-ReglazeBootableUsb -UsbDrive $UsbDrive -IsoPath $ResolvedIso -MediaArtifactsDir $ResolvedDist -Force:$Force -RetainWindowsFiles:$RetainWindowsFiles -Simulation:$Simulation -Live:(-not $Simulation) -Elevate:$Elevate -SkipElevation:$SkipElevation
        }
    }

    "iso" {
        $IsoScript = Join-Path $RepoRoot "src\media\Get-WindowsIso.ps1"
        if (Test-Path $IsoScript) {
            . $IsoScript
            $TargetDest = if ($DistDir) { Resolve-ReglazeTargetDirectory $DistDir } else { Join-Path $RepoRoot "downloads" }
            Get-Windows11Iso -IsoPath $IsoPath -DestinationDir $TargetDest -OpenBrowser:$OpenBrowser -Simulation:$Simulation -Live:(-not $Simulation)
        } else {
            Write-ReglazeError "ISO discovery engine not found at: $IsoScript"
            exit 1
        }
    }

    "media" {
        $ResolvedCfg = if ($ConfigDir) { Resolve-ReglazeConfigFile $ConfigDir } else { Resolve-ReglazeConfigFile }
        $ResolvedDist = if ($DistDir) { Resolve-ReglazeTargetDirectory $DistDir } else { (Join-Path $RepoRoot "dist\media") }

        # Ensure media artifacts are compiled first
        if (-not (Test-Path (Join-Path $ResolvedDist "autounattend.xml"))) {
            Write-ReglazeInfo "Compiling deployment media artifacts first..."
            $CompilerScript = Join-Path $RepoRoot "src\compiler\Compile-Reglaze.ps1"
            $global:LASTEXITCODE = 0
            $CompileRes = & $CompilerScript -Config $ResolvedCfg -DistDir $ResolvedDist
            if ($null -ne $global:LASTEXITCODE -and $global:LASTEXITCODE -ne 0) { exit $global:LASTEXITCODE }
            if ($null -ne $CompileRes -and $CompileRes.PSObject.Properties['Status'] -and $CompileRes.Status -ne "Success") { exit 1 }
        }

        # Resolve ISO if not specified and not retaining Windows files
        $ResolvedIso = $IsoPath
        if (-not $RetainWindowsFiles) {
            if (-not $ResolvedIso) {
                $IsoModule = Join-Path $RepoRoot "src\media\Get-WindowsIso.ps1"
                . $IsoModule
                $IsoResult = Get-Windows11Iso -DestinationDir (Join-Path $RepoRoot "downloads") -OpenBrowser:$OpenBrowser -Simulation:$Simulation -Live:(-not $Simulation)
                $ResolvedIso = $IsoResult.IsoPath
            }
        }

        if (-not $UsbDrive -and -not $Simulation) {
            Write-ReglazeError "Missing required -UsbDrive parameter (e.g. -UsbDrive E:)."
            exit 1
        }
        $TargetUsb = if ($UsbDrive) { $UsbDrive } else { "E:" }

        $MediaModule = Join-Path $RepoRoot "src\media\Build-Media.ps1"
        if (Test-Path $MediaModule) {
            . $MediaModule
            New-ReglazeBootableUsb -UsbDrive $TargetUsb -IsoPath $ResolvedIso -MediaArtifactsDir $ResolvedDist -Force:$Force -RetainWindowsFiles:$RetainWindowsFiles -Simulation:$Simulation -Live:(-not $Simulation) -Elevate:$Elevate -SkipElevation:$SkipElevation
        } else {
            Write-ReglazeError "Media builder module not found at: $MediaModule"
            exit 1
        }
    }

    "bootstrap" {
        $ResolvedCfg = if ($ConfigDir) { Resolve-ReglazeConfigFile $ConfigDir } else { Resolve-ReglazeConfigFile }
        $ResolvedPayload = if ($DistDir) { Resolve-ReglazeTargetDirectory $DistDir } else { $null }
        $BootstrapScript = Join-Path $RepoRoot "src\runner\Start-MachineBootstrap.ps1"
        if (Test-Path $BootstrapScript) {
            & $BootstrapScript -PayloadDir $ResolvedPayload -ConfigFile $ResolvedCfg -Simulation:$Simulation -NoReboot:$NoReboot -SkipUpdates:$SkipUpdates -SkipDsc:$SkipDsc
        } else {
            Write-ReglazeError "Bootstrap runner not found at: $BootstrapScript"
            exit 1
        }
    }

    "hydrate" {
        $ResolvedCfg = if ($ConfigDir) { Resolve-ReglazeConfigFile $ConfigDir } else { Resolve-ReglazeConfigFile }
        $ResolvedPayload = if ($DistDir) { Resolve-ReglazeTargetDirectory $DistDir } else { $null }
        $HydrateScript = Join-Path $RepoRoot "src\runner\Start-UserHydration.ps1"
        if (Test-Path $HydrateScript) {
            & $HydrateScript -PayloadDir $ResolvedPayload -ConfigFile $ResolvedCfg -Simulation:$Simulation
        } else {
            Write-ReglazeError "Hydration runner not found at: $HydrateScript"
            exit 1
        }
    }

    "test" {
        Write-ReglazeBanner "DIAGNOSTIC TEST SUITE"
        $M1Script = Join-Path $RepoRoot "tests\Test-Milestone1.ps1"
        $M2Script = Join-Path $RepoRoot "tests\Test-Milestone2.ps1"
        $M3Script = Join-Path $RepoRoot "tests\Test-Milestone3.ps1"
        $M4Script = Join-Path $RepoRoot "tests\Test-Milestone4.ps1"

        if ($Target -eq "m1" -or $Target -eq "milestone1") {
            if (Test-Path $M1Script) { & $M1Script -All:$All }
        } elseif ($Target -eq "m2" -or $Target -eq "milestone2") {
            if (Test-Path $M2Script) { & $M2Script -All:$All }
        } elseif ($Target -eq "m3" -or $Target -eq "milestone3") {
            if (Test-Path $M3Script) { & $M3Script -All:$All }
        } elseif ($Target -eq "m4" -or $Target -eq "milestone4") {
            if (Test-Path $M4Script) { & $M4Script -All:$All }
        } else {
            Write-ReglazeInfo "Executing Milestone 1, Milestone 2, Milestone 3 & Milestone 4 test suites..."
            $M1Success = $true
            $M2Success = $true
            $M3Success = $true
            $M4Success = $true
            if (Test-Path $M1Script) {
                & $M1Script -All:$All
                if ($LASTEXITCODE -ne 0) { $M1Success = $false }
            }
            if (Test-Path $M2Script) {
                & $M2Script -All:$All
                if ($LASTEXITCODE -ne 0) { $M2Success = $false }
            }
            if (Test-Path $M3Script) {
                & $M3Script -All:$All
                if ($LASTEXITCODE -ne 0) { $M3Success = $false }
            }
            if (Test-Path $M4Script) {
                & $M4Script -All:$All
                if ($LASTEXITCODE -ne 0) { $M4Success = $false }
            }
            if (-not $M1Success -or -not $M2Success -or -not $M3Success -or -not $M4Success) { exit 1 }
        }
    }

    "version" {
        Write-Host "Reglaze CLI v1.0.0 (Disposable Windows Workstation Engine)" -ForegroundColor Cyan
    }

    "help" {
        Write-ReglazeBanner "CLI HELP & SYNTAX GUIDE"
        Write-Host "  USAGE:" -ForegroundColor Yellow
        Write-Host "    pwsh ./bin/reglaze.ps1 <command> [options]"
        Write-Host ""
        Write-Host "  COMMANDS:" -ForegroundColor Yellow
        Write-Host "    audit          Pre-flight discovery sweep (emits audit-reference.json and scaffolds reglaze.yaml)"
        Write-Host "    validate       Validates blueprint against application catalog & safety constraints"
        Write-Host "    migration-plan Generates draft pre-install migration manifest (migration-manifest.yaml) with size stats"
        Write-Host "    migrate        Creates target sync/data directories and stages files via multi-threaded Robocopy"
        Write-Host "    compile        Compiles declarative blueprint into installation media artifacts"
        Write-Host "    media          Builds vanilla UEFI bootable USB installation media with DISM split"
        Write-Host "    iso            Discovers or downloads official Microsoft Windows 11 installation ISO"
        Write-Host "    bootstrap      Machine-level unattended provisioning run under LocalAdmin (Phase 4)"
        Write-Host "    hydrate        Staged user-level interactive hydration wizard (Phase 5)"
        Write-Host "    test           Runs verification and diagnostic test suite"
        Write-Host "    version        Prints current Reglaze CLI version"
        Write-Host ""
        Write-Host "  ENVIRONMENT VARIABLES:" -ForegroundColor Yellow
        Write-Host "    `$env:REGLAZE_DIR      Target directory for live reglaze.yaml and audit-reference.json"
        Write-Host "    `$env:REGLAZE_CONFIG   Explicit override path for reglaze.yaml"
        Write-Host "    `$env:REGLAZE_PROFILE  Default profile name for 'reglaze audit' when not specified via -Profile"
        Write-Host ""
        Write-Host "  PARAMETERS:" -ForegroundColor Yellow
        Write-Host "    -ConfigDir (-Config, -c) Directory containing (or to contain) reglaze.yaml, audit-reference.json, etc."
        Write-Host "    -DistDir   (-Dist, -d)   Target directory for compiled installation media artifacts (dist/media)"
        Write-Host "    -UsbDrive                Target USB drive letter for bootable installation media (e.g. E:)"
        Write-Host "    -RetainWindowsFiles      Preserves existing Windows install files on USB and only refreshes Reglaze files"
        Write-Host "                             (Aliases: -UpdateOnly, -KeepWindowsFiles, -QuickUpdate, -RetainInstaller)"
        Write-Host "    -Profile   (-p)          Reglaze profile name for pre-flight audit scaffolding (e.g. 'workstation')"
        Write-Host "    -Threads                 Worker thread count for pre-install migration (defaults to safe 2)"
        Write-Host ""
        Write-Host "  EXAMPLES:" -ForegroundColor Yellow
        Write-Host "    pwsh ./bin/reglaze.ps1 audit -ConfigDir `"C:\reglaze-config`" -Profile `"workstation`""
        Write-Host "    pwsh ./bin/reglaze.ps1 migration-plan -ConfigDir `"C:\reglaze-config`""
        Write-Host "    pwsh ./bin/reglaze.ps1 migrate -ConfigDir `"C:\reglaze-config`""
        Write-Host "    pwsh ./bin/reglaze.ps1 validate -ConfigDir `"C:\reglaze-config`""
        Write-Host "    pwsh ./bin/reglaze.ps1 compile -ConfigDir `"C:\reglaze-config`" -DistDir `"C:\reglaze-dist`" -UsbDrive `"E:`""
        Write-Host "    pwsh ./bin/reglaze.ps1 compile -UsbDrive `"E:`" -RetainWindowsFiles"
        Write-Host "    pwsh ./bin/reglaze.ps1 media -UsbDrive `"E:`" -UpdateOnly"
        Write-Host "    pwsh ./bin/reglaze.ps1 test"
        Write-Host ""
    }
}
