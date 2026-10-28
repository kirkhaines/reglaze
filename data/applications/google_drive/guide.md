# Google Drive for Desktop: Post-Install Configuration & Sync Migration Guide

Google Drive for Desktop provides both the **Tier 2 Virtual Cloud Streaming Mount** (`{{STREAM_MOUNT}}`) and **Tier 3 Local Synced Folders** (`storage.sync.directories`).

During Phase 4 (`bootstrap.ps1`), `reglaze` automatically installs `Google.GoogleDrive` via WinGet DSC and configures the Windows machine policy registry key (`HKLM:\SOFTWARE\Policies\Google\DriveFS\DefaultMountPoint = "{{STREAM_DRIVE_LETTER}}"`) so the virtual streaming drive mounts at **`{{STREAM_MOUNT}}`**.

---

## Step-by-Step Setup & Synced Folder Migration

### 1. Authenticate Google Drive for Desktop
- Sign in to Google Drive for Desktop when prompted using **`{{PRIMARY_EMAIL}}`**.
- Verify that **`{{STREAM_VERIFY_FOLDER}}`** is mounted and accessible in File Explorer.

### 2. Configure Local Synced Directories ("Folders from your computer")
Open **Google Drive Preferences** (click the Google Drive tray icon &rarr; Gear icon &rarr; **Preferences**) and under **Folders from your computer**, click **Add folder** and select **Sync with Google Drive** for each of the following pre-created local directories:

{{SYNC_DIRECTORIES_LIST}}

### 3. Populate Synced Directories from Previous Profile Computer (`{{SOURCE_COMPUTER_NAME}}`)
Because Google Drive associates synced computer folders with a specific OS installation instance under **Computers**, your previous installation for profile **`{{PROFILE_NAME}}`** appears under **`{{SOURCE_COMPUTER_NAME}}`**.

- **Migration Mode**: `{{MIGRATION_MODE}}` (default: `copy` — leaves the previous computer's folders intact as a backup snapshot).
- **Source Location**: `https://drive.google.com/drive/computers` (under **`{{SOURCE_COMPUTER_NAME}}`**) or locally via **`{{STREAM_MOUNT}}\Other computers\{{SOURCE_COMPUTER_NAME}}\<CloudFolder>`**.
- For each synced folder above, `{{MIGRATION_MODE}}` the contents from **`{{SOURCE_COMPUTER_NAME}}`** into the corresponding folder of **`{{TARGET_COMPUTER_NAME}}`** (or allow `reglaze hydrate` to copy them from `{{STREAM_MOUNT}}\Other computers\{{SOURCE_COMPUTER_NAME}}` once mounted) and wait for Google Drive to report **Up to date** before proceeding to directory junction creation.

