<#
.SYNOPSIS
    Windows 11 autounattend.xml generator for Reglaze.
.DESCRIPTION
    Compiles a deployment answer file with WinPE dynamic disk matching, OS partitioning,
    unattended specialization, LocalAdmin provisioning with AutoLogon count 1,
    standard primary user creation, and FirstLogon bootstrap invocation.
#>
[CmdletBinding()]
param()

function Build-AutounattendXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Blueprint,

        [Parameter(Mandatory=$false)]
        [PSCustomObject]$AuditReference = $null,

        [Parameter(Mandatory=$true)]
        [string]$OutputPath
    )

    $ComputerName = if ($Blueprint.system.computer_name) { $Blueprint.system.computer_name } else { "DESKTOP" }
    $TimeZone = if ($Blueprint.system.timezone) { $Blueprint.system.timezone } else { "Central Standard Time" }
    
    # User Account Configuration
    $AdminUser = if ($Blueprint.system.users.local_admin.username) { $Blueprint.system.users.local_admin.username } else { "LocalAdmin" }
    $AdminPassEnv = if ($Blueprint.system.users.local_admin.password_env) { $Blueprint.system.users.local_admin.password_env } else { "LOCAL_ADMIN_PASSWORD" }
    $AdminPassword = [System.Environment]::GetEnvironmentVariable($AdminPassEnv)
    if (-not $AdminPassword) { $AdminPassword = "ReglazeLocalAdmin2026!" }

    $PrimaryUser = if ($Blueprint.system.users.primary_user.username) { $Blueprint.system.users.primary_user.username } else { "User" }
    $PrimaryIsAdmin = if ($null -ne $Blueprint.system.users.primary_user.is_admin) { $Blueprint.system.users.primary_user.is_admin } else { $false }
    $PrimaryGroup = if ($PrimaryIsAdmin) { "Administrators" } else { "Users" }

    # Target OS Disk Matching Parameters
    $TargetSerial = if ($Blueprint.disks.target_os_disk.serial_number) { $Blueprint.disks.target_os_disk.serial_number } else { "" }
    $TargetBus = if ($Blueprint.disks.target_os_disk.bus_type) { $Blueprint.disks.target_os_disk.bus_type } else { "NVMe" }
    $TargetDiskId = if ($null -ne $Blueprint.disks.target_os_disk.disk_id) { $Blueprint.disks.target_os_disk.disk_id } else { 0 }

    # Preserved Disk Serial Numbers
    $PreservedSerials = @()
    if ($Blueprint.disks.preserved_disks) {
        foreach ($pd in $Blueprint.disks.preserved_disks) {
            if ($pd.serial_number) { $PreservedSerials += "`"$($pd.serial_number)`"" }
        }
    }
    $PreservedSerialsParam = $PreservedSerials -join ","

    # Product Key (use Retail Pro generic KMS key for installation if digital license)
    $ProductKey = "VK7JG-NPHTM-C97JM-9MPGT-3V66T"
    if ($AuditReference -and $AuditReference.system_and_licensing.installed_product_key) {
        $AuditKey = $AuditReference.system_and_licensing.installed_product_key
        if ($AuditKey -match '^[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}$') {
            $ProductKey = $AuditKey
        }
    }

    $XmlContent = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage>
        <UILanguage>en-US</UILanguage>
      </SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DiskConfiguration>
        <WillShowUI>OnError</WillShowUI>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData>
              <Key>/IMAGE/NAME</Key>
              <Value>Windows 11 Pro</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>$TargetDiskId</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
          <WillShowUI>OnError</WillShowUI>
        </OSImage>
      </ImageInstall>
      <UserData>
        <ProductKey>
          <Key>$ProductKey</Key>
          <WillShowUI>OnError</WillShowUI>
        </ProductKey>
        <AcceptEula>true</AcceptEula>
      </UserData>
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>1</Order>
          <Description>Dynamic Disk Signature Verification</Description>
          <Path>powershell.exe -ExecutionPolicy Bypass -Command "&amp; { `$dm = (Get-PSDrive -PSProvider FileSystem | ForEach-Object { (Join-Path `$_.Root 'Reglaze\DiskMatch.ps1'), (Join-Path `$_.Root 'DiskMatch.ps1') } | Where-Object { Test-Path `$_ } | Select-Object -First 1); if (`$dm) { &amp; `$dm -TargetSerialNumber '$TargetSerial' -TargetBusType '$TargetBus' -TargetDiskId $TargetDiskId -PreservedSerialNumbers @($PreservedSerialsParam) -DiskpartOutputPath X:\diskpart.txt } else { Write-Error 'DiskMatch.ps1 not found on any drive' } }"</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>2</Order>
          <Description>Execute Dynamic Disk Partitioning</Description>
          <Path>cmd.exe /c if exist X:\diskpart.txt diskpart.exe /s X:\diskpart.txt</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>

  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>$ComputerName</ComputerName>
      <TimeZone>$TimeZone</TimeZone>
    </component>
  </settings>

  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <AutoLogon>
        <Password>
          <Value>$AdminPassword</Value>
          <PlainText>true</PlainText>
        </Password>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
        <Username>$AdminUser</Username>
      </AutoLogon>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreens>true</HideOEMRegistrationScreens>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>$AdminPassword</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
        <LocalAccounts>
          <LocalAccount wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <Password>
              <Value>$AdminPassword</Value>
              <PlainText>true</PlainText>
            </Password>
            <Description>Reglaze Automated Provisioning Administrator</Description>
            <DisplayName>$AdminUser</DisplayName>
            <Group>Administrators</Group>
            <Name>$AdminUser</Name>
          </LocalAccount>
          <LocalAccount wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <Password>
              <Value></Value>
              <PlainText>true</PlainText>
            </Password>
            <Description>Reglaze Standard Daily Driver</Description>
            <DisplayName>$PrimaryUser</DisplayName>
            <Group>$PrimaryGroup</Group>
            <Name>$PrimaryUser</Name>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>1</Order>
          <Description>Launch Reglaze Machine Bootstrap</Description>
          <CommandLine>powershell.exe -ExecutionPolicy Bypass -NoExit -Command "&amp; { if (-not (Test-Path C:\Reglaze\payload\bootstrap.ps1)) { `$src = (Get-PSDrive -PSProvider FileSystem | ForEach-Object { Join-Path `$_.Root 'payload' } | Where-Object { Test-Path (Join-Path `$_ 'bootstrap.ps1') } | Select-Object -First 1); if (`$src) { New-Item -ItemType Directory -Path C:\Reglaze -Force | Out-Null; Copy-Item -Path `$src -Destination C:\Reglaze\payload -Recurse -Force } }; if (Test-Path C:\Reglaze\payload\bootstrap.ps1) { &amp; C:\Reglaze\payload\bootstrap.ps1 } else { Write-Error 'Reglaze bootstrap payload not found.' } }"</CommandLine>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
"@

    $OutDir = Split-Path -Parent $OutputPath
    if ($OutDir -and -not (Test-Path $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }

    $XmlContent | Set-Content -Path $OutputPath -Encoding UTF8
    return $OutputPath
}
