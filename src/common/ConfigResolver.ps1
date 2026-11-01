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

    if ($ExplicitDirectory -and (Test-Path -LiteralPath $ExplicitDirectory)) {
        if (-not (Test-Path -LiteralPath $ExplicitDirectory -PathType Container)) {
            # File path passed instead of directory; resolve its parent container folder
            return (Split-Path -Parent (Resolve-Path -LiteralPath $ExplicitDirectory).Path)
        }
        return (Resolve-Path -LiteralPath $ExplicitDirectory).Path
    }

    if ($ExplicitDirectory) {
        # Check if caller passed a file path that doesn't exist yet (e.g. ...\reglaze.yaml)
        if ($ExplicitDirectory -match '\.[a-zA-Z0-9]+$') {
            return [System.IO.Path]::GetFullPath((Split-Path -Parent $ExplicitDirectory))
        }
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

    if ($ExplicitConfig -and (Test-Path -LiteralPath $ExplicitConfig)) {
        if (Test-Path -LiteralPath $ExplicitConfig -PathType Container) {
            # Directory passed; check for reglaze.yaml or reglaze.yml
            $CandYaml = Join-Path $ExplicitConfig "reglaze.yaml"
            $CandYml = Join-Path $ExplicitConfig "reglaze.yml"
            if (Test-Path -LiteralPath $CandYaml) {
                return (Resolve-Path -LiteralPath $CandYaml).Path
            } elseif (Test-Path -LiteralPath $CandYml) {
                return (Resolve-Path -LiteralPath $CandYml).Path
            }
        } else {
            return (Resolve-Path -LiteralPath $ExplicitConfig).Path
        }
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
