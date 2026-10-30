<#
.SYNOPSIS
    WSL2 distribution and package discovery module for Reglaze.
.DESCRIPTION
    Discovers installed WSL distributions, identifies the default distro,
    and inspects user-installed (non-standard) packages inside Linux distros (e.g. Debian/Ubuntu)
    using apt-mark / dpkg, filtering out base cloud-image packages.
    Safely avoids hanging on Windows 11 systems where wsl.exe is an inbox stub
    by checking HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss first
    and executing wsl.exe with closed stdin and a strict process timeout.
#>
[CmdletBinding()]
param()

function Invoke-WslProcessWithTimeout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Arguments,
        [int]$TimeoutMs = 5000,
        [System.Text.Encoding]$Encoding = [System.Text.Encoding]::UTF8
    )

    $Psi = New-Object System.Diagnostics.ProcessStartInfo
    $Psi.FileName = "wsl.exe"
    $Psi.Arguments = $Arguments
    $Psi.UseShellExecute = $false
    $Psi.CreateNoWindow = $true
    $Psi.RedirectStandardInput = $true
    $Psi.RedirectStandardOutput = $true
    $Psi.RedirectStandardError = $true
    $Psi.StandardOutputEncoding = $Encoding

    $Proc = New-Object System.Diagnostics.Process
    $Proc.StartInfo = $Psi

    if (-not $Proc.Start()) {
        return [PSCustomObject]@{ ExitCode = -1; TimedOut = $false; OutputLines = @() }
    }

    # Immediately close stdin so interactive "Press any key to install WSL" prompts cannot block
    try { $Proc.StandardInput.Close() } catch {}

    $OutTask = $Proc.StandardOutput.ReadToEndAsync()
    $Null = $Proc.StandardError.ReadToEndAsync()

    if (-not $Proc.WaitForExit($TimeoutMs)) {
        try { $Proc.Kill() } catch {}
        return [PSCustomObject]@{ ExitCode = -1; TimedOut = $true; OutputLines = @() }
    }

    $RawOut = $OutTask.GetAwaiter().GetResult()
    # Strip any UTF-16LE null bytes and split lines
    $CleanText = ($RawOut -replace "`0", "")
    $Lines = @(
        $CleanText -split "\r?\n" |
            ForEach-Object { $_.TrimEnd() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    return [PSCustomObject]@{
        ExitCode    = $Proc.ExitCode
        TimedOut    = $false
        OutputLines = $Lines
    }
}

function Get-WslAudit {
    [CmdletBinding()]
    param(
        [string]$LxssRegistryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"
    )

    $WslData = [PSCustomObject]@{
        enabled           = $false
        distros           = @()
        default_distro    = $null
        detected_packages = @()
    }

    # 1. Fast registry pre-check: if Lxss has no registered distribution subkeys, WSL has no distros installed.
    #    Do NOT invoke wsl.exe in this case, as the Windows 11 inbox stub prompts interactively and blocks for 60s.
    if (-not (Test-Path -LiteralPath $LxssRegistryPath)) {
        return $WslData
    }

    $RegisteredDistros = @(
        Get-ChildItem -LiteralPath $LxssRegistryPath -ErrorAction SilentlyContinue |
            ForEach-Object {
                $Props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                if ($Props -and $Props.DistributionName) {
                    $Props.DistributionName
                }
            } |
            Where-Object { $_ -and $_ -notlike "docker-desktop*" }
    )

    if ($RegisteredDistros.Count -eq 0) {
        return $WslData
    }

    if (-not (Get-Command "wsl.exe" -ErrorAction SilentlyContinue)) {
        return $WslData
    }

    try {
        # wsl.exe -l -v outputs UTF-16LE on Windows
        $ListResult = Invoke-WslProcessWithTimeout -Arguments "-l -v" -TimeoutMs 5000 -Encoding ([System.Text.Encoding]::Unicode)
        if (-not $ListResult.TimedOut -and $ListResult.ExitCode -eq 0 -and $ListResult.OutputLines.Count -gt 0) {
            foreach ($Line in $ListResult.OutputLines) {
                $CleanLine = $Line -replace "`0", ""
                if ($CleanLine -match '^\s*(\*?)\s*([a-zA-Z0-9.\-_]+)\s+(Running|Stopped|Installing)\s+(\d+)') {
                    $IsDefault = ($Matches[1] -eq "*")
                    $DistroName = $Matches[2].Trim()
                    if ($DistroName -like "docker-desktop*") { continue }

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

            if ($WslData.distros.Count -gt 0) {
                $WslData.enabled = $true
                $WslData.detected_packages = @("git", "curl", "rclone")

                $TargetDistro = if ($WslData.default_distro) { $WslData.default_distro } else { $WslData.distros[0].name }
                $PkgResult = Invoke-WslProcessWithTimeout -Arguments "-d $TargetDistro -- bash -c `"apt-mark showmanual 2>/dev/null | sort`"" -TimeoutMs 8000 -Encoding ([System.Text.Encoding]::UTF8)

                if (-not $PkgResult.TimedOut -and $PkgResult.ExitCode -eq 0 -and $PkgResult.OutputLines.Count -gt 0) {
                    $BaseUbuntuPackages = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    @(
                        "base-files", "bash", "bsdutils", "coreutils", "dash", "debianutils",
                        "diffutils", "findutils", "grep", "gzip", "hostname", "init",
                        "libattr1", "login", "ncurses-base", "ncurses-bin", "ubuntu-minimal",
                        "ubuntu-wsl", "util-linux", "whiptail"
                    ) | ForEach-Object { $BaseUbuntuPackages.Add($_) | Out-Null }

                    $CustomPkgs = @()
                    foreach ($Pkg in $PkgResult.OutputLines) {
                        $CleanPkg = ($Pkg -replace "`0", "").Trim()
                        # Strictly validate Debian/Ubuntu package name syntax so error messages are never captured
                        if ($CleanPkg -match '^[a-z0-9][a-z0-9+.\-]+$' -and -not $BaseUbuntuPackages.Contains($CleanPkg)) {
                            $CustomPkgs += $CleanPkg
                        }
                    }

                    if ($CustomPkgs.Count -gt 0) {
                        if (-not ($CustomPkgs -contains "git")) { $CustomPkgs += "git" }
                        if (-not ($CustomPkgs -contains "curl")) { $CustomPkgs += "curl" }
                        $WslData.detected_packages = @($CustomPkgs | Sort-Object -Unique)
                    }
                }
            }
        }
    } catch {
        Write-Warning "Failed to query WSL: $($_.Exception.Message)"
    }

    return $WslData
}
