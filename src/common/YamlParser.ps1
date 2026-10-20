<#
.SYNOPSIS
    Zero-dependency pure PowerShell YAML parser for Reglaze.
.DESCRIPTION
    Parses hierarchical YAML documents (dictionaries, lists, scalars, booleans,
    integers, and inline objects) into nested PSCustomObjects without requiring
    external modules or Python packages.
#>
[CmdletBinding()]
param()

function ConvertFrom-ReglazeYaml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [Alias("YamlText")]
        [string]$YamlContent
    )

    $rawLines = $YamlContent -split "\r?\n"
    $lines = [System.Collections.Generic.List[PSCustomObject]]::new()

    for ($i = 0; $i -lt $rawLines.Count; $i++) {
        $raw = $rawLines[$i]
        if ($raw -match '^\s*#' -or [string]::IsNullOrWhiteSpace($raw)) { continue }
        
        $indent = 0
        while ($indent -lt $raw.Length -and $raw[$indent] -eq ' ') { $indent++ }
        
        $content = $raw.Trim()
        if ($content -match '^(.*?)\s+#(?![^"]*"|[^'']*'').*$') {
            $content = $Matches[1].Trim()
        }

        $lines.Add([PSCustomObject]@{
            Indent  = $indent
            Content = $content
            LineNum = $i + 1
        })
    }

    $script:yamlIdx = 0

    function Parse-Scalar([string]$val) {
        $v = $val.Trim()
        if ($v -eq 'true') { return $true }
        if ($v -eq 'false') { return $false }
        if ($v -eq 'null' -or $v -eq '~') { return $null }
        if ($v -eq '{}') { return [PSCustomObject]@{} }
        if ($v -eq '[]') { return @() }
        if ($v -match '^-?\d+$') { return [int64]$v }
        if ($v -match '^-?\d+\.\d+$') { return [double]$v }
        if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) {
            return $v.Substring(1, $v.Length - 2)
        }
        return $v
    }

    function Parse-Block([int]$minIndent) {
        $blockObj = [ordered]@{}
        $blockArr = [System.Collections.Generic.List[object]]::new()
        $blockIsArr = $false

        while ($script:yamlIdx -lt $lines.Count) {
            $item = $lines[$script:yamlIdx]
            if ($item.Indent -lt $minIndent) { break }

            if ($item.Content.StartsWith("- ") -or $item.Content -eq "-") {
                $blockIsArr = $true
                $afterDash = $item.Content.Substring(1).Trim()
                $script:yamlIdx++

                if ([string]::IsNullOrWhiteSpace($afterDash)) {
                    $child = Parse-Block ($item.Indent + 2)
                    $blockArr.Add($child)
                } elseif ($afterDash -match '^([a-zA-Z0-9_\-]+)\s*:\s*(.*)$') {
                    $subObj = [ordered]@{}
                    $k = $Matches[1].Trim()
                    $v = $Matches[2].Trim()
                    if ([string]::IsNullOrWhiteSpace($v)) {
                        $subObj[$k] = Parse-Block ($item.Indent + 4)
                    } else {
                        $subObj[$k] = Parse-Scalar $v
                    }
                    
                    while ($script:yamlIdx -lt $lines.Count -and $lines[$script:yamlIdx].Indent -eq ($item.Indent + 2) -and -not $lines[$script:yamlIdx].Content.StartsWith("-")) {
                        $subLine = $lines[$script:yamlIdx]
                        if ($subLine.Content -match '^([a-zA-Z0-9_\-]+)\s*:\s*(.*)$') {
                            $sk = $Matches[1].Trim()
                            $sv = $Matches[2].Trim()
                            $script:yamlIdx++
                            if ([string]::IsNullOrWhiteSpace($sv)) {
                                $subObj[$sk] = Parse-Block ($subLine.Indent + 2)
                            } else {
                                $subObj[$sk] = Parse-Scalar $sv
                            }
                        } else {
                            break
                        }
                    }
                    $blockArr.Add([PSCustomObject]$subObj)
                } else {
                    $blockArr.Add((Parse-Scalar $afterDash))
                }
            } elseif ($item.Content -match '^([a-zA-Z0-9_\-]+)\s*:\s*(.*)$') {
                $key = $Matches[1].Trim()
                $valStr = $Matches[2].Trim()
                $script:yamlIdx++

                if ([string]::IsNullOrWhiteSpace($valStr)) {
                    $child = Parse-Block ($item.Indent + 2)
                    $blockObj[$key] = $child
                } else {
                    $blockObj[$key] = Parse-Scalar $valStr
                }
            } else {
                $script:yamlIdx++
            }
        }

        if ($blockIsArr) {
            return ,$blockArr.ToArray()
        }
        return [PSCustomObject]$blockObj
    }

    return Parse-Block 0
}

function Get-ReglazeBlueprintObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Blueprint file not found at: $Path"
    }

    $Content = Get-Content -Raw -LiteralPath $Path -Encoding UTF8
    return ConvertFrom-ReglazeYaml -YamlContent $Content
}
