<#
.SYNOPSIS
    Network adapter, sharing mode, DNS/hosts, and custom firewall rule discovery module for Reglaze.
.DESCRIPTION
    Performs strictly read-only inspection of network adapters (capturing disabled unused adapters
    by MAC address and description), File Explorer Simple vs Normal/Advanced sharing mode,
    network profile category (Private vs Public), Network Discovery / File & Printer Sharing state,
    custom hosts file entries, and user-created Windows Firewall exceptions.
#>
[CmdletBinding()]
param()

function Get-NetworkAudit {
    [CmdletBinding()]
    param(
        [string[]]$IgnoredProgramPatterns = @()
    )

    $NetworkData = [PSCustomObject]@{
        sharing_wizard_enabled           = $true
        network_category                 = "Private"
        network_discovery_enabled        = $false
        file_and_printer_sharing_enabled = $false
        password_protected_sharing       = $true
        adapters                         = @()
        hosts_entries                    = @()
        firewall_rules                   = @()
    }

    # 1. Simple vs. Normal (Advanced) Sharing & Password Protected Sharing
    try {
        $Adv = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -ErrorAction SilentlyContinue
        if ($Adv -and $null -ne $Adv.SharingWizardOn) {
            # SharingWizardOn = 0 means Normal/Advanced sharing tab; 1 means Simple sharing wizard
            $NetworkData.sharing_wizard_enabled = ($Adv.SharingWizardOn -ne 0)
        }

        $Lsa = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -ErrorAction SilentlyContinue
        if ($Lsa -and $null -ne $Lsa.everyoneincludesanonymous) {
            $NetworkData.password_protected_sharing = ($Lsa.everyoneincludesanonymous -eq 0)
        }
    } catch {}

    # 2. Active Network Connection Profile (Private vs Public)
    try {
        if (Get-Command "Get-NetConnectionProfile" -ErrorAction SilentlyContinue) {
            $Profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
            $PrimaryProfile = $Profiles | Where-Object { $_.IPv4Connectivity -eq "Internet" } | Select-Object -First 1
            if (-not $PrimaryProfile -and $Profiles.Count -gt 0) {
                $PrimaryProfile = $Profiles[0]
            }
            if ($PrimaryProfile -and $PrimaryProfile.NetworkCategory) {
                $NetworkData.network_category = [string]$PrimaryProfile.NetworkCategory
            }
        }
    } catch {}

    # 3. Network Adapters (Physical + Permanent Adapters, Enabled/Disabled State & Static DNS)
    try {
        if (Get-Command "Get-NetAdapter" -ErrorAction SilentlyContinue) {
            $RawAdapters = @(
                Get-NetAdapter -IncludeHidden:$false -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.Name -notmatch "^vEthernet" -and
                        $_.InterfaceDescription -notmatch "Hyper-V Virtual|WAN Miniport|Microsoft Kernel Debug|Microsoft Wi-Fi Direct Virtual|Terodo|ISATAP"
                    }
            )

            $AdapterList = [System.Collections.Generic.List[PSCustomObject]]::new()
            foreach ($Nic in $RawAdapters) {
                $IsEnabled = ($Nic.Status -ne "Disabled" -and $Nic.AdminStatus -ne "Down")
                $CustomDns = @()
                try {
                    # Check if static DNS servers are configured in registry for this interface GUID
                    if ($Nic.InterfaceGuid) {
                        $TcpipKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($Nic.InterfaceGuid)"
                        $TcpProps = Get-ItemProperty -LiteralPath $TcpipKey -ErrorAction SilentlyContinue
                        if ($TcpProps -and -not [string]::IsNullOrWhiteSpace($TcpProps.NameServer)) {
                            $CustomDns = @($TcpProps.NameServer -split '[,;\s]+' | Where-Object { $_ })
                        }
                    }
                } catch {}

                $AdapterList.Add([PSCustomObject]@{
                    name        = $Nic.Name
                    description = $Nic.InterfaceDescription
                    mac_address = $Nic.MacAddress
                    status      = [string]$Nic.Status
                    enabled     = [bool]$IsEnabled
                    physical    = [bool]$Nic.PhysicalMediaType
                    dns_servers = $CustomDns
                })
            }

            # Also inspect Get-PnpDevice -Class Net for physical PCI/USB network adapters disabled in Device Manager
            # (which are unloaded from NDIS and therefore omitted from Get-NetAdapter output)
            if (Get-Command "Get-PnpDevice" -ErrorAction SilentlyContinue) {
                $SeenDescriptions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($Existing in $AdapterList) {
                    if ($Existing.description) { [void]$SeenDescriptions.Add($Existing.description) }
                }

                $DisabledPnpNics = @(
                    Get-PnpDevice -Class Net -PresentOnly -ErrorAction SilentlyContinue |
                        Where-Object {
                            $_.InstanceId -match "^(PCI|USB)\\" -and
                            $_.FriendlyName -and
                            -not $SeenDescriptions.Contains($_.FriendlyName) -and
                            ($_.Status -ne "OK" -or $_.Problem -eq "CM_PROB_DISABLED")
                        }
                )
                foreach ($PnpNic in $DisabledPnpNics) {
                    [void]$SeenDescriptions.Add($PnpNic.FriendlyName)
                    $AdapterList.Add([PSCustomObject]@{
                        name        = $PnpNic.FriendlyName
                        description = $PnpNic.FriendlyName
                        mac_address = $null
                        status      = "Disabled"
                        enabled     = $false
                        physical    = $true
                        dns_servers = @()
                    })
                }
            }

            $NetworkData.adapters = $AdapterList.ToArray()
        }
    } catch {}

    # 4. Custom Hosts File Entries
    try {
        $HostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
        if (Test-Path -LiteralPath $HostsPath) {
            $HostsLines = Get-Content -LiteralPath $HostsPath -ErrorAction SilentlyContinue
            $CustomHosts = [System.Collections.Generic.List[string]]::new()
            foreach ($Line in $HostsLines) {
                $Trimmed = ($Line -replace '#.*$', '').Trim()
                if ([string]::IsNullOrWhiteSpace($Trimmed)) { continue }
                if ($Trimmed -match '^(127\.0\.0\.1|::1)\s+localhost$') { continue }
                $CustomHosts.Add($Trimmed)
            }
            $NetworkData.hosts_entries = $CustomHosts.ToArray()
        }
    } catch {}

    # 5. Network Discovery, File & Printer Sharing & Custom Firewall Exceptions
    try {
        if (Get-Command "Get-NetFirewallRule" -ErrorAction SilentlyContinue) {
            $AllRules = @(Get-NetFirewallRule -ErrorAction SilentlyContinue)

            $NetDiscActive = $AllRules | Where-Object {
                ($_.DisplayGroup -eq "Network Discovery" -or $_.Group -eq "@FirewallAPI.dll,-32752") -and
                $_.Enabled -eq "True" -and $_.Action -eq "Allow"
            } | Select-Object -First 1
            $NetworkData.network_discovery_enabled = ($null -ne $NetDiscActive)

            $FpsActive = $AllRules | Where-Object {
                ($_.DisplayGroup -eq "File and Printer Sharing" -or $_.Group -eq "@FirewallAPI.dll,-28502") -and
                $_.Enabled -eq "True" -and $_.Action -eq "Allow"
            } | Select-Object -First 1
            $NetworkData.file_and_printer_sharing_enabled = ($null -ne $FpsActive)

            # Filter to user/custom firewall rules (exclude OS @-grouped rules and UWP AppContainer Owner rules)
            $CandidateCustomRules = @(
                $AllRules | Where-Object {
                    [string]::IsNullOrWhiteSpace($_.Group) -and
                    [string]::IsNullOrWhiteSpace($_.Owner) -and
                    [string]::IsNullOrWhiteSpace($_.PackageFamilyName) -and
                    $_.Enabled -eq "True" -and
                    $_.DisplayName -notmatch "^(Core Networking|Windows Defender|Cast to Device|Wi-Fi Direct|mDNS|Cortana|Microsoft Edge|OneDrive|Delivery Optimization| AllJoyn|DIAL protocol|Wireless Display)"
                }
            )

            $FirewallEntries = [System.Collections.Generic.List[PSCustomObject]]::new()
            $SeenRuleSignatures = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

            foreach ($Rule in ($CandidateCustomRules | Select-Object -First 75)) {
                $PortFilter = $Rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
                $AppFilter = $Rule | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue

                $Protocol = if ($PortFilter -and $PortFilter.Protocol) { [string]$PortFilter.Protocol } else { "Any" }
                $LocalPort = if ($PortFilter -and $PortFilter.LocalPort) { ($PortFilter.LocalPort -join ",") } else { "Any" }
                $RemotePort = if ($PortFilter -and $PortFilter.RemotePort) { ($PortFilter.RemotePort -join ",") } else { "Any" }
                $Program = if ($AppFilter -and $AppFilter.Program) { [string]$AppFilter.Program } else { "Any" }

                # Skip rules belonging to standard Steam games or auto-registered browser mDNS rules if requested
                if ($Program -ne "Any" -and $Program -match '(?i)(\\Steam\\steamapps\\common\\|\\Google\\Chrome\\Application\\chrome\.exe|\\BraveSoftware\\|\\Mozilla Firefox\\)') {
                    continue
                }

                $Sig = "$($Rule.DisplayName)|$($Rule.Direction)|$($Rule.Action)|$Protocol|$LocalPort|$Program"
                if (-not $SeenRuleSignatures.Add($Sig)) { continue }

                $FirewallEntries.Add([PSCustomObject]@{
                    name        = $Rule.Name
                    display_name= $Rule.DisplayName
                    direction   = [string]$Rule.Direction
                    action      = [string]$Rule.Action
                    protocol    = $Protocol
                    local_port  = $LocalPort
                    remote_port = $RemotePort
                    program     = $Program
                    profile     = [string]$Rule.Profile
                    enabled     = ($Rule.Enabled -eq "True")
                })
            }
            $NetworkData.firewall_rules = $FirewallEntries.ToArray()
        }
    } catch {}

    return $NetworkData
}

