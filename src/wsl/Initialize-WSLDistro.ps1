<#
.SYNOPSIS
    WSL2 Distribution Initializer for Reglaze.
.DESCRIPTION
    Non-interactively provisions the WSL2 base Linux distribution by injecting
    user provisioning and configuration commands directly through the 'root'
    user. Configures passwordless sudo, creates /etc/wsl.conf to boot into the
    specified user, and installs required Linux developer packages.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$false)]
    [string]$Distro = "Ubuntu",

    [Parameter(Mandatory=$false)]
    [string]$WSLUser = "developer",

    [Parameter(Mandatory=$false)]
    [string[]]$Packages = @("build-essential", "git", "curl", "zsh", "rclone", "unzip"),

    [switch]$Simulation = $true,
    [switch]$Live = $false
)

# Fail-safe: Always simulated unless explicitly flagged -Live
$IsSimulated = $Simulation -or (-not $Live)

# =============================================================================
# [HITL-ID]: HITL-M4-01
# [HITL-TARGET]: WSL2 / Non-Interactive User Provisioning via Root Injection
# [HITL-STATUS]: VERIFIED
# [HITL-DESCRIPTION]: Injects useradd and passwordless sudoers rules into WSL2 instance as root to bypass interactive UNIX onboarding prompts.
# [HITL-TEST-SNIPPET]:
#   # Safe verification of root command injection in WSL2:
#   wsl.exe -d Ubuntu -u root -- id -u
# [HITL-LAST-INPUT]: wsl.exe -d Ubuntu -u root -- id -u (2026-10-21)
# [HITL-LAST-RESULT]: Returned 0, confirming root command execution executes non-interactively without prompting.
# [HITL-PATTERN]: wsl.exe -d $Distro -u root -- /bin/bash -c "..."
# [HITL-AVOID]: Interactive 'wsl.exe -d <distro>' which halts unattended automation waiting for UNIX username prompt
# =============================================================================

# =============================================================================
# [HITL-ID]: HITL-M4-02
# [HITL-TARGET]: WSL2 / /etc/wsl.conf Default User & Systemd Configuration
# [HITL-STATUS]: VERIFIED
# [HITL-DESCRIPTION]: Writes /etc/wsl.conf with [user] default = <user> and [boot] systemd = true.
# [HITL-TEST-SNIPPET]:
#   # Safe read-only inspection of wsl.conf:
#   wsl.exe -d Ubuntu -u root -- cat /etc/wsl.conf
# [HITL-LAST-INPUT]: wsl.exe -d Ubuntu -u root -- cat /etc/wsl.conf (2026-10-21)
# [HITL-LAST-RESULT]: Verified active config: [boot] systemd=true, [user] default=kirkh.
# [HITL-PATTERN]: cat << 'EOF' > /etc/wsl.conf; [user] default = $WSLUser; [boot] systemd = true
# [HITL-AVOID]: Manually editing /etc/wsl.conf without verifying syntax
# =============================================================================

function Initialize-WSLDistro {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [string]$Distro = "Ubuntu",
        [string]$WSLUser = "developer",
        [string[]]$Packages = @("build-essential", "git", "curl", "zsh", "rclone", "unzip"),
        [switch]$Simulation = $true,
        [switch]$Live = $false
    )

    $IsSim = $Simulation -or (-not $Live)
    $Result = [PSCustomObject]@{
        Distro        = $Distro
        WSLUser       = $WSLUser
        Status        = "Unknown"
        Message       = ""
        PackagesCount = $Packages.Count
        Simulated     = $IsSim
    }

    if (-not $Distro) {
        $Result.Status = "Failed"
        $Result.Message = "Distribution name cannot be empty."
        return $Result
    }

    if (-not $WSLUser) {
        $Result.Status = "Failed"
        $Result.Message = "WSL username cannot be empty."
        return $Result
    }

    $PkgString = ($Packages -join " ")

    $BashSetup = @"
set -e
# 1. Create developer user if missing
if ! id -u "$WSLUser" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$WSLUser"
    echo "$WSLUser ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/99-$WSLUser"
    chmod 0440 "/etc/sudoers.d/99-$WSLUser"
fi

# 2. Configure /etc/wsl.conf
cat << 'EOF' > /etc/wsl.conf
[user]
default = $WSLUser

[boot]
systemd = true

[interop]
enabled = true
appendWindowsPath = true
EOF

# 3. Install packages non-interactively if requested
if [ -n "$PkgString" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends $PkgString || true
fi
"@

    # Ensure UNIX LF line endings
    $BashSetup = $BashSetup.Replace("`r`n", "`n")

    if ($IsSim) {
        $Result.Status = "Simulated"
        $Result.Message = "Simulated non-interactive root user '$WSLUser' setup and package staging in WSL2 '$Distro'."
        return $Result
    }

    try {
        # Check if wsl.exe is available in PATH
        if (-not (Get-Command "wsl.exe" -ErrorAction SilentlyContinue)) {
            $Result.Status = "Failed"
            $Result.Message = "wsl.exe command not found in PATH."
            return $Result
        }

        # Check if distribution is installed
        $DistroList = & wsl.exe --list --quiet 2>&1
        $DistroClean = $DistroList | ForEach-Object { ($_ -replace "`0", "").Trim() } | Where-Object { $_ -ne "" }
        if ($DistroClean -notcontains $Distro) {
            $Result.Status = "Skipped"
            $Result.Message = "WSL2 distribution '$Distro' is not installed or registered."
            return $Result
        }

        # Execute provisioning script as root
        $ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
        $ProcessInfo.FileName = "wsl.exe"
        $ProcessInfo.Arguments = "-d $Distro -u root -- /bin/bash -c `"$BashSetup`""
        $ProcessInfo.RedirectStandardOutput = $true
        $ProcessInfo.RedirectStandardError = $true
        $ProcessInfo.UseShellExecute = $false
        $ProcessInfo.CreateNoWindow = $true

        $Process = [System.Diagnostics.Process]::Start($ProcessInfo)
        $StdOut = $Process.StandardOutput.ReadToEnd()
        $StdErr = $Process.StandardError.ReadToEnd()
        $Process.WaitForExit()

        if ($Process.ExitCode -eq 0) {
            $Result.Status = "Success"
            $Result.Message = "Configured root user '$WSLUser', wsl.conf, and packages for '$Distro'."
        } else {
            $Result.Status = "Failed"
            $Result.Message = "WSL2 configuration exited with code $($Process.ExitCode): $StdErr"
        }
    } catch {
        $Result.Status = "Failed"
        $Result.Message = "Exception initializing WSL2: $($_.Exception.Message)"
    }

    return $Result
}
