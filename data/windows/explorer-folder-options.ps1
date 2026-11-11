<#
.SYNOPSIS
    Configures Windows File Explorer preferences, context menu style, and relocated User Shell Folders.
.DESCRIPTION
    SCOPE: Phase 5 (User Scope - HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer)
    ORDERING DEPENDENCY:
      - Must run in the primary user's interactive session (never under LocalAdmin in Phase 4, which
        would only mutate LocalAdmin's HKCU hive and risk pre-creating uninitialized user folders).
      - Must run AFTER preserved drives are verified (Step 0) so secondary drive targets (e.g., D:\Downloads)
        exist, and BEFORE user directory junctions (Step 9) so Known Folder paths are established first.

    Applies developer-friendly Explorer settings:
    - Show hidden files and folders
    - Show file name extensions
    - Open File Explorer to "This PC" or "Quick Access"
    - Hide frequent folders / recent files from Quick Access
    - Restore Windows 10 Classic Right-Click Context Menu
    - Simple vs. Normal/Advanced File Sharing (SharingWizardOn in HKCU)
    - Relocate Known User Shell Folders (Desktop, Documents, Downloads, Pictures, Music, Videos)
#>
[CmdletBinding()]
param (
    [switch]$ShowHiddenFiles = $true,
    [switch]$ShowFileExtensions = $true,
    [ValidateSet("ThisPC", "QuickAccess")]
    [string]$LaunchTo = "ThisPC",
    [switch]$HideRecentFromQuickAccess = $true,
    [switch]$ClassicContextMenu = $false,
    [Nullable[bool]]$SharingWizardEnabled = $null,
    [PSCustomObject]$UserShellFolders = $null
)

Write-Host "Applying Windows Explorer folder options..." -ForegroundColor Cyan

$AdvancedKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
if (-not (Test-Path $AdvancedKey)) {
    New-Item -Path $AdvancedKey -Force | Out-Null
}

# 1. Show hidden files, folders, and drives
Set-ItemProperty -Path $AdvancedKey -Name "Hidden" -Value $(if ($ShowHiddenFiles) { 1 } else { 2 }) -Type DWord
if ($ShowHiddenFiles) {
    Set-ItemProperty -Path $AdvancedKey -Name "ShowSuperHidden" -Value 0 -Type DWord
}
Write-Host "  [+] Hidden files: $(if ($ShowHiddenFiles) { 'Visible' } else { 'Hidden' })" -ForegroundColor Green

# 2. Show file name extensions
Set-ItemProperty -Path $AdvancedKey -Name "HideFileExt" -Value $(if ($ShowFileExtensions) { 0 } else { 1 }) -Type DWord
Write-Host "  [+] File extensions: $(if ($ShowFileExtensions) { 'Visible' } else { 'Hidden' })" -ForegroundColor Green

# 3. Open Explorer to "This PC" (1) or "Quick Access / Home" (2)
$LaunchVal = if ($LaunchTo -eq "ThisPC") { 1 } else { 2 }
Set-ItemProperty -Path $AdvancedKey -Name "LaunchTo" -Value $LaunchVal -Type DWord
Write-Host "  [+] Launch Explorer to: $LaunchTo" -ForegroundColor Green

# 4. Hide recent files and frequent folders in Quick Access
$TrackVal = if ($HideRecentFromQuickAccess) { 0 } else { 1 }
Set-ItemProperty -Path $AdvancedKey -Name "Start_TrackDocs" -Value $TrackVal -Type DWord
Set-ItemProperty -Path $AdvancedKey -Name "ShowRecent" -Value $TrackVal -Type DWord -ErrorAction SilentlyContinue
Set-ItemProperty -Path $AdvancedKey -Name "ShowFrequent" -Value $TrackVal -Type DWord -ErrorAction SilentlyContinue
Write-Host "  [+] Quick Access recent tracking: $(if ($HideRecentFromQuickAccess) { 'Disabled' } else { 'Enabled' })" -ForegroundColor Green

# 5. Classic Right-Click Context Menu
$ClassicClsidPath = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
if ($ClassicContextMenu) {
    if (-not (Test-Path -LiteralPath $ClassicClsidPath)) {
        New-Item -Path $ClassicClsidPath -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $ClassicClsidPath -Name "(Default)" -Value "" -Type String
    Write-Host "  [+] Context Menu: Classic full menu enabled" -ForegroundColor Green
} else {
    $ParentClsid = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}"
    if (Test-Path -LiteralPath $ParentClsid) {
        Remove-Item -LiteralPath $ParentClsid -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 5b. Simple vs. Normal (Advanced) File Sharing (HKCU SharingWizardOn)
if ($null -ne $SharingWizardEnabled) {
    Set-ItemProperty -Path $AdvancedKey -Name "SharingWizardOn" -Value $(if ($SharingWizardEnabled) { 1 } else { 0 }) -Type DWord
    Write-Host "  [+] File Sharing Mode: $(if ($SharingWizardEnabled) { 'Simple (Sharing Wizard)' } else { 'Normal / Advanced Sharing' })" -ForegroundColor Green
}

# 6. Relocated Windows User Shell Folders
if ($UserShellFolders) {
    $UsfKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
    $SfKey  = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
    $FolderMap = @{
        desktop   = "Desktop"
        documents = "Personal"
        downloads = "{374DE290-123F-4565-9164-39C4925E467B}"
        pictures  = "My Pictures"
        music     = "My Music"
        videos    = "My Video"
    }
    foreach ($Key in $FolderMap.Keys) {
        if ($UserShellFolders.PSObject.Properties[$Key] -and -not [string]::IsNullOrWhiteSpace($UserShellFolders.$Key)) {
            $TargetFolder = $UserShellFolders.$Key
            # Safety guard: never pre-create C:\Users\<user> for an uninitialized user profile from another account (e.g. LocalAdmin)
            if ($TargetFolder -match '^[A-Za-z]:\\Users\\([^\\]+)' -and $env:USERPROFILE -and -not $TargetFolder.StartsWith($env:USERPROFILE, [System.StringComparison]::OrdinalIgnoreCase)) {
                $TargetProfileRoot = Join-Path (Split-Path -Parent $env:USERPROFILE) $Matches[1]
                if (-not (Test-Path -LiteralPath (Join-Path $TargetProfileRoot "NTUSER.DAT"))) {
                    Write-Warning "  [!] Skipping User Shell Folder '$Key' -> '$TargetFolder' because user profile '$TargetProfileRoot' has not been initialized yet."
                    continue
                }
            }
            if (-not (Test-Path -LiteralPath $TargetFolder)) {
                New-Item -ItemType Directory -Path $TargetFolder -Force -ErrorAction SilentlyContinue | Out-Null
            }
            $RegValueName = $FolderMap[$Key]
            Set-ItemProperty -Path $UsfKey -Name $RegValueName -Value $TargetFolder -Type ExpandString -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $SfKey  -Name $RegValueName -Value $TargetFolder -Type String -ErrorAction SilentlyContinue
            Write-Host "  [+] User Shell Folder '$Key' -> $TargetFolder" -ForegroundColor Green
        }
    }
}

# Restart Explorer to apply changes immediately if running interactively
if (Get-Process "explorer" -ErrorAction SilentlyContinue) {
    Stop-Process -Name "explorer" -Force
}
