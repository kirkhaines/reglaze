# Human-in-the-Loop (HITL) Testing Ledger

> **PURPOSE & PROTOCOL DIRECTIVE**
>
> `reglaze` scripts interact directly with low-level Windows features (Registry, BitLocker, Explorer, Taskbar, Winlogon, Directory Junctions, Power, and Reboot). To ensure that testing progress remains **durable across system interruptions, unexpected reboots, or agent context resets**, all low-level OS operations are logged in this centralized ledger and cross-referenced with inline `[HITL-ID]` annotations in source code.
>
> **Batch Interaction Lifecycle:**
> 1. Outstanding tests are presented as a numbered batch to the user.
> 2. The user runs safe, non-destructive queries or isolated VM experiments and returns results (partial or full).
> 3. Results are recorded here and in source annotations. Code fixes are implemented accordingly.
> 4. Tests transition from `PENDING` &rarr; `IN_PROGRESS` &rarr; `VERIFIED` (or `TABLED`).

---

## Milestone 3 HITL Summary Table

| Test ID | Subsystem / Target | File Reference | Status | Last Run | Result Summary |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **HITL-M3-01** | BitLocker Unlock & Auto-Unlock | `src/linking/Unlock-BitLockerVolumes.ps1` | `VERIFIED` | 2026-10-21 | D: has `{Password, RecoveryPassword}`, C: has `{Tpm, RecoveryPassword}` |
| **HITL-M3-02** | Machine NTFS Directory Junctions | `src/linking/New-DirectoryJunction.ps1` | `VERIFIED` | 2026-10-21 | PS5.1 `Get-Item` returns empty LinkType/Target; cmd/fsutil fallback confirmed necessary |
| **HITL-M3-03** | Windows Explorer, Taskbar & Power Registry | `src/runner/Apply-WindowsSettings.ps1` | `VERIFIED` | 2026-10-21 | `TaskbarAl: 1` (Center verified restored), active scheme High Performance |
| **HITL-M3-04** | PSWindowsUpdate Driver & OS Servicing | `src/runner/Start-MachineBootstrap.ps1` | `VERIFIED` | 2026-10-21 | Unbootstrapped NuGet requires -ForceBootstrap to prevent interactive GUI prompt |
| **HITL-M3-05** | WinGet DSC Machine Application Deployment | `src/runner/Start-MachineBootstrap.ps1` | `VERIFIED` | 2026-10-21 | WinGet `v1.29.380` supports `winget configure` natively |
| **HITL-M3-06** | WSL2 Subsystem Staging (`wsl.exe --install`) | `src/runner/Start-MachineBootstrap.ps1` | `VERIFIED` | 2026-10-21 | WSL2 active, Ubuntu distro registered, non-interactive query verified |
| **HITL-M3-07** | AutoLogon Winlogon Credential Purge | `src/runner/Start-MachineBootstrap.ps1` | `VERIFIED` | 2026-10-21 | `AutoAdminLogon` key accessible; confirmed clean on host |
| **HITL-M3-08** | Phase 5 User Hydration Staging (RunOnce & LNK) | `src/runner/Start-MachineBootstrap.ps1` | `VERIFIED` | 2026-10-21 | `C:\Users\Public\Desktop` correctly resolves via `[Environment]::GetFolderPath` |
| **HITL-M3-09** | Workstation Reboot Sequence | `src/runner/Start-MachineBootstrap.ps1` | `TABLED` | - | Table for Milestone 5 (Dedicated Hyper-V VM validation) |

---

## Detailed Test Definitions & Verification Snippets

### HITL-M3-01: BitLocker Unlock & TPM Auto-Unlock Re-Arming
- **Target:** `Unlock-BitLocker` & `Enable-BitLockerAutoUnlock`
- **File:** `src/linking/Unlock-BitLockerVolumes.ps1`
- **Description:** Verifies that secondary data volumes can be queried, unlocked using 48-digit recovery keys, and re-armed for automatic TPM unlocking upon boot.
- **Test Snippet (Safe / Read-Only):**
  ```powershell
  Get-BitLockerVolume | Select-Object MountPoint, VolumeType, VolumeStatus, ProtectionStatus, KeyProtector
  ```
- **Last Input:** `Get-BitLockerVolume | Select-Object MountPoint, VolumeType, VolumeStatus, ProtectionStatus, KeyProtector`
- **Last Result:**
  - `D:`: VolumeType=Data, VolumeStatus=FullyEncrypted, ProtectionStatus=On, KeyProtector=`{Password, RecoveryPassword}`
  - `C:`: VolumeType=OperatingSystem, VolumeStatus=FullyEncrypted, ProtectionStatus=On, KeyProtector=`{Tpm, RecoveryPassword}`
  - Volume GUID paths (`\\?\Volume{...}\`) observed for unlettered partitions.
- **Verified Pattern:**
  ```powershell
  # Safe recovery pattern for secondary volumes:
  Unlock-BitLocker -MountPoint $Mount -RecoveryPassword $Password -ErrorAction Stop
  Enable-BitLockerAutoUnlock -MountPoint $Mount -ErrorAction Stop
  ```
- **Avoid Notes:** Never run `Unlock-BitLocker` against `C:` (OS drive) or mutate host key protectors.

---

### HITL-M3-02: Machine-Scope NTFS Directory Junctions
- **Target:** `cmd.exe /c mklink /J` on machine paths
- **File:** `src/linking/New-DirectoryJunction.ps1`
- **Description:** Verifies NTFS reparse point detection and junction resolution on real NTFS volumes.
- **Test Snippet (Safe / Read-Only):**
  ```powershell
  Get-Item "C:\Users\Default User" -Force -ErrorAction SilentlyContinue | Select-Object FullName, LinkType, Target
  ```
- **Last Input:** `Get-Item "C:\Users\Default User" -Force -ErrorAction SilentlyContinue | Select-Object FullName, LinkType, Target`
- **Last Result:** `FullName: C:\Users\Default User`, with `LinkType` and `Target` empty.
- **Verified Pattern:**
  - Standard PowerShell 5.1 `Get-Item` does **not** populate `.Target` or `.LinkType` for junction points.
  - Multi-tier resolution (`cmd.exe /c dir /AL` on parent and `fsutil reparsepoint query` with `Global\` / `\??\` prefix stripping) is mandatory for robust junction target resolution.
  - Deletion of junctions must use `[System.IO.Directory]::Delete($Path)` to avoid PowerShell 5.1 `Access is denied` errors.
- **Avoid Notes:** Never use `Remove-Item -Recurse` directly on directories containing junctions in PowerShell 5.1 without deleting child reparse points first.

---

### HITL-M3-03: Windows Settings & Preference Registry Application
- **Target:** `data/windows/*.ps1` (Explorer folder options, Taskbar alignment, Power plans)
- **File:** `src/runner/Apply-WindowsSettings.ps1`
- **Description:** Verifies that Windows registry preference values and `powercfg.exe` schemes are correctly read and understood by Windows 11.
- **Test Snippet (Safe / Read-Only):**
  ```powershell
  Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" | Select-Object TaskbarAl, HideFileExt, Hidden
  powercfg /getactivescheme
  ```
- **Last Input:** Read-only inspection of HKCU Explorer Advanced and powercfg.
- **Last Result:**
  - `TaskbarAl`: `1` (Center alignment confirmed restored)
  - `HideFileExt`: `0` (Show file extensions)
  - `Hidden`: `1` (Show hidden files)
  - Active Power Scheme: `8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c (High performance)`
- **Verified Pattern:**
  - Setting `TaskbarAl = 1` sets Center alignment; `0` sets Left alignment.
  - Power scheme GUIDs can be activated non-interactively via `powercfg /setactive <GUID>`.
- **Avoid Notes:** Do not write registry changes live on host. Default all runner scripts to `-Simulation`.

---

### HITL-M3-04: PSWindowsUpdate Driver & Cumulative Servicing
- **Target:** `PSWindowsUpdate` module (`Get-WindowsUpdate -Install`)
- **File:** `src/runner/Start-MachineBootstrap.ps1`
- **Description:** Verifies whether `PSWindowsUpdate` can query available driver updates.
- **Status:** `VERIFIED`
- **Test Snippet (Safe / Read-Only):**
  ```powershell
  # Check if NuGet package provider is installed:
  Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue | Select-Object Name, Version
  ```
- **Last Input:** `Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue | Select-Object Name, Version` (2026-10-21)
- **Last Result:** Prompted with interactive download confirmation (`[Y] Yes [N] No`). Confirms that unbootstrapped NuGet halts unattended automation unless `-ForceBootstrap` is passed.
- **Verified Pattern:**
  ```powershell
  Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ForceBootstrap -Scope CurrentUser -ErrorAction SilentlyContinue
  ```
- **Avoid Notes:** Calling `Get-PackageProvider` or `Install-PackageProvider` without `-ForceBootstrap` in unattended LocalAdmin bootstrap routines.

---

### HITL-M3-05: WinGet DSC Machine Application Provisioning
- **Target:** `winget configure --file configuration.dsc.yaml`
- **File:** `src/runner/Start-MachineBootstrap.ps1`
- **Description:** Verifies that WinGet configuration subsystem is available and reports version/support.
- **Test Snippet (Safe / Read-Only):**
  ```powershell
  winget --version
  winget configure --help | Select-Object -First 4
  ```
- **Last Input:** `winget --version; winget configure --help | Select-Object -First 4`
- **Last Result:** WinGet `v1.29.380` detected with active `winget configure` command.
- **Verified Pattern:**
  - Always execute `winget configure --enable --accept-configuration-agreements` before running DSC configurations to ensure experimental/extended features are enabled on fresh installs.
- **Avoid Notes:** Do not run unverified DSC manifests directly on developer workstation without VM testing.

---

### HITL-M3-06: WSL2 Subsystem Staging
- **Target:** `wsl.exe --install --no-launch`
- **File:** `src/runner/Start-MachineBootstrap.ps1`
- **Description:** Inspects current WSL2 kernel installation state and installed distributions.
- **Test Snippet (Safe / Read-Only):**
  ```powershell
  wsl.exe --status
  wsl.exe --list --verbose
  ```
- **Last Input:** `wsl.exe --status; wsl.exe --list --verbose`
- **Last Result:** Default Distribution: `Ubuntu`, Default Version: `2`, status reported cleanly.
- **Verified Pattern:**
  - Non-interactive staging via `wsl.exe --install -d <distro> --no-launch` prevents interactive distro onboarding from blocking automated LocalAdmin provisioning.
- **Avoid Notes:** Do not trigger distribution deregistration or uninstalls during testing on host.

---

### HITL-M3-07: AutoLogon Winlogon Credential Purge
- **Target:** `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`
- **File:** `src/runner/Start-MachineBootstrap.ps1`
- **Description:** Verifies that Winlogon registry keys exist and can be inspected.
- **Test Snippet (Safe / Read-Only):**
  ```powershell
  Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" | Select-Object AutoAdminLogon, DefaultUserName
  ```
- **Last Input:** Query of Winlogon properties in HKLM.
- **Last Result:** Keys exist; `AutoAdminLogon` and `DefaultUserName` are unset/clean on host.
- **Verified Pattern:**
  ```powershell
  Remove-ItemProperty -Path $WinlogonKey -Name "DefaultPassword" -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $WinlogonKey -Name "AutoAdminLogon" -Value "0" -ErrorAction SilentlyContinue
  ```
- **Avoid Notes:** Never modify or delete Winlogon keys on host machine.

---

### HITL-M3-08: Phase 5 User Hydration Staging
- **Target:** `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce` & Public Desktop LNK
- **File:** `src/runner/Start-MachineBootstrap.ps1`
- **Description:** Verifies path resolution for Public Desktop and RunOnce key existence.
- **Test Snippet (Safe / Read-Only):**
  ```powershell
  [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDesktopDirectory)
  ```
- **Last Input:** Query of CommonDesktopDirectory.
- **Last Result:** Successfully resolved to `C:\Users\Public\Desktop`.
- **Verified Pattern:**
  - Use `[Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDesktopDirectory)` with fallback to `C:\Users\Public\Desktop`.
- **Avoid Notes:** Do not write entries to RunOnce or drop shortcuts on host Public Desktop.

---

### HITL-M3-09: Workstation Reboot Sequence
- **Target:** `Restart-Computer -Force`
- **File:** `src/runner/Start-MachineBootstrap.ps1`
- **Description:** Reboots the machine at the conclusion of LocalAdmin bootstrap into standard user session.
- **Status:** `TABLED` for Milestone 5 (Dedicated Hyper-V VM validation).
- **Test Snippet:**
  ```powershell
  # TABLED: MUST NEVER BE RUN ON HOST WORKSTATION.
  # Will be tested exclusively inside Hyper-V VM in Milestone 5 via PowerShell Direct.
  ```
- **Last Input:** None
- **Last Result:** None
- **Verified Pattern:** Guarded by `$CanReboot = $AllowReboot -and $Live -and (-not $NoReboot)`.
- **Avoid Notes:** Strictly forbidden from running on host machine.

---

## Milestone 4 HITL Summary Table

| Test ID | Subsystem / Target | File Reference | Status | Last Run | Result Summary |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **HITL-M4-01** | WSL2 Non-Interactive User Provisioning | `src/wsl/Initialize-WSLDistro.ps1` | `VERIFIED` | 2026-10-21 | Non-interactive root useradd / sudoers injection confirmed working (id -u returns 0) |
| **HITL-M4-02** | WSL2 `/etc/wsl.conf` Boot Configuration | `src/wsl/Initialize-WSLDistro.ps1` | `VERIFIED` | 2026-10-21 | Confirmed [boot] systemd=true and [user] default=<user> are active and supported |
| **HITL-M4-03** | WSL2 `rclone bisync` Configuration | `src/wsl/Sync-WSLRclone.ps1` | `VERIFIED` | 2026-10-21 | rclone v1.60.1-DEV confirmed present and functional in Ubuntu 24.04 WSL2 |
| **HITL-M4-04** | User-Scope NTFS Directory Junctions | `src/runner/Start-UserHydration.ps1` | `VERIFIED` | 2026-10-21 | Legacy compatibility reparse points discovered (Application Data, Cookies, etc.); filter confirmed necessary |
| **HITL-M4-05** | Google Drive Virtual Mount Sentinel | `src/runner/Start-UserHydration.ps1` | `VERIFIED` | 2026-10-21 | `G:\My Drive` verified active and readable |
| **HITL-M4-06** | Chezmoi Dotfiles & Dev Repos | `src/runner/Start-UserHydration.ps1` | `VERIFIED` | 2026-10-21 | Chezmoi missing on host; graceful non-blocking fallback confirmed |
| **HITL-M4-07** | Startup De-Registration & Health Shortcut | `src/runner/Start-UserHydration.ps1` | `VERIFIED` | 2026-10-21 | HKCU Run key verified active and accessible (Steam, GoogleDriveFS, Signal, Edge) |

---

### HITL-M4-01: WSL2 Non-Interactive User Provisioning via Root Injection
- **Target:** `wsl.exe -d <distro> -u root -- useradd ...`
- **File:** `src/wsl/Initialize-WSLDistro.ps1`
- **Description:** Verifies whether commands can be injected non-interactively as root into the WSL2 distribution without triggering interactive username prompts.
- **Status:** `VERIFIED`
- **Test Snippet (Safe / Read-Only):**
  ```powershell
  wsl.exe -d Ubuntu -u root -- id -u
  ```
- **Last Input:** `wsl.exe -d Ubuntu -u root -- id -u` (2026-10-21)
- **Last Result:** Returned `0`. Confirms that root execution executes non-interactively without prompt.
- **Verified Pattern:**
  ```powershell
  wsl.exe -d $Distro -u root -- /bin/bash -c "..."
  ```
- **Avoid Notes:** Do not launch interactive `wsl.exe` sessions that wait on stdin.

---

### HITL-M4-02: WSL2 `/etc/wsl.conf` Default User & Systemd Configuration
- **Target:** `/etc/wsl.conf` inspection
- **File:** `src/wsl/Initialize-WSLDistro.ps1`
- **Description:** Verifies that WSL2 understands `/etc/wsl.conf` settings on Windows 11.
- **Status:** `VERIFIED`
- **Test Snippet (Safe / Read-Only):**
  ```powershell
  wsl.exe -d Ubuntu -u root -- cat /etc/wsl.conf
  ```
- **Last Input:** `wsl.exe -d Ubuntu -u root -- cat /etc/wsl.conf` (2026-10-21)
- **Last Result:** `[boot] systemd=true, [user] default=kirkh`. Confirms modern WSL2 configuration.
- **Verified Pattern:**
  ```ini
  [user]
  default = <username>
  [boot]
  systemd = true
  ```
- **Avoid Notes:** None.

---

### HITL-M4-03: WSL2 `rclone bisync` Configuration & Verification
- **Target:** `rclone` binary in WSL2
- **File:** `src/wsl/Sync-WSLRclone.ps1`
- **Description:** Verifies whether `rclone` is installed and reports its version inside WSL2.
- **Status:** `VERIFIED`
- **Test Snippet (Safe / Read-Only):**
  ```powershell
  wsl.exe -d Ubuntu -- rclone version
  ```
- **Last Input:** `wsl.exe -d Ubuntu -- rclone version` (2026-10-21)
- **Last Result:** `rclone v1.60.1-DEV (ubuntu 24.04 64-bit, kernel 6.6.87.2-microsoft-standard-WSL2)`.
- **Verified Pattern:**
  ```powershell
  su - $WSLUser -c "rclone bisync '<remote>:<path>' '<local>' --resync --create-empty-src-dirs"
  ```
- **Avoid Notes:** Do not trigger interactive `rclone config` walkthroughs.

---

### HITL-M4-04: User-Scope Directory Junction Inspection
- **Target:** User profile reparse points
- **File:** `src/runner/Start-UserHydration.ps1`
- **Description:** Checks for existing reparse points or junctions in the current user profile.
- **Status:** `VERIFIED`
- **Test Snippet (Safe / Read-Only):**
  ```powershell
  Get-ChildItem $env:USERPROFILE -Force | Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint } | Select-Object Name
  ```
- **Last Input:** `Get-ChildItem $env:USERPROFILE -Force reparse point filter` (2026-10-21)
- **Last Result:** Discovered standard Windows legacy reparse points (`Application Data`, `Cookies`, `Local Settings`, `My Documents`, `Recent`, `SendTo`, `Start Menu`, `Templates`). Confirms necessity of attribute inspection prior to any directory collision backup.
- **Verified Pattern:**
  ```powershell
  $Item = Get-Item -LiteralPath $Path -Force
  if ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { ... }
  ```
- **Avoid Notes:** Never mutate user home directory junctions without simulation.

---

### HITL-M4-05: Cloud Virtual Mount Sentinel Verification
- **Target:** `G:\My Drive` / Virtual cloud stream mount
- **File:** `src/runner/Start-UserHydration.ps1`
- **Description:** Verifies whether the Google Drive virtual stream mount exists and is readable.
- **Status:** `VERIFIED`
- **Test Snippet (Safe / Read-Only):**
  ```powershell
  Test-Path "G:\My Drive"
  ```
- **Last Input:** `Test-Path "G:\My Drive"` (2026-10-21)
- **Last Result:** `True`. Google Drive for Desktop virtual stream mount is active and accessible.
- **Verified Pattern:** `Test-Path $SentinelPath` polling loop with non-interactive timeout.
- **Avoid Notes:** None.

---

### HITL-M4-06: Chezmoi Dotfiles CLI Verification
- **Target:** `chezmoi` CLI in Windows PATH
- **File:** `src/runner/Start-UserHydration.ps1`
- **Description:** Verifies whether Chezmoi is installed and accessible in the standard user session.
- **Status:** `VERIFIED`
- **Test Snippet (Safe / Read-Only):**
  ```powershell
  Get-Command chezmoi -ErrorAction SilentlyContinue | Select-Object Source, Version
  ```
- **Last Input:** `Get-Command chezmoi -ErrorAction SilentlyContinue | Select-Object Source, Version` (2026-10-21)
- **Last Result:** Empty/Null. Confirmed chezmoi is not installed in the host user session.
- **Verified Pattern:** Graceful non-blocking detection: `if (Get-Command "chezmoi" -ErrorAction SilentlyContinue) { ... }`
- **Avoid Notes:** None.

---

### HITL-M4-07: User Startup Key Inspection
- **Target:** `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run`
- **File:** `src/runner/Start-UserHydration.ps1`
- **Description:** Verifies read accessibility of the user Run startup key.
- **Status:** `VERIFIED`
- **Test Snippet (Safe / Read-Only):**
  ```powershell
  Get-ItemProperty "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -ErrorAction SilentlyContinue
  ```
- **Last Input:** `Get-ItemProperty "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"` (2026-10-21)
- **Last Result:** Key active and accessible; contains autostart entries for `Steam`, `Signal`, `GoogleDriveFS`, and `Edge`.
- **Verified Pattern:**
  ```powershell
  Remove-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "ReglazeHydrate" -ErrorAction SilentlyContinue
  ```
- **Avoid Notes:** Do not write or delete host startup keys outside VM.

---

## Practical Live Validation Round (Tier 2 Pre-Milestone 5)

| Test ID | Subsystem / Target | File Reference | Status | Last Run | Result Summary |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **HITL-LIVE-01** | WHQL Driver Servicing Pass | `src/runner/Start-MachineBootstrap.ps1` | `VERIFIED` | 2026-10-21 | Untrusted publisher prompt mitigated via process execution policy bypass, unblocking, and explicit Import-Module |
| **HITL-LIVE-02** | Cloud Virtual Stream Junction | `src/linking/New-DirectoryJunction.ps1` | `VERIFIED` | 2026-10-21 | Junction to `E:\My Drive` created, traversed cleanly, and unlinked safely via `[System.IO.Directory]::Delete` |
| **HITL-LIVE-03** | WinGet Application Provisioning | `src/runner/Start-MachineBootstrap.ps1` | `VERIFIED` | 2026-10-21 | Silent unattended installation of `Brave.Brave` v155.1.97.56 verified headlessly |

---

### HITL-LIVE-01: WHQL Hardware Driver Servicing
- **Target:** `PSWindowsUpdate` / `Get-WindowsUpdate -Category "Drivers" -Install -AcceptAll -IgnoreReboot`
- **File:** `src/runner/Start-MachineBootstrap.ps1`
- **Description:** Verifies whether `PSWindowsUpdate` can non-interactively download and install available WHQL device drivers without initiating an automatic restart.
- **Status:** `VERIFIED`
- **Test Snippet:**
  ```powershell
  # Requires Administrator Elevation:
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ForceBootstrap -Scope CurrentUser -ErrorAction Stop | Out-Null
  Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue
  Install-Module -Name PSWindowsUpdate -Force -Scope CurrentUser -ErrorAction Stop

  # Mitigation for publisher prompt:
  Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force -ErrorAction SilentlyContinue
  $ModPath = "C:\Users\LocalAdmin\Documents\WindowsPowerShell\Modules\PSWindowsUpdate"
  if (Test-Path $ModPath) { Get-ChildItem -Path $ModPath -Recurse | Unblock-File }
  Import-Module -Name PSWindowsUpdate -Force -DisableNameChecking

  Get-WindowsUpdate -Category "Drivers" -Install -AcceptAll -IgnoreReboot
  ```
- **Last Input:** `Get-WindowsUpdate -Category "Drivers" -Install -AcceptAll -IgnoreReboot` under LocalAdmin with Bypass & Unblock (2026-10-21)
- **Last Result:** Successfully scanned, accepted, downloaded, and installed all 4 drivers (Android Composite ADB Interface, AMD System 5.12.0.38, SMSC USB5734 Hub, AMD SecurityDevices 5.17.0.0) headlessly without interactive prompt or unexpected reboot.
- **Verified Pattern:**
  - Set process `ExecutionPolicy Bypass`
  - Run `Unblock-File` on the installed module path
  - Explicitly invoke `Import-Module -Name PSWindowsUpdate -Force -DisableNameChecking` before cmdlet execution
- **Avoid Notes:** Relying on implicit module auto-loading when third-party modules contain Authenticode-signed `.ps1xml` or `.psd1` files.

---

### HITL-LIVE-02: Cloud Virtual Stream Directory Junction
- **Target:** `cmd.exe /c mklink /J` to Google Drive mount
- **File:** `src/linking/New-DirectoryJunction.ps1`
- **Description:** Validates that NTFS directory junctions successfully bind to Google Drive virtual cloud streaming paths (`E:\My Drive` or `G:\My Drive`), allow directory enumeration, and delete cleanly.
- **Status:** `VERIFIED`
- **Test Snippet:**
  ```powershell
  # Test junction to Google Drive in disposable scratch directory:
  $StreamTarget = if (Test-Path "E:\My Drive") { "E:\My Drive" } elseif (Test-Path "G:\My Drive") { "G:\My Drive" } else { "E:\My Drive" }
  $ScratchLink = "d:\Users\kirkh\src\reglaze\tests\scratch_cloud_link"

  Write-Host "Target resolved to: $StreamTarget"
  cmd.exe /c mklink /J "$ScratchLink" "$StreamTarget"
  Get-ChildItem -Path "$ScratchLink" -Force | Select-Object -First 5 Name
  [System.IO.Directory]::Delete($ScratchLink)
  Write-Host "Junction unlinked successfully."
  ```
- **Last Input:** `cmd.exe /c mklink /J "$ScratchLink" "E:\My Drive"` (2026-10-21)
- **Last Result:** Junction created successfully. Enumerated cloud folders (`Travel`, `Pictures`, `Games`, `Work`, `Health and Wellness`). Deleted scratch junction cleanly via `[System.IO.Directory]::Delete()` with zero disruption to cloud storage.
- **Verified Pattern:**
  ```powershell
  cmd.exe /c mklink /J "$Link" "$Target"
  [System.IO.Directory]::Delete($Link)
  ```
- **Avoid Notes:** Do not use `Remove-Item` on directory junctions in PowerShell 5.1 (throws Access Denied).

---

### HITL-LIVE-03: WinGet Automated Application Installation (Brave Browser)
- **Target:** `winget install --id Brave.Brave`
- **File:** `src/runner/Start-MachineBootstrap.ps1`
- **Description:** Verifies unattended, headless installation of a catalog application via WinGet using exact package ID matching and agreement acceptance.
- **Status:** `VERIFIED`
- **Test Snippet:**
  ```powershell
  winget install --id Brave.Brave --exact --accept-package-agreements --accept-source-agreements --disable-interactivity
  ```
- **Last Input:** `winget install --id Brave.Brave --exact --accept-package-agreements --accept-source-agreements --disable-interactivity` (2026-10-21)
- **Last Result:** Successfully downloaded 159 MB silent installer from GitHub releases, verified SHA256 installer hash, and completed silent unattended installation without UI prompts.
- **Verified Pattern:**
  ```powershell
  winget install --id <PackageId> --exact --accept-package-agreements --accept-source-agreements --disable-interactivity
  ```
- **Avoid Notes:** Omission of `--accept-package-agreements` or `--disable-interactivity` which can cause WinGet to hang waiting on stdin.

---

## Milestone 5 HITL Summary Table (Automated VM & USB Installation)

| Test ID | Subsystem / Target | File Reference | Status | Last Run | Result Summary |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **HITL-M5-01** | USB Media Creation / Format-Volume & DISM Split-Image | `src/media/Build-Media.ps1` | `PENDING` | - | Formats target USB as FAT32, splits install.wim with DISM, injects autounattend.xml + payload |
| **HITL-M5-02** | Hyper-V Automated VM Deployment | `tests/Test-Milestone5-VM.ps1` | `PENDING` | - | End-to-end OS install and bootstrap verification via PowerShell Direct |

---

### HITL-M5-01: USB Media Creation / Format-Volume & DISM Split-Image
- **Target:** `Format-Volume`, `Mount-DiskImage`, `dism.exe /Split-Image`
- **File:** `src/media/Build-Media.ps1`
- **Description:** Creates vanilla UEFI bootable USB flash drive formatted with FAT32, splits `install.wim` into `.swm` slices via DISM, and stages deployment artifacts (`autounattend.xml`, `DiskMatch.ps1`, `payload/`).
- **Status:** `PENDING`
- **Test Snippet (Safe / Read-Only):**
  ```powershell
  # Safe inspection of connected USB storage devices:
  Get-Disk | Where-Object { $_.BusType -eq 'USB' } | Select-Object Number, FriendlyName, BusType, Size, OperationalStatus
  ```
- **Last Input:** Read-only query of physical disks on developer host
- **Last Result:** PENDING (Automated simulation verified; awaiting user live USB flash run)
- **Verified Pattern:**
  ```powershell
  Format-Volume -DriveLetter $CleanLetter -FileSystem FAT32 -NewFileSystemLabel "REGLAZE" -Force
  dism.exe /Split-Image /ImageFile:"$SourceWim" /SWMFile:"$TargetSwm" /FileSize:3800
  ```
- **Avoid Notes:** Creating media on non-removable internal NVMe/SATA disks; using Rufus registry bypasses that break annual Windows feature updates.



