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
                                    [ Phase 1: User Blueprint Review & Data Staging ]
                                    │ (Customize reglaze.yaml, validate mappings, and run
                                    │  migration-plan / migrate to stage non-junctioned data)
                                    ▼
                                    [ Phase 2: Media & Artifact Generation ]
                                    │ (reglaze compile / reglaze media)
                ┌───────────────────┼───────────────────┐
                ▼                   ▼                   ▼
        autounattend.xml   configuration.dsc.yaml   bootstrap.ps1 + hydrate.ps1
        (Hands-free WinPE)  (Machine WinGet Apps)   (& modular *-helpers.ps1)
                │                   │                   │
                └───────────────────┴───────────────────┘
                                    ▼
                         [ Bootable Install Media ]
                                    ▼
                       [ Phase 3: Unattended Install ]
                        (Provisions LocalAdmin & Non-Admin User)
                                    ▼
                    [ Phase 4: Machine-Scope Provisioning ]
                     (LocalAdmin: Drive Letters, BitLocker,
                      Drivers, Machine Apps & Machine Settings)
                                    ▼
                      [ Phase 5: User-Scope Hydration ]
                        (Standard User: Desktop Theme, Browser +
                         Password Manager Auth Bootstrap, Cloud Mount,
                         Steam, Manual Apps, Junctions & WSL2)
                                    ▼
                            [ Fully Restored ]

```

### The 6 Execution Phases

| Phase | Component | Responsibility |
| :--- | :--- | :--- |
| **0. Pre-Flight Audit** | `Invoke-Audit.ps1` | Scans your existing PC prior to wiping (requires `-Profile <name>` when no existing `reglaze.yaml` is present). Extracts BitLocker recovery keys, Windows activation/license info, physical disk and partition GUIDs/IDs, active directory junctions, installed WinGet packages, non-WinGet ARP software, Steam libraries, and Windows preferences. Records the computer-to-profile mapping in `profile-computers.json`, correlates detected software against `data/applications.json`, and emits `audit-reference.json` alongside an initial, scaffolded `reglaze.yaml`. |
| **1. Blueprint Review & Validation** | Config Editor & `Test-ReglazeSchema.ps1` | You inspect and edit `reglaze.yaml` against `audit-reference.json`. The `reglaze` compiler validates declared applications against `data/applications.json` (and any personal `<ConfigDir>/applications.json`): any directory marked `needs_mapping: true` must be mapped to its recommended target type (`streaming` vs `sync`), or you must provide an explicit `override` with a rationale. Uncataloged apps and custom folders are declared under `custom:`. |
| **1b. Pre-Install Data Staging (`migration-plan` & `migrate`)** | `Invoke-PreInstallMigration.ps1` | For existing Windows installs that do not yet use directory junctions, `reglaze migration-plan` inspects your edited `reglaze.yaml` and `audit-reference.json` to emit a draft `migration-manifest.yaml` with measured byte sizes and file counts. After you review/edit the manifest to disable or remove any unneeded directories, `reglaze migrate` creates all target sync/streaming/data directories and transfers files using multi-threaded `robocopy.exe` (`/MT:2 /E /XO`) so your persistent targets are ready before wiping the OS. |
| **2. Media Generation** | `Compile-Reglaze.ps1` & `Build-Media.ps1` | Compiles `reglaze.yaml` into deployment artifacts (`autounattend.xml`, `configuration.dsc.yaml`, `bootstrap.ps1`, `bootstrap-helpers.ps1`, `hydrate.ps1`, `hydrate-helpers.ps1`, `setup-wsl.sh`) and packages them onto a bootable UEFI installation USB drive with required drivers and offline bootstrap packages. |
| **3. Unattended Install** | `autounattend.xml` | Boots from USB media, identifies the target OS disk via multi-factor hardware attributes (Serial Number, Bus Type, Model) to protect secondary drives, partitions and applies the Windows image, provisions the dedicated `LocalAdmin` account with temporary setup auto-logon, and creates your primary standard user account (`local_to_msa`). |
| **4. Machine-Scope Provisioning (`LocalAdmin`)** | `bootstrap.ps1` & `bootstrap-helpers.ps1` | Auto-logs into `LocalAdmin`. Reconciles preserved drive letters via a 3-phase atomic swap, halts with a safe power-down checkpoint (`Stop-Computer`) if required preserved disks were physically disconnected during install so you can reconnect them, unlocks preserved BitLocker volumes by hardware identity (`SerialNumber` + `PartitionGuid`), installs WHQL storage/display/network drivers and updates, applies **machine-scoped** Windows settings (`HKLM:` policies, power plan, network profile, camera privacy), installs **machine-wide** WinGet packages (recording any user-installer packages to `deferred-user-packages.json`), pre-stages WSL2 kernel features (`wsl --install --no-distribution`) and the `Reglaze Hydration` desktop launcher, and purges auto-logon credentials before rebooting. |
| **5. User-Scope Hydration (`primary_user`)** | `hydrate.ps1` & `hydrate-helpers.ps1` | You sign into your primary standard user account and launch **Reglaze Hydration** from the desktop shortcut. Applies **user-scoped** `HKCU:` Windows preferences (Dark Mode, Taskbar, Explorer, Input, Audio/Display), guides you through the **Foundational Browser & Password Manager Authentication Bootstrap**, relocates Windows shell folders (`Documents`, `Pictures`, `Desktop`) to `%DATA_DRIVE%`, installs user-scoped WinGet packages, mounts Google Drive and restores staged local sync folders, connects Steam to existing `%DATA_DRIVE%` libraries, walks through any manual app installers, creates `%USERPROFILE%` directory junctions (and re-applies any cloud-hosted wallpaper), and provisions your WSL2 Linux distribution (`setup-wsl.sh`), `rclone bisync`, and `dev_repos`. |

### Execution Scope & Step Dependency Model

A core design rule in `reglaze` is the strict separation between **Phase 4 (Machine Scope under `LocalAdmin`)** and **Phase 5 (User Scope under `primary_user`)**, paired with deterministic step ordering inside each script:

1. **Why User Actions Must Wait Until Phase 5 (`hydrate.ps1`)**:
   * **Per-User Registry Isolation (`HKCU:`)**: During Phase 4, Windows runs under the temporary `LocalAdmin` session. Writing Explorer, Taskbar, Theme, Input, or User `PATH` settings to `HKCU:` during Phase 4 only modifies `LocalAdmin`'s disposable hive.
   * **Preventing `.000` User Profile Collisions**: If Phase 4 pre-creates any folder or junction inside `C:\Users\<PrimaryUser>` before that user signs into Windows interactively for the first time, the Windows User Profile Service (`ProfSvc`) treats the existing directory as a collision and creates a suffixed profile directory (`C:\Users\<PrimaryUser>.000`) on first login.
   * **User-Scoped Installers & WSL Distros**: Per-user installers (`%LOCALAPPDATA%\Programs`) and WSL2 Linux distributions (`HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss`) register exclusively under the active user context. Phase 4 installs only machine-wide WSL kernel features (`wsl --install --no-distribution`) and automatically defers any WinGet package that rejects `--scope machine` (`-1978335216`) or admin context (`-1978335146`) to Phase 5 via `deferred-user-packages.json`.
2. **Highlighted Step: Browser & Password Manager Foundational Authentication Bootstrap**:
   * Setting up your primary browser (e.g., Chrome) and password manager extension (e.g., Bitwarden) is **not treated like an ordinary application install**.
   * While the browser binary is installed machine-wide in Phase 4, **Step 2 of `hydrate.ps1` (`Invoke-BrowserAuthBootstrap`)** runs immediately after basic desktop personalization and *before* Google Drive, Steam, or manual software setups.
   * It registers your browser as the default handler, prompts you to sign into your browser profile and unlock your password manager extension, and opens `chrome://history/syncedTabs` so your credentials, passkeys, and active sessions are ready in a single click for every subsequent OAuth flow (Google Drive sign-in, Steam Guard, and manual app downloads).
3. **Strict Intra-Phase Ordering**:
   * Every step in `bootstrap.ps1`, `bootstrap-helpers.ps1`, `hydrate.ps1`, and `hydrate-helpers.ps1` includes inline `[DEPENDENCY & ORDERING]` comments explaining why it runs where it does (for example: preserved drive letters and BitLocker auto-unlock must complete before `%DATA_DRIVE%` junctions or Steam libraries are accessed; Google Drive must mount `%STREAM%` and user apps must finish installing before `Invoke-UserJunctionsAndPins` replaces empty default `%APPDATA%` folders with junctions).
   * See [Section 5.1 of `docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#51-cross-phase--intra-phase-dependency-architecture) for the complete dependency flowcharts and step-by-step precondition/postcondition tables.

---

## 3. Project Structure

```text
reglaze/
├── bin/
│   └── reglaze.ps1                      # Main CLI entry point (audit, validate, migration-plan, migrate, compile, media, test)
├── data/
│   ├── applications/                    # Modular application catalog (one directory per app_id)
│   │   ├── _schema.json                 # Formal schema for individual app manifests
│   │   ├── _template/                   # Starter template (app.json, guide.md, post-install.ps1)
│   │   ├── adobe_lightroom/             # app.json
│   │   ├── outfox/                      # app.json, guide.md, post-install.ps1
│   │   ├── vscode/                      # app.json, post-install.ps1
│   │   └── ... (beat_saber, steam, lotro, git, etc.)
│   ├── windows/                         # Modular Windows settings scripts (explicit Phase 4 Machine vs. Phase 5 User scope)
│   │   ├── explorer-folder-options.ps1  # [Phase 5 User] Hidden files, extensions, launch to This PC, SharingWizardOn, UserShellFolders
│   │   ├── taskbar-system-tray.ps1      # [Phase 5 User] Taskbar alignment, search mode, widgets, tray icons
│   │   ├── performance-power.ps1        # [Phase 4 Machine & Phase 5 User] Power scheme, LongPaths, ssh-agent, ClipboardHistory, DefaultTerminal
│   │   ├── theme-personalization.ps1    # [Phase 5 User] Dark/Light mode, accent color, desktop wallpaper
│   │   ├── input-mouse-keyboard.ps1     # [Phase 5 User] Mouse acceleration, NumLock, accessibility hotkeys
│   │   ├── audio-display.ps1            # [Phase 4 Machine & Phase 5 User] Camera PnP, HAGS, CoreAudio endpoints, Game Mode, display layout
│   │   ├── network-firewall.ps1         # [Phase 4 Machine] Active network profile category (Private/Public)
│   │   ├── shell-pins.ps1               # [Phase 4 Machine & Phase 5 User] Start layout policy, Quick Access pins, User PATH, Steam libraries
│   │   └── audit-windows-settings.ps1   # [Phase 0 Audit] Captures existing system & user settings
│   └── applications.json                # Merged/cached application catalog index
├── docs/
│   └── ARCHITECTURE.md                  # Comprehensive system architecture, security model & dependency matrices
├── schemas/
│   └── reglaze.schema.json              # JSON Schema validating reglaze.yaml
├── src/
│   ├── audit/                           # Phase 0 Pre-wipe discovery scripts
│   │   ├── Audit-Hardware.ps1           # Physical disks, serial numbers, partition GUIDs & hardware
│   │   ├── Audit-Licensing.ps1          # Windows edition, digital license, product keys & user identity
│   │   ├── Audit-BitLocker.ps1          # Extracts BitLocker protectors & recovery passwords
│   │   ├── Audit-Apps.ps1               # Discovers WinGet packages, ARP software & Steam libraries
│   │   ├── Audit-Junctions.ps1          # Discovers existing NTFS directory junctions & reparse points
│   │   ├── Audit-StorageProviders.ps1   # Discovers cloud streaming mounts & local sync roots
│   │   ├── Audit-Network.ps1            # Discovers network adapters, sharing mode & firewall rules
│   │   ├── Audit-Wsl.ps1                # Discovers WSL2 distributions & installed packages
│   │   ├── Invoke-AdminAudit.ps1        # Elevated helper for BitLocker & hardware queries
│   │   └── Invoke-Audit.ps1             # Phase 0 Audit CLI orchestrator
│   ├── common/                          # Shared subsystems & parsers
│   │   ├── Catalog.ps1                  # Merges data/applications/ with optional user applications.json
│   │   ├── ConfigResolver.ps1           # Resolves configuration paths & profile registries
│   │   ├── GameLibraries.ps1            # Multi-library game discovery & fresh install engine
│   │   ├── Logging.ps1                  # Structured console & transcript logging
│   │   └── YamlParser.ps1               # Dependency-free PowerShell YAML parser
│   ├── compiler/                        # Phase 1 & 2 Compiler & modular script generators
│   │   ├── Test-ReglazeValidation.ps1   # Schema & storage tier safety validator
│   │   ├── Resolve-Variables.ps1        # Resolves %STREAM%, %SYNC_<ID>%, %OS_DRIVE%, %DATA_DRIVE%
│   │   ├── Build-Autounattend.ps1       # Generates hardware-targeted autounattend.xml
│   │   ├── Build-WinGetDSC.ps1          # Generates configuration.dsc.yaml
│   │   ├── Build-Payload.ps1            # Orchestrates USB deployment bundle & offline bootstrap caches
│   │   ├── Build-BootstrapScript.ps1    # Generates Phase 4 bootstrap.ps1 & bootstrap-helpers.ps1
│   │   ├── Build-HydrateScript.ps1      # Generates Phase 5 hydrate.ps1, hydrate-helpers.ps1 & setup-wsl.sh
│   │   ├── DiskMatch.ps1 / .vbs         # WinPE dynamic target disk verification & protection
│   │   └── Compile-Reglaze.ps1          # Phase 2 Compiler CLI orchestrator
│   ├── linking/                         # NTFS Directory Junction, Drive Letter & Migration engine
│   │   ├── Invoke-PreInstallMigration.ps1 # Phase 1b migration-manifest.yaml planner & robocopy stager
│   │   ├── Set-ReglazeDriveLetters.ps1  # 3-phase atomic preserved drive letter reconciliation
│   │   ├── Unlock-BitLockerVolumes.ps1  # Hardware-matched BitLocker unlock & auto-unlock binding
│   │   ├── New-DirectoryJunction.ps1    # Idempotent NTFS junction creator
│   │   ├── Test-ReparsePoint.ps1        # Reparse point target verifier
│   │   └── Backup-CollisionFolder.ps1   # Non-destructive collision backup helper
│   ├── media/                           # Phase 2.5 Bootable USB media creation
│   │   ├── Get-WindowsIso.ps1           # Official Windows ISO discovery & BITS download helper
│   │   └── Build-Media.ps1              # Native UEFI FAT32 USB builder with DISM split-wim & -UpdateOnly refresh
│   ├── runner/                          # Phase 4 & 5 runtime orchestration scripts
│   │   ├── Apply-WindowsSettings.ps1    # Phase-aware Windows settings dispatcher (-Phase Phase4 | Phase5 | All)
│   │   ├── Start-MachineBootstrap.ps1   # Phase 4 Machine Bootstrap runner
│   │   └── Start-UserHydration.ps1      # Phase 5 User Hydration runner
│   └── wsl/                             # WSL2 Linux integration
│       ├── Initialize-WSLDistro.ps1
│       └── Sync-WSLRclone.ps1
├── examples/
│   ├── audit-reference.json             # Reference output from pre-flight audit
│   └── reglaze.yaml                     # Complete reference workstation specification
├── reglaze.yaml                         # Your personal system blueprint (git-ignored)
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

* **Identity & Discoverability:** Captures the unique `app_id` (e.g., `beat_saber`, `outfox`, `satisfactory`, `neva`, `bloodstained`, `lotro`, `steam`, `adobe_lightroom`, `vscode`, `git`, `docker_desktop`), `name`, official `website`, and installation metadata (`method`, WinGet Package ID `winget_id`, Steam App ID `steam_id`).
* **Generic Installation Guidance:** For applications requiring human intervention (such as `outfox`), `data/applications/` houses machine-independent installation metadata (`method: "manual"`, `download_url`, `default_target_directory`, and step-by-step instructions). User blueprints only specify machine-specific parameters (`version`, custom path, `post_install_script`).
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
7. **Unrecognized / Custom Applications (`applications.custom`):** During `reglaze audit`, any installed WinGet packages, Steam games, Add/Remove Programs (ARP) registry entries, or existing NTFS directory junctions that do not match a catalog entry are automatically populated under `applications.custom:` in `reglaze.yaml`. You can either configure `link`, `target`, and `storage_type` directly under `applications.custom:`, or promote those applications into reusable catalog definitions via a personal `applications.json` file (see below).

### User-Extensible Application Catalog (`<output-dir>/applications.json`) & LLM Prompt

To add application definitions that are **reusable across audits** without modifying the `reglaze` source repository—and without baking directory schemas solely into `reglaze.yaml` where re-running `reglaze audit` could overwrite them—you can place a personal **`applications.json`** file in your Reglaze configuration/output directory alongside `reglaze.yaml` and `audit-reference.json`:

* **Automatic Discovery & Override Precedence:** `reglaze audit`, `reglaze validate`, and `reglaze compile` automatically load `<output-dir>/applications.json` and merge it with the built-in catalog (`data/applications/`). Any `app_id` in your personal `applications.json` either adds a new catalog application or overrides the built-in entry with the same `app_id`.
* **Automatic Promotion out of `custom:`:** After placing your `applications.json` in the output directory (or appending new entries to it), simply run `reglaze audit` again. Applications that were previously listed under `applications.custom:` will automatically match your `applications.json`, move into the main `applications:` section, and have their `directories:` pre-populated with recommended junction targets.

#### Generating Your `applications.json` with a Standard Chat LLM

You can attach your **`audit-reference.json`** and **`reglaze.yaml`** (plus your existing **`applications.json`**, if updating one) to any chat LLM (ChatGPT, Claude, Gemini) with the following prompt:

````markdown
I am configuring a declarative Windows workstation blueprint using `reglaze`.
Attached are my machine's `audit-reference.json` and `reglaze.yaml` (and optionally my existing `applications.json`).

Please inspect the unrecognized applications listed under `applications.custom` in `reglaze.yaml` (cross-referencing `installed_winget_packages`, `detected_non_winget_applications`, `detected_game_libraries`, and `detected_directory_junctions` in `audit-reference.json`) and generate a complete `applications.json` file for my Reglaze configuration directory.

### Requirements for `applications.json`

1. **Top-Level Format:** Output a valid JSON array of application objects (`[ { ... }, ... ]`). If I attached an existing `applications.json`, preserve its existing entries and merge the new ones.
2. **Matching Identifiers (Critical for `reglaze audit` auto-correlation):**
   - `app_id`: snake_case identifier (e.g., `"obs_studio"`, `"baldur_gate_3"`).
   - `name`: Must match the application's `name` / `display_name` from `reglaze.yaml` / `audit-reference.json` so `reglaze audit` automatically correlates it.
   - `website`: Official homepage URL.
   - `install`:
     - If installed via WinGet: `"method": "winget"`, `"winget_id": "<exact WinGet id>"` (from `applications.custom` or `installed_winget_packages`).
     - If installed via Steam: `"method": "steam"`, `"steam_id": <integer Steam App ID>`.
     - If installed manually (non-WinGet ARP software): `"method": "manual"`, `"download_url": "<official download page>"`, `"default_target_directory": "<install path using %PROGRAMFILES%, %LOCALAPPDATA%, %GAMES_DIR%, etc.>"`, and step-by-step `"instructions": [ "..." ]`.
     - Set unused fields (`winget_id`, `steam_id`, `download_url`, `default_target_directory`, `guide_file`, `post_install_script`) to `null`, and `instructions` to `[]` when not needed.
3. **Directory Mappings & Storage Tier Safety Rules (`directories`):**
   - For each application, research where it stores persistent user state on Windows (settings/configs, user profiles, plugins/extensions, save games, custom songs/mods, or database catalogs).
   - Use Reglaze path placeholders in `default_path`: `%APPDATA%`, `%LOCALAPPDATA%`, `%USERPROFILE%\\AppData\\LocalLow`, `%USERPROFILE%\\Documents`, `%USERPROFILE%\\Saved Games`, `%PROGRAMDATA%`, `%PROGRAMFILES%`, `%PROGRAMFILES(X86)%`, `%GAMES_DIR%`, `%STEAM_DIR%`.
   - Each directory object MUST include:
     - `"id"`: snake_case folder identifier (e.g., `"user_settings"`, `"game_saves"`, `"catalog"`).
     - `"description"`: Brief explanation of what is stored here.
     - `"default_path"`: Default Windows path using `%VAR%` placeholders.
     - `"category"`: One of `"configs"`, `"saves"`, `"songs"`, `"catalog"`, `"library"`.
     - `"needs_mapping"`: `true` if wiping `C:` would lose important user state; `false` if ephemeral or purely cloud-hosted.
     - `"safe_for_stream"`:
       - `false` if the directory contains SQLite databases, LevelDB/RocksDB stores, high-I/O caches, or lock-sensitive files that corrupt on virtual cloud streaming drives (such as Google Drive `G:` / `E:`).
       - `true` if the directory contains flat config files (JSON, INI, XML, YAML), discrete save files, or static assets safe for virtual cloud streaming.
     - `"recommended_storage"`:
       - `"streaming"` when `safe_for_stream` is `true`.
       - `"sync"` when `safe_for_stream` is `false` (requires a local NTFS folder backed by two-way cloud sync).
       - `"local_preserved"` for large bulk data, media caches, or game assets that belong on `%DATA_DRIVE%`.
     - `"notes"`: Short rationale for the storage recommendation (especially file-locking or SQLite behavior).
   - If an application is a stateless CLI tool, runtime, or hardware driver utility that needs no directory junctions, include the application with `"directories": []` so `reglaze audit` recognizes it and moves it out of `applications.custom`.
   - **Skip or Ignore Windows 11 Inbox / Pre-Installed Apps:** Do NOT generate install entries for built-in or pre-installed Windows 11 apps and system components (such as `Microsoft Teams` / `Microsoft.Teams`, `Outlook for Windows` / `Microsoft.Outlook`, `Windows Terminal` / `Microsoft.WindowsTerminal`, `Copilot` / `Microsoft.365Copilot`, `Microsoft Edge`, `OneDrive`, `Power Automate`, or `Dev Home`), or mark them with `"ignore": true` if present in `applications.custom`.
   - If an entry in `applications.custom` is an unwanted OEM utility, redistributable, or subcomponent that should be completely ignored by `reglaze`, include `"ignore": true` on its object.
4. **Optional Per-Application User `PATH` Additions (`path_entries`):**
   - Most installers register their own `PATH` entries automatically. However, if a manual or portable application requires a directory added to the user `PATH`, include `"path_entries": [ "%PROGRAMFILES%\\Vendor\\Tool\\bin" ]` on the application object.

### Example Schema Entry
```json
[
  {
    "app_id": "example_app",
    "name": "Example Application",
    "website": "https://example.com",
    "install": {
      "method": "winget",
      "winget_id": "Vendor.ExampleApp",
      "steam_id": null,
      "download_url": null,
      "default_target_directory": null,
      "guide_file": null,
      "post_install_script": null,
      "instructions": []
    },
    "directories": [
      {
        "id": "app_config",
        "description": "User preferences and plugin configurations",
        "default_path": "%APPDATA%\\ExampleApp",
        "category": "configs",
        "needs_mapping": true,
        "safe_for_stream": true,
        "recommended_storage": "streaming",
        "notes": "Flat JSON/INI configuration files; safe for virtual cloud streaming."
      }
    ]
  }
]
```
````

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

* **BitLocker Recovery Keys (`Audit-BitLocker.ps1`)**: Queries all protected volumes using `Get-BitLockerVolume` to capture key protectors and numeric recovery passwords, ensuring auxiliary drives are automatically unlocked and never locked out post-reinstall.
* **Drive, Partition & Hardware Identification (`Audit-Hardware.ps1`)**: Identifies physical drive numbers, serial numbers, models, partition styles (GPT/MBR), partition GUIDs, volumes, and file systems to ensure `autounattend.xml` targets the exact OS drive without risking secondary data drives.
* **Licensing, Activation & User Identity (`Audit-Licensing.ps1`)**: Extracts the current Windows edition, licensing channel (OEM/Retail/Digital License), partial/full product key details, and current primary user identity.
* **Comprehensive Application Discovery (`Audit-Apps.ps1`)**: Discovers installed software across **WinGet** (`winget list`), the Windows **Add/Remove Programs (ARP)** registry hives (64-bit, 32-bit WoW64, and per-user `HKCU:`), and **Steam** game libraries (`libraryfolders.vdf` and `appmanifest_*.acf`), correlating findings against `data/applications/`.
* **Windows Preferences & System Settings (`audit-windows-settings.ps1`)**: Audits user and system settings (File Explorer folder options, user shell folder locations, Taskbar alignment/search/tray icons, power schemes and sleep timeouts, Dark/Light theme, mouse/keyboard preferences, audio/display topology, and network profile category).
* **Directory Junctions & Reparse Points (`Audit-Junctions.ps1`)**: Scans `%USERPROFILE%`, `%APPDATA%`, and local application directories for existing reparse points (`fsutil reparsepoint query` / `Get-Item | ? LinkType`), cross-referencing findings against `data/applications/`.
* **Cloud Storage, Network & WSL Discovery (`Audit-StorageProviders.ps1`, `Audit-Network.ps1`, `Audit-Wsl.ps1`)**: Captures Google Drive streaming mount letters and sync roots, network adapter profiles, and installed WSL2 distributions.
* **Output Artifacts (`Invoke-Audit.ps1`)**:
  * `audit-reference.json`: Complete dump of hardware IDs, licensing metadata, BitLocker keys, disk partitions, WinGet packages, non-WinGet ARP software, and Windows system preferences.
  * `reglaze.yaml`: Scaffolded starter blueprint pre-populated with discovered system settings, packages, storage mappings, and suggested junction configurations ready for editing.

---

## 8. Getting Started & Step-by-Step Usage Guide

### Step 1: Clone `reglaze` & Set Required Environment Variables
Clone this repository on the Windows PC you want to audit and re-image (or on any machine where you manage your workstation blueprints) and set the local administrator password variable used when compiling deployment media:

```powershell
git clone https://github.com/your-org/reglaze.git
cd reglaze

# Set the password for the dedicated LocalAdmin account (used for UAC elevation and Phase 4 setup)
$env:LOCAL_ADMIN_PASSWORD = "YourStrongLocalAdminPassword!"

# Optional: If using WSL2 rclone sync with your own Google Cloud OAuth 2.0 API project
$env:GDRIVE_CLIENT_ID = "your-client-id.apps.googleusercontent.com"
$env:GDRIVE_CLIENT_SECRET = "your-client-secret"
```

### Step 2: Run the Pre-Flight Audit on Your Existing PC
Scan your current Windows installation to capture hardware identifiers, disk serial numbers, BitLocker recovery keys, installed applications, and Windows preferences:

```powershell
pwsh ./bin/reglaze.ps1 audit -Profile workstation -ConfigDir ./my-workstation
```
This creates `./my-workstation/audit-reference.json`, `./my-workstation/profile-computers.json`, and a pre-populated `./my-workstation/reglaze.yaml`.

### Step 3: Customize & Validate `reglaze.yaml`
Open `./my-workstation/reglaze.yaml` and tailor it to your desired setup (refer to [examples/reglaze.yaml](examples/reglaze.yaml) for a full example):
* **Disks**: Confirm `disks.target_os_disk` points to your OS boot drive and `disks.preserved_disks` lists all secondary data drives (`%DATA_DRIVE%`, etc.) that must remain untouched.
* **Users**: Verify `system.users.local_admin` and `system.users.primary_user` (your daily standard non-admin user account).
* **Storage**: Configure your cloud streaming mount (`storage.streaming`, e.g., Google Drive `E:` or `G:`) and local two-way sync folders (`storage.sync`).
* **Applications & Directory Mappings**: Review the `applications:` block (and optionally generate a personal `./my-workstation/applications.json` using the LLM prompt in Section 5 to promote custom apps). Validate your blueprint at any time with:
  ```powershell
  pwsh ./bin/reglaze.ps1 validate -ConfigDir ./my-workstation
  ```

### Step 4: Stage Existing User Data Before Wiping (`migration-plan` & `migrate`)
If your current PC has application settings, saves, or catalogs on `C:` that are not yet backed by junctions on your cloud drive or preserved data drive, stage them before wiping:

```powershell
# 1. Generate a draft migration manifest with measured folder sizes and file counts
pwsh ./bin/reglaze.ps1 migration-plan -ConfigDir ./my-workstation

# 2. Review ./my-workstation/migration-manifest.yaml (set enabled: false on anything you want to skip)

# 3. Copy enabled folders to their target streaming, sync, and preserved data locations via robocopy
pwsh ./bin/reglaze.ps1 migrate -ConfigDir ./my-workstation
```

### Step 5: Compile Blueprint & Create Bootable USB Media
Compile your blueprint into deployment artifacts (`autounattend.xml`, `configuration.dsc.yaml`, `bootstrap.ps1`, `bootstrap-helpers.ps1`, `hydrate.ps1`, `hydrate-helpers.ps1`, `setup-wsl.sh`) and write them to a USB flash drive:

```powershell
# Compile blueprint into ./dist and build a full UEFI bootable Windows 11 USB installer on drive E:
# (Automatically downloads or locates the official Windows 11 ISO, formats FAT32, splits install.wim, and injects payload)
pwsh ./bin/reglaze.ps1 compile -ConfigDir ./my-workstation -DistDir ./dist -UsbDrive "E:"

# Tip: Updating an existing Reglaze USB drive in seconds
# If your USB drive already has the base Windows installer files and you only edited reglaze.yaml or scripts,
# pass -RetainWindowsFiles (or use 'media -UpdateOnly') to refresh autounattend.xml and \Reglaze without re-copying the ISO:
pwsh ./bin/reglaze.ps1 compile -ConfigDir ./my-workstation -DistDir ./dist -UsbDrive "E:" -RetainWindowsFiles
```

### Step 6: Boot from USB (Phase 3 Unattended Install & Phase 4 Machine Bootstrap)
1. Boot your PC from the USB flash drive.
2. **Phase 3 (Unattended Windows Setup)** automatically verifies the target OS disk by hardware attributes (`SerialNumber`, `BusType`, `Model`), wipes and partitions only the OS disk, installs Windows, creates `LocalAdmin` and your primary user account, and logs into `LocalAdmin`.
3. **Phase 4 (`C:\Reglaze\payload\bootstrap.ps1`)** starts automatically in the `LocalAdmin` session:
   * Reconciles preserved drive letters (`D:`, etc.) and unlocks preserved BitLocker volumes using your audited recovery keys.
   * Installs WHQL storage, display, and network drivers plus Windows Updates.
   * Applies **machine-scoped** Windows settings (`HKLM:` policies, power scheme, network profile, camera privacy).
   * Installs **machine-scoped** WinGet applications (automatically deferring any user-only installers to Phase 5) and machine-wide WSL2 kernel features.
   * Stages the **Reglaze Hydration** shortcut on the desktop, clears `LocalAdmin` auto-logon, and reboots to the Windows sign-in screen.

### Step 7: Sign In & Run User Hydration (Phase 5)
1. Sign into Windows using your **primary standard user account** (`primary_user`).
2. Double-click the **Reglaze Hydration** shortcut on your desktop (which launches `C:\Reglaze\payload\hydrate.ps1` and `hydrate-helpers.ps1`):
   * **Step 1 — User Personalization**: Applies your `HKCU:` desktop preferences immediately (Dark Mode, Taskbar layout, File Explorer options, mouse/keyboard settings, audio/display configuration).
   * **Step 2 — Foundational Browser & Password Manager Authentication Bootstrap**: Sets your primary browser (e.g., Chrome) as the default browser, launches it so you can sign into your browser profile and unlock your password manager extension (e.g., Bitwarden), and opens `chrome://history/syncedTabs`. Completing this first makes every subsequent login effortless.
   * **Step 3 & 4 — Shell Folders & User-Scope Apps**: Redirects Windows shell folders (`Documents`, `Pictures`, `Desktop`) to `%DATA_DRIVE%` and installs user-scoped WinGet packages without UAC prompts.
   * **Step 5 & 6 — Google Drive Mount & Steam Discovery**: Guides you through signing into Google Drive (verifying your `%STREAM%` mount and restoring staged local sync folders) and signing into Steam (automatically reconnecting existing `%DATA_DRIVE%` Steam libraries).
   * **Step 7 & 8 — Manual Apps & Directory Junctions**: Walks through any manual software installers, links all `%USERPROFILE%` / `%APPDATA%` directory junctions to `%STREAM%`, `%SYNC_<ID>%`, and `%DATA_DRIVE%`, and re-applies your desktop wallpaper if hosted on a cloud drive.
   * **Step 9 — WSL2 & Developer Repos**: Installs your WSL2 Linux distribution under your user account, runs `setup-wsl.sh`, and configures `rclone bisync` and `dev_repos`.
3. If you ever close the terminal or reboot mid-hydration, simply double-click **Reglaze Hydration** on the desktop to resume safely from where you left off.
