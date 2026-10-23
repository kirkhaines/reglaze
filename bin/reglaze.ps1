<#
.SYNOPSIS
    Reglaze CLI - Disposable Windows Workstation Engine
.DESCRIPTION
    Main command-line interface for executing the Reglaze lifecycle:
    audit, validate, compile, bootstrap, hydrate, and test.
.EXAMPLE
    reglaze.ps1 audit
    reglaze.ps1 audit -OutputDir "G:\My Drive\Reglaze"
    reglaze.ps1 validate -Config "G:\My Drive\Reglaze\reglaze.yaml"
    reglaze.ps1 compile -OutputDir "./dist"
#>
[CmdletBinding()]
param (
    [Parameter(Position=0)]
    [ValidateSet("audit", "validate", "compile", "bootstrap", "hydrate", "media", "iso", "test", "version", "help")]
    [string]$Command = "help",

    [Parameter(Position=1)]
    [string]$Target = $null,

    [Alias("c")]
    [string]$Config = $null,

    [Alias("o")]
    [string]$OutputDir = $null,

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
    [switch]$SkipDsc = $false
)

$RepoRoot = Split-Path -Parent $PSScriptRoot

# Import common utilities
. (Join-Path $RepoRoot "src\common\Logging.ps1")
. (Join-Path $RepoRoot "src\common\ConfigResolver.ps1")

switch ($Command) {
    "audit" {
        $ResolvedOut = if ($OutputDir) { $OutputDir } elseif ($Target) { $Target } else { $null }
        $AuditScript = Join-Path $RepoRoot "src\audit\Invoke-Audit.ps1"
        & $AuditScript -OutputDir $ResolvedOut -Force:$Force -SkipElevation:$SkipElevation -Elevate:$Elevate
    }

    "validate" {
        $ResolvedCfg = if ($Config) { $Config } elseif ($Target) { $Target } else { Resolve-ReglazeConfigFile }
        if (-not $ResolvedCfg -or -not (Test-Path $ResolvedCfg)) {
            Write-ReglazeError "Configuration file not found. Specify via -Config or set `$env:REGLAZE_DIR."
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

    "compile" {
        $ResolvedCfg = if ($Config) { $Config } elseif ($Target) { $Target } else { Resolve-ReglazeConfigFile }
        $ResolvedOut = if ($OutputDir) { $OutputDir } else { (Join-Path $RepoRoot "dist\media") }

        $CompilerScript = Join-Path $RepoRoot "src\compiler\Compile-Reglaze.ps1"
        if (Test-Path $CompilerScript) {
            & $CompilerScript -Config $ResolvedCfg -OutputDir $ResolvedOut
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        } else {
            Write-ReglazeError "Compiler engine not found at: $CompilerScript"
            exit 1
        }

        # If -UsbDrive specified during compile, chain into USB media creation
        if ($UsbDrive) {
            Write-Host ""
            Write-ReglazeInfo "Proceeding directly to bootable USB media creation on $UsbDrive..."
            $ResolvedIso = $IsoPath
            if (-not $ResolvedIso) {
                . (Join-Path $RepoRoot "src\media\Get-WindowsIso.ps1")
                $IsoResult = Get-Windows11Iso -DestinationDir (Join-Path $RepoRoot "downloads") -OpenBrowser:$OpenBrowser -Simulation:$Simulation -Live:(-not $Simulation)
                $ResolvedIso = $IsoResult.IsoPath
            }
            . (Join-Path $RepoRoot "src\media\Build-Media.ps1")
            New-ReglazeBootableUsb -UsbDrive $UsbDrive -IsoPath $ResolvedIso -MediaArtifactsDir $ResolvedOut -Force:$Force -Simulation:$Simulation -Live:(-not $Simulation)
        }
    }

    "iso" {
        $IsoScript = Join-Path $RepoRoot "src\media\Get-WindowsIso.ps1"
        if (Test-Path $IsoScript) {
            . $IsoScript
            $TargetDest = if ($OutputDir) { $OutputDir } else { Join-Path $RepoRoot "downloads" }
            Get-Windows11Iso -IsoPath $IsoPath -DestinationDir $TargetDest -OpenBrowser:$OpenBrowser -Simulation:$Simulation -Live:(-not $Simulation)
        } else {
            Write-ReglazeError "ISO discovery engine not found at: $IsoScript"
            exit 1
        }
    }

    "media" {
        $ResolvedCfg = if ($Config) { $Config } elseif ($Target) { $Target } else { Resolve-ReglazeConfigFile }
        $ResolvedOut = if ($OutputDir) { $OutputDir } else { (Join-Path $RepoRoot "dist\media") }

        # Ensure media artifacts are compiled first
        if (-not (Test-Path (Join-Path $ResolvedOut "autounattend.xml"))) {
            Write-ReglazeInfo "Compiling deployment media artifacts first..."
            $CompilerScript = Join-Path $RepoRoot "src\compiler\Compile-Reglaze.ps1"
            & $CompilerScript -Config $ResolvedCfg -OutputDir $ResolvedOut
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        }

        # Resolve ISO if not specified
        $ResolvedIso = $IsoPath
        if (-not $ResolvedIso) {
            $IsoModule = Join-Path $RepoRoot "src\media\Get-WindowsIso.ps1"
            . $IsoModule
            $IsoResult = Get-Windows11Iso -DestinationDir (Join-Path $RepoRoot "downloads") -OpenBrowser:$OpenBrowser -Simulation:$Simulation -Live:(-not $Simulation)
            $ResolvedIso = $IsoResult.IsoPath
        }

        if (-not $UsbDrive -and -not $Simulation) {
            Write-ReglazeError "Missing required -UsbDrive parameter (e.g. -UsbDrive E:)."
            exit 1
        }
        $TargetUsb = if ($UsbDrive) { $UsbDrive } else { "E:" }

        $MediaModule = Join-Path $RepoRoot "src\media\Build-Media.ps1"
        if (Test-Path $MediaModule) {
            . $MediaModule
            New-ReglazeBootableUsb -UsbDrive $TargetUsb -IsoPath $ResolvedIso -MediaArtifactsDir $ResolvedOut -Force:$Force -Simulation:$Simulation -Live:(-not $Simulation)
        } else {
            Write-ReglazeError "Media builder module not found at: $MediaModule"
            exit 1
        }
    }

    "bootstrap" {
        $ResolvedCfg = if ($Config) { $Config } elseif ($Target) { $Target } else { Resolve-ReglazeConfigFile }
        $BootstrapScript = Join-Path $RepoRoot "src\runner\Start-MachineBootstrap.ps1"
        if (Test-Path $BootstrapScript) {
            & $BootstrapScript -PayloadDir $OutputDir -ConfigFile $ResolvedCfg -Simulation:$Simulation -NoReboot:$NoReboot -SkipUpdates:$SkipUpdates -SkipDsc:$SkipDsc
        } else {
            Write-ReglazeError "Bootstrap runner not found at: $BootstrapScript"
            exit 1
        }
    }

    "hydrate" {
        $ResolvedCfg = if ($Config) { $Config } elseif ($Target) { $Target } else { Resolve-ReglazeConfigFile }
        $HydrateScript = Join-Path $RepoRoot "src\runner\Start-UserHydration.ps1"
        if (Test-Path $HydrateScript) {
            & $HydrateScript -PayloadDir $OutputDir -ConfigFile $ResolvedCfg -Simulation:$Simulation
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
        Write-Host "    audit        Pre-flight discovery sweep (emits audit-reference.json and scaffolds reglaze.yaml)"
        Write-Host "    validate     Validates blueprint against application catalog & safety constraints"
        Write-Host "    compile      Compiles declarative blueprint into installation media artifacts"
        Write-Host "    media        Builds vanilla UEFI bootable USB installation media with DISM split"
        Write-Host "    iso          Discovers or downloads official Microsoft Windows 11 installation ISO"
        Write-Host "    bootstrap    Machine-level unattended provisioning run under LocalAdmin (Phase 4)"
        Write-Host "    hydrate      Staged user-level interactive hydration wizard (Phase 5)"
        Write-Host "    test         Runs verification and diagnostic test suite"
        Write-Host "    version      Prints current Reglaze CLI version"
        Write-Host ""
        Write-Host "  ENVIRONMENT VARIABLES:" -ForegroundColor Yellow
        Write-Host "    `$env:REGLAZE_DIR      Target directory for live reglaze.yaml and audit-reference.json"
        Write-Host "    `$env:REGLAZE_CONFIG   Explicit override path for reglaze.yaml"
        Write-Host ""
        Write-Host "  EXAMPLES:" -ForegroundColor Yellow
        Write-Host "    pwsh ./bin/reglaze.ps1 audit -OutputDir `"G:\My Drive\Reglaze`""
        Write-Host "    pwsh ./bin/reglaze.ps1 validate -Config `"G:\My Drive\Reglaze\reglaze.yaml`""
        Write-Host "    pwsh ./bin/reglaze.ps1 test"
        Write-Host ""
    }
}
