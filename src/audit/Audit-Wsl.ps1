<#
.SYNOPSIS
    WSL2 distribution and package discovery module for Reglaze.
.DESCRIPTION
    Discovers installed WSL distributions, identifies the default distro,
    and inspects user-installed (non-standard) packages inside Linux distros (e.g. Debian/Ubuntu)
    using apt-mark / dpkg, filtering out base cloud-image packages.
#>
[CmdletBinding()]
param()

function Get-WslAudit {
    [CmdletBinding()]
    param()

    $WslData = [PSCustomObject]@{
        enabled           = $false
        distros           = @()
        default_distro    = $null
        detected_packages = @("git", "curl", "rclone")
    }

    if (-not (Get-Command "wsl.exe" -ErrorAction SilentlyContinue)) {
        return $WslData
    }

    try {
        $RawLines = & wsl.exe -l -v 2>$null
        if ($RawLines) {
            $WslData.enabled = $true
            foreach ($Line in $RawLines) {
                # Clean null bytes from potential UTF-16 output
                $CleanLine = $Line -replace "`0", ""
                if ($CleanLine -match '^\s*(\*?)\s*([a-zA-Z0-9.\-_]+)\s+(Running|Stopped)\s+(\d+)') {
                    $IsDefault = ($Matches[1] -eq "*")
                    $DistroName = $Matches[2].Trim()
                    if ($IsDefault -or -not $WslData.default_distro) {
                        $WslData.default_distro = $DistroName
                    }
                    $WslData.distros += [PSCustomObject]@{
                        name       = $DistroName
                        state      = $Matches[3]
                        version    = [int]$Matches[4]
                        is_default = $IsDefault
                    }
                }
            }

            $TargetDistro = if ($WslData.default_distro) { $WslData.default_distro } else { "Ubuntu" }
            $ManualPkgs = & wsl.exe -d $TargetDistro -- bash -c "apt-mark showmanual 2>/dev/null | sort" 2>$null
            if ($ManualPkgs) {
                $BaseUbuntuPackages = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                @(
                    "base-files", "bash", "bsdutils", "coreutils", "dash", "debianutils", 
                    "diffutils", "findutils", "grep", "gzip", "hostname", "init", 
                    "libattr1", "login", "ncurses-base", "ncurses-bin", "ubuntu-minimal", 
                    "ubuntu-wsl", "util-linux", "whiptail"
                ) | ForEach-Object { $BaseUbuntuPackages.Add($_) | Out-Null }

                $CustomPkgs = @()
                foreach ($Pkg in $ManualPkgs) {
                    $CleanPkg = $Pkg.Trim()
                    if ($CleanPkg -and -not $BaseUbuntuPackages.Contains($CleanPkg)) {
                        $CustomPkgs += $CleanPkg
                    }
                }

                # Ensure fundamental tooling is retained
                if (-not ($CustomPkgs -contains "git")) { $CustomPkgs += "git" }
                if (-not ($CustomPkgs -contains "curl")) { $CustomPkgs += "curl" }

                $WslData.detected_packages = @($CustomPkgs | Sort-Object -Unique)
            }
        }
    } catch {
        Write-Warning "Failed to query WSL: $($_.Exception.Message)"
    }

    return $WslData
}
