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
                         (Test-Path -LiteralPath $MyDrivePath -ErrorAction SilentlyContinue)
        if ($IsGoogleDrive) {
            $StreamingInfo.cloud_provider  = "google-drive"
            $StreamingInfo.mount_point     = "${DriveLetter}:"
            $StreamingInfo.verify_folder   = $MyDrivePath
            $StreamingInfo.stream_variable = "STREAM"
            $StreamingInfo.detected        = $true
            break
        }
    }

    # 2. Discover Google Drive for Desktop Synced Folders & Computer Container Name
    $SyncedDirectories = @()
    $DetectedComputerFolderName = "My Computer"
    $DriveFsBase = Join-Path $env:LOCALAPPDATA "Google\DriveFS"
    $DriveFsDb = Join-Path $DriveFsBase "root_preference_sqlite.db"

    if (Test-Path $DriveFsDb -ErrorAction SilentlyContinue) {
        try {
            $TempDb = Join-Path $env:TEMP "reglaze_drivefs_roots_$((Get-Random)).db"
            # Copy with FileShare ReadWrite to avoid locking collisions
            $FileStream = [System.IO.File]::Open($DriveFsDb, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $OutStream = [System.IO.File]::Create($TempDb)
            $FileStream.CopyTo($OutStream)
            $FileStream.Close()
            $OutStream.Close()

            # Locate account metadata_sqlite_db if present to resolve the exact 'Computers' container title (e.g., 'My Computer')
            $TempMetaDb = ""
            $MetaDbFile = Get-ChildItem -Path $DriveFsBase -Filter "metadata_sqlite_db" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($MetaDbFile) {
                try {
                    $TempMetaDb = Join-Path $env:TEMP "reglaze_drivefs_meta_$((Get-Random)).db"
                    $MIn = [System.IO.File]::Open($MetaDbFile.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    $MOut = [System.IO.File]::Create($TempMetaDb)
                    $MIn.CopyTo($MOut)
                    $MIn.Close()
                    $MOut.Close()
                } catch {
                    $TempMetaDb = ""
                }
            }

            if (Get-Command "python" -ErrorAction SilentlyContinue) {
                $PyScript = Join-Path $env:TEMP "reglaze_query_roots_$((Get-Random)).py"
                $PyCode = @'
import sqlite3, json, sys, os
temp_db = sys.argv[1]
temp_meta = sys.argv[2] if len(sys.argv) > 2 else ""
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
doc_ids = []
for r in cursor.fetchall():
    item = {'title': r[0], 'root_path': r[1], 'absolute_path': r[2], 'doc_id': None, 'media_id': None}
    idx = 3
    if has_doc_id:
        item['doc_id'] = r[idx]
        if r[idx]:
            doc_ids.append(str(r[idx]))
        idx += 1
    if has_media_id:
        item['media_id'] = r[idx]
    rows.append(item)
conn.close()

computer_name = None
if temp_meta and os.path.exists(temp_meta) and doc_ids:
    try:
        mconn = sqlite3.connect(temp_meta)
        item_cols = [c[1] for c in mconn.execute("PRAGMA table_info(items);").fetchall()]
        id_col = 'id' if 'id' in item_cols else ('cloud_id' if 'cloud_id' in item_cols else ('doc_id' if 'doc_id' in item_cols else None))
        if id_col and 'stable_id' in item_cols and 'local_title' in item_cols:
            for did in doc_ids:
                q = f"""
                SELECT p_item.local_title
                FROM items c_item
                JOIN parents p ON p.item_stable_id = c_item.stable_id
                JOIN items p_item ON p_item.stable_id = p.parent_stable_id
                WHERE c_item.{id_col} = ?
                LIMIT 1;
                """
                res = mconn.execute(q, (did,)).fetchone()
                if res and res[0]:
                    computer_name = str(res[0])
                    break
        mconn.close()
    except Exception:
        pass

print(json.dumps({'roots': rows, 'computer_name': computer_name}))
'@
                $PyCode | Set-Content -Path $PyScript -Encoding UTF8
                $JsonResult = & python $PyScript $TempDb $TempMetaDb 2>$null
                Remove-Item $PyScript -Force -ErrorAction SilentlyContinue

                if ($JsonResult) {
                    $ParsedPayload = $JsonResult | ConvertFrom-Json
                    if ($ParsedPayload.computer_name) {
                        $DetectedComputerFolderName = [string]$ParsedPayload.computer_name
                    }
                    $Roots = if ($null -ne $ParsedPayload.roots) { @($ParsedPayload.roots) } else { @($ParsedPayload) }
                    foreach ($Root in $Roots) {
                        if (-not $Root.title) { continue }
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

            if (Test-Path $TempDb) { Remove-Item $TempDb -Force -ErrorAction SilentlyContinue }
            if ($TempMetaDb -and (Test-Path $TempMetaDb)) { Remove-Item $TempMetaDb -Force -ErrorAction SilentlyContinue }
        } catch {
            Write-Warning "Could not parse Google Drive sync roots: $($_.Exception.Message)"
        }
    }

    # Fallback check against '<StreamMount>\Other computers' if streaming mount is active
    if ($StreamingInfo.detected -and $StreamingInfo.mount_point) {
        $OtherCompsDir = Join-Path "$($StreamingInfo.mount_point)\" "Other computers"
        if (Test-Path -LiteralPath $OtherCompsDir -ErrorAction SilentlyContinue) {
            $CompFolders = @(Get-ChildItem -LiteralPath $OtherCompsDir -Directory -ErrorAction SilentlyContinue)
            if ($CompFolders.Count -eq 1) {
                $DetectedComputerFolderName = $CompFolders[0].Name
            } elseif ($CompFolders.Count -gt 1 -and $SyncedDirectories.Count -gt 0) {
                $BestFolder = $null
                $BestScore = 0
                foreach ($CF in $CompFolders) {
                    $Score = 0
                    foreach ($SD in $SyncedDirectories) {
                        if (Test-Path -LiteralPath (Join-Path $CF.FullName $SD.cloud_folder) -ErrorAction SilentlyContinue) {
                            $Score++
                        }
                    }
                    if ($Score -gt $BestScore) {
                        $BestScore = $Score
                        $BestFolder = $CF.Name
                    }
                }
                if ($BestFolder) {
                    $DetectedComputerFolderName = $BestFolder
                }
            }
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
        streaming            = $StreamingInfo
        computer_folder_name = $DetectedComputerFolderName
        sync_directories     = $SyncedDirectories
        user_shell_folders   = $ShellFolders
    }
}
