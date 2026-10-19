<#
.SYNOPSIS
    Path and environment resolution logic for Reglaze configuration and audit artifacts.
#>

function Get-ReglazeRootDirectory {
    # Returns the repository root folder where src/ and data/ live
    $ScriptDir = Split-Path -Parent $PSScriptRoot
    if (Test-Path (Join-Path $ScriptDir "data\applications")) {
        return $ScriptDir
    }
    # Fallback: traverse upwards until data/applications is found
    $Current = $PSScriptRoot
    while ($Current -and (Test-Path $Current)) {
        if (Test-Path (Join-Path $Current "data\applications")) {
            return $Current
        }
        $Parent = Split-Path -Parent $Current
        if ($Parent -eq $Current) { break }
        $Current = $Parent
    }
    return (Get-Location).Path
}

function Resolve-ReglazeTargetDirectory {
    param (
        [string]$ExplicitDirectory = $null
    )

    if ($ExplicitDirectory -and (Test-Path $ExplicitDirectory)) {
        return (Resolve-Path $ExplicitDirectory).Path
    }

    if ($ExplicitDirectory) {
        # Directory requested but does not exist yet; return absolute path to be created
        return [System.IO.Path]::GetFullPath($ExplicitDirectory)
    }

    # Check environment variable REGLAZE_DIR or REGLAZE_HOME
    $EnvDir = if ($env:REGLAZE_DIR) { $env:REGLAZE_DIR } else { $env:REGLAZE_HOME }
    if ($EnvDir) {
        if (-not (Test-Path $EnvDir)) {
            New-Item -ItemType Directory -Path $EnvDir -Force | Out-Null
        }
        return (Resolve-Path $EnvDir).Path
    }

    # Default to current working directory
    return (Get-Location).Path
}

function Resolve-ReglazeConfigFile {
    param (
        [string]$ExplicitConfig = $null
    )

    if ($ExplicitConfig -and (Test-Path $ExplicitConfig)) {
        return (Resolve-Path $ExplicitConfig).Path
    }

    if ($env:REGLAZE_CONFIG -and (Test-Path $env:REGLAZE_CONFIG)) {
        return (Resolve-Path $env:REGLAZE_CONFIG).Path
    }

    $TargetDir = Resolve-ReglazeTargetDirectory
    $Candidate = Join-Path $TargetDir "reglaze.yaml"
    if (Test-Path $Candidate) {
        return (Resolve-Path $Candidate).Path
    }

    # Check examples/reglaze.yaml if running in repo
    $RepoRoot = Get-ReglazeRootDirectory
    $ExampleCandidate = Join-Path $RepoRoot "examples\reglaze.yaml"
    if (Test-Path $ExampleCandidate) {
        return (Resolve-Path $ExampleCandidate).Path
    }

    return $null
}

function Resolve-AuditReferenceFile {
    param (
        [string]$ExplicitAuditFile = $null
    )

    if ($ExplicitAuditFile -and (Test-Path $ExplicitAuditFile)) {
        return (Resolve-Path $ExplicitAuditFile).Path
    }

    $TargetDir = Resolve-ReglazeTargetDirectory
    $Candidate = Join-Path $TargetDir "audit-reference.json"
    if (Test-Path $Candidate) {
        return (Resolve-Path $Candidate).Path
    }

    $RepoRoot = Get-ReglazeRootDirectory
    $ExampleCandidate = Join-Path $RepoRoot "examples\audit-reference.json"
    if (Test-Path $ExampleCandidate) {
        return (Resolve-Path $ExampleCandidate).Path
    }

    return $null
}
