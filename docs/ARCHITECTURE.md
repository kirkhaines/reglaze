# Reglaze: System Architecture & Technical Design Specification

| Document Metadata | Details |
| :--- | :--- |
| **Project** | `reglaze` |
| **Title** | System Architecture & Technical Design Specification |
| **Status** | Approved Baseline |
| **Version** | 1.0.0 |
| **Target Platforms** | Windows 11 Pro / Enterprise (x64, ARM64) |
| **Author / Architect** | Antigravity Engine & Kirk Haines |

---

## 1. Executive Summary & Vision

### 1.1 The Problem
Traditional personal workstation maintenance treats operating system installations as precious, bespoke artifacts ("pets"). Over months and years, Windows installations accumulate registry fragmentation, unmanaged dependencies, inconsistent environment variables, orphaned background services, and undocumented customizations. When a catastrophic hardware failure occurs or performance degrades, rebuilding the workstation requires days of manual installation, credential recovery, application re-configuration, and directory linking.

### 1.2 The Solution: Declarative, Disposable Workstations ("Cattle, Not Pets")
`reglaze` transforms Windows workstations into fully disposable, immutable computing nodes defined entirely by code (Infrastructure as Code - IaC). With `reglaze`, a developer or creative professional can treat their Windows OS drive as completely ephemeral:

$$\text{Bare Metal} \xrightarrow[\text{Automated Deployment}]{\text{< 60 Minutes}} \text{Fully Hydrated, Identical Production Workstation}$$

All configuration, application state, credentials, developer repositories, and game libraries are externalized into decoupled storage tiers. Operating system reinstallation ceases to be an ordeal; it becomes a routine, low-stress operational procedure.

```mermaid
graph TD
    subgraph Blueprint ["Declarative Blueprint (Code)"]
        YAML["reglaze.yaml"]
        JSON["data/applications.json"]
        AUDIT["audit-reference.json"]
    end

    subgraph Compiler ["Reglaze Compiler"]
        COMP["reglaze compile"]
    end

    subgraph Artifacts ["Deployment Media Artifacts"]
        XML["autounattend.xml"]
        DSC["configuration.dsc.yaml"]
        BOOT["bootstrap.ps1"]
        WSL["setup-wsl.sh"]
        KEYS["bitlocker-payload.json"]
    end

    subgraph Targets ["Physical Workstation Tiers"]
        C["Ephemeral OS Disk (C:)"]
        D["Preserved Bulk Storage (D:)"]
        G["Cloud Virtual Mount (G:)"]
        SYNC["Local Sync Roots (C:\Sync, D:\Projects)"]
    end

    Blueprint --> COMP
    COMP --> Artifacts
    Artifacts -->|WinPE & Specialize| C
    Artifacts -->|Unlock & Re-key| D
    Artifacts -->|Authenticate & Stream| G
    Artifacts -->|Rclone Bisync| SYNC
```

---

## 2. Core Architecture Principles

1. **Declarative Single Source of Truth**: The complete machine state is defined in `reglaze.yaml` validated against the reference catalog `data/applications.json`.
2. **Strict Tiered Storage Decoupling**: File types are routed to storage tiers matched to their performance, locking semantics, and size requirements.
3. **Dual-User Security Partitioning**: Administrative provisioning runs under a dedicated `LocalAdmin` account; daily operations execute under a standard non-administrator account linked to a Microsoft Account.
4. **Resilient Hardware Disambiguation**: Physical storage drives are matched using multi-factor hardware attributes (Serial Number, Bus Type, Model, Size), never volatile disk indices (`Disk 0`).
5. **Human-in-the-Loop (HITL) Staging**: Automated phases execute to the maximum extent possible before clustering interactive steps (Cloud authentication, Steam Guard, manual setup) to prevent user alert fatigue.
6. **Non-Destructive Idempotency**: Directory junction creation, package installations, and sync configurations can be executed repeatedly without data loss or duplicate state.

---

## 3. Tiered Storage Model & Linking Strategy

A critical failure mode of previous cloud workstation frameworks is routing database-backed applications (e.g., Lightroom, Darktable) or active Git repositories to cloud streaming virtual file systems (such as Google Drive for Desktop's virtual `G:` drive). Streaming mounts lack POSIX file-locking semantics, drop SQLite journal locks, and introduce high network I/O latency, causing catalog corruption and crashed processes.

`reglaze` formalizes a **4-Tier Storage Topology**:

| Tier | Name | Storage Medium | Characteristics & Usage | Example Paths |
| :--- | :--- | :--- | :--- | :--- |
| **Tier 1** | **Ephemeral OS** | Primary NVMe SSD (`C:`) | Completely disposable. Wiped during installation. Hosts OS binaries, `AppData\Local` caches, temporary files, and system pagefiles. | `C:\Windows`, `C:\Program Files` |
| **Tier 2** | **Cloud-Streamed Virtual Mount** | Virtual File System Mount (`G:\My Drive`) | Real-time on-demand cloud streaming. Ideal for flat text configs, VS Code settings, game saves, and media assets that tolerate virtual file system semantics. | `G:\My Drive\Config\VSCode`, `G:\My Drive\Backups\Saves` |
| **Tier 3** | **Cloud-Synced Local Roots** | High-Speed Local NVMe (`C:\Sync`, `D:\Projects`) | True local NTFS storage with POSIX/NTFS file locks and native NVMe I/O speed. Backed up to cloud asynchronously via bidirectional sync (`rclone bisync`). Required for SQLite catalogs and Git repos. | `C:\Sync\Catalogs\Lightroom`, `D:\Projects\reglaze` |
| **Tier 4** | **Preserved Secondary Storage** | Dedicated Local NVMe/SSD (`D:`) | Massive local disk preserved across OS reinstallations. Holds raw video footage, Steam games, virtual machine disks. Excluded from OS wipe. | `D:\Games\Steam`, `D:\VirtualMachines` |

### 3.1 Junction Mechanics (`mklink /J`)
`reglaze` exclusively utilizes **NTFS Directory Junctions** (`mklink /J`) rather than directory symbolic links (`mklink /D`):
* **No Developer Mode Required**: Creating directory junctions does not require Windows Developer Mode or elevated UAC privileges during user hydration.
* **Kernel-Level Transparent Redirection**: Directory junctions operate at the NTFS file system filter driver layer (`IO_REPARSE_TAG_MOUNT_POINT`), presenting as local directories to legacy Win32, .NET, and UWP applications.
* **Hard Boundary Enforcement**: Directory junctions only target local file system namespaces (e.g. `C:\`, `D:\`, `G:\`), preventing network loopback issues.

### 3.2 Directory Collision & Hydration Strategy
When establishing junction links during user hydration, the linking engine follows an atomic, non-destructive state machine:

```mermaid
flowchart TD
    Start["Evaluate Directory Link Request"] --> CheckSource{"Does local source directory exist?"}
    
    CheckSource -- Yes --> CheckSourceJunction{"Is it already a valid Junction?"}
    CheckSourceJunction -- Yes (Correct Target) --> Done["Link Up to Date (No-op)"]
    CheckSourceJunction -- Yes (Wrong Target) --> RemoveOldJunction["Remove existing junction link"] --> CreateNewJunction
    CheckSourceJunction -- No (Real Directory) --> CheckTarget{"Does remote target directory exist?"}
    
    CheckSource -- No --> CreateTargetIfMissing["Ensure target directory exists"] --> CreateNewJunction["Create Junction: mklink /J Source Target"]
    
    CheckTarget -- Target Exists & Populated --> BackupSource["Rename local source to .bak_<timestamp>"] --> CreateNewJunction
    CheckTarget -- Target Empty or Missing --> MigrateLocal["Copy local source content to target"] --> RemoveOriginal["Remove local source directory"] --> CreateNewJunction
    
    CreateNewJunction --> Verify["Verify reparse point target"] --> Done
```

### 3.3 Variable Placeholders & Token Resolution
To decouple blueprints from physical machine drive topologies, all directory paths in `reglaze.yaml` and `data/applications.json` use standardized variable placeholders:

| Variable Placeholder | Definition & Resolution Rule | Example Value |
| :--- | :--- | :--- |
| `%OS_DRIVE%` | Resolves to the letter of the target OS installation volume. | `C:` |
| `%DATA_DRIVE%` | Resolves to the letter of the primary preserved secondary disk. | `D:` |
| `%STREAM%` | Resolves to the verified cloud streaming sentinel root. | `G:\My Drive` |
| `%SYNC_<ID>%` | Resolves to the local path of a declared sync root (e.g., `storage.sync.directories.<id>`). | `C:\Sync\Catalogs`, `D:\Projects` |
| `%<CUSTOM_VAR>%` | Resolves to any custom path shortcut declared in `variables:` (e.g., `STEAM_DIR`). | `D:\SteamLibrary` |

> [!IMPORTANT]
> **Syntax Standardization:** All variable placeholders strictly use the underscore format (e.g., `%SYNC_CATALOGS%`, `%SYNC_PROJECTS%`). The colon format (such as `%SYNC:catalogs%`) is explicitly rejected by the schema validator.

### 3.4 Dotfile & Configuration Management via Chezmoi (Git-Optional)

While Chezmoi is frequently paired with remote Git repositories, **Chezmoi operates on local directory trees and does not require Git**. `reglaze` supports running Chezmoi directly against storage backends provisioned in Google Drive:

1. **Decoupled Source Directory**:
   - The Chezmoi source state can reside directly within the cloud streaming tier (`%STREAM%\Config\chezmoi`) or within a local sync root (`%SYNC_PROJECTS%\dotfiles`).
   - Invocation does not require cloning a repository; it reads the source directory directly:
     ```powershell
     chezmoi apply --source "$env:STREAM\Config\chezmoi"
     ```
   - Alternatively, a lightweight `~/.config/chezmoi/chezmoi.toml` can be provisioned by `reglaze` pointing to the source directory:
     ```toml
     sourceDir = "G:/My Drive/Config/chezmoi"
     ```

2. **App-Specific Config Reading & Writing (`modify_` scripts)**:
   - For applications with complex configuration files (e.g. `UserPreferences.ini`, `settings.json`, XML configs) where overwriting the entire file would destroy dynamic runtime state or machine-specific tokens, Chezmoi supports **`modify_` scripts**.
   - A `modify_<filename>.ps1` script receives the existing target file on standard input (`stdin`), executes programmatic transformations (e.g., updating specific INI keys, merging JSON fragments, or toggling XML attributes), and emits the modified content on standard output (`stdout`).
   - If the target file does not yet exist on disk, Chezmoi provides an empty stream or default template to the script.

3. **Lifecycle Script Execution (`run_` scripts)**:
   - **`run_once_`**: Executes once per machine (e.g. installing CLI extensions, setting one-time registry keys).
   - **`run_onchange_`**: Re-executes whenever an accompanying configuration file changes (e.g. hashing a plugins list and running an installer when the hash changes).
   - **`run_after_`**: Executes after configuration files are written (e.g. reloading daemon settings or restarting an agent).

---

## 4. Security, Secrets & Threat Model

### 4.1 Threat Model & Security Boundaries

```mermaid
graph LR
    subgraph Host ["Physical Host Boundaries"]
        subgraph AdminBoundary ["Phase 4: LocalAdmin (Elevated Machine Scope)"]
            Bootstrap["bootstrap.ps1 + bootstrap-helpers.ps1"]
            WinGetDSC["WinGet DSC (--scope machine)"]
            BitLocker["Drive Letters & BitLocker Auto-Unlock"]
            WSLKernel["WSL2 Kernel (--no-distribution)"]
            MachineCfg["HKLM Policy, Drivers, Firewall & Machine Junctions"]
        end
        
        subgraph UserBoundary ["Phase 5: Primary User (Standard User Scope)"]
            Hydrate["hydrate.ps1 + hydrate-helpers.ps1"]
            AuthBootstrap["Auth Bootstrap: Default Browser + Password Manager"]
            CloudAuth["Google Drive Mount & Sync Migration"]
            SteamAuth["Steam Login & Multi-Library Discovery"]
            UserJuncs["HKCU Settings, User Shell Folders & User Junctions"]
            WSLUser["User-Scope WSL2 Distro Install & setup-wsl.sh"]
        end
    end

    AdminBoundary -.->|UAC Elevation Only| UserBoundary
    Bootstrap -->|Purge AutoLogon, Stage Public Desktop Shortcut & Reboot| UserBoundary
    AuthBootstrap -->|Unlocks OAuth, 2FA & Credentials| CloudAuth
    AuthBootstrap -->|Unlocks Credentials & Steam Guard| SteamAuth
```

1. **Principle of Least Privilege**:
   - The primary user is created as a **standard non-administrator user** (`is_admin: false`).
   - Daily activities, web browsing, developer tasks, and gaming run entirely without administrative rights.
   - UAC elevation requires entering credentials for the distinct `LocalAdmin` account.
2. **Ephemeral Auto-Logon Lifecycle**:
   - Auto-logon is enabled **exclusively** for `LocalAdmin` during initial WinPE/Specialize provisioning to execute machine setup (`bootstrap.ps1`).
   - The final task of `bootstrap.ps1` purges auto-logon credentials from `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon` (`DefaultUserName`, `DefaultPassword`, `AutoAdminLogon`).
   - Subsequent boots present the standard Windows lock screen.
3. **No Secrets in Version Control**:
   - `reglaze.yaml` and `audit-reference.json` contain references to environment variables (e.g. `password_env: "LOCAL_ADMIN_PASSWORD"`, `client_id_env: "GDRIVE_CLIENT_ID"`).
   - The compiler pulls credentials from the local host environment during media compilation.
   - Root `reglaze.yaml`, `audit-reference.json`, `dist/`, and recovery payloads are listed in `.gitignore`.
4. **Preserved Disk BitLocker Recovery Pipeline**:
   - Preserved secondary disks (`D:`) are protected by BitLocker with TPM + Recovery Password protectors.
   - Wiping `C:` breaks the TPM auto-unlock relationship for `D:`.
   - During `reglaze compile`, the recovery key for `D:` harvested in `audit-reference.json` is packaged into a protected payload file on the installation media (`payload\bitlocker-keys.json`).
   - During Phase 4, `bootstrap.ps1` runs under `LocalAdmin`:
     ```powershell
     Unlock-BitLocker -MountPoint "D:" -RecoveryPassword $RecoveredKey
     Enable-BitLockerAutoUnlock -MountPoint "D:"
     ```
   - This restores seamless auto-unlock for the preserved volume without exposing the key on unencrypted secondary drives.

---

## 5. End-to-End System Lifecycle (The 6 Phases)

The complete lifecycle of a `reglaze` workstation consists of six discrete phases:

```mermaid
sequenceDiagram
    autonumber
    actor Dev as Operator
    participant Audit as Phase 0: Audit
    participant Blueprint as Phase 1: Blueprint
    participant Compiler as Phase 2: Compiler
    participant Media as Phase 2.5: UEFI Media Builder
    participant WinPE as Phase 3: WinPE Setup
    participant Machine as Phase 4: Machine Bootstrap
    participant User as Phase 5: User Hydration

    Dev->>Audit: Run reglaze audit on existing machine
    Audit-->>Blueprint: Emits audit-reference.json & initial reglaze.yaml
    Dev->>Blueprint: Customizes apps, drives & sync roots
    Dev->>Compiler: Run reglaze compile
    Compiler-->>Compiler: Validates against data/applications.json
    Compiler-->>Compiler: Emits autounattend.xml & payload/
    Dev->>Media: Run reglaze media -UsbDrive E:
    Media-->>Media: Acquires Windows 11 ISO (BITS/download)
    Media-->>Media: Formats USB as FAT32 & splits install.wim via DISM
    Media-->>WinPE: Injects autounattend.xml & payload/ into bootable USB
    Dev->>WinPE: Boots machine via USB media
    WinPE->>WinPE: Multi-factor disk identification (Match Serial & BusType)
    WinPE->>WinPE: Partitions C:, applies Windows image, creates LocalAdmin
    WinPE->>Machine: Reboots into LocalAdmin (AutoLogon: true)
    Machine->>Machine: Reconciles drive letters, provisions EFI bcdboot & unlocks BitLocker
    Machine->>Machine: Installs WHQL drivers, Windows updates & DriveFS HKLM policies
    Machine->>Machine: Applies WinGet DSC (--scope machine) & queues user-only apps
    Machine->>Machine: Stages WSL2 kernel (--no-distribution), machine junctions & HKLM settings
    Machine->>Machine: Creates primary user, purges AutoLogon & drops Public Desktop shortcut
    Machine->>User: Reboots to Windows Logon
    Dev->>User: Signs in as Primary User & launches 'Reglaze Hydration' shortcut
    User->>User: Step 1-2: Applies HKCU personalization, multi-monitor layout & optional MSA link
    User->>User: Step 3 (Auth Bootstrap): Sets Default Browser, syncs profile/tabs & unlocks Password Manager
    User->>User: Step 4-5: Relocates User Shell Folders & installs user-scope WinGet packages
    User->>User: Step 6: Authenticates Google Drive (%STREAM%) & migrates synced folders
    User->>User: Step 7-8: Authenticates Steam (reattaches preserved libraries) & manual apps
    User->>User: Step 9: Creates user junctions, re-applies cloud wallpaper & sets shell pins
    User->>User: Step 10-11: Installs user-scope WSL2 distro, runs setup-wsl.sh & verifies dev repos
    User-->>Dev: System Fully Hydrated & Ready
```

---

### 5.1 Cross-Phase & Intra-Phase Dependency Architecture

Provisioning a Windows workstation from bare metal involves strict causal dependencies across hardware initialization, volume mounting, registry hive lifecycles, authentication sessions, and filesystem paths. Executing steps out of order—or in the wrong security context (`LocalAdmin` vs. `primary_user`)—leads to broken junctions, unmounted drives, profile corruption (`C:\Users\<user>.000`), or missing user customizations.

```mermaid
flowchart TD
    subgraph P0_P2 ["Phases 0-2: Pre-Install & Compilation"]
        A0["Phase 0: Audit\n(Disks, BitLocker Keys, Apps, Settings)"] --> A1["Phase 1: Blueprint & Pre-Install Migrate\n(reglaze.yaml, Cloud/Preserved Data Staged)"]
        A1 --> A2["Phase 2: Compile & Media\n(autounattend.xml, payload/, Bootable USB)"]
    end

    subgraph P3 ["Phase 3: WinPE & Specialize"]
        A2 --> W1["WinPE DiskMatch\n(Verify Target OS Disk by Serial + BusType)"]
        W1 --> W2["Partition C: (EFI + MSR + OS)\n& Apply Windows 11 Image"]
    end

    subgraph P4 ["Phase 4: Machine Bootstrap (bootstrap.ps1 under LocalAdmin)"]
        W2 --> B1["Step 1: Pass 1 Drive Letters\n& Connected BitLocker Unlock"]
        B1 --> B1b["Step 1b: Standalone UEFI Bootloader\n(bcdboot C:\\Windows /s EFI)"]
        B1b --> B2["Step 2: WHQL Hardware Drivers\n(Storage, NIC, GPU, Audio)"]
        B2 --> B2b["Step 2b: Pass 2 Drive Letters\n& Missing Disk Shutdown Check"]
        B2b --> B3["Step 3: Windows Quality Updates"]
        B3 --> B4["Step 4: HKLM DriveFS Policy +\nWinGet DSC (--scope machine)"]
        B4 --> B5["Step 5: WSL2 Subsystem Kernel\n(wsl --install --no-distribution)"]
        B5 --> B6["Step 6: Machine Junctions &\nDeferred Junction Parent ACLs"]
        B6 --> B7["Step 7: Machine Windows Settings\n(Power, GPU HwSch, NIC/Firewall, Start Policy)"]
        B7 --> B8["Step 8-9: Create Primary User, Purge AutoLogon,\nDrop Public Desktop Shortcut & Reboot"]
    end

    subgraph P5 ["Phase 5: User Hydration (hydrate.ps1 under Primary User)"]
        B8 --> H0["Step 0-1: Verify Preserved Drives &\nApply HKCU Theme, Display Topology, Input, Taskbar"]
        H0 --> H2["Step 2: Optional Microsoft Account Link"]
        H2 --> H3["Step 3: FOUNDATIONAL AUTH BOOTSTRAP\n(Default Browser + Profile Sync + Password Manager)"]
        H3 --> H4["Step 4: Relocate Known User Shell Folders\n& Explorer Options (HKCU)"]
        H4 --> H5["Step 5: User-Scope WinGet Packages\n(user-packages.json)"]
        H3 --> H6["Step 6: Google Drive Mount (%STREAM%)\n& Sync Folder Migration (%SYNC_*%)"]
        H3 --> H7["Step 7: Steam Login, Library Discovery\n& Bulk Game Installation"]
        H3 --> H8["Step 8: Manual Application Walkthroughs"]
        H4 & H5 & H6 & H7 & H8 --> H9["Step 9: User Directory Junctions,\nCloud Wallpaper Re-Apply & Shell Pins"]
        H9 --> H10["Step 10-11: User-Scope WSL2 Distro Install\n(wsl --install -d <Distro>), setup-wsl.sh & Dev Repos"]
    end
```

#### 1. Machine Scope (`Phase 4` / `LocalAdmin`) vs. User Scope (`Phase 5` / `primary_user`) Separation
A core architectural invariant of `reglaze` is that **Phase 4 (`bootstrap.ps1`) only mutates machine-wide state (`HKLM:`, system services, physical disks, `C:\Program Files*`, `C:\ProgramData`)**, while **Phase 5 (`hydrate.ps1`) mutates user-scoped state (`HKCU:`, `%USERPROFILE%`, `%APPDATA%`, `%LOCALAPPDATA%`)**:

| Subsystem | Phase 4 (`LocalAdmin` - Machine Scope) | Phase 5 (`primary_user` - User Scope) | Why This Separation Is Required |
| :--- | :--- | :--- | :--- |
| **User Profile Directory (`C:\Users\<user>`)** | Creates the local account (`New-LocalUser`), but **never** creates files or folders inside `C:\Users\<user>`. | Initializes `C:\Users\<user>` naturally on first interactive sign-in, then relocates Known Folders and links junctions. | Pre-creating `C:\Users\<user>` before Windows `ProfSvc` runs on first login causes Windows to treat the folder as a collision and create `C:\Users\<user>.000` or `<user>.<PC>`. |
| **Windows Registry Settings (`windows/*.ps1`)** | Applies `HKLM:` and hardware settings: Power Plan (`powercfg`), `LongPathsEnabled`, `ssh-agent` service, PnP camera disabling, `HwSchMode`, Network/Firewall/hosts, and `HKLM` `ConfigureStartPins` policy. | Applies `HKCU:` and session settings: Explorer options, `SharingWizardOn`, `User Shell Folders`, Taskbar/Tray/Clock, Theme/Accent/Wallpaper, Mouse/Keyboard/Input languages, CoreAudio endpoints/volume, `GameBar`, and multi-monitor layout (`ChangeDisplaySettingsEx`). | Running `HKCU:` scripts in Phase 4 only modifies the temporary `LocalAdmin` hive and has zero effect on the primary user's desktop. |
| **WinGet Packages** | Installs system-wide packages (`--scope machine`), including the user's browser and password manager binaries. Packages returning `-1978335216` (no machine installer) or `-1978335146` (no admin context) are queued into `user-packages.json`. | Installs per-user packages (`user-packages.json` with `--scope user`) inside the primary user's session. | Per-user installers write to `%LOCALAPPDATA%\Programs` and `HKCU:\...\Uninstall`. Installing them under `LocalAdmin` traps them inside `C:\Users\LocalAdmin`. |
| **WSL2 Subsystem vs. Linux Distro** | Runs `wsl.exe --install --no-distribution` to enable the machine-wide Virtual Machine Platform and WSL2 kernel. | Runs `wsl.exe --install -d <Distro> --no-launch` and `setup-wsl.sh` inside the primary user session. | WSL distributions are registered per-user in `HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss`. Installing a distro under `LocalAdmin` makes it invisible to the primary user. |
| **Directory Junctions & Parent ACLs** | Links `Scope = "machine"` junctions (`C:\ProgramData`, `C:\Program Files*`) whose targets are on local preserved disks. Grants `BUILTIN\Users` modify ACLs on parent folders of deferred `RequiresElevation` junctions (e.g., `C:\Program Files (x86)\Steam`). | Links all `Scope = "user"` junctions (including `%USERPROFILE%` paths, cloud `%STREAM%` / `%SYNC_*%` targets, and Steam `userdata` / game mod folders). | Cloud mounts (`%STREAM%`) and Steam game folders do not exist until Phase 5; granting parent folder ACLs in Phase 4 allows the non-admin user in Phase 5 to link `Steam\userdata` without UAC failure. |

#### 2. Highlight: Browser & Password Manager as a Foundational Authentication Bootstrap (Phase 5, Step 3)
Unlike ordinary applications, the user's **Primary Browser** (e.g., Google Chrome) and **Password Manager** (e.g., Bitwarden) form a **two-stage authentication bootstrap** that bridges unattended machine setup and interactive user hydration:
1. **Stage 1 — Binary Provisioning in Phase 4 (`bootstrap.ps1` Step 4)**: The browser and password manager desktop/extension prerequisites are installed machine-wide via WinGet DSC so the binaries are already present on disk before the user logs in.
2. **Stage 2 — Early Session & Credential Unlock in Phase 5 (`hydrate.ps1` Step 3)**: Before `hydrate.ps1` attempts to mount cloud storage (Step 6), sign into Steam (Step 7), or guide manual application downloads (Step 8), Step 3 prompts the user to:
   - Set their browser as the **Windows Default Browser** (`chrome.exe --make-default-browser`).
   - Sign into their browser profile to sync bookmarks, extensions, and settings.
   - Sign into and unlock their **password manager extension** (e.g., Bitwarden).
   - Restore open tabs from their previous Windows installation via `chrome://history/syncedTabs` (`Open all`).
3. **Why Step 3 Must Precede Steps 6–8**:
   - **Google Drive for Desktop (Step 6)** launches a browser-based OAuth 2.0 flow in the default browser; having the browser profile and password manager already unlocked makes OAuth sign-in a single click.
   - **Steam (Step 7)** and **Manual Application Portals (Step 8)** require complex passwords and 2FA/TOTP codes stored in the password manager.

#### 3. Phase 4 (`bootstrap.ps1`) Step-by-Step Dependency Table

| Step | Action | Prerequisite Steps | Downstream Dependents & Ordering Rationale |
| :--- | :--- | :--- | :--- |
| **Step 1** | Pass 1 Drive Letter Reconciliation & Connected BitLocker Unlock | Phase 3 WinPE install | Moves the USB installer off reserved letters (e.g., `E:`), assigns canonical letters (`D:`, `F:`) to preserved disks by hardware serial number, and unlocks connected BitLocker volumes before any path references them. |
| **Step 1b** | Standalone UEFI Bootloader (`bcdboot C:\Windows /s <EFI> /f UEFI`) | Step 1 | Ensures the target OS disk (`C:`) has a bootable EFI System Partition even if Windows Setup reused an existing EFI partition on a secondary drive. |
| **Step 2** | Automated WHQL Hardware Driver Servicing (`PSWindowsUpdate`) | Step 1 | Must run **before** Step 2b (Pass 2 disk check) and Step 7 (GPU/NIC/Audio settings) so storage controllers, network adapters, and display drivers are loaded. |
| **Step 2b** | Pass 2 Drive Letter Reconciliation & Missing Disk Reconnect Check | Step 2 (Storage drivers loaded) | Verifies all required preserved disks are connected. If the user unplugged secondary SATA/NVMe drives during WinPE for safety, re-arms `LocalAdmin` AutoLogon + `RunOnce` and powers down cleanly (`Stop-Computer`) so drives can be reconnected before Step 6 creates junctions pointing to them. |
| **Step 3** | General Windows Quality & Security Cumulative Updates | Step 2 | Applies OS security/servicing updates before WinGet DSC and WSL2 kernel provisioning. |
| **Step 4** | Google Drive `HKLM` Policy & WinGet DSC Machine Provisioning | Step 1 (USB moved off `E:`), Step 3 | Sets `HKLM:\SOFTWARE\Policies\Google\DriveFS\DefaultMountPoint` and suppresses backup prompts **before** `Google.GoogleDrive` is installed so its first launch uses the configured mount letter. Installs machine-scope apps and queues user-only packages to `user-packages.json`. |
| **Step 5** | Machine-Scope WSL2 Kernel Staging (`wsl --install --no-distribution`) | Step 3 | Provisions the machine-wide WSL2 kernel while elevated so Phase 5 (`hydrate.ps1` Step 10) can register the Linux distribution in user scope without elevation. |
| **Step 6** | Machine-Scope Directory Junctions & Deferred Junction ACLs | Step 2b (Preserved drives verified), Step 4 (Apps installed) | Creates junctions under `C:\ProgramData` and `C:\Program Files*` targeting preserved drives, and grants `BUILTIN\Users` modify ACLs on parent directories of deferred Phase 5 junctions (e.g., `Steam\userdata`). |
| **Step 7** | Machine-Scope Windows System Settings | Step 2 (Drivers loaded) | Configures Power Plan, `LongPathsEnabled`, `ssh-agent`, PnP camera disabling, Hardware GPU Scheduling (`HwSchMode`), Network/Firewall/hosts, and `HKLM` Start Menu pin policy. |
| **Step 8–9** | Primary User Creation, AutoLogon Purge & Public Desktop Shortcut | Steps 1–7 complete | Creates the primary user account, clears `LocalAdmin` AutoLogon credentials, drops `Reglaze Hydration.lnk` on `C:\Users\Public\Desktop`, and reboots to the Windows login screen. |

#### 4. Phase 5 (`hydrate.ps1`) Step-by-Step Dependency Table

| Step | Action | Prerequisite Steps | Downstream Dependents & Ordering Rationale |
| :--- | :--- | :--- | :--- |
| **Step 0** | Preserved Disk Mount Verification | Phase 4 Step 2b | Confirms all required preserved drives (`D:`, `F:`) are online before User Shell Folders or junctions reference them. |
| **Step 1** | User-Scope Personalization, Display Topology, Input & Taskbar | Step 0 | Runs first so multi-monitor positioning (`ChangeDisplaySettingsEx`), Dark Mode, mouse speed, and taskbar layout are comfortable during all subsequent interactive steps. |
| **Step 2** | Microsoft Account (MSA) Connection (Optional) | Step 1 | Allows optional linking of the local account to a Microsoft Account for Store/digital license sync. |
| **Step 3** | **Foundational Auth Bootstrap (Browser & Password Manager)** | Phase 4 Step 4 (Browser installed) | Unlocks browser OAuth sessions, restores prior open tabs (`chrome://history/syncedTabs`), and unlocks password manager credentials required by Steps 6, 7, and 8. |
| **Step 4** | Relocate User Shell Folders & Explorer Options (`HKCU`) | Step 0 (Preserved drives online) | Relocates `Desktop`, `Documents`, `Downloads`, `Pictures`, `Music`, and `Videos` and sets `SharingWizardOn` in `HKCU:` **before** Step 9 links user directory junctions. |
| **Step 5** | User-Scope WinGet Packages (`user-packages.json`) | Phase 4 Step 4 | Installs per-user applications (`%LOCALAPPDATA%`) **before** Step 9 links their configuration directories or pins their shortcuts. |
| **Step 6** | Google Drive Mount (`%STREAM%`) & Sync Migration (`%SYNC_*%`) | Phase 4 Step 4 (DriveFS policy), Phase 5 Step 3 (Browser OAuth) | Mounts `%STREAM%` (e.g., `E:\My Drive`) and migrates synced folders from `Other computers\<Name>` **before** Step 9 creates junctions targeting `%STREAM%` or `%SYNC_*%`. |
| **Step 7** | Steam Sign-In, Library Discovery & Bulk Game Installs | Step 0 (Preserved drives), Step 3 (Password manager) | Authenticates Steam, discovers preserved libraries, restores `shortcuts.vdf`, and installs games **before** Step 9 links `Steam\userdata` or game mod directories (e.g., Beat Saber `CustomLevels`). |
| **Step 8** | Manual Application Installation Walkthroughs | Step 3 (Browser & Password Manager) | Guides installation of `method: "manual"` applications **before** Step 9 links their config/asset folders. |
| **Step 9** | User Directory Junctions, Cloud Wallpaper & Shell Pins | Steps 0, 4, 5, 6, 7, 8 | All target drives, cloud mounts, and app folders now exist; creates all `Scope = "user"` junctions/symlinks, re-applies desktop wallpaper if hosted on a cloud/junction path, and applies Quick Access pins, Taskbar pins, User `PATH`, and Steam library VDF entries. |
| **Step 10–11** | User-Scope WSL2 Distro Install (`setup-wsl.sh`) & Dev Repos | Phase 4 Step 5 (WSL2 kernel), Step 9 | Registers the Linux distribution under the primary user's `HKCU:\...\Lxss` hive, runs `setup-wsl.sh` as root, restarts the distro (`wsl --terminate`), and verifies dev repositories/dotfiles. |

---

### Phase 0: Pre-Flight Discovery & Machine Audit (`reglaze audit`)

The audit engine runs non-destructively on the existing running Windows installation. It collects hardware signatures, licensing data, and file system relationships.

#### Multi-Factor Storage Signature Discovery
To eliminate catastrophic data loss caused by non-deterministic disk ordering in WinPE (where USB drives or NVMe bus scans can cause `Disk 0` to become `Disk 1`), the audit records immutable hardware identifiers:

```powershell
Get-CimInstance Win32_DiskDrive | Select-Object `
    DeviceID, Index, Model, SerialNumber, InterfaceType, Size, `
    @{Name="BusType"; Expression={(Get-PhysicalDisk -DeviceNumber $_.Index).BusType}}, `
    @{Name="UniqueId"; Expression={(Get-PhysicalDisk -DeviceNumber $_.Index).UniqueId}}
```

#### BitLocker Recovery Key Extraction
For every volume protected by BitLocker:
```powershell
Get-BitLockerVolume | ForEach-Object {
    $vol = $_
    $recoveryKey = $vol.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }
    [PSCustomObject]@{
        MountPoint       = $vol.MountPoint
        VolumeType       = $vol.VolumeType
        EncryptionMethod = $vol.EncryptionMethod
        RecoveryPassword = $recoveryKey.RecoveryPassword
        RecoveryKeyId    = $recoveryKey.KeyProtectorId
    }
}
```

#### Dual Application Discovery: WinGet + Add/Remove Programs (ARP)
WinGet manifests only cover software distributed through the Windows Package Manager. To detect manually installed applications, standalone software, and older installers (InnoSetup, NSIS, InstallShield, MSI), `audit.ps1` executes a comprehensive registry harvest across three distinct hives:
1. **64-bit Machine-Wide**: `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*`
2. **32-bit WoW64 Machine-Wide**: `HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*`
3. **Current User (Per-User Installs)**: `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*`

The audit module:
- Extracts `DisplayName`, `DisplayVersion`, `Publisher`, `InstallLocation`, `InstallDate`, and `UninstallString`.
- Filters out OS updates, hotfixes, and language packs (`SystemComponent -ne 1`, `ParentKeyName -eq $null`).
- De-duplicates items already tracked by WinGet.
- Cross-references remaining applications against the `data/applications/` catalog using normalized names and fuzzy publisher matching.
- Emits unmatched applications into `detected_non_winget_applications` in `audit-reference.json`, allowing the user to easily identify and transition manual software into `custom:` or new `data/applications/<app_id>` definitions.

#### Windows Preferences & System Settings Discovery
The pre-flight audit executes `data/windows/audit-windows-settings.ps1` to capture current environment configurations:
- **File Explorer**: Hidden file visibility (`Hidden`), file extension display (`HideFileExt`), navigation target (`LaunchTo`).
- **Taskbar & Tray**: Taskbar alignment (`TaskbarAl`), search display mode (`SearchboxTaskbarMode`), widgets (`TaskbarDa`), and system tray icon visibility.
- **Power & Performance**: Active power scheme GUID and display/sleep timeouts (`powercfg`).

#### Pre-Flight Output Artifacts
1. `audit-reference.json`: The machine hardware, cryptographic profile, installed WinGet packages, non-WinGet ARP software, `profile_association`, and detected Windows settings.
2. `profile-computers.json`: Persistent computer-to-profile registry mapping each `profile` to its historical `computer_name` containers and synced folders (`Computers/<ComputerName>/<Folder>`).
3. `reglaze.yaml`: Pre-populated skeleton blueprint reflecting detected packages, junction mappings, `profile`, hardware-identified `preserved_disks`, and `storage.sync` (`source_computer`, `migration_mode`). When running `reglaze audit` without an existing `reglaze.yaml` in the output directory, `-Profile <name>` is required.

---

### Phase 1: Blueprint Specification & Validation (`reglaze validate`)

The operator configures `reglaze.yaml`. The compiler runs comprehensive semantic and safety validation against `data/applications.json`:

```mermaid
graph TD
    YAML["reglaze.yaml"] --> Parser["Schema Parser"]
    Catalog["data/applications.json"] --> Validator["Validation Engine"]
    Parser --> Validator

    Validator --> Rule1{"Application exists in catalog?"}
    Rule1 -- No --> CustomCheck{"Declared in custom list?"}
    CustomCheck -- No --> Err1["Fatal Error: Unknown app_id"]
    CustomCheck -- Yes --> Rule2
    Rule1 -- Yes --> Rule2{"Mandatory directories mapped?"}
    
    Rule2 -- Missing & No Override --> Err2["Fatal Error: Missing mandatory mapping"]
    Rule2 -- Mapped --> Rule3{"Is safe_for_stream false?"}
    
    Rule3 -- Yes --> StreamCheck{"Target uses %STREAM%?"}
    StreamCheck -- Yes & No Override --> Err3["Safety Violation: DB catalog cannot use streaming!"]
    StreamCheck -- No --> Valid["Blueprint Validated"]
    Rule3 -- No --> Valid
```

#### Core Validation Rules:
1. **Catalog Integrity**: Any application declared under `applications` must match an `app_id` in `data/applications.json`. Uncataloged applications must reside in `custom`.
2. **Mandatory Mapping Enforcement**: If `needs_mapping: true` in the catalog, `reglaze.yaml` must provide a `target` path or an explicit `override: { action: "omit" }`.
3. **Safety Protection**: If `safe_for_stream: false` in the catalog, specifying a target that resolves to `%STREAM%` fails compilation unless overridden with `override: { action: "force_stream", reason: "..." }`.
4. **Variable Verification**: All `%SYNC_<ID>%` tokens must resolve to a valid entry under `storage.sync.directories`.

---

### Phase 2: Compiler & Media Artifact Generation (`reglaze compile`)

The compiler merges `reglaze.yaml`, `audit-reference.json`, and `data/applications.json` into deployment artifacts:

```
dist/media/
├── autounattend.xml               # WinPE partitioning & specialize answer file
├── Reglaze/
│   ├── reglaze.tag                # Build sentinel tag binding WinPE & FirstLogon to this USB
│   ├── prepare-target-disk.cmd    # WinPE target OS disk matcher & GPT partitioner
│   ├── DiskMatch.ps1              # Multi-factor disk signature matcher
│   └── payload/
│       ├── configuration.dsc.yaml # Machine-scope WinGet DSC manifest
│       ├── user-packages.json     # User-scope & deferred WinGet packages queue
│       ├── disk-config.json       # Preserved disk & drive letter reconciliation manifest
│       ├── bitlocker-keys.json    # Encrypted secondary volume recovery keys
│       ├── junctions-manifest.json# Pre-computed machine & user junction mapping table
│       ├── google-drive-setup.json# Cloud streaming & synced folder migration manifest
│       ├── windows-settings.json  # Declarative Windows, network, display & pin settings
│       ├── bootstrap.ps1          # Phase 4 Machine Bootstrap orchestrator (LocalAdmin)
│       ├── bootstrap-helpers.ps1  # Phase 4 helper subscript (EFI, Updates, DSC, Junctions)
│       ├── hydrate.ps1            # Phase 5 User Hydration orchestrator (Primary User)
│       ├── hydrate-helpers.ps1    # Phase 5 helper subscript (Auth Bootstrap, Cloud, Steam, WSL)
│       ├── setup-wsl.sh           # WSL2 non-interactive Linux root provisioner
│       ├── windows/               # Modular Windows settings scripts (data/windows/*.ps1)
│       └── applications.json      # Filtered reference catalog for blueprint apps
└── EFI/boot/                      # Windows Setup UEFI bootloader
```

#### `autounattend.xml` Architecture
* **`windowsPE` Pass**: Executes WinPE pre-installation script to identify the target OS disk using multi-factor criteria. Partitions the drive into EFI (100MB), MSR (16MB), Windows OS (NTFS), and Recovery (1000MB).
* **`specialize` Pass**: Sets computer name, timezone, product key from `audit-reference.json`, and enables base features (`Microsoft-Windows-Subsystem-Linux`, `VirtualMachinePlatform`).
* **`oobeSystem` Pass**: Creates `LocalAdmin` and the standard user (`local_to_msa`). Sets `AutoLogon` for `LocalAdmin` with `LogonCount: 1`. Directs `FirstLogonCommands` to launch `C:\Reglaze\bootstrap.ps1`.

---

### Phase 2.5: Official Windows 11 ISO Acquisition & Native UEFI Bootable Media Creation (`reglaze media`, `reglaze iso`)

To eliminate reliance on fragile third-party flashing utilities (Rufus, Ventoy) and avoid the manual multi-step Microsoft Media Creation Tool (MCT) GUI wizard, `reglaze` provides a native, 100% Microsoft-compliant UEFI bootable USB flashing engine.

#### 1. Why Native UEFI FAT32 with DISM Split-Wim?
* **Universal UEFI Boot Compatibility**: UEFI firmware implementations across modern motherboards natively support booting from FAT32 partitions. Formatting the USB drive as FAT32 ensures zero firmware incompatibilities across AMD and Intel platforms.
* **The 4GB FAT32 Limitation**: Modern Windows 11 installation ISOs contain an `install.wim` file that exceeds FAT32's 4GB file size limit (often 4.8 GB – 5.5 GB).
* **Native DISM Image Splitting**: Third-party tools often work around this limit by creating complex dual-partition drives or NTFS bootloaders requiring custom UEFI drivers (UEFI:NTFS). Instead, `reglaze` uses Windows' built-in DISM command:
  ```cmd
  dism.exe /Split-Image /ImageFile:"D:\sources\install.wim" /SWMFile:"E:\sources\install.swm" /FileSize:3800
  ```
  Windows Setup natively recognizes split `.swm` files (`install.swm`, `install2.swm`) out of the box without requiring any registry hacks, modified bootloaders, or bypass scripts.
* **Preserving Annual Windows Feature Updates**: Flashing tools like Rufus often inject setup-time registry bypasses (bypassing TPM 2.0, Secure Boot, or CPU requirements). These registry hacks frequently break subsequent major Windows feature updates (e.g. 23H2 &rarr; 24H2). `reglaze` produces completely vanilla, standard installation media that satisfies all native Windows servicing pipelines.

#### 2. Workflow & Step-by-Step Execution:
```mermaid
flowchart TD
    Invoke["reglaze media -UsbDrive E:"] --> SafeCheck{"Test-ValidUsbDrive: Is drive C: or internal NVMe/SATA?"}
    SafeCheck -- Yes --> Abort["CRITICAL SAFETY ABORT: Rejects internal/system drives"]
    SafeCheck -- No --> FindIso{"Get-Windows11Iso: Local ISO found?"}
    
    FindIso -- No --> Download["BITS Background Intelligent Transfer / Browser Helper"] --> MountIso
    FindIso -- Yes --> MountIso["Mount-DiskImage -ImagePath Win11.iso"]
    
    MountIso --> FormatFat32["Format-Volume -FileSystem FAT32 -Label REGLAZE"]
    FormatFat32 --> CopyBase["robocopy /XF install.wim (extract bootloaders, EFI, setup)"]
    CopyBase --> DismSplit["dism /Split-Image /ImageFile:install.wim /SWMFile:install.swm /FileSize:3800"]
    DismSplit --> Inject["Copy autounattend.xml, DiskMatch.ps1, payload/ to USB root"]
    Inject --> Dismount["Dismount-DiskImage Win11.iso"]
    Dismount --> Done["Vanilla UEFI Bootable USB Ready"]
```

#### 3. Strict Safety Guardrails (`Test-ValidUsbDrive`):
Before issuing any formatting command, `Test-ValidUsbDrive` inspects physical disk topology using CIM and storage cmdlets:
1. **System Drive Protection**: Evaluates drive letter against `$env:SystemDrive` and strictly rejects `C:` with a fatal error.
2. **Fixed Internal Disk Protection**: Queries `(Get-Disk).BusType` and `(Get-Disk).IsRemovable`. If the drive is located on an internal NVMe, SATA, or RAID bus (`BusType -ne 'USB'`), formatting is rejected unless `-Force` is explicitly passed.

#### 4. ISO Acquisition Engine (`Get-WindowsIso.ps1`):
* **Local Discovery**: Scans working directories, `./downloads/`, and standard user `Downloads` folders for existing official ISOs (`Win11*.iso` > 3GB).
* **Automated BITS Transfer**: If a direct URL is supplied or available, uses Background Intelligent Transfer Service (`Start-BitsTransfer`) with pause/resume support.
* **Interactive Browser Helper**: If manual download is preferred (`-OpenBrowser`), opens the official Microsoft software download portal (`https://www.microsoft.com/software-download/windows11`) and monitors the target directory with active file-lock polling until download completion.

---

### Phase 3: Automated OS Deployment (WinPE & Specialize)

When booting from the generated media, WinPE executes the **Dynamic Disk Matching Engine** before diskpart executes:

```mermaid
flowchart TD
    Boot["WinPE Boot"] --> ScanDisks["Query Get-CimInstance Win32_DiskDrive"]
    ScanDisks --> MatchTarget["Match criteria for Target OS Disk: BusType=NVMe, SerialNumber=NVME_..."]
    
    MatchTarget --> FoundTarget{"Target OS Disk found?"}
    FoundTarget -- No --> Halts["ABORT: Target disk signature mismatch. Halting to prevent data loss."]
    FoundTarget -- Yes --> VerifyPreserved["Verify Preserved Disks are NOT targeted for wipe"]
    
    VerifyPreserved --> DiskpartClean["diskpart: select disk X -> clean -> convert gpt"]
    DiskpartClean --> Partitioning["Create EFI, MSR, OS (C:), Recovery partitions"]
    Partitioning --> ApplyImage["Apply Windows 11 Image (DISM / Apply-Image)"]
    ApplyImage --> WriteSpecialize["Stage C:\Reglaze payload & answer files"]
    WriteSpecialize --> Reboot["Reboot into Windows Specialize"]
```

```powershell
# WinPE Pre-Install Disk Resolution Logic
$TargetSerial = "NVME_DISK_0001_SAMPLE"
$TargetBus = "NVMe"

$Disks = Get-PhysicalDisk
$TargetDisk = $Disks | Where-Object { 
    $_.SerialNumber -eq $TargetSerial -and $_.BusType -eq $TargetBus 
}

if (-not $TargetDisk) {
    Write-Error "CRITICAL: Could not uniquely match target OS disk! Halting installation."
    Exit 1
}

$DiskNumber = $TargetDisk.DeviceId
# Generate dynamic diskpart script selecting $DiskNumber
```

---

### Phase 4: Post-Install Machine Orchestration (`bootstrap.ps1` under LocalAdmin)

Upon initial boot, Windows automatically logs into `LocalAdmin`. `bootstrap.ps1` executes non-interactively in strict sequence, with durable checkpoint support if preserved drives were physically disconnected during Phase 3:

```powershell
# 1. Pass 1 Drive Letter Reconciliation (3-phase atomic swap)
#    - Clears drive letters from unconfigured fixed drives and preserved_disks without expected_mount
#    - Moves removable/USB media out of reserved drive letters (C:, preserved_disks, streaming mount_point)
#    - Assigns expected_mount letters to connected preserved_disks via SerialNumber + PartitionNumber/PartitionGuid
$ReconcilePass1 = Invoke-DriveLetterReconciliation -DiskConfigPath "C:\Reglaze\payload\disk-config.json" -Live

# 2. Automated WHQL Driver Servicing (Chipset, Audio, Network, Storage)
#    Executes prior to missing-disk check so all storage controllers are initialized
if ($Blueprint.system.updates.drivers -ne $false) {
    Install-PackageProvider -Name NuGet -Force -Scope CurrentUser
    Install-Module -Name PSWindowsUpdate -Force -Scope CurrentUser
    Get-WindowsUpdate -Category "Drivers" -Install -AcceptAll -IgnoreReboot -ErrorAction SilentlyContinue
}

# 3. Missing Required Preserved Disk Reconnect Checkpoint
#    If any preserved disk with RequiredByConfig = true is physically disconnected:
#    - Preserves LocalAdmin AutoLogon (AutoLogonCount = 1)
#    - Registers HKLM RunOnce -> bootstrap.ps1 (resuming via bootstrap-state.json)
#    - Shuts down the workstation (Stop-Computer -Force) so the operator can reconnect drives
if ($ReconcilePass1.MissingRequiredDisks.Count -gt 0) {
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "ReglazeBootstrapResume" -Value "powershell.exe -ExecutionPolicy Bypass -File C:\Reglaze\payload\bootstrap.ps1"
    Stop-Computer -Force
}

# 4. Pass 2 Drive Letter Reconciliation & BitLocker Unlock
#    Unlocks connected preserved volumes by hardware identity (DiskSerialNumber + PartitionGuid)
#    and re-arms TPM auto-unlock (Enable-BitLockerAutoUnlock) after expected_mount letters are settled
$ReconcilePass2 = Invoke-DriveLetterReconciliation -DiskConfigPath "C:\Reglaze\payload\disk-config.json" -Live
Unlock-PreservedBitLockerVolumes -PayloadPath "C:\Reglaze\payload\bitlocker-keys.json" -ConnectedSerialNumbers $ReconcilePass2.ConnectedSerialNumbers -Live

# 5. General Windows Quality & Security Update Pass
if ($Blueprint.system.updates.windows_updates -ne $false) {
    Get-WindowsUpdate -NotCategory "Drivers" -Install -AcceptAll -IgnoreReboot -ErrorAction SilentlyContinue
}

# 6. Configure Google Drive Streaming Mount Policy & Execute WinGet DSC
#    Pre-configures HKLM:\SOFTWARE\Policies\Google\DriveFS\DefaultMountPoint (e.g., "E")
New-Item -Path "HKLM:\SOFTWARE\Policies\Google\DriveFS" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Google\DriveFS" -Name "DefaultMountPoint" -Value "E" -Type String
winget configure --file "C:\Reglaze\payload\configuration.dsc.yaml" --accept-configuration-agreements --disable-interactivity

# 5. Stage Machine-Scope WSL2 Subsystem Kernel (Distros are user-scoped and deferred to Phase 5)
wsl.exe --install --no-distribution

# 6. Create Machine-Level Local Preserved Junctions & Grant Deferred Junction Parent ACLs
#    Cloud (%STREAM%), sync (%SYNC_*%), and Steam junctions are deferred to Phase 5;
#    grants BUILTIN\Users modify permissions on parent folders (e.g. C:\Program Files (x86)\Steam)
Invoke-MachineJunctionsAndPermissions -PayloadDir "C:\Reglaze\payload"

# 7. Apply Machine-Scope Windows Settings (Power, PnP Cameras, HwSchMode, Network/Firewall, Start Policy)
#    User-scoped HKCU settings and User Shell Folders are deferred to Phase 5
Invoke-MachineWindowsSettings -PayloadDir "C:\Reglaze\payload"

# 8. Ensure Primary User Account Exists & Destroy AutoLogon Credentials
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "DefaultPassword" -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "AutoAdminLogon" -Value "0"

# 9. Stage Phase 5 Hydration Shortcut on Public Desktop & Restart
#    Places 'Reglaze Hydration.lnk' on C:\Users\Public\Desktop (without RunOnce auto-launch)
Restart-Computer -Force
```

---

### Phase 5: User & Application Hydration (Standard User Session)

The operator signs in as the primary user and launches the **`Reglaze Hydration`** shortcut on their Desktop. `hydrate.ps1` (assisted by `hydrate-helpers.ps1`) executes the staged orchestration:

```mermaid
flowchart TD
    Logon["User Signs In & Launches 'Reglaze Hydration' Shortcut"] --> Step01["Step 0-1: Verify Preserved Disks & Apply HKCU Theme, Display Topology, Input & Taskbar"]
    Step01 --> ConnectMSA["Step 2: Connect to Microsoft Account (Optional)"]
    ConnectMSA --> AuthBoot["Step 3 (Auth Bootstrap): Default Browser, Chrome Profile/Tabs Sync & Bitwarden Unlock"]
    AuthBoot --> ShellFolders["Step 4-5: Relocate User Shell Folders & Install User-Scope WinGet Packages"]
    ShellFolders --> HITL1["Step 6: Sign in to Google Drive for Desktop & Migrate Sync Folders"]
    
    HITL1 --> WaitStream{"Poll sentinel path: E:\\My Drive"}
    WaitStream -- Not Ready --> WaitStream
    WaitStream -- Ready --> HITL2["Step 7: Launch Steam, Discover Libraries & Bulk-Install Games"]
    
    HITL2 --> HITL3["Step 8: Prompt for Manual App Installs (OutFox, etc.)"]
    HITL3 --> LinkJunctions["Step 9: Create User Directory Junctions, Re-Apply Cloud Wallpaper & Set Shell Pins"]
    LinkJunctions --> WSLHydrate["Step 10: Install User-Scope WSL2 Distro (wsl --install -d Ubuntu) & Run setup-wsl.sh"]
    WSLHydrate --> GitHydrate["Step 11: Verify Dev Repositories & Chezmoi Dotfiles"]
    GitHydrate --> Complete["Workstation Fully Hydrated!"]
```

#### Staged Human-in-the-Loop (HITL) Execution
To prevent overwhelming the user with simultaneous dialogs and ensure every step's prerequisites are ready before it runs, interactive tasks are strictly sequenced:
1. **Foundational Authentication Bootstrap (Browser & Password Manager - Step 3)**: Before any cloud or game client sign-in occurs, `hydrate.ps1` launches the user's preferred browser (`--make-default-browser chrome://history/syncedTabs`) and Windows Default Apps settings so the user can sign into their browser profile, restore prior open tabs, and unlock their password manager extension (e.g., Bitwarden). This makes all subsequent OAuth popups, complex passwords, and 2FA codes immediately accessible.
2. **Cloud Virtual Mount & Sync Migration (Step 6)**: The runner displays the blueprint-tailored Google Drive setup checklist (`WHAT TO DO / WHAT NOT TO DO DURING GOOGLE DRIVE SETUP`), launches `GoogleDriveFS.exe`, polls for the virtual streaming mount sentinel (`%STREAM%`), and migrates OS-drive synced folders from `Other computers\<SourceComputerName>`.
3. **Steam Multi-Library Discovery & Bulk Game Installs (Step 7)**: Steam launches for user login and Steam Guard verification. Preserved libraries across all drives are discovered automatically, non-Steam shortcuts (`shortcuts.vdf`) are restored, and uninstalled blueprint games are presented for bulk installation via a Steam Collection or automated `steam://install/<AppID>` links.
4. **Manual App Installations (Step 8)**: For apps flagged with `"install": { "method": "manual" }` (such as OutFox), `reglaze` displays the official download URL, target directory, and setup instructions before Step 9 links their asset/config junctions.

#### Non-Interactive WSL2 Provisioning
To avoid interactive UNIX prompts (`Enter new UNIX username:`) halting the pipeline, WSL2 is provisioned by injecting commands directly through `root`:

```powershell
# Executed by hydrate.ps1 on the host
$Distro = "Ubuntu"
$WSLUser = "developer"

# Run non-interactive setup as root inside WSL2
wsl.exe -d $Distro -u root -- /bin/bash -c @"
set -e
# Create user if not present
if ! id -u $WSLUser >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo $WSLUser
    echo '$WSLUser ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-$WSLUser
fi

# Configure rclone bisync
mkdir -p /home/$WSLUser/.config/rclone
cat << 'EOF' > /home/$WSLUser/.config/rclone/rclone.conf
[gdrive]
type = drive
client_id = $Env:GDRIVE_CLIENT_ID
client_secret = $Env:GDRIVE_CLIENT_SECRET
scope = drive
EOF
chown -R $WSLUser:$WSLUser /home/$WSLUser/.config

# Stage and run initial rclone bisync
su - $WSLUser -c 'rclone bisync gdrive:dev_repos /home/$WSLUser/dev_repos --resync --create-empty-src-dirs'
"@
```

#### HITL State Resumption, Checkpoints & Desktop Shortcut

To ensure a seamless user experience even if the operator is interrupted, exits the terminal, or experiences a reboot:

1. **State Tracking & Checkpoints (`hydration-state.json`)**:
   - `hydrate.ps1` maintains an idempotent state file at `%LOCALAPPDATA%\Reglaze\hydration-state.json`.
   - Each completed milestone records a timestamped checkpoint:
     ```json
     {
       "msa_connected": true,
       "cloud_stream_authenticated": true,
       "steam_library_connected": true,
       "manual_apps_installed": ["outfox"],
       "junctions_established": true,
       "wsl_provisioned": true,
       "dev_repos_cloned": false,
       "completed": false
     }
     ```
   - When launched, `hydrate.ps1` checks this state file. Completed milestones are validated and skipped, allowing the operator to resume exactly where they left off.

2. **Automatic Startup & Self-Unregistration**:
   - At the conclusion of Phase 4, the installer registers `hydrate.ps1` in the standard user's startup registry key:
     `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\ReglazeHydrate`
   - When the final milestone completes (`completed: true`), `hydrate.ps1` **automatically unregisters itself**:
     ```powershell
     Remove-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "ReglazeHydrate" -ErrorAction SilentlyContinue
     ```
   - Subsequent user logins boot directly into a clean, unencumbered Windows desktop.

3. **Visible Desktop Resumption Shortcut**:
   - During initial user session initialization, a prominent shortcut is placed on the operator's desktop:
     `%USERPROFILE%\Desktop\Resume Reglaze Setup.lnk`
     pointing to:
     `powershell.exe -ExecutionPolicy Bypass -NoExit -File C:\Reglaze\payload\hydrate.ps1`
   - If the operator closes the terminal or needs to pause setup, they can simply double-click this desktop shortcut to resume at any time.
   - Upon final completion, the script renames the shortcut to `Reglaze Health Check.lnk` to provide a 1-click diagnostic tool for verifying ongoing junction and sync health.

---

## 6. Component Architecture & CLI Interface

The `reglaze` framework is implemented as an extensible PowerShell engine with a standardized CLI command suite and modular catalog architecture:

```
reglaze/
├── bin/
│   └── reglaze.ps1                      # Main CLI wrapper script (audit, validate, migration-plan, migrate, compile, media, test)
├── data/
│   ├── applications/                    # Modular Application Catalog (one directory per app_id)
│   │   ├── _schema.json                 # Formal JSON Schema for individual app manifests
│   │   ├── _template/                   # Starter template for adding new applications
│   │   │   ├── app.json
│   │   │   ├── guide.md
│   │   │   └── post-install.ps1
│   │   ├── adobe_lightroom/
│   │   │   └── app.json
│   │   ├── outfox/
│   │   │   ├── app.json
│   │   │   ├── guide.md                 # Interactive manual install instructions
│   │   │   └── post-install.ps1         # Post-install shortcuts and path configuration
│   │   ├── vscode/
│   │   │   ├── app.json
│   │   │   └── post-install.ps1         # Extension initialization
│   │   └── ... (beat_saber, steam, lotro, git, etc.)
│   ├── windows/                         # Modular Windows Settings & Preferences (Phase 4 Machine vs. Phase 5 User Scope)
│   │   ├── explorer-folder-options.ps1  # [Phase 5 User] Hidden files, extensions, launch to This PC, SharingWizardOn, UserShellFolders
│   │   ├── taskbar-system-tray.ps1      # [Phase 5 User] Taskbar alignment, search mode, widgets, tray pins
│   │   ├── performance-power.ps1        # [Phase 4 Machine & Phase 5 User (-Scope)] Power scheme, LongPaths, ssh-agent, ClipboardHistory, DefaultTerminal
│   │   ├── theme-personalization.ps1    # [Phase 5 User] Dark/Light theme, accent color, desktop wallpaper
│   │   ├── input-mouse-keyboard.ps1     # [Phase 5 User] Pointer precision, NumLock state, Sticky/Filter keys
│   │   ├── audio-display.ps1            # [Phase 4 Machine & Phase 5 User (-Scope)] Camera PnP, HAGS, CoreAudio endpoints, Game Mode, multi-monitor layout
│   │   ├── network-firewall.ps1         # [Phase 4 Machine] Active NIC NetworkCategory (Private/Public)
│   │   ├── shell-pins.ps1               # [Phase 4 Machine & Phase 5 User] Start layout policy, Quick Access pins, User PATH, Steam libraryfolders.vdf
│   │   └── audit-windows-settings.ps1   # [Phase 0 Audit] Captures existing Windows settings for baseline
│   └── applications.json                # Merged/cached catalog index
├── src/
│   ├── audit/                           # Phase 0 Audit Engine
│   │   ├── Audit-Hardware.ps1
│   │   ├── Audit-Licensing.ps1
│   │   ├── Audit-BitLocker.ps1
│   │   ├── Audit-Apps.ps1               # Scans WinGet + Add/Remove Programs (ARP) + Steam
│   │   ├── Audit-Junctions.ps1
│   │   ├── Audit-StorageProviders.ps1
│   │   ├── Audit-Network.ps1
│   │   ├── Audit-Wsl.ps1
│   │   ├── Invoke-AdminAudit.ps1
│   │   └── Invoke-Audit.ps1
│   ├── common/                          # Shared Subsystems & Parsers
│   │   ├── Catalog.ps1
│   │   ├── ConfigResolver.ps1
│   │   ├── GameLibraries.ps1            # Multi-library game discovery & fresh install engine
│   │   ├── Logging.ps1
│   │   └── YamlParser.ps1
│   ├── compiler/                        # Phase 1 & 2 Compiler & Modular Script Generator Engine
│   │   ├── Test-ReglazeValidation.ps1
│   │   ├── Resolve-Variables.ps1
│   │   ├── Build-Autounattend.ps1
│   │   ├── Build-WinGetDSC.ps1
│   │   ├── Build-Payload.ps1            # Payload compiler & artifact bundler
│   │   ├── Build-BootstrapScript.ps1    # Generates modular Phase 4 bootstrap.ps1 & bootstrap-helpers.ps1
│   │   ├── Build-HydrateScript.ps1      # Generates modular Phase 5 hydrate.ps1, hydrate-helpers.ps1 & setup-wsl.sh
│   │   ├── DiskMatch.ps1 / .vbs
│   │   └── Compile-Reglaze.ps1
│   ├── linking/                         # Junction, Drive Letter, BitLocker & Migration Engine
│   │   ├── Invoke-PreInstallMigration.ps1 # Generates migration-manifest.yaml & runs multi-threaded robocopy staging
│   │   ├── Set-ReglazeDriveLetters.ps1  # 3-phase atomic preserved drive letter reconciliation
│   │   ├── Unlock-BitLockerVolumes.ps1  # Hardware-matched BitLocker unlock & auto-unlock binding
│   │   ├── New-DirectoryJunction.ps1
│   │   ├── Test-ReparsePoint.ps1
│   │   └── Backup-CollisionFolder.ps1
│   ├── media/                           # Phase 2.5 UEFI Media Builder Engine
│   │   ├── Get-WindowsIso.ps1           # Official ISO discovery & BITS downloader
│   │   └── Build-Media.ps1              # Universal FAT32 builder with DISM split-wim & rapid -UpdateOnly refresh
│   ├── runner/                          # Phase 4 & 5 Orchestration Runners
│   │   ├── Apply-WindowsSettings.ps1    # Phase-aware dispatcher (-Phase Phase4 | Phase5 | All)
│   │   ├── Start-MachineBootstrap.ps1   # Phase 4 Machine Bootstrap runner
│   │   └── Start-UserHydration.ps1      # Phase 5 User Hydration runner
│   └── wsl/                             # WSL2 Integration Subsystem
│       ├── Initialize-WSLDistro.ps1
│       └── Sync-WSLRclone.ps1
├── schemas/
│   └── reglaze.schema.json
├── examples/
│   ├── audit-reference.json
│   └── reglaze.yaml
└── docs/
    ├── ARCHITECTURE.md
    └── HITL_TESTING.md
```

### CLI Command Specifications

| CLI Command | Phase | Description |
| :--- | :--- | :--- |
| `reglaze audit [-Profile <name>] [-ConfigDir <path>]` | Phase 0 | Performs pre-flight discovery of the current machine, producing `audit-reference.json`, `profile-computers.json`, and a baseline `reglaze.yaml`. `-Profile` is required if no existing `reglaze.yaml` is found in the target directory. |
| `reglaze validate [-ConfigDir <path>]` | Phase 1 | Validates a blueprint against `data/applications.json` (and optional `<ConfigDir>/applications.json`), checking syntax, mandatory mappings, and safety constraints. |
| `reglaze migration-plan [-ConfigDir <path>]` | Phase 1b | Inspects `reglaze.yaml` and `audit-reference.json` to emit a draft `migration-manifest.yaml` with measured byte sizes and file counts for pre-wipe data staging. |
| `reglaze migrate [-ConfigDir <path>]` | Phase 1b | Executes `migration-manifest.yaml`, creating target sync/streaming/data directories and copying files via multi-threaded `robocopy.exe` before wiping the OS. |
| `reglaze compile [-ConfigDir <path>] [-DistDir <path>] [-UsbDrive <drive>] [-RetainWindowsFiles]` | Phase 2 | Compiles the declarative blueprint into installation media artifacts (`autounattend.xml`, `configuration.dsc.yaml`, `bootstrap.ps1`, `bootstrap-helpers.ps1`, `hydrate.ps1`, `hydrate-helpers.ps1`, `setup-wsl.sh`) and optionally deploys or updates USB media. |
| `reglaze media -UsbDrive <drive> [-DistDir <path>] [-UpdateOnly]` | Phase 2.5 | Formats target USB drive (or refreshes only `autounattend.xml` and `\Reglaze` when `-UpdateOnly` is passed) and writes the bootable UEFI installation media bundle. |
| `reglaze test [-Milestone <1..4\|All>]` | Verification | Runs the automated milestone validation and regression test suites. |

---

## 7. Data Models & Schemas

### 7.1 `reglaze.yaml` Specification

```yaml
version: "1.0"
profile: "string"

system:
  computer_name: "string"
  os_edition: "string"
  timezone: "string"
  licensing:
    channel: "Retail | OEM | Volume"
    backup_key_reference: "audit-reference.json"
  users:
    local_admin:
      username: "LocalAdmin"
      password_env: "LOCAL_ADMIN_PASSWORD"
      auto_logon: true          # Only active during setup Phase 4
    primary_user:
      account_type: "local_to_msa | local | microsoft"
      email: "string"
      username: "string"
      is_admin: false           # Standard user
      auto_logon: false         # Daily interactive login
  features:
    developer_mode: bool
    virtual_machine_platform: bool
    subsystem_for_linux: bool

disks:
  target_os_disk:
    serial_number: "string"    # Hardware identifier from audit
    bus_type: "NVMe | SATA"
    wipe_and_partition: true
    drive_variable: "OS_DRIVE" # Exposes %OS_DRIVE%
  preserved_disks:
    - serial_number: "string"
      expected_mount: "D:"
      drive_variable: "DATA_DRIVE" # Exposes %DATA_DRIVE%
      label: "string"

storage:
  streaming:
    cloud_provider: "google-drive"
    mount_point: "G:"
    verify_folder: "G:\\My Drive"
    stream_variable: "STREAM"  # Exposes %STREAM%
  sync:
    provider: "google-drive-sync | rclone"
    directories:
      catalogs:
        local_path: "%OS_DRIVE%\\Sync\\Catalogs"
        cloud_folder: "Catalogs"
        verify_folder: "%OS_DRIVE%\\Sync\\Catalogs"
        sync_variable: "SYNC_CATALOGS" # Exposes %SYNC_CATALOGS%
      projects:
        local_path: "%DATA_DRIVE%\\Projects"
        cloud_folder: "Projects"
        sync_variable: "SYNC_PROJECTS" # Exposes %SYNC_PROJECTS%
  api_credentials:
    client_id_env: "GDRIVE_CLIENT_ID"
    client_secret_env: "GDRIVE_CLIENT_SECRET"

variables:
  GAMES_DIR: "%DATA_DRIVE%\\Games"
  STEAM_DIR: "%DATA_DRIVE%\\SteamLibrary"

applications:
  <app_id>:
    install: bool              # Optional: defaults to true
    directories:
      <directory_id>:
        target: "string"       # Variable path (%STREAM%\..., %SYNC_CATALOGS%\...)
        override:              # Optional override block
          action: "omit | force_stream | force_sync"
          reason: "string"

custom:
  - name: "string"
    winget_id: "string"
    directories:
      - name: "string"
        source: "string"
        target: "string"

wsl2:
  default_distro: "Ubuntu"
  packages: ["git", "rclone", "curl"]
  sync:
    engine: "rclone"
    mode: "bisync"
    local_path: "/home/developer/dev_repos"
    remote_path: "gdrive:dev_repos"

dev_repos:
  root: "%SYNC_PROJECTS%"
  remotes:
    - name: "string"
      repo: "git@github.com:..."
      method: "git | chezmoi"
```

### 7.2 `data/applications.json` Schema

Each entry represents a certified application profile:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "ApplicationCatalogEntry",
  "type": "object",
  "required": ["app_id", "name", "directories"],
  "properties": {
    "app_id": { "type": "string" },
    "name": { "type": "string" },
    "website": { "type": "string" },
    "install": {
      "type": "object",
      "properties": {
        "method": { "enum": ["winget", "steam", "manual"] },
        "winget_id": { "type": ["string", "null"] },
        "steam_id": { "type": ["integer", "null"] },
        "download_url": { "type": "string" },
        "default_target_directory": { "type": "string" },
        "instructions": { "type": "array", "items": { "type": "string" } }
      }
    },
    "directories": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["id", "description", "default_path", "category", "needs_mapping", "safe_for_stream", "recommended_storage"],
        "properties": {
          "id": { "type": "string" },
          "description": { "type": "string" },
          "default_path": { "type": "string" },
          "category": { "enum": ["config", "saves", "songs", "catalog", "library"] },
          "needs_mapping": { "type": "boolean" },
          "safe_for_stream": { "type": "boolean" },
          "recommended_storage": { "enum": ["streaming", "sync", "local_preserved"] },
          "notes": { "type": "string" }
        }
      }
    }
  }
}
```

---

## 8. Rollback, Error Handling & Idempotency Strategy

| Failure Scenario | Detection Mechanism | Automated Mitigation / Recovery |
| :--- | :--- | :--- |
| **WinPE Disk Mismatch** | Target disk Serial Number or Bus Type not found in CIM query. | **Halt Immediately**. Windows setup is aborted with a clear diagnostic error before any diskpart `clean` command runs. Preserved drives remain untouched. |
| **BitLocker Auto-Unlock Failure** | `Unlock-BitLocker` returns access denied or invalid key. | Fall back to interactive prompt during Phase 4 requesting manual entry of the recovery key; pauses bootstrap until secondary drive is mounted. |
| **Junction Target Missing** | Target cloud folder does not exist on `%STREAM%` or `%SYNC_*%`. | Engine creates the parent target tree automatically; if cloud mount is not ready, prompts user to verify cloud client sync status. |
| **Directory Collision** | Target directory has existing files and local directory also has existing files. | Local directory is renamed to `<folder>.bak_<timestamp>` before junction creation. No files are overwritten or deleted. |
| **WinGet Package Install Failure** | Exit code non-zero during DSC pass. | WinGet logs failure to `C:\Reglaze\logs\winget.log`; pipeline records warning and proceeds with remaining packages to maximize hydration progress. |
| **WSL2 rclone bisync Conflict** | `rclone bisync` detects changes on both sides without common base. | Rclone creates `.conflict` files with timestamps; pipeline completes and warns user to inspect conflict files. |

---

## 9. Testing, Verification & Phased Deployment Strategy

To prevent system disruption or unintended modifications to developer workstations while ensuring high deployment fidelity, `reglaze` follows a three-tiered verification and staged rollout strategy:

### 9.1 Tier 1: In-Repo Mocking & Simulation (Milestones 3 & 4 Active Development)
- **Host OS Isolation:** Active development of directory junction managers, machine bootstrap runners, and user hydration wizards strictly executes against developer workstations using `-Simulation` switches, synthetic mocks, and isolated temporary test folders (`tests/temp_*`).
- **Human-in-the-Loop (HITL) Micro-Experiments:** When low-level Win32, CIM, WSL, or registry syntax requires empirical verification, the developer reviews and executes isolated, read-only snippets manually rather than allowing automated suites to touch host system configuration.
- **Fast Feedback Loop:** Automated test suites (`tests/Test-Milestone*.ps1`) execute in seconds, verifying branching logic, path calculations, collision backups, and error handling without mutating host registry hives, BitLocker volumes, or Windows Explorer state.

### 9.2 Tier 2: Staged Real-World Testing (Pre-Milestone 5)
- **Low-Risk Practical Passes:** Before committing to high-complexity or primary workstation re-imaging, compiled installation media is deployed to a clean, secondary/low-stakes target machine.
- **Iterative Refinement:** Multiple iterations are conducted to observe real hardware and firmware timings, WinPE disk matching behavior, WinGet DSC package installation reliability, and driver servicing in the wild.
- **Feedback Loop:** Any edge cases identified during practical deployments (e.g., driver timing, UAC prompts, or cloud mount synchronization delays) are fed back into compiler templates and runner scripts before higher-stakes rollouts.

### 9.3 Tier 3: Automated Hyper-V VM Testing (Milestone 5)
- **Local Isolated Virtualization:** Milestone 5 builds automated end-to-end integration testing using a dedicated Windows 11 Hyper-V virtual machine (`Reglaze-TestVM`).
- **Dual-Disk Topology:** The test VM is configured with two virtual hard disks:
  - **VHDX 1 (`C:`):** Ephemeral OS target disk for clean installation.
  - **VHDX 2 (`D:`):** Preserved bulk storage disk pre-populated with synthetic game libraries, projects, and BitLocker keys to validate secondary volume retention and auto-unlock re-arming.
- **PowerShell Direct Automation:** Host test harnesses execute commands and collect diagnostics inside the running VM over Hyper-V VMBus sockets (`Invoke-Command -VMName`, `Copy-Item -ToSession`) without requiring network plumbing.
- **Instant Checkpoint Rollback:** Test harnesses automatically restore clean VM checkpoints (`Restore-VMSnapshot`) before and after full provisioning runs, enabling continuous regression testing without manual intervention.

### 9.4 Human-in-the-Loop (HITL) Testing Protocol & Comment Standard
To ensure durability of testing progress across system interruptions, unexpected reboots, or agent context resets, low-level OS manipulation points must be annotated directly in code and tracked in [docs/HITL_TESTING.md](docs/HITL_TESTING.md).

1. **Standardized Inline Annotation Schema:**
   ```powershell
   # [HITL-ID]: HITL-M3-01
   # [HITL-TARGET]: Component / Cmdlet / Subsystem (e.g., Enable-BitLockerAutoUnlock)
   # [HITL-STATUS]: PENDING | IN_PROGRESS | VERIFIED | TABLED
   # [HITL-DESCRIPTION]: Explanation of what needs validation and risks involved
   # [HITL-TEST-SNIPPET]: PowerShell test snippet for the user to run
   # [HITL-LAST-INPUT]: Arguments/parameters tested in the latest run
   # [HITL-LAST-RESULT]: Output, error message, or exit code received from the user
   # [HITL-PATTERN]: Working command pattern to emulate in production code
   # [HITL-AVOID]: Approaches/cmdlets that failed or caused issues (and why)
   ```
2. **Batched Interaction Lifecycle:**
   - Outstanding tests are collected and presented to the user as a numbered batch in the turn response.
   - The user returns results (partial or complete).
   - The agent updates inline annotations and [docs/HITL_TESTING.md](docs/HITL_TESTING.md), records fixes, and returns the updated roster of pending tests until all are verified or tabled.

---

## 10. Implementation Roadmap & Milestones

### Milestone 1: CLI Foundation & Pre-Flight Discovery (`reglaze audit`)
- [x] Implement `src/audit/` PowerShell modules for hardware, disk, licensing, BitLocker, and junction discovery.
- [x] Implement schema validation for `audit-reference.json` and `reglaze.yaml`.
- [x] Build automated unit tests verifying hardware signature generation across virtual and physical disks.

### Milestone 2: Compiler & Artifact Generator (`reglaze compile`)
- [x] Implement template rendering engines for `autounattend.xml` and `configuration.dsc.yaml`.
- [x] Build the dynamic WinPE disk matching script (`DiskMatch.ps1`).
- [x] Implement validation engine enforcing application catalog safety rules (`safe_for_stream: false` checks).
- [x] Implement variable expansion engine (`%OS_DRIVE%`, `%DATA_DRIVE%`, `%STREAM%`, `%SYNC_<ID>%`).

### Milestone 3: Linking Engine & Machine Bootstrap (`reglaze bootstrap`)
- [x] Implement `src/linking/` directory junction management with collision detection and backup logic.
- [x] Implement BitLocker recovery key injection and `Enable-BitLockerAutoUnlock` automation.
- [x] Build machine-level orchestration script (`bootstrap.ps1`) executing under `LocalAdmin`.
- [x] Build AutoLogon cleanup logic.

### Milestone 4: User Hydration & WSL2 Integration (`reglaze hydrate`)
- [x] Build user-level staged interactive wizard (Cloud mount verification, Steam launch, manual app guidance).
- [x] Implement non-interactive WSL2 bootstrap script using root `useradd` and `rclone bisync` configuration.
- [x] Implement `dev_repos` cloning and Chezmoi dotfiles application.

### Milestone 5: End-to-End Validation & Packaging
- [ ] Hyper-V / Proxmox VM end-to-end automated testing with secondary virtual disks and PowerShell Direct.
- [ ] Bare-metal test pass on physical workstation hardware.
- [ ] CLI packaging and installation documentation.
