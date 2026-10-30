<#
.SYNOPSIS
    Storage provider and cloud sync discovery module for Reglaze.
.DESCRIPTION
    Discovers active cloud streaming mounts (e.g. Google Drive virtual E:/G: drive),
    excludes physical disk partitions to prevent false positives when a backup drive
    contains a 'My Drive' folder, selects a conflict-free default drive letter (G: if free,
    otherwise the first available letter), discovers Google Drive for Desktop local sync roots,
    and captures redirected Windows User Shell Folders (Desktop, Documents, Downloads, Pictures, Music, Videos).
#>
[CmdletBinding()]
param()

function Resolve-ConflictFreeStreamingMountLetter {
    [CmdletBinding()]
    param(
        [string[]]$OccupiedLetters = @(),
        [string]$PreferredLetter = "G:"
    )

    $OccupiedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    [void]$OccupiedSet.Add("C")
    foreach ($Entry in $OccupiedLetters) {
        if (-not [string]::IsNullOrWhiteSpace($Entry)) {
            $Clean = ($Entry.Trim() -replace '[:\\/\s]', '').ToUpper()
            if ($Clean.Length -eq 1) {
                [void]$OccupiedSet.Add($Clean)
            }
        }
    }

    $PrefClean = ($PreferredLetter.Trim() -replace '[:\\/\s]', '').ToUpper()
    if ($PrefClean.Length -eq 1 -and -not $OccupiedSet.Contains($PrefClean)) {
        return "${PrefClean}:"
    }

    # Check G first, then D..Z in alphabetical order
    $Candidates = @('G') + ([char[]]([char]'D'..[char]'Z') | ForEach-Object { [string]$_ })
    foreach ($Candidate in $Candidates) {
        if (-not $OccupiedSet.Contains($Candidate)) {
            return "${Candidate}:"
        }
    }

    return "Z:"
}

function Get-StorageProvidersAudit {
    [CmdletBinding()]
    param(
        [string[]]$AdditionalOccupiedLetters = @()
    )

    # 1. Identify all drive letters occupied by physical disk partitions
    $PhysicalLetters = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    [void]$PhysicalLetters.Add("C")
    try {
        $Partitions = Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter }
        foreach ($Part in $Partitions) {
            $LetterStr = ([string]$Part.DriveLetter).Trim().ToUpper()
            if ($LetterStr.Length -eq 1 -and $LetterStr -match '^[A-Z]$') {
                [void]$PhysicalLetters.Add($LetterStr)
            }
        }
    } catch {}

    foreach ($Extra in $AdditionalOccupiedLetters) {
        if (-not [string]::IsNullOrWhiteSpace($Extra)) {
            $Clean = ($Extra.Trim() -replace '[:\\/\s]', '').ToUpper()
            if ($Clean.Length -eq 1) {
                [void]$PhysicalLetters.Add($Clean)
            }
        }
    }

    $DefaultMount = Resolve-ConflictFreeStreamingMountLetter -OccupiedLetters @($PhysicalLetters) -PreferredLetter "G:"

    $StreamingInfo = [PSCustomObject]@{
        cloud_provider  = "google-drive"
        mount_point     = $DefaultMount
        verify_folder   = "$DefaultMount\My Drive"
        stream_variable = "STREAM"
        detected        = $false
    }

    $FsDrives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
    foreach ($Drive in $FsDrives) {
        $DriveLetter = "$($Drive.Name)".Trim().ToUpper()
        if ($DriveLetter.Length -ne 1) { continue }

        # Never treat a physical disk partition (from Get-Partition) as a virtual cloud streaming mount,
        # even if it happens to contain a backup folder named "My Drive".
        if ($PhysicalLetters.Contains($DriveLetter)) {
            continue
        }

        $RootPath = "${DriveLetter}:\"
        $MyDrivePath = Join-Path $RootPath "My Drive"

        $VolLabel = $null
        try {
            $VolObj = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='${DriveLetter}:'" -ErrorAction SilentlyContinue
            if ($VolObj) { $VolLabel = $VolObj.VolumeName }
        } catch {}

        $IsGoogleDrive = ($Drive.Description -and $Drive.Description -like "*Google Drive*") -or
                         ($VolLabel -and $VolLabel -like "*Google Drive*") -or
                         (Test-Path -LiteralPath $MyDrivePath)
        if ($IsGoogleDrive) {
            $StreamingInfo.cloud_provider  = "google-drive"
            $StreamingInfo.mount_point     = "${DriveLetter}:"
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
        desktop   = $null
        documents = $null
        downloads = $null
        pictures  = $null
        music     = $null
        videos    = $null
    }

    try {
        $RegShell = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction SilentlyContinue
        if ($RegShell) {
            $ShellFolders.desktop   = if ($RegShell.Desktop) { [Environment]::ExpandEnvironmentVariables($RegShell.Desktop) } else { $null }
            $ShellFolders.documents = if ($RegShell.Personal) { [Environment]::ExpandEnvironmentVariables($RegShell.Personal) } else { $null }
            $ShellFolders.downloads = if ($RegShell.'{374DE290-123F-4565-9164-39C4925E467B}') { [Environment]::ExpandEnvironmentVariables($RegShell.'{374DE290-123F-4565-9164-39C4925E467B}') } else { $null }
            $ShellFolders.pictures  = if ($RegShell.'My Pictures') { [Environment]::ExpandEnvironmentVariables($RegShell.'My Pictures') } else { $null }
            $ShellFolders.music     = if ($RegShell.'My Music') { [Environment]::ExpandEnvironmentVariables($RegShell.'My Music') } else { $null }
            $ShellFolders.videos    = if ($RegShell.'My Video') { [Environment]::ExpandEnvironmentVariables($RegShell.'My Video') } else { $null }
        }
    } catch {}

    return [PSCustomObject]@{
        streaming          = $StreamingInfo
        sync_directories   = $SyncedDirectories
        user_shell_folders = $ShellFolders
    }
}
