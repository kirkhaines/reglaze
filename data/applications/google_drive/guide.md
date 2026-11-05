# Google Drive for Desktop: Post-Install Configuration & Sync Migration Guide

Google Drive for Desktop provides both the **Tier 2 Virtual Cloud Streaming Mount** (`{{STREAM_MOUNT}}`) and **Tier 3 Local Synced Folders** (`storage.sync.directories`).

During Phase 4 (`bootstrap.ps1`), `reglaze` automatically installs `Google.GoogleDrive` via WinGet DSC and configures the Windows machine policy registry key (`HKLM:\SOFTWARE\Policies\Google\DriveFS\DefaultMountPoint = "{{STREAM_DRIVE_LETTER}}"`) so the virtual streaming drive mounts at **`{{STREAM_MOUNT}}`**.

---

## Step-by-Step Setup & Synced Folder Migration

### 1. Authenticate Google Drive & Onboarding Rules (What To Do vs. What Not To Do)
- Sign in to Google Drive for Desktop when prompted using **`{{PRIMARY_EMAIL}}`**.
- **DO NOT** select `Desktop`, `Documents`, or `Pictures` if Google Drive's initial setup wizard asks to back up or sync default Windows folders on this computer (uncheck all suggested folders and skip).
- **DO** configure **Google Drive (`My Drive` syncing options)** to **Stream files** (NOT *Mirror files*).
- Verify that **`{{STREAM_VERIFY_FOLDER}}`** is mounted and accessible in File Explorer.

### 2. Configure Local Synced Directories ("Folders from your computer")
- {{SYNC_SETUP_INSTRUCTION}}

{{SYNC_DIRECTORIES_LIST}}

### 3. Populate Synced Directories from Previous Profile Computer (`{{SOURCE_COMPUTER_NAME}}`)
- {{SYNC_MIGRATION_INSTRUCTION}}
- **Migration Mode**: `{{MIGRATION_MODE}}` (default: `copy` - leaves the previous computer's folders intact as a backup snapshot).
- **Source Location**: `https://drive.google.com/drive/computers` (under **`{{SOURCE_COMPUTER_NAME}}`**) or locally via **`{{STREAM_MOUNT}}\Other computers\{{SOURCE_COMPUTER_NAME}}\<CloudFolder>`**.

