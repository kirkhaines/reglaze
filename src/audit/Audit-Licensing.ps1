<#
.SYNOPSIS
    Windows OS version, build, and licensing audit module for Reglaze.
.DESCRIPTION
    Extracts OS Edition, Build Number, License Status, Channel (Retail/OEM/Volume),
    and partial or full product key details.
#>
[CmdletBinding()]
param()

function Get-LicensingAudit {
    [CmdletBinding()]
    param()

    $OsInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $LicenseProduct = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*Windows*" } | Select-Object -First 1

    $Edition = if ($OsInfo) { $OsInfo.Caption.Replace("Microsoft ", "").Trim() } else { "Windows 11 Pro" }
    $Build = if ($OsInfo) { $OsInfo.BuildNumber } else { "26100" }
    $FullVersion = if ($OsInfo) { "$($OsInfo.Caption) $($OsInfo.Version) (Build $Build)" } else { "Microsoft Windows 11 Build $Build" }

    $Channel = "Retail"
    $Status = "Licensed"
    $PartialKey = "UNKNOWN"

    if ($LicenseProduct) {
        if ($LicenseProduct.Description -match "RETAIL") {
            $Channel = "Retail"
        } elseif ($LicenseProduct.Description -match "OEM") {
            $Channel = "OEM"
        } elseif ($LicenseProduct.Description -match "VOLUME") {
            $Channel = "Volume"
        }

        $Status = if ($LicenseProduct.LicenseStatus -eq 1) { "Licensed" } else { "Unlicensed" }
        $PartialKey = if ($LicenseProduct.PartialProductKey) { "XXXXX-XXXXX-XXXXX-XXXXX-$($LicenseProduct.PartialProductKey)" } else { "Digital License" }
    }

    # Query BIOS / firmware embedded OEM key if present
    $FirmwareKey = $null
    try {
        $DpmKey = (Get-CimInstance -Namespace root/cimv2 -ClassName SoftwareLicensingService -ErrorAction SilentlyContinue).OA3xOriginalProductKey
        if ($DpmKey) {
            $FirmwareKey = $DpmKey
        }
    } catch {}

    $InstalledKey = if ($FirmwareKey) { $FirmwareKey } else { $PartialKey }

    return [PSCustomObject]@{
        os_version            = $FullVersion
        os_edition            = $Edition
        os_build              = $Build
        installed_product_key = $InstalledKey
        license_status        = $Status
        license_channel       = $Channel
        digital_license       = ($Status -eq "Licensed")
    }
}

function Get-UserIdentityAudit {
    [CmdletBinding()]
    param()

    $Email = $null

    # 1. Query Microsoft Connected Account email from IdentityCRL
    try {
        $MsaKeys = Get-ChildItem "HKCU:\Software\Microsoft\IdentityCRL\UserExtendedProperties" -ErrorAction SilentlyContinue
        if ($MsaKeys) {
            $Email = ($MsaKeys | Select-Object -First 1 -ExpandProperty PSChildName)
        }
    } catch {}

    # 2. Query Git global email
    if (-not $Email) {
        try {
            $GitEmail = & git config --global user.email 2>$null
            if ($GitEmail -and $GitEmail.Contains("@")) {
                $Email = $GitEmail.Trim()
            }
        } catch {}
    }

    # 3. Query whoami /upn
    if (-not $Email) {
        try {
            $Upn = & whoami /upn 2>$null
            if ($Upn -and $Upn.Contains("@")) {
                $Email = $Upn.Trim()
            }
        } catch {}
    }

    $IsDetected = ($Email -ne $null)
    if (-not $Email) {
        $Email = "$($env:USERNAME)@example.com"
    }

    return [PSCustomObject]@{
        username       = $env:USERNAME
        email          = $Email
        account_type   = if ($IsDetected) { "local_to_msa" } else { "local" }
        email_detected = $IsDetected
    }
}


