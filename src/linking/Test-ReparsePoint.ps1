<#
.SYNOPSIS
    NTFS Reparse point and directory junction inspection utility for Reglaze.
.DESCRIPTION
    Inspects filesystem paths to detect NTFS reparse points and directory junctions,
    resolving the underlying target path and verifying target validity.
#>
[CmdletBinding()]
param()

function Get-ReparsePointInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    $Result = [PSCustomObject]@{
        Path           = $Path
        Exists         = $false
        IsReparsePoint = $false
        IsJunction     = $false
        Target         = $null
        TargetExists   = $false
        IsValid        = $false
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return $Result
    }

    $Result.Exists = $true

    try {
        $Item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $IsReparse = ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        $Result.IsReparsePoint = $IsReparse

        if ($IsReparse) {
            $Target = $null

            # Method 1: PowerShell 7 / .NET 6+ LinkTarget property
            if ($Item.PSObject.Properties['LinkTarget'] -and $Item.LinkTarget) {
                $Target = $Item.LinkTarget
            }
            # Method 2: Target property (standard PS Core / WinPS FileSystemProvider)
            elseif ($Item.PSObject.Properties['Target'] -and $Item.Target) {
                if ($Item.Target -is [System.Collections.IEnumerable] -and $Item.Target -isnot [string]) {
                    $Target = ($Item.Target | Select-Object -First 1)
                } else {
                    $Target = "$($Item.Target)"
                }
            }
            # Method 3: Parse parent dir /AL (Windows PowerShell 5.1 compatibility)
            if (-not $Target) {
                try {
                    $Parent = Split-Path -Parent $Path
                    $Leaf = Split-Path -Leaf $Path
                    if (-not $Parent) { $Parent = "." }
                    $DirLines = & cmd.exe /c "dir /AL `"$Parent`" 2>nul"
                    foreach ($Line in $DirLines) {
                        if ($Line -match "<JUNCTION>\s+$([regex]::Escape($Leaf))\s+\[(.*?)\]") {
                            $Target = $Matches[1].Trim()
                            break
                        }
                    }
                } catch {}
            }

            # Method 4: fsutil reparsepoint query fallback
            if (-not $Target) {
                try {
                    $FsOutput = & fsutil reparsepoint query "$Path" 2>nul
                    foreach ($FLine in $FsOutput) {
                        if ($FLine -match "Print Name:\s*(.*)$") {
                            $Target = $Matches[1].Trim()
                            break
                        } elseif ($FLine -match "Substitute Name:\s*(.*)$") {
                            $Target = $Matches[1].Trim()
                            break
                        }
                    }
                } catch {}
            }

            if ($Target) {
                # Clean up Win32 device prefixes like \??\C:\..., Global\D:\..., or Global\??\D:\...
                if ($Target -match '^(?:Global\\|\?\?\\|\\\\\?\\)*([A-Za-z]:\\.*)$') {
                    $Target = $Matches[1]
                } elseif ($Target.StartsWith("\??\")) {
                    $Target = $Target.Substring(4)
                } elseif ($Target.StartsWith("Global\")) {
                    $Target = $Target.Substring(7)
                }
                $Result.Target = $Target
                $Result.IsJunction = $true
                $Result.TargetExists = (Test-Path -LiteralPath $Target)
                $Result.IsValid = $Result.TargetExists
            }
        }
    } catch {
        # Access denied or path error
    }

    return $Result
}

function Test-IsDirectoryJunction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    $Info = Get-ReparsePointInfo -Path $Path
    return ($Info.Exists -and $Info.IsJunction)
}
