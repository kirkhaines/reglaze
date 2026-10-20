<#
.SYNOPSIS
    Master compilation orchestrator for Reglaze deployment media.
.DESCRIPTION
    Validates reglaze.yaml against the application catalog and safety constraints,
    merges audit hardware/licensing data, and generates the complete, ready-to-flash
    installation media directory containing autounattend.xml, WinPE dynamic disk matching,
    and the post-install provisioning payload.
.EXAMPLE
    Compile-Reglaze.ps1 -Config "G:\My Drive\Reglaze\reglaze.yaml" -OutputDir "./dist/media"
#>
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$Config = $null,

    [Parameter(Position=1)]
    [string]$OutputDir = $null,

    [string]$AuditFile = $null,

    [switch]$SkipValidation = $false
)

$CompilerRoot = $PSScriptRoot
$RepoRoot = Split-Path -Parent (Split-Path -Parent $CompilerRoot)
$CommonRoot = Join-Path $RepoRoot "src\common"

. (Join-Path $CommonRoot "Logging.ps1")
. (Join-Path $CommonRoot "ConfigResolver.ps1")
. (Join-Path $CommonRoot "YamlParser.ps1")
. (Join-Path $CompilerRoot "Test-ReglazeValidation.ps1")
. (Join-Path $CompilerRoot "Build-Autounattend.ps1")
. (Join-Path $CompilerRoot "Build-Payload.ps1")

function Invoke-ReglazeCompilation {
    [CmdletBinding()]
    param(
        [string]$ConfigFile = $null,
        [string]$TargetOutputDir = $null,
        [string]$AuditReferencePath = $null,
        [bool]$BypassValidation = $false
    )

    Write-ReglazeBanner "REGLAZE COMPILER & ARTIFACT GENERATOR"

    # 1. Resolve Target Blueprint
    $BlueprintFile = if ($ConfigFile) { $ConfigFile } else { Resolve-ReglazeConfigFile }
    if (-not $BlueprintFile -or -not (Test-Path $BlueprintFile)) {
        Write-ReglazeError "Blueprint file not found. Specify via -Config or set `$env:REGLAZE_DIR."
        exit 1
    }
    Write-ReglazeInfo "Blueprint Source: $BlueprintFile"

    # 2. Resolve Target Output Media Directory
    $MediaDir = if ($TargetOutputDir) { $TargetOutputDir } else { (Join-Path $RepoRoot "dist\media") }
    Write-ReglazeInfo "Media Target:     $MediaDir"

    # 3. Resolve Audit Reference Data
    $AuditPath = $null
    if ($AuditReferencePath -and (Test-Path $AuditReferencePath)) {
        $AuditPath = $AuditReferencePath
    } else {
        $BlueprintDir = Split-Path -Parent $BlueprintFile
        $SiblingAudit = Join-Path $BlueprintDir "audit-reference.json"
        if (Test-Path $SiblingAudit) {
            $AuditPath = $SiblingAudit
        } else {
            $EnvAudit = Resolve-AuditReferenceFile
            if ($EnvAudit -and (Test-Path $EnvAudit)) {
                $AuditPath = $EnvAudit
            }
        }
    }

    $AuditReference = $null
    if ($AuditPath -and (Test-Path $AuditPath)) {
        Write-ReglazeInfo "Audit Reference:  $AuditPath"
        try {
            $AuditReference = Get-Content -Raw -LiteralPath $AuditPath | ConvertFrom-Json
        } catch {
            Write-ReglazeWarning "Failed to parse audit-reference.json ($($_.Exception.Message)). Proceeding without hardware snapshot."
        }
    } else {
        Write-ReglazeWarning "No audit-reference.json found. Proceeding with generic hardware & KMS licensing defaults."
    }

    # 4. Semantic & Safety Blueprint Validation
    if (-not $BypassValidation) {
        Write-ReglazeInfo "Running blueprint semantic and safety validation..."
        $ValidationResult = Test-ReglazeBlueprint -Path $BlueprintFile -RepoRoot $RepoRoot

        if ($ValidationResult.Warnings.Count -gt 0) {
            foreach ($Warn in $ValidationResult.Warnings) {
                Write-ReglazeWarning $Warn
            }
        }

        if (-not $ValidationResult.IsValid) {
            foreach ($Err in $ValidationResult.Errors) {
                Write-ReglazeError $Err
            }
            Write-ReglazeError "Compilation aborted due to $($ValidationResult.Errors.Count) validation error(s)."
            exit 1
        }
        Write-ReglazeSuccess "Blueprint validation passed with 0 errors."
        $Blueprint = $ValidationResult.Blueprint
    } else {
        Write-ReglazeWarning "Skipping blueprint validation by user request."
        $Blueprint = Get-ReglazeBlueprintObject -Path $BlueprintFile
    }

    # 5. Initialize Output Directory Structure
    if (-not (Test-Path $MediaDir)) {
        New-Item -ItemType Directory -Path $MediaDir -Force | Out-Null
    }
    $ReglazeDir = Join-Path $MediaDir "Reglaze"
    if (-not (Test-Path $ReglazeDir)) {
        New-Item -ItemType Directory -Path $ReglazeDir -Force | Out-Null
    }
    $PayloadDir = Join-Path $MediaDir "payload"
    if (-not (Test-Path $PayloadDir)) {
        New-Item -ItemType Directory -Path $PayloadDir -Force | Out-Null
    }

    # 6. Generate autounattend.xml
    Write-ReglazeInfo "Generating autounattend.xml..."
    $AutounattendPath = Join-Path $MediaDir "autounattend.xml"
    Build-AutounattendXml -Blueprint $Blueprint -AuditReference $AuditReference -OutputPath $AutounattendPath | Out-Null
    Write-ReglazeSuccess "Generated: $AutounattendPath"

    # 7. Stage WinPE Disk Matching Script
    Write-ReglazeInfo "Staging WinPE dynamic disk matching engine..."
    $SourceDiskMatch = Join-Path $CompilerRoot "DiskMatch.ps1"
    $TargetDiskMatch1 = Join-Path $ReglazeDir "DiskMatch.ps1"
    $TargetDiskMatch2 = Join-Path $MediaDir "DiskMatch.ps1"
    Copy-Item -Path $SourceDiskMatch -Destination $TargetDiskMatch1 -Force
    Copy-Item -Path $SourceDiskMatch -Destination $TargetDiskMatch2 -Force
    Write-ReglazeSuccess "Staged: $TargetDiskMatch1"

    # 8. Compile Deployment Payload (WinGet DSC, BitLocker, Junctions, Bootstrap, Hydrate, WSL2)
    Write-ReglazeInfo "Compiling deployment payload artifacts..."
    $PayloadResult = Build-ReglazePayload -Blueprint $Blueprint -AuditReference $AuditReference -RepoRoot $RepoRoot -PayloadDir $PayloadDir
    Write-ReglazeSuccess "Compiled: $($PayloadResult.JunctionCount) directory junctions in junctions-manifest.json"
    Write-ReglazeSuccess "Compiled: WinGet DSC application configuration ($($PayloadResult.DscPath))"
    Write-ReglazeSuccess "Compiled: Machine bootstrap runner ($($PayloadResult.BootstrapPath))"
    Write-ReglazeSuccess "Compiled: User hydration wizard ($($PayloadResult.HydratePath))"
    Write-ReglazeSuccess "Compiled: WSL2 non-interactive provisioner ($($PayloadResult.WslScriptPath))"

    # 9. Completion Summary
    Write-Host ""
    Write-ReglazeBanner "COMPILATION SUCCESSFUL"
    Write-Host "  Artifacts ready for deployment media:" -ForegroundColor Cyan
    Write-Host "    • Root:     $MediaDir" -ForegroundColor White
    Write-Host "    • Answer:   $AutounattendPath" -ForegroundColor White
    Write-Host "    • Payload:  $PayloadDir" -ForegroundColor White
    Write-Host ""

    return [PSCustomObject]@{
        Status            = "Success"
        MediaDir          = $MediaDir
        AutounattendPath  = $AutounattendPath
        PayloadDir        = $PayloadDir
        DscPath           = $PayloadResult.DscPath
        JunctionCount     = $PayloadResult.JunctionCount
        BitLockerKeyCount = $PayloadResult.BitLockerKeyCount
    }
}

if ($Config -or $MyInvocation.InvocationName -ne '.') {
    Invoke-ReglazeCompilation -ConfigFile $Config -TargetOutputDir $OutputDir -AuditReferencePath $AuditFile -BypassValidation:$SkipValidation
}
