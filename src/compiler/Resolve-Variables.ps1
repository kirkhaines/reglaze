<#
.SYNOPSIS
    Variable placeholder resolution engine for Reglaze.
.DESCRIPTION
    Extracts and resolves standardized path variable placeholders (%OS_DRIVE%, %DATA_DRIVE%,
    %STREAM%, %SYNC_<ID>%, and custom variables declared under variables:) across blueprints
    and application manifests.
#>
[CmdletBinding()]
param()

function Get-BlueprintVariables {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Blueprint
    )

    $VarMap = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # 1. OS Disk Variable
    $OsVar = if ($Blueprint.disks.target_os_disk.drive_variable) { $Blueprint.disks.target_os_disk.drive_variable } else { "OS_DRIVE" }
    $VarMap[$OsVar] = "C:"

    # 2. Preserved Disks Variables
    if ($Blueprint.disks.preserved_disks) {
        foreach ($PDisk in $Blueprint.disks.preserved_disks) {
            if ($PDisk.drive_variable -and $PDisk.expected_mount) {
                $VarMap[$PDisk.drive_variable] = $PDisk.expected_mount
            }
        }
    }

    # 3. Streaming Mount Variable
    if ($Blueprint.storage.streaming) {
        $StreamVar = if ($Blueprint.storage.streaming.stream_variable) { $Blueprint.storage.streaming.stream_variable } else { "STREAM" }
        $StreamVal = if ($Blueprint.storage.streaming.verify_folder) { $Blueprint.storage.streaming.verify_folder } else { $Blueprint.storage.streaming.mount_point }
        if ($StreamVal) {
            $VarMap[$StreamVar] = $StreamVal.TrimEnd('\')
        }
    }

    # 4. Sync Root Variables
    if ($Blueprint.storage.sync -and $Blueprint.storage.sync.directories) {
        $SyncDirs = $Blueprint.storage.sync.directories
        $DirProps = if ($SyncDirs -is [System.Collections.IDictionary]) { $SyncDirs.Keys } else { $SyncDirs.PSObject.Properties.Name }
        foreach ($PropName in $DirProps) {
            $DirObj = if ($SyncDirs -is [System.Collections.IDictionary]) { $SyncDirs[$PropName] } else { $SyncDirs.$PropName }
            if ($DirObj.sync_variable -and $DirObj.local_path) {
                $VarMap[$DirObj.sync_variable] = $DirObj.local_path
            }
        }
    }

    # 5. Custom Blueprint Variables (e.g. GAMES_DIR, STEAM_DIR)
    if ($Blueprint.variables) {
        $CustomVars = $Blueprint.variables
        $VarProps = if ($CustomVars -is [System.Collections.IDictionary]) { $CustomVars.Keys } else { $CustomVars.PSObject.Properties.Name }
        foreach ($PropName in $VarProps) {
            $Val = if ($CustomVars -is [System.Collections.IDictionary]) { $CustomVars[$PropName] } else { $CustomVars.$PropName }
            if ($Val) {
                $VarMap[$PropName] = [string]$Val
            }
        }
    }

    # Recursive resolution for variables referencing other variables (e.g., %DATA_DRIVE%\Games)
    $ResolvedMap = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Key in $VarMap.Keys) {
        $ResolvedMap[$Key] = Resolve-VariableString -InputString $VarMap[$Key] -VariableMap $VarMap
    }

    return $ResolvedMap
}

function Resolve-VariableString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$InputString,

        [Parameter(Mandatory=$true)]
        [System.Collections.Generic.Dictionary[string, string]]$VariableMap,

        [int]$MaxDepth = 5
    )

    $Result = $InputString
    $Depth = 0

    while ($Result -match '%([a-zA-Z0-9_]+)%' -and $Depth -lt $MaxDepth) {
        $Depth++
        $MatchesList = [regex]::Matches($Result, '%([a-zA-Z0-9_]+)%')
        $ReplacedAny = $false

        foreach ($Match in $MatchesList) {
            $Token = $Match.Groups[1].Value
            if ($VariableMap.ContainsKey($Token)) {
                $Replacement = $VariableMap[$Token]
                $Result = $Result.Replace("%$Token%", $Replacement)
                $ReplacedAny = $true
            }
        }

        if (-not $ReplacedAny) {
            # Remaining tokens are either environment variables or unknown tokens
            break
        }
    }

    # Normalize consecutive backslashes while preserving UNC network shares (\\server\share)
    if ($Result -notmatch '^\\\\[^\\]') {
        $Result = [regex]::Replace($Result, '\\{2,}', '\')
    }

    return $Result
}

function Test-UnresolvedTokens {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$InputString
    )

    $MatchesList = [regex]::Matches($InputString, '%([a-zA-Z0-9_]+)%')
    $Unresolved = @()

    $StandardEnvVars = @(
        "USERPROFILE", "APPDATA", "LOCALAPPDATA", "PROGRAMFILES", 
        "PROGRAMFILES(X86)", "TEMP", "TMP", "SYSTEMROOT", "PUBLIC", "ALLUSERSPROFILE"
    )

    foreach ($Match in $MatchesList) {
        $Token = $Match.Groups[1].Value
        if ($StandardEnvVars -notcontains $Token.ToUpper()) {
            $Unresolved += $Token
        }
    }

    return ,@($Unresolved)
}
