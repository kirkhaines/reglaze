<#
.SYNOPSIS
    Storage provider and cloud sync discovery module for Reglaze.
.DESCRIPTION
    Discovers active cloud streaming mounts (e.g. Google Drive virtual E: drive),
    Google Drive for Desktop configured local sync roots, OneDrive mounts,
    and redirected Windows User Shell Folders (Documents, Downloads, Pictures).
#>
[CmdletBinding()]
param()

function Get-StorageProvidersAudit {
    [CmdletBinding()]
    param()

    # 1. Discover Cloud Streaming Mounts
    $StreamingInfo = [PSCustomObject]@{
        cloud_provider  = "google-drive"
        mount_point     = "G:"
        verify_folder   = "G:\My Drive"
        stream_variable = "STREAM"
        detected        = $false
    }

    $FsDrives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
    foreach ($Drive in $FsDrives) {
        $RootPath = "$($Drive.Name):\"
        $MyDrivePath = Join-Path $RootPath "My Drive"

        $IsGoogleDrive = ($Drive.Description -and $Drive.Description -like "*Google Drive*") -or (Test-Path $MyDrivePath)
        if ($IsGoogleDrive) {
            $StreamingInfo.cloud_provider  = "google-drive"
            $StreamingInfo.mount_point     = "$($Drive.Name):"
            $StreamingInfo.verify_folder   = $MyDrivePath
            $StreamingInfo.stream_variable = "STREAM"
            $StreamingInfo.detected        = $true
            break
        }
    }

    # 2. Discover Google Drive for Desktop Synced Folders
    $SyncedDirectories = @()
    $DriveFsDb = Join-Path $env:LOCALAPPDATA "Google\DriveFS\root_preference_sqlite.db"

    if (Test-Path $DriveFsDb) {
        try {
            $TempDb = Join-Path $env:TEMP "reglaze_drivefs_roots_$((Get-Random)).db"
            # Copy with FileShare ReadWrite to avoid locking collisions
            $FileStream = [System.IO.File]::Open($DriveFsDb, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $OutStream = [System.IO.File]::Create($TempDb)
            $FileStream.CopyTo($OutStream)
            $FileStream.Close()
            $OutStream.Close()

            if (Get-Command "python" -ErrorAction SilentlyContinue) {
                $PyScript = Join-Path $env:TEMP "reglaze_query_roots_$((Get-Random)).py"
                $PyCode = @'
import sqlite3, json, sys
temp_db = sys.argv[1]
conn = sqlite3.connect(temp_db)
cols = [c[1] for c in conn.execute("PRAGMA table_info(roots);").fetchall()]
has_doc_id = 'doc_id' in cols
has_media_id = 'media_id' in cols
query_cols = ['title', 'root_path', 'last_seen_absolute_path']
if has_doc_id:
    query_cols.append('doc_id')
if has_media_id:
    query_cols.append('media_id')
cursor = conn.execute(f"SELECT {', '.join(query_cols)} FROM roots WHERE state = 2;")
rows = []
for r in cursor.fetchall():
    item = {'title': r[0], 'root_path': r[1], 'absolute_path': r[2], 'doc_id': None, 'media_id': None}
    idx = 3
    if has_doc_id:
        item['doc_id'] = r[idx]
        idx += 1
    if has_media_id:
        item['media_id'] = r[idx]
    rows.append(item)
conn.close()
print(json.dumps(rows))
'@
                $PyCode | Set-Content -Path $PyScript -Encoding UTF8
                $JsonResult = & python $PyScript $TempDb 2>$null
                Remove-Item $PyScript -Force -ErrorAction SilentlyContinue

                if ($JsonResult) {
                    $Roots = $JsonResult | ConvertFrom-Json
                    foreach ($Root in $Roots) {
                        $CleanId = ($Root.title -replace "[^a-zA-Z0-9_]", "_").ToLower()
                        $VarName = "SYNC_" + ($CleanId.ToUpper())
                        $SyncedDirectories += [PSCustomObject]@{
                            id            = $CleanId
                            title         = $Root.title
                            local_path    = $Root.absolute_path
                            cloud_folder  = $Root.title
                            verify_folder = $Root.absolute_path
                            sync_variable = $VarName
                            cloud_doc_id  = $Root.doc_id
                            media_id      = $Root.media_id
                        }
                    }
                }
            }

            if (Test-Path $TempDb) { Remove-Item $TempDb -Force }
        } catch {
            Write-Warning "Could not parse Google Drive sync roots: $($_.Exception.Message)"
        }
    }

    # 3. Discover Windows User Shell Folders (Folder Redirections)
    $ShellFolders = [PSCustomObject]@{
        documents = $null
        downloads = $null
        pictures  = $null
        music     = $null
        videos    = $null
    }

    try {
        $RegShell = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction SilentlyContinue
        if ($RegShell) {
            $ShellFolders.documents = $RegShell.Personal
            $ShellFolders.downloads = $RegShell.'{374DE290-123F-4565-9164-39C4925E467B}'
            $ShellFolders.pictures  = $RegShell.'My Pictures'
            $ShellFolders.music     = $RegShell.'My Music'
            $ShellFolders.videos    = $RegShell.'My Video'
        }
    } catch {}

    return [PSCustomObject]@{
        streaming          = $StreamingInfo
        sync_directories   = $SyncedDirectories
        user_shell_folders = $ShellFolders
    }
}
