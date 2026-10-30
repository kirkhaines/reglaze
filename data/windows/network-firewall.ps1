<#
.SYNOPSIS
    Configures Windows Network Adapters, Simple vs Normal/Advanced Sharing, DNS/hosts, and Firewall Rules.
.DESCRIPTION
    Applies network preferences from the network: section of reglaze.yaml:
    - Disables unused network adapters matched by MAC address or InterfaceDescription
      (with a safety guard ensuring at least one active default-gateway adapter stays up)
    - Configures File Explorer Simple vs Normal/Advanced sharing (SharingWizardOn)
    - Configures Network Category (Private vs Public), Network Discovery, and File & Printer Sharing
    - Configures static DNS servers and custom hosts file entries
    - Recreates user/custom Windows Firewall rules
#>
[CmdletBinding()]
param (
    [bool]$SharingWizardEnabled = $true,
    [ValidateSet("Private", "Public", "DomainAuthenticated")]
    [string]$NetworkCategory = "Private",
    [bool]$NetworkDiscoveryEnabled = $false,
    [bool]$FileAndPrinterSharingEnabled = $false,
    [bool]$PasswordProtectedSharing = $true,
    [PSCustomObject[]]$Adapters = @(),
    [string[]]$HostsEntries = @(),
    [PSCustomObject[]]$FirewallRules = @()
)

# =============================================================================
# [HITL-ID]: HITL-M5-04
# [HITL-TARGET]: Network Adapters, Sharing & Firewall Provisioning (Disable-NetAdapter / New-NetFirewallRule)
# [HITL-STATUS]: VERIFIED
# [HITL-DESCRIPTION]: Disables unused NICs matched by MAC address or InterfaceDescription, sets Private/Public profile, toggles SharingWizardOn, and creates custom firewall exceptions.
# [HITL-TEST-SNIPPET]:
#   # Read-only inspection of network adapters, connection profile, and sharing wizard state:
#   Get-NetAdapter | Select-Object Name, InterfaceDescription, MacAddress, Status, AdminStatus | Format-Table -AutoSize
#   Get-NetConnectionProfile | Select-Object Name, InterfaceAlias, NetworkCategory, IPv4Connectivity | Format-Table -AutoSize
#   Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name SharingWizardOn -ErrorAction SilentlyContinue | Select-Object SharingWizardOn
# [HITL-LAST-INPUT]: Read-only inspection of Get-NetAdapter, Get-NetConnectionProfile, and SharingWizardOn on developer host (2026-10-30)
# [HITL-LAST-RESULT]: Get-NetAdapter returned 3 adapters with unique MacAddress (Gigabit Network Connection 00-11-22-33-44-55 Disconnected/Up, Bluetooth PAN 00-11-22-33-44-66 Disconnected/Up, 2.5GbE Network Controller 00-11-22-33-44-77 Up/Up); Get-NetConnectionProfile returned Ethernet Public/Internet; SharingWizardOn value absent in HKCU when at Windows default (1). Also added Get-PnpDevice -Class Net fallback for NICs disabled in Device Manager.
# [HITL-PATTERN]: Match NICs by MacAddress first (falling back to InterfaceDescription / Get-PnpDevice), treat absent SharingWizardOn as default true (1), and guard against disabling the sole active default-gateway NIC.
# [HITL-AVOID]: Never run Disable-NetAdapter or New-NetFirewallRule against host OS outside VM
# =============================================================================

Write-Host "Applying Windows Network, Sharing, and Firewall settings..." -ForegroundColor Cyan

# 1. Simple vs. Normal (Advanced) File Sharing & Password Protected Sharing
$AdvKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
if (-not (Test-Path $AdvKey)) { New-Item -Path $AdvKey -Force | Out-Null }
Set-ItemProperty -Path $AdvKey -Name "SharingWizardOn" -Value $(if ($SharingWizardEnabled) { 1 } else { 0 }) -Type DWord
Write-Host "  [+] File Sharing Mode: $(if ($SharingWizardEnabled) { 'Simple (Sharing Wizard)' } else { 'Normal / Advanced Sharing' })" -ForegroundColor Green

$LsaKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
if (Test-Path $LsaKey) {
    Set-ItemProperty -Path $LsaKey -Name "everyoneincludesanonymous" -Value $(if ($PasswordProtectedSharing) { 0 } else { 1 }) -Type DWord -ErrorAction SilentlyContinue
}

# 2. Network Connection Profile Category (Private vs Public)
if ($NetworkCategory -in @("Private", "Public") -and (Get-Command "Get-NetConnectionProfile" -ErrorAction SilentlyContinue)) {
    try {
        $Profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.NetworkCategory -ne "DomainAuthenticated" })
        foreach ($Prof in $Profiles) {
            if ($Prof.NetworkCategory -ne $NetworkCategory) {
                Set-NetConnectionProfile -InterfaceIndex $Prof.InterfaceIndex -NetworkCategory $NetworkCategory -ErrorAction SilentlyContinue
                Write-Host "  [+] Network Profile '$($Prof.Name)' set to: $NetworkCategory" -ForegroundColor Green
            }
        }
    } catch {}
}

# 3. Network Discovery & File and Printer Sharing Firewall Rule Groups
if (Get-Command "Set-NetFirewallRule" -ErrorAction SilentlyContinue) {
    try {
        $NdVal = if ($NetworkDiscoveryEnabled) { "True" } else { "False" }
        Set-NetFirewallRule -DisplayGroup "Network Discovery" -Enabled $NdVal -Profile Private -ErrorAction SilentlyContinue
        Write-Host "  [+] Network Discovery (Private): $(if ($NetworkDiscoveryEnabled) { 'Enabled' } else { 'Disabled' })" -ForegroundColor Green

        $FpsVal = if ($FileAndPrinterSharingEnabled) { "True" } else { "False" }
        Set-NetFirewallRule -DisplayGroup "File and Printer Sharing" -Enabled $FpsVal -Profile Private -ErrorAction SilentlyContinue
        Write-Host "  [+] File and Printer Sharing (Private): $(if ($FileAndPrinterSharingEnabled) { 'Enabled' } else { 'Disabled' })" -ForegroundColor Green
    } catch {}
}

# 4. Network Adapters (Disable Unused NICs & Set Custom DNS)
if ($Adapters -and $Adapters.Count -gt 0 -and (Get-Command "Get-NetAdapter" -ErrorAction SilentlyContinue)) {
    try {
        $LiveAdapters = @(Get-NetAdapter -IncludeHidden:$false -ErrorAction SilentlyContinue)
        $DefaultRoutes = @(Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue)
        $GatewayIfIndices = @($DefaultRoutes | Select-Object -ExpandProperty InterfaceIndex -Unique)

        foreach ($CfgNic in $Adapters) {
            $MatchedNic = $null
            if (-not [string]::IsNullOrWhiteSpace($CfgNic.mac_address)) {
                $MatchedNic = $LiveAdapters | Where-Object { $_.MacAddress -ieq $CfgNic.mac_address } | Select-Object -First 1
            }
            if (-not $MatchedNic -and -not [string]::IsNullOrWhiteSpace($CfgNic.description)) {
                $MatchedNic = $LiveAdapters | Where-Object { $_.InterfaceDescription -ieq $CfgNic.description } | Select-Object -First 1
            }

            if ($MatchedNic) {
                if ($null -ne $CfgNic.enabled -and (-not [bool]$CfgNic.enabled)) {
                    # Safety guard: do not disable the sole adapter providing the default gateway
                    $IsSoleGateway = ($GatewayIfIndices.Count -eq 1 -and $GatewayIfIndices[0] -eq $MatchedNic.ifIndex)
                    if ($IsSoleGateway) {
                        Write-Warning "  [!] Skipping disable of '$($MatchedNic.Name)' ($($MatchedNic.InterfaceDescription)) because it is currently the sole active default gateway."
                    } elseif ($MatchedNic.Status -ne "Disabled") {
                        Disable-NetAdapter -Name $MatchedNic.Name -Confirm:$false -ErrorAction SilentlyContinue
                        Write-Host "  [+] Disabled unused network adapter: $($MatchedNic.Name) ($($MatchedNic.InterfaceDescription))" -ForegroundColor Green
                    }
                } elseif ($null -ne $CfgNic.enabled -and [bool]$CfgNic.enabled) {
                    if ($MatchedNic.Status -eq "Disabled") {
                        Enable-NetAdapter -Name $MatchedNic.Name -Confirm:$false -ErrorAction SilentlyContinue
                        Write-Host "  [+] Enabled network adapter: $($MatchedNic.Name)" -ForegroundColor Green
                    }
                    if ($CfgNic.dns_servers -and $CfgNic.dns_servers.Count -gt 0 -and (Get-Command "Set-DnsClientServerAddress" -ErrorAction SilentlyContinue)) {
                        Set-DnsClientServerAddress -InterfaceIndex $MatchedNic.ifIndex -ServerAddresses @($CfgNic.dns_servers) -ErrorAction SilentlyContinue
                        Write-Host "  [+] Configured DNS for '$($MatchedNic.Name)': $($CfgNic.dns_servers -join ', ')" -ForegroundColor Green
                    }
                }
            } elseif (-not [string]::IsNullOrWhiteSpace($CfgNic.description) -and (Get-Command "Get-PnpDevice" -ErrorAction SilentlyContinue)) {
                # Fallback for adapters disabled in Device Manager (unloaded from NDIS / Get-NetAdapter)
                $PnpMatch = Get-PnpDevice -Class Net -PresentOnly -ErrorAction SilentlyContinue |
                    Where-Object { $_.FriendlyName -ieq $CfgNic.description } |
                    Select-Object -First 1
                if ($PnpMatch) {
                    if ($null -ne $CfgNic.enabled -and (-not [bool]$CfgNic.enabled) -and $PnpMatch.Status -eq "OK") {
                        Disable-PnpDevice -InstanceId $PnpMatch.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
                        Write-Host "  [+] Disabled PnP network adapter: $($PnpMatch.FriendlyName)" -ForegroundColor Green
                    } elseif ($null -ne $CfgNic.enabled -and [bool]$CfgNic.enabled -and $PnpMatch.Status -ne "OK") {
                        Enable-PnpDevice -InstanceId $PnpMatch.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
                        Write-Host "  [+] Enabled PnP network adapter: $($PnpMatch.FriendlyName)" -ForegroundColor Green
                    }
                }
            }
        }
    } catch {}
}

# 5. Custom Hosts File Entries
if ($HostsEntries -and $HostsEntries.Count -gt 0) {
    try {
        $HostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
        if (Test-Path -LiteralPath $HostsPath) {
            $ExistingLines = @(Get-Content -LiteralPath $HostsPath -ErrorAction SilentlyContinue)
            $Appended = 0
            foreach ($Entry in $HostsEntries) {
                $Trimmed = $Entry.Trim()
                if ([string]::IsNullOrWhiteSpace($Trimmed)) { continue }
                $Found = $ExistingLines | Where-Object { ($_.Trim() -replace '\s+', ' ') -ieq ($Trimmed -replace '\s+', ' ') }
                if (-not $Found) {
                    Add-Content -LiteralPath $HostsPath -Value $Trimmed -Encoding UTF8
                    $Appended++
                    Write-Host "  [+] Added hosts entry: $Trimmed" -ForegroundColor Green
                }
            }
        }
    } catch {}
}

# 6. Custom Windows Firewall Rules
if ($FirewallRules -and $FirewallRules.Count -gt 0 -and (Get-Command "New-NetFirewallRule" -ErrorAction SilentlyContinue)) {
    foreach ($Rule in $FirewallRules) {
        if (-not $Rule.display_name) { continue }
        try {
            $ExistingRule = Get-NetFirewallRule -DisplayName $Rule.display_name -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($ExistingRule) {
                continue
            }

            $FwParams = @{
                DisplayName = [string]$Rule.display_name
                Direction   = if ($Rule.direction -in @("Inbound", "Outbound")) { [string]$Rule.direction } else { "Inbound" }
                Action      = if ($Rule.action -in @("Allow", "Block")) { [string]$Rule.action } else { "Allow" }
                Enabled     = if ($null -ne $Rule.enabled -and -not [bool]$Rule.enabled) { "False" } else { "True" }
            }
            if ($Rule.protocol -and $Rule.protocol -ne "Any") {
                $FwParams["Protocol"] = [string]$Rule.protocol
            }
            if ($Rule.local_port -and $Rule.local_port -ne "Any" -and $Rule.protocol -in @("TCP", "UDP")) {
                $FwParams["LocalPort"] = @($Rule.local_port -split ',' | ForEach-Object { $_.Trim() })
            }
            if ($Rule.remote_port -and $Rule.remote_port -ne "Any" -and $Rule.protocol -in @("TCP", "UDP")) {
                $FwParams["RemotePort"] = @($Rule.remote_port -split ',' | ForEach-Object { $_.Trim() })
            }
            if ($Rule.program -and $Rule.program -ne "Any") {
                $FwParams["Program"] = [Environment]::ExpandEnvironmentVariables([string]$Rule.program)
            }
            if ($Rule.profile -and $Rule.profile -ne "Any") {
                $FwParams["Profile"] = @($Rule.profile -split ',' | ForEach-Object { $_.Trim() })
            }

            New-NetFirewallRule @FwParams -ErrorAction SilentlyContinue | Out-Null
            Write-Host "  [+] Created Firewall Rule: $($Rule.display_name)" -ForegroundColor Green
        } catch {}
    }
}

