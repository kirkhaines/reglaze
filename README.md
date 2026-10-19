# reglaze 🪟✨

> **Declarative, disposable Windows workstation orchestration.**  
> Scraping away accumulated cruft, configuration drift, and bloat—resealing a pristine Windows runtime with a single blueprint.

---

## 1. Vision & Core Philosophy

Modern software engineering treats servers and compute runtimes as disposable infrastructure defined by code. Desktop Windows installs, by contrast, frequently suffer from gradual entropy: registry pollution, orphaned app state, broken updates, and configuration rot. 

**`reglaze`** brings the **Infrastructure as Code (IaC)** paradigm to personal Windows workstations:

1. **The OS is a Disposable Runtime:** Your local Windows installation holds zero persistent state. If the OS exhibits corruption or instability, wiping and restoring it takes minimal effort and minimal active human attention.
2. **Least Privilege by Default (Dual-User Security):** Single-user workstations should not run daily tasks as an Administrator. `reglaze` provisions a dedicated `LocalAdmin` account strictly for UAC privilege elevation while configuring the primary user (e.g., your Microsoft Account) as a standard non-admin user.
3. **Tiered Persistent State Strategy:**
   * **Virtual Streaming Storage:** Everyday documents, media archives, and lightweight app configs reside on cloud-first virtual streaming filesystems (e.g., Google Drive streaming mounts).
   * **Local Storage with Folder Syncing for High-I/O & Sensitive Catalogs:** Streaming filesystems are ill-suited for file formats sensitive to file-locking latency, database concurrency, or partial writes (such as Adobe Lightroom catalogs, Darktable database caches, and active Git repositories). These workloads reside locally on fast SSD storage and rely on dedicated two-way folder syncing engines or remote Git synchronization to prevent catalog corruption.
   * **Secondary Drives for Bulk Data:** Datasets too large or high-bandwidth for cloud tiers (raw 4K/8K video production footage, large local game installs, virtual machine images) remain on dedicated secondary internal or external drives. These drives persist untouched across OS wipes, with the user retaining explicit responsibility for their own backup routines and data integrity.
4. **Application Catalog & Guided Mapping Enforcement:** Applications spread state unpredictably across `%APPDATA%`, `%LOCALAPPDATA%`, `Saved Games`, and Steam libraries. `reglaze` maintains a built-in **Application Reference Catalog** (`data/applications.json`) detailing notable directories (configs, saves, songs, catalogs) and their storage properties (`needs_mapping`, `safe_for_stream`, `recommended_storage`). The declarative spec organizes settings into an `applications` section keyed by `app_id`, enforcing recommended mappings while supporting an extensible `custom` section for arbitrary directories.
5. **Decoupled Local App State (Junctions as Shims):** Local applications and games expect state in fixed directories. `reglaze` restores these connections seamlessly using automated directory junctions pointing into your cloud mount, local sync root, or secondary drive.
6. **Integrated WSL2 Linux Subsystem:** Modern developer workstations require Linux alongside Windows. `reglaze` configures WSL2 with a target distribution (e.g., Ubuntu), installs essential toolchains, and orchestrates background `rclone` synchronization of developer repositories (`dev_repos`) into Google Drive.
7. **Unified API Quota & Rate Limit Protection:** Heavy background synchronization across thousands of files triggers Google Drive's shared API quotas. `reglaze` accepts custom Google Cloud OAuth 2.0 API Client credentials once at the root storage configuration and propagates them across all Windows and WSL2 sync services, eliminating `403 User Rate Limit Exceeded` stalls.
8. **Tool-Agnostic Declarative Specification:** You define *what* your system needs once in a human-readable, schema-validated configuration file. `reglaze` translates that single source of truth into tool-specific execution artifacts (`autounattend.xml`, WinGet DSC YAML, PowerShell bootstrap scripts, WSL configuration scripts, and dotfile managers).

---

## 2. System Architecture & Lifecycle

```

[ Phase 0: Pre-Flight Audit ]
│ (Scans system, BitLocker keys, Windows licenses, disk IDs, junctions, packages)
├───────────────────────────────────┐
▼                                   ▼
[ audit-reference.json ]            [ reglaze.yaml (Scaffolded Initial Draft) ]
(Hardware, Keys & Disks Reference)  │
                                    │◄─── [ data/applications.json ]
                                    ▼     (Reference Catalog & Safety Rules)
                                    [ Phase 1: User Blueprint Review & Edit ]
                                    │ (User customizes, validates app mappings,
                                    │  and configures LocalAdmin + standard user)
                                    ▼
                                    [ Phase 2: Media & Artifact Generation ]
                                    │ (reglaze compiler / media creator)
                ┌───────────────────┼───────────────────┐
                ▼                   ▼                   ▼
        autounattend.xml   configuration.dsc.yaml   bootstrap.ps1 & setup-wsl.sh
        (Hands-free WinPE)    (WinGet DSC Apps)    (Junctions, WSL2 & rclone Sync)
                │                   │                   │
                └───────────────────┴───────────────────┘
                                    ▼
                         [ Bootable Install Media ]
                                    ▼
                       [ Phase 3: Unattended Install ]
                        (Provisions LocalAdmin & Non-Admin User)
                                    ▼
                    [ Phase 4: System & App Provisioning ]
                                    ▼
                      [ Phase 5: State Linking & Tailoring ]
                        (WSL2 Distro, rclone API Setup,
                         dev_repos sync, directory junctions)
                                    ▼
                            [ Fully Restored ]

```

### The 6 Execution Phases

| Phase | Component | Responsibility |
| :--- | :--- | :--- |
| **0. Pre-Flight Audit** | `audit.ps1` | Scans the active PC prior to wiping. Extracts BitLocker recovery keys, Windows activation/license info, physical disk and partition GUIDs/IDs, active directory junctions, installed WinGet packages, Git remotes, and environment variables. Correlates detected software against `data/applications.json` and emits `audit-reference.json` alongside an initial, scaffolded `reglaze.yaml`. |
| **1. User Blueprint Review & Validation** | Manual / Config Editor & Compiler | The user inspects and edits `reglaze.yaml` against `audit-reference.json`. The `reglaze` compiler validates declared applications against `data/applications.json`: any directory marked `needs_mapping: true` must be mapped to its recommended target type (`streaming` vs `sync`), or the user must provide an explicit `override` with a rationale. Uncataloged apps and custom folders are declared under `custom:`. |
| **2. Media Generation** | `Compile-Reglaze.ps1` & `New-InstallMedia.ps1` | Compiles `reglaze.yaml` into tool-specific artifacts (`autounattend.xml`, `configuration.dsc.yaml`, `bootstrap.ps1`, `setup-wsl.sh`) and packages them onto bootable installation media (USB or ISO) with required drivers and bootstrap scripts. |
| **3. Unattended Install** | `autounattend.xml` | Boots from media, identifies target OS disk via multi-factor hardware attributes (Serial Number, Bus Type, Model) to protect secondary drives, partitions and applies Windows image, provisions dedicated `LocalAdmin` with temporary setup auto-logon, and creates the primary standard user account (`local_to_msa`). |
| **4. Machine Provisioning & BitLocker Recovery** | `bootstrap.ps1` & WinGet DSC | Auto-logs into `LocalAdmin`. Unlocks preserved secondary drives using embedded recovery keys and re-arms TPM auto-unlock (`Enable-BitLockerAutoUnlock`). Declaratively provisions system features (WSL2, Hyper-V, Developer Mode), runtimes, and core applications via WinGet DSC, pre-stages WSL2, and purges auto-logon credentials before rebooting. |
| **5. User & Application Hydration** | `hydrate.ps1` & `Setup-Wsl.ps1` | Primary standard user signs in interactively (connecting to MSA). Staged human-in-the-loop steps: cloud storage authentication (Google Drive sentinel mount) &rarr; Steam GUI sign-in (instantly detects pre-existing `%DATA_DRIVE%` library) &rarr; manual app install guidance (e.g. OutFox). Establishes directory junctions, executes non-interactive WSL2 root user provisioning with `rclone bisync`, clones `dev_repos`, and runs post-flight health verification. |

---

## 3. Project Structure

```text
reglaze/
├── data/
│   ├── applications/           # Modular application catalog (one directory per app_id)
│   │   ├── _schema.json        # Formal schema for individual app manifests
│   │   ├── _template/          # Starter template (app.json, guide.md, post-install.ps1)
│   │   ├── adobe_lightroom/    # app.json
│   │   ├── outfox/             # app.json, guide.md, post-install.ps1
│   │   ├── vscode/             # app.json, post-install.ps1
│   │   └── ... (beat_saber, steam, lotro, git, etc.)
│   ├── windows/                # Modular Windows settings & preference scripts
│   │   ├── explorer-folder-options.ps1  # Hidden files, extensions, launch to This PC
│   │   ├── taskbar-system-tray.ps1      # Taskbar alignment, search mode, tray icons
│   │   ├── performance-power.ps1        # Power plan and display/sleep timeouts
│   │   └── audit-windows-settings.ps1   # Audits existing system settings
│   └── applications.json       # Cached/merged application catalog index
├── docs/
│   ├── ARCHITECTURE.md         # Comprehensive system architecture & technical design
│   └── TESTING_GUIDE.md        # Walkthrough for third-party testers
├── schemas/
│   └── reglaze.schema.json     # JSON Schema validating the agnostic spec
├── src/
│   ├── audit/                  # Pre-wipe discovery scripts
│   │   ├── Audit-BitLocker.ps1 # Extracts BitLocker recovery keys
│   │   ├── Audit-Licensing.ps1 # Gathers Windows edition, digital license & product keys
│   │   ├── Audit-Storage.ps1   # Enumerates physical disks, partition GUIDs & drive letters
│   │   ├── Audit-Apps.ps1      # Discovers WinGet packages AND Add/Remove Programs (ARP)
│   │   ├── Audit-Junctions.ps1 # Discovers existing directory junctions and reparse points
│   │   └── Invoke-Audit.ps1    # Emits audit-reference.json & scaffolded reglaze.yaml
│   ├── compiler/               # Translates reglaze.yaml -> tool outputs
│   │   ├── generators/
│   │   │   ├── UnattendGenerator.ps1
│   │   │   ├── WinGetDscGenerator.ps1
│   │   │   ├── BootstrapGenerator.ps1
│   │   │   ├── WslGenerator.ps1
│   │   │   └── RcloneGenerator.ps1
│   │   └── Compile-Reglaze.ps1
│   ├── media/                  # Media creation utilities
│   │   └── New-InstallMedia.ps1# Injects unattended artifacts into bootable USB/ISO
│   └── runtime/                # Scripts packaged onto the deployment media
│       ├── Install-Junctions.ps1
│       ├── Test-CloudMount.ps1
│       ├── Setup-Wsl.ps1
│       ├── hydrate.ps1         # User hydration runner with checkpoint resumption
│       └── sync-dev-repos.sh   # Background rclone bisync script inside WSL2
├── examples/
│   ├── audit-reference.json    # Reference output from pre-flight audit
│   └── reglaze.yaml            # Complete reference workstation specification
├── reglaze.yaml                # Your personal system blueprint (git-ignored)
└── README.md
```

---

## 4. Agnostic Configuration Blueprint (`reglaze.yaml`)

The single declaration file defines your entire environment without hardcoding syntax for specific tools. A complete reference specification is available in [examples/reglaze.yaml](examples/reglaze.yaml) alongside its matching audit dump in [examples/audit-reference.json](examples/audit-reference.json).

### Core Schema Highlights

```yaml
version: "1.0"
profile: "developer-creative-workstation"

system:
  computer_name: "WORKSTATION-01"
  os_edition: "Windows 11 Pro"
  timezone: "Central Standard Time"
  licensing:
    channel: "Retail"
    backup_key_reference: "audit-reference.json"
  users:
    # Dedicated local admin account for UAC privilege elevation
    local_admin:
      username: "LocalAdmin"
      password_env: "LOCAL_ADMIN_PASSWORD"
      description: "Dedicated local administrator for UAC elevation"
      auto_logon: true          # Temporarily used by unattended setup for initial provisioning
    # Primary daily interactive user (configured as a standard non-admin account)
    primary_user:
      account_type: "local_to_msa" # Created locally, connected interactively to MSA post-install
      email: "developer@example.com"
      username: "Developer"
      is_admin: false           # Standard user without administrative privileges
      auto_logon: false         # Daily interactive login
  features:
    developer_mode: true
    virtual_machine_platform: true
    subsystem_for_linux: true

disks:
  target_os_disk:
    disk_id: 0 # Matches Disk 0 from audit-reference.json
    wipe_and_partition: true
    drive_variable: "OS_DRIVE" # Exposes %OS_DRIVE% (e.g. C:)
  preserved_disks:
    - disk_id: 1
      label: "Bulk-Data"
      expected_mount: "D:"
      drive_variable: "DATA_DRIVE" # Exposes %DATA_DRIVE% (e.g. D:)
      description: "Dedicated high-capacity SSD for raw media, VMs, and game libraries (user-backed up)"

storage:
  streaming:
    cloud_provider: "google-drive"
    mount_point: "G:"
    verify_folder: "G:\\My Drive"
    stream_variable: "STREAM"     # Exposes %STREAM% -> G:\My Drive
  sync:
    provider: "google-drive-sync"
    directories:
      # Multiple synced folders can be defined; accessible via %SYNC_<ID>%
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
    # Defined ONCE here; compiler injects into Windows sync scripts and WSL2 rclone.conf
    client_id_env: "GDRIVE_CLIENT_ID"
    client_secret_env: "GDRIVE_CLIENT_SECRET"

# Custom directory/drive shortcut variables
variables:
  GAMES_DIR: "%DATA_DRIVE%\\Games"
  STEAM_DIR: "%DATA_DRIVE%\\SteamLibrary"

# Unified applications section.
# Presence in this list implies automatic installation (via WinGet or Steam) unless overridden.
# Directories use variable placeholders (%STREAM%, %SYNC_<ID>%, %OS_DRIVE%, %DATA_DRIVE%, etc.)
applications:
  # Pattern 1: Cloud-Streamed Settings (WinGet app)
  vscode:
    directories:
      user_settings:
        target: "%STREAM%\\Config\\VSCode"

  # Pattern 2: Database Catalog requiring Local Sync + Inline Directory Override
  adobe_lightroom:
    directories:
      catalog:
        target: "%SYNC_CATALOGS%\\Lightroom" # Satisfies 'recommended_storage: sync'
      presets:
        override:
          action: "omit"
          reason: "Starting clean with default presets; previous presets archived separately"

  # Pattern 3: Multi-Tier Storage (Large assets on secondary disk D:, save states in streaming G:)
  beat_saber:
    directories:
      custom_levels:
        target: "%STEAM_DIR%\\steamapps\\common\\Beat Saber\\Beat Saber_Data\\CustomLevels"
      game_saves:
        target: "%STREAM%\\Backups\\BeatSaber\\AppData"

  # Pattern 4: Human-in-the-Loop Manual Install for Non-Automated Software
  # Note: Download URL, method, and generic instructions are inherited from applications.json
  outfox:
    install:
      version: "0.5.0 Alpha"
      target_directory: "%GAMES_DIR%\\OutFox"
      post_install_script: "./scripts/post-install-outfox.ps1"
    directories:
      songs:
        target: "%GAMES_DIR%\\OutFox\\Songs"
      save:
        target: "%STREAM%\\Backups\\OutFox\\Save"

  # Pattern 5: Zero-Configuration Tools (CLI runtimes, container engines)
  git: {}
  docker_desktop: {}

  # Pattern 6: Custom / Uncataloged Applications & Arbitrary Folders
  custom:
    - name: "RetroArch Emulators"
      install: false
      directories:
        - name: "RetroArch Saves and States"
          link: "%OS_DRIVE%\\Emulators\\RetroArch\\saves"
          target: "%STREAM%\\Backups\\Emulators\\RetroArch\\saves"
          storage_type: "streaming"

# WSL2 Linux Subsystem Environment
wsl2:
  enabled: true
  distro: "Ubuntu-24.04"
  default_user: "developer"
  packages:
    - "build-essential"
    - "git"
    - "curl"
    - "zsh"
    - "python3-pip"
    - "rclone"
  dev_repos:
    root: "~/dev"
    sync_engine: "rclone"
    rclone:
      remote_name: "gdrive"
      remote_folder: "Backups/WSL_DevRepos"
      sync_direction: "bidirectional"
      schedule: "*/30 * * * *"
      # API credentials automatically inherited from storage.api_credentials above

dev_repos:
  root: "%SYNC_PROJECTS%" # Uses synced projects folder defined in storage.sync
  remotes:
    - name: "dotfiles"
      repo: "git@github.com:developer/dotfiles.git"
      method: "chezmoi"

```

---

## 5. Application Reference Catalog & Directory Junction Strategy

### Application Reference Catalog (`data/applications.json`)

Applications store critical data in disparate, undocumented local folders. `reglaze` ships with a curated reference catalog specifying known software profiles:

* **Identity & Discoverability:** Captures the unique `app_id` (e.g., `beat_saber`, `outfox`, `satisfactory`, `neva`, `bloodstained`, `lotro`, `steam`, `adobe_lightroom`, `vscode`, `git`, `docker_desktop`), `name`, `winget_id`, Steam App ID (`steam_id`), and official `website`.
* **Generic Installation Guidance:** For applications requiring human intervention (such as `outfox`), `data/applications.json` houses machine-independent installation metadata (`method: "manual"`, `download_url`, `default_target_directory`, and step-by-step instructions). User blueprints only specify machine-specific parameters (`version`, custom path, `post_install_script`).
* **Notable Directories:** Lists specific app paths (`configs`, `saves`, `songs`, `catalogs`, `code`) with default directory locations and variable placeholders (`%GAMES_DIR%`, `%STEAM_LIBRARY%`).
* **Storage Properties & Safety Rules:**
  * `needs_mapping`: Indicates whether unlinked data is lost during an OS wipe.
  * `safe_for_stream`: Specifies if the directory can safely be hosted on a virtual streaming cloud drive. SQLite catalogs (Lightroom, Darktable) and active Git object databases are flagged `safe_for_stream: false` because streaming file-locking semantics cause database corruption and index latency.
  * `recommended_storage`: Designates whether the directory belongs on `streaming`, `sync` (local bidirectional sync), or `local_preserved` (secondary disk).

### Variable Placeholders & Storage Roots

To prevent brittle hardcoded drive letters and paths, `reglaze` supports standardized variable placeholders:
* **Drive Identifiers:** `%OS_DRIVE%` (target OS disk, e.g. `C:`) and `%DATA_DRIVE%` (secondary preserved disk, e.g. `D:`).
* **Streaming Mount:** `%STREAM%` (resolves to the cloud streaming sentinel root, e.g. `G:\My Drive`).
* **Multiple Synced Roots:** `%SYNC_<ID>%` (e.g. `%SYNC_CATALOGS%` &rarr; `C:\Sync\Catalogs`, `%SYNC_PROJECTS%` &rarr; `D:\Projects`).
* **Custom Shortcuts:** Any custom variable declared under `variables:` (e.g. `%GAMES_DIR%`, `%STEAM_DIR%`).

### Enforcement & Override Policy

During compilation (Phase 1), `reglaze` parses the `applications` block declared in `reglaze.yaml` against `data/applications.json`:

1. **Catalog Lookup by `app_id`:** Each key in `applications` references an `app_id` in `data/applications.json`.
2. **Implied Installation:** Listing an application implies automatic installation (via WinGet or Steam) by default. Setting `install: false` skips installation (useful if the application binary is already preserved on secondary storage).
3. **Catalog-Driven Manual Installs:** When an application requires manual setup, `reglaze` merges the generic instructions and download URL from `data/applications.json` with any machine-specific parameters declared in `reglaze.yaml` (such as `target_directory`, `version`, or `post_install_script`). During execution, the runner pauses to present guidance to the operator before establishing junction links.
4. **Mandatory Mappings:** If an application has notable directories with `needs_mapping: true`, the user must declare a target under `directories.<directory_id>.target`.
5. **Safety Verification:** If a directory is flagged `safe_for_stream: false`, pointing its junction target to a streaming mount (`%STREAM%\...`) will fail validation.
6. **Inline Overrides:** To intentionally omit a required directory or divert it from recommendations, specify an `override:` block directly within that directory's configuration:
   ```yaml
   presets:
     override:
       action: "omit" # or "allow_stream"
       reason: "Using stock presets on fresh install"
   ```
7. **Custom Applications & Arbitrary Paths:** Any application or folder not found in `data/applications.json` can be configured under `applications.custom:`, specifying explicit `link`, `target`, and `storage_type` parameters.

### Directory Junction Mechanics

Windows directory junctions (`mklink /J`) are used to link local application paths to cloud or synced mounts:
* **User-Space Safety:** Unlike symbolic links, Directory Junctions operate cleanly without requiring elevated administrator privileges under standard Windows security policies.
* **Mount Sentinel Timing:** Junction creation pauses until the cloud streaming client or sync engine completes authentication and sentinel paths (`Test-Path "G:\My Drive"`, `Test-Path "C:\Sync"`) return ready.
* **Idempotency:** The junction script removes existing placeholder folders created by fresh software installers prior to linking, ensuring collision-free runs.

---

## 6. WSL2 & Developer Repositories (`dev_repos`)

`reglaze` provides first-class automation for configuring a unified Linux developer workstation under WSL2:

### Automated Distribution & Package Provisioning
* Provisions the specified distribution (e.g., `Ubuntu-24.04`) via `wsl --install --distribution <distro>`.
* Creates the non-root developer user with sudo privileges and executes non-interactive `apt` provisioning for declared packages (`build-essential`, `git`, `zsh`, `rclone`, etc.).

### Rclone Dev Repositories Sync
* Active Git repositories and build trees must reside inside the native ext4 WSL2 VHD filesystem (e.g., `~/dev`) rather than over the Windows 9P filesystem bridge (`/mnt/c/...`) to avoid catastrophic filesystem performance degradation.
* `reglaze` configures `rclone` inside WSL2 to synchronize `~/dev` to a designated Google Drive remote folder (`Backups/WSL_DevRepos`) on a scheduled systemd user timer.

### Git-Optional Dotfile & Application Config Management via Chezmoi
* **Decoupled from Git:** While Chezmoi is often paired with Git repositories, `reglaze` supports running Chezmoi directly backed by a local folder provisioned inside Google Drive streaming (`%STREAM%\Config\chezmoi`) or local sync roots (`%SYNC_PROJECTS%\dotfiles`). No Git remote repository is required.
* **App-Specific Config Modifiers (`modify_` scripts):** For applications with dynamic or sensitive settings files (JSON, INI, XML), Chezmoi's `modify_<filename>.ps1` scripts read existing application configurations from `stdin`, programmatically transform specific keys/sections, and output the updated configuration to `stdout`. This preserves local machine state while enforcing desired options without overwriting whole files statically.

### Single API Credential Declaration & Quota Protection
* **The Problem:** The default public API client ID shared by tools like `rclone` frequently encounters Google's global queries-per-second throttling. During full syncs of dev repos containing thousands of files, this causes `HTTP 403: User Rate Limit Exceeded` errors and stalled backups.
* **The Solution:** Google Drive OAuth 2.0 API credentials (`client_id_env` and `client_secret_env`) are configured **once** under `storage.api_credentials` in `reglaze.yaml`. The compiler automatically injects these credentials into both Windows synchronization scripts and the WSL2 `rclone.conf` configuration, ensuring uninterrupted wire-speed synchronization under your private project quota.

---

## 7. Pre-Flight Audit Tools (`src/audit/`)

Before wiping an existing installation, `reglaze` runs a non-destructive discovery sweep via `Invoke-Audit.ps1` to produce both `audit-reference.json` (for recovery and verification) and an initial `reglaze.yaml` draft:

* **BitLocker Recovery Keys (`Audit-BitLocker.ps1`)**: Queries all protected volumes using `Get-BitLockerVolume` to capture key protectors and numeric recovery passwords, ensuring auxiliary drives are not permanently locked out post-reinstall.
* **Licensing & Activation Checks (`Audit-Licensing.ps1`)**: Extracts the current Windows edition, licensing channel (OEM/Retail/Digital License), and partial or full product key details via WMI/SoftwareLicensingService.
* **Drive & Partition Identification (`Audit-Storage.ps1`)**: Identifies physical drive numbers, serial numbers, models, partition styles (GPT/MBR), partition GUIDs, volumes, and file systems to ensure `autounattend.xml` targets the exact OS drive without risking secondary data drives.
* **Comprehensive Application Discovery (`Audit-Apps.ps1`)**: Discovers installed software across both **WinGet** (`winget export`) and the Windows **Add/Remove Programs (ARP)** registry hives (64-bit, 32-bit WoW64, and per-user HKCU). Detects manual installers (InnoSetup, NSIS, MSI), de-duplicates against WinGet, and correlates findings against `data/applications/`.
* **Windows Preferences & System Settings (`audit-windows-settings.ps1`)**: Audits user and system settings (File Explorer folder options, Taskbar alignment and search mode, power schemes and sleep timeouts).
* **Directory Junctions & Reparse Points (`Audit-Junctions.ps1`)**: Scans `%USERPROFILE%`, `%APPDATA%`, and local application directories for existing reparse points (`fsutil reparsepoint query` / `Get-Item | ? LinkType`), cross-referencing findings against `data/applications/`.
* **Output Artifacts**:
  * `audit-reference.json`: Complete dump of hardware IDs, licensing metadata, BitLocker keys, disk partitions, WinGet packages, non-WinGet ARP software, and Windows system preferences.
  * `reglaze.yaml`: Scaffolded starter blueprint pre-populated with discovered system settings, packages, storage mappings, and suggested junction configurations ready for user editing.

---

## 8. Instructions for Testers

1. **Clone the Repo:** Clone `reglaze` to a secondary machine or run inside a test VM (Hyper-V or Proxmox).
2. **Execute Pre-Flight Audit (Optional on Existing PC):**
   ```powershell
   pwsh ./src/audit/Invoke-Audit.ps1 -OutputDir ./audit-output
   ```
   Inspect `audit-output/audit-reference.json` and review the scaffolded `reglaze.yaml`.
3. **Review & Edit `reglaze.yaml`:**
   * Review [examples/reglaze.yaml](examples/reglaze.yaml) and [examples/audit-reference.json](examples/audit-reference.json) for reference configurations.
   * Adjust target disk IDs and secondary preserved drives.
   * Configure `system.users` with your `LocalAdmin` credentials and primary standard Microsoft Account.
   * Verify declared applications against [data/applications.json](data/applications.json).
   * Ensure directories with `needs_mapping: true` have junction targets, or provide inline `overrides`.
   * Configure `wsl2` distro preferences and Google Drive OAuth API credentials under `storage.api_credentials`.
4. **Run the Compiler & Media Generator:**
   ```powershell
   pwsh ./src/compiler/Compile-Reglaze.ps1 -Config ./examples/reglaze.yaml -OutputDir ./dist
   pwsh ./src/media/New-InstallMedia.ps1 -ArtifactsDir ./dist -TargetDrive "E:"
   ```
5. **Inspect Generated Artifacts (`./dist`):**
   * Check `autounattend.xml` against the target disk setup, partition layout, and dual-user (`LocalAdmin` + standard user) provisioning.
   * Review `configuration.dsc.yaml` to ensure all package IDs resolve.
   * Review `bootstrap.ps1` for mount point checks, sync folder verifications, and junction arguments.
   * Review `setup-wsl.sh` and generated `rclone.conf` for WSL2 dev repo synchronization with injected Google Drive API credentials.
6. **Report Issues:** Submit feedback on catalog validations, broken WinGet packages, drive letter race conditions, BitLocker recovery, or API rate limit handling.